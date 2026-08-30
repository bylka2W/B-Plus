import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(r"C:\B-Plus\agent\agent b+")))
import torch
from core.train_new_model import MixedZigRuDataset
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m
from torch.utils.data import DataLoader

mode = sys.argv[1] if len(sys.argv) > 1 else "plain"
SEQ, BS, NSTEPS = 1024, 2, 6
tok = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json")
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=8_000_000)
tr, _ = torch.utils.data.random_split(ds, [len(ds)-200, 200])
dl = DataLoader(tr, batch_size=BS, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)
torch.backends.cuda.enable_flash_sdp(False); torch.backends.cuda.enable_mem_efficient_sdp(True); torch.backends.cuda.enable_math_sdp(True)
DEV = "cuda:0"; syn = torch.cuda.synchronize
model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).cuda()
if mode == "optbf16":
    model = model.to(torch.bfloat16)  # params bf16 -> AdamW state bf16 (2.4GB not 4.8GB)
opt = torch.optim.AdamW(model.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=True)
sgd_opt = torch.optim.SGD(model.parameters(), lr=3e-4, momentum=0.9, weight_decay=0.1)
it = iter(dl)
if mode == "warmsgd":
    # allocate AdamW state once via a zero-grad step, then we use SGD in the loop
    for p in model.parameters():
        if p.grad is None: p.grad = torch.zeros_like(p)
    opt.step(); model.zero_grad(set_to_none=True)
    print("  (state pre-allocated via zero-grad step)", flush=True)
if mode == "idle4g":
    dummy = torch.empty(int(4.8e9)//4, dtype=torch.float32, device=DEV)
    print(f"  (allocated idle 4.8GB tensor; model VRAM will be ~{torch.cuda.memory_allocated()/1e9:.1f}GB)", flush=True)
print(f"=== mode={mode} ===", flush=True)
for i in range(NSTEPS):
    b = next(it); x = b[0].to(DEV, non_blocking=True); y = b[1].to(DEV, non_blocking=True)
    syn(); t0=time.monotonic()
    with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
        _, loss = model(x, targets=y)
    syn(); t1=time.monotonic()
    loss.backward(); syn(); t2=time.monotonic()
    if mode == "opt":
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
    elif mode == "sgd":
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        with torch.no_grad():
            for p in model.parameters():
                if p.grad is not None: p -= 3e-4 * p.grad
    elif mode == "adamw0":
        # AdamW but lr=0: m,v get REAL values, weights UNCHANGED
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.param_groups[0]["lr"] = 0.0
        opt.step()
    elif mode == "warmsgd":
        # state pre-allocated (zero-grad step done once before loop), then SGD
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        with torch.no_grad():
            for p in model.parameters():
                if p.grad is not None: p -= 3e-4 * p.grad
    elif mode == "sgdmom":
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        sgd_opt.step()
    model.zero_grad(set_to_none=True)
    syn(); t3=time.monotonic()
    print(f"  s{i+1}: fwd={ (t1-t0)*1000:.0f} bwd={ (t2-t1)*1000:.0f} post={ (t3-t2)*1000:.0f} tot={ (t3-t0)*1000:.0f}ms  VRAM={torch.cuda.memory_allocated()/1e9:.1f}GB", flush=True)
print("DONE", flush=True)
