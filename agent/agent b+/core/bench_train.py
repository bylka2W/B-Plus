"""Staged training-speed benchmark for the 606M (1440-dim) model.

Keeps model size, 60k steps and quality FIXED; only squeezes execution
throughput. Each stage prints tokens/sec, steps/sec, VRAM and ETA immediately.
No subprocess calls (uses torch CUDA stats). Run in foreground.
"""
import sys, time
from pathlib import Path
AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+")
sys.path.insert(0, str(AGENT_ROOT))
import torch
import torch.nn as nn
from torch.utils.data import DataLoader
from core.train_new_model import MixedZigRuDataset
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m

SEQ, BS, STEPS = 1024, 2, 25
WARM = 5
TOK = r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json"

if not torch.cuda.is_available():
    raise RuntimeError("CUDA is required for training; refusing to fall back to CPU")
DEV = "cuda:0"
print("DEVICE: cuda:0", flush=True)
print("GPU:", torch.cuda.get_device_name(0), flush=True)
print("CUDA:", torch.cuda.is_available(), flush=True)

print("building dataset (seq=%d)..." % SEQ, flush=True)
tok = ZigTokenizer.load(TOK)
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=8_000_000)
tr, va = torch.utils.data.random_split(ds, [len(ds)-min(len(ds)//20,200), min(len(ds)//20,200)])
print("dataset chunks=%d" % len(ds), flush=True)


def run_stage(name, tf32, fused, pin, use_compile):
    if tf32:
        torch.backends.cuda.matmul.allow_tf32 = True
        torch.backends.cudnn.allow_tf32 = True
    model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).to(DEV)
    if use_compile:
        try:
            model = torch.compile(model, mode="default")
        except Exception as e:
            print("  [compile skipped: %s]" % e, flush=True)
    model.train()
    opt = torch.optim.AdamW(model.parameters(), lr=3e-4, betas=(0.9, 0.95),
                            weight_decay=0.1, fused=fused)
    dl = DataLoader(tr, batch_size=BS, shuffle=True, drop_last=True,
                    num_workers=0, pin_memory=pin)
    it = iter(dl)
    t0 = time.monotonic()
    last = 0.0
    for i in range(STEPS):
        try:
            xb, yb = next(it)
        except StopIteration:
            it = iter(dl); xb, yb = next(it)
        xb = xb.to(DEV, non_blocking=pin); yb = yb.to(DEV, non_blocking=pin)
        opt.zero_grad(set_to_none=True)
        with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
            _, loss = model(xb, targets=yb)
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        last = loss.item()
    dt = time.monotonic() - t0
    eff = STEPS - WARM
    tok_per_s = eff * SEQ * BS / dt
    step_s = eff / dt
    vram = torch.cuda.memory_allocated()/1e9
    print("=== %s ===" % name, flush=True)
    print("  DEVICE=%s  loss=%.3f" % (DEV, last), flush=True)
    print("  STEPS/SEC=%.3f  TOKENS/SEC=%d" % (step_s, int(tok_per_s)), flush=True)
    print("  VRAM=%.1fGB" % vram, flush=True)
    print("  ETA(60000)=%.1fh" % (60000/step_s/3600), flush=True)
    del model, opt, dl
    torch.cuda.empty_cache()


print("\n########## STAGED BENCHMARK (606M, seq=1024, bs=2) ##########", flush=True)
run_stage("S0 CUDA+AMP",            tf32=False, fused=False, pin=False, use_compile=False)
run_stage("S1 +TF32",               tf32=True,  fused=False, pin=False, use_compile=False)
run_stage("S2 +fused AdamW",        tf32=True,  fused=True,  pin=False, use_compile=False)
run_stage("S3 +pinned/nonblock",    tf32=True,  fused=True,  pin=True,  use_compile=False)
run_stage("S4 +torch.compile",      tf32=True,  fused=True,  pin=True,  use_compile=True)
print("\nDONE", flush=True)
