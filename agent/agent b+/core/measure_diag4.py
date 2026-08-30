import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(r"C:\B-Plus\agent\agent b+")))
import torch
from core.train_new_model import MixedZigRuDataset
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m
from torch.utils.data import DataLoader

SEQ, BS, NSTEPS = 1024, 2, 2
tok = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json")
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=8_000_000)
tr, _ = torch.utils.data.random_split(ds, [len(ds)-200, 200])
dl = DataLoader(tr, batch_size=BS, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)
torch.backends.cuda.enable_flash_sdp(False); torch.backends.cuda.enable_mem_efficient_sdp(True); torch.backends.cuda.enable_math_sdp(True)
DEV = "cuda:0"

def run(label, step_fn):
    model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).cuda()
    opt = torch.optim.AdamW(model.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=True)
    wq = model.layers[0].attention.wq.weight
    it = iter(dl); out = []
    for i in range(NSTEPS):
        b = next(it); x = b[0].to(DEV, non_blocking=True); y = b[1].to(DEV, non_blocking=True)
        p0 = wq.data_ptr()
        t0 = time.monotonic()
        with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
            _, loss = model(x, targets=y)
        t1 = time.monotonic(); loss.backward(); t2 = time.monotonic()
        step_fn(model, opt, i)
        p1 = wq.data_ptr()
        t3 = time.monotonic()
        out.append((t1-t0, t2-t1, t3-t2, p1 != p0))
    print(f"[{label}]", " | ".join(f"s{i+1}: fwd={a*1000:.0f} bwd={b*1000:.0f} post={c*1000:.0f} reparam={d} tot={(a+b+c)*1000:.0f}ms" for i,(a,b,c,d) in enumerate(out)), flush=True)

def adamw(model, opt, i):
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    opt.step(); opt.zero_grad(set_to_none=True)

def adamw_emptycache(model, opt, i):
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    opt.step(); opt.zero_grad(set_to_none=True)
    torch.cuda.empty_cache()

def sgd_clip(model, opt, i):
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    with torch.no_grad():
        for p in model.parameters():
            if p.grad is not None: p -= 3e-4 * p.grad
    model.zero_grad(set_to_none=True)

print("ADAMW (reparam check)", flush=True); run("ADAMW", adamw)
print("ADAMW + empty_cache()", flush=True); run("ADAMW-EC", adamw_emptycache)
print("SGD + clip", flush=True); run("SGD-CLIP", sgd_clip)
print("DONE", flush=True)
