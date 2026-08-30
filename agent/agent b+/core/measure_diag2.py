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

torch.backends.cuda.enable_flash_sdp(False)
torch.backends.cuda.enable_mem_efficient_sdp(True)
torch.backends.cuda.enable_math_sdp(True)
torch.backends.cuda.matmul.allow_tf32 = True
torch.backends.cudnn.allow_tf32 = True
torch.backends.cudnn.benchmark = False
DEV = "cuda:0"

def make_model():
    return build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).cuda()

def run(label, mutate):
    model = make_model()
    opt = torch.optim.AdamW(model.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=True)
    it = iter(dl)
    out = []
    for i in range(NSTEPS):
        b = next(it)
        x = b[0].to(DEV, non_blocking=True); y = b[1].to(DEV, non_blocking=True)
        t0 = time.monotonic()
        with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
            _, loss = model(x, targets=y)
        t1 = time.monotonic()
        loss.backward()
        t2 = time.monotonic()
        mutate(model, opt, i)
        t3 = time.monotonic()
        out.append((t1-t0, t2-t1, t3-t2))
    print(f"[{label}]", " | ".join(f"s{i+1}: fwd={a*1000:.0f} bwd={b*1000:.0f} post={c*1000:.0f} tot={(a+b+c)*1000:.0f}ms" for i,(a,b,c) in enumerate(out)), flush=True)

def flush_denorm(model):
    with torch.no_grad():
        for p in model.parameters():
            if p.dtype.is_floating_point:
                p.data.masked_fill_(p.data.abs() < 1e-32, 0.0)

# G: real backward, then ZERO grads so optimizer.step() is ~no-op (tests step MECHANISM / state alloc)
def g_mutate(model, opt, i):
    for p in model.parameters():
        if p.grad is not None: p.grad = None
    opt.step(); opt.zero_grad(set_to_none=True)
# H: real optimizer.step, then flush denormals (tests DENORMAL/value hypothesis)
def h_mutate(model, opt, i):
    opt.step(); opt.zero_grad(set_to_none=True)
    flush_denorm(model)
# K: plain in-place SGD update, NO AdamW state (tests if ANY real value change slows fwd)
def k_mutate(model, opt, i):
    with torch.no_grad():
        for p in model.parameters():
            if p.grad is not None:
                p -= 3e-4 * p.grad
    model.zero_grad(set_to_none=True)

print("G: zero-grad step (no real update)", flush=True); run("G", g_mutate)
print("H: real step + flush denormals", flush=True);     run("H", h_mutate)
print("K: plain SGD in-place (no AdamW state)", flush=True); run("K", k_mutate)
print("DONE", flush=True)
