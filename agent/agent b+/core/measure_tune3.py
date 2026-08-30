import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(r"C:\B-Plus\agent\agent b+")))
import torch
from core.train_new_model import MixedZigRuDataset
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m
from torch.utils.data import DataLoader

SEQ, BS, NSTEPS = 1024, 2, 6
tok = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json")
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=8_000_000)
tr, _ = torch.utils.data.random_split(ds, [len(ds)-200, 200])
dl = DataLoader(tr, batch_size=BS, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)
torch.backends.cuda.enable_flash_sdp(False); torch.backends.cuda.enable_mem_efficient_sdp(True); torch.backends.cuda.enable_math_sdp(True)
DEV = "cuda:0"; syn = torch.cuda.synchronize

def make_bf16():
    return build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).to(DEV, dtype=torch.bfloat16)

def run(label, model, opt):
    it = iter(dl); out=[]
    for i in range(NSTEPS):
        b = next(it); x = b[0].to(DEV, non_blocking=True); y = b[1].to(DEV, non_blocking=True)
        syn(); t0=time.monotonic()
        with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
            _, loss = model(x, targets=y)
        syn(); t1=time.monotonic()
        loss.backward(); syn(); t2=time.monotonic()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step(); opt.zero_grad(set_to_none=True)
        syn(); t3=time.monotonic()
        out.append((t1-t0, t2-t1, t3-t2))
        if i >= 1:
            print(f"  s{i+1}: fwd={ (t1-t0)*1000:.0f} bwd={ (t2-t1)*1000:.0f} post={ (t3-t2)*1000:.0f} tot={ (t3-t0)*1000:.0f}ms", flush=True)
    mean = sum(o[0]+o[1]+o[2] for o in out[1:])/(NSTEPS-1)
    print(f"[{label}] mean tot={mean:.0f}ms -> {int(BS*SEQ/mean)} tok/s", flush=True)

torch.set_float32_matmul_precision('high')
for mode in ["max-autotune", "reduce-overhead"]:
    print(f"=== torch.compile mode={mode} ===", flush=True)
    m = make_bf16()
    t0=time.monotonic(); mc = torch.compile(m, mode=mode); print(f"  compile() call {time.monotonic()-t0:.1f}s", flush=True)
    o = torch.optim.AdamW(mc.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=True)
    run(mode, mc, o)
print("DONE", flush=True)
