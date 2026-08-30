import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(r"C:\B-Plus\agent\agent b+")))
import torch
from core.model import build_model_600m, apply_rotary_emb, precompute_freqs_cis
from core.train_new_model import MixedZigRuDataset
from knowledge.tokenizer import ZigTokenizer
from torch.utils.data import DataLoader

# 1) numeric correctness vs reference complex rotation
torch.manual_seed(0)
D = 8
x = torch.randn(1, 2, 4, D, dtype=torch.bfloat16)
t = torch.arange(4).float()
freqs = torch.outer(t, 1.0/(10000.0**(torch.arange(0, D//2).float()/(D//2))))
ref_cos, ref_sin = torch.cos(freqs), torch.sin(freqs)
x1, x2 = x[..., :D//2], x[..., D//2:]
ref = torch.cat([x1*ref_cos - x2*ref_sin, x1*ref_sin + x2*ref_cos], dim=-1)
cos, sin = precompute_freqs_cis(D, 4)
got = apply_rotary_emb(x, cos, sin)
print("RoPE real vs reference max abs diff:", (got.float()-ref.float()).abs().max().item(), flush=True)

# 2) training forward finite-loss check
SEQ, BS = 1024, 2
tok = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json")
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=2_000_000)
tr, _ = torch.utils.data.random_split(ds, [len(ds)-200, 200])
dl = DataLoader(tr, batch_size=BS, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)
torch.backends.cuda.enable_flash_sdp(False); torch.backends.cuda.enable_mem_efficient_sdp(True); torch.backends.cuda.enable_math_sdp(True)
DEV="cuda:0"; syn=torch.cuda.synchronize
model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).to(DEV, dtype=torch.bfloat16)
opt = torch.optim.AdamW(model.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=True)
it = iter(dl)
for i in range(3):
    b=next(it); x=b[0].to(DEV,non_blocking=True); y=b[1].to(DEV,non_blocking=True)
    with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
        _, loss = model(x, targets=y)
    loss.backward(); torch.nn.utils.clip_grad_norm_(model.parameters(),1.0)
    opt.step(); opt.zero_grad(set_to_none=True)
    print(f"  step {i+1} loss={float(loss):.4f} finite={torch.isfinite(loss).item()}", flush=True)

# 3) compile no longer warns about complex
print("--- compile test ---", flush=True)
mc = torch.compile(model)
b=next(it); x=b[0].to(DEV,non_blocking=True); y=b[1].to(DEV,non_blocking=True)
with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
    _, loss = mc(x, targets=y)
print("compiled fwd loss finite:", torch.isfinite(loss).item(), flush=True)
print("DONE", flush=True)
