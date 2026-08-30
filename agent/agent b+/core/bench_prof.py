import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(r"C:\B-Plus\agent\agent b+")))
import torch
from torch.profiler import profile, ProfilerActivity
from core.train_new_model import MixedZigRuDataset
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m
from torch.utils.data import DataLoader

SEQ, BS, NWARM, NPROF = 1024, 2, 5, 10
tok = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json")
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=8_000_000)
tr, _ = torch.utils.data.random_split(ds, [len(ds)-200, 200])
dl = DataLoader(tr, batch_size=BS, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)
torch.backends.cuda.enable_flash_sdp(False); torch.backends.cuda.enable_mem_efficient_sdp(True); torch.backends.cuda.enable_math_sdp(True)
DEV="cuda:0"; syn=torch.cuda.synchronize
model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).to(DEV, dtype=torch.bfloat16)
opt = torch.optim.AdamW(model.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=True)
it = iter(dl)
def step():
    b = next(it); x=b[0].to(DEV,non_blocking=True); y=b[1].to(DEV,non_blocking=True)
    with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
        _, loss = model(x, targets=y)
    loss.backward(); torch.nn.utils.clip_grad_norm_(model.parameters(),1.0)
    opt.step(); opt.zero_grad(set_to_none=True)
print("warmup...", flush=True)
for _ in range(NWARM): step(); syn()
print("profiling...", flush=True)
with profile(activities=[ProfilerActivity.CUDA], record_shapes=True) as prof:
    for _ in range(NPROF):
        step(); syn()
print("=== TOP CUDA OPS by self CUDA time ===", flush=True)
print(prof.key_averages(group_by_input_shape=True).table(sort_by="self_cuda_time_total", row_limit=25), flush=True)
print("=== complex-tensor ops (FX) ===", flush=True)
try:
    gm = torch.fx.symbolic_trace(model)
    for n in gm.graph.nodes:
        if any("complex" in str(t) for t in getattr(n, 'meta', {}).get('tensor_meta', []) if False):
            pass
except Exception as e:
    print("fx trace skipped:", e, flush=True)
print("DONE", flush=True)
