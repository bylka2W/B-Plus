import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(r"C:\B-Plus\agent\agent b+")))
import torch
from core.train_new_model import MixedZigRuDataset
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m
from torch.utils.data import DataLoader

SEQ, BS, NSTEPS = 1024, 2, 3
tok = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json")
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=8_000_000)
tr, _ = torch.utils.data.random_split(ds, [len(ds)-200, 200])
dl = DataLoader(tr, batch_size=BS, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)
torch.backends.cuda.enable_flash_sdp(False); torch.backends.cuda.enable_mem_efficient_sdp(True); torch.backends.cuda.enable_math_sdp(True)
DEV = "cuda:0"

def stats(name, t):
    t = t.float()
    with torch.no_grad():
        nan = torch.isnan(t).sum().item(); inf = torch.isinf(t).sum().item()
        d = t[t != 0]
        den = (d.abs() < 1e-20).sum().item() if d.numel() else 0
        print(f"    {name}: nan={nan} inf={inf} den<1e-20={den} min={t.min().item():.3e} max={t.max().item():.3e} absmean={t.abs().mean().item():.3e}", flush=True)

def run(label, opt_fn, inspect=False):
    model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).cuda()
    it = iter(dl)
    for i in range(NSTEPS):
        b = next(it)
        x = b[0].to(DEV, non_blocking=True); y = b[1].to(DEV, non_blocking=True)
        t0 = time.monotonic()
        with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
            _, loss = model(x, targets=y)
        t1 = time.monotonic(); loss.backward(); t2 = time.monotonic()
        if inspect and i == 0:
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            stats("  grad(tok_emb) BEFORE", model.tok_emb.weight.grad)
        opt_fn(model, i)
        t3 = time.monotonic()
        if inspect and i == 0:
            stats("  tok_emb AFTER", model.tok_emb.weight)
            stats("  output  AFTER", model.output.weight)
            stats("  wq L0   AFTER", model.layers[0].attention.wq.weight)
        print(f"[{label}] s{i+1}: fwd={(t1-t0)*1000:.0f} bwd={(t2-t1)*1000:.0f} post={(t3-t2)*1000:.0f} tot={(t3-t0)*1000:.0f}ms", flush=True)

def adamw_fused(model, i):
    if not hasattr(model, '_opt_f'):
        model._opt_f = torch.optim.AdamW(model.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=True)
    if i == 0: torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    model._opt_f.step(); model._opt_f.zero_grad(set_to_none=True)

def adamw_nofuse(model, i):
    if not hasattr(model, '_opt_n'):
        model._opt_n = torch.optim.AdamW(model.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=False)
    if i == 0: torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    model._opt_n.step(); model._opt_n.zero_grad(set_to_none=True)

def sgd_inplace(model, i):
    with torch.no_grad():
        for p in model.parameters():
            if p.grad is not None: p -= 3e-4 * p.grad
    model.zero_grad(set_to_none=True)

print("== AdamW fused (inspect weights) ==", flush=True)
m = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).cuda()
m._opt_f = torch.optim.AdamW(m.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=True)
run("ADAMW-F", adamw_fused, inspect=True)
print("== AdamW NON-fused ==", flush=True)
m2 = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).cuda()
m2._opt_n = torch.optim.AdamW(m2.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=False)
run("ADAMW-NF", adamw_nofuse)
print("== SGD in-place ==", flush=True)
run("SGD", sgd_inplace)
print("DONE", flush=True)
