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
syn = torch.cuda.synchronize

def run(label, step_fn):
    model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).cuda()
    opt = torch.optim.AdamW(model.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=True)
    it = iter(dl); out=[]
    for i in range(NSTEPS):
        b = next(it); x = b[0].to(DEV, non_blocking=True); y = b[1].to(DEV, non_blocking=True)
        syn()
        t0=time.monotonic()
        with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
            _, loss = model(x, targets=y)
        syn(); t1=time.monotonic()
        loss.backward(); syn(); t2=time.monotonic()
        step_fn(model, opt, i)
        syn(); t3=time.monotonic()
        out.append((t1-t0, t2-t1, t3-t2))
    print(f"[{label}]", " | ".join(f"s{i+1}: fwd={a*1000:.0f} bwd={b*1000:.0f} post={c*1000:.0f} tot={(a+b+c)*1000:.0f}ms" for i,(a,b,c) in enumerate(out)), flush=True)

def adamw_clip(model, opt, i):
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    opt.step(); opt.zero_grad(set_to_none=True)
def adamw_noclip(model, opt, i):
    opt.step(); opt.zero_grad(set_to_none=True)
def sgd_noclip(model, opt, i):
    with torch.no_grad():
        for p in model.parameters():
            if p.grad is not None: p -= 3e-4 * p.grad
    model.zero_grad(set_to_none=True)
def clip_only(model, opt, i):
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    model.zero_grad(set_to_none=True)
def adamw_clip_scalar(model, opt, i):
    # scalar clip: just scale grads by 0.5 in-place, NO global norm computation
    with torch.no_grad():
        for p in model.parameters():
            if p.grad is not None: p.grad.mul_(0.5)
    opt.step(); opt.zero_grad(set_to_none=True)

print("1 AdamW+clip", flush=True); run("ADAMW+CLIP", adamw_clip)
print("2 AdamW no clip", flush=True); run("ADAMW-NOCLIP", adamw_noclip)
print("3 SGD no clip", flush=True); run("SGD-NOCLIP", sgd_noclip)
print("4 clip ONLY (no opt)", flush=True); run("CLIP-ONLY", clip_only)
print("5 AdamW + SCALAR clip (no global norm)", flush=True); run("ADAMW-SCALAR", adamw_clip_scalar)
print("DONE", flush=True)
