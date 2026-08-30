"""Measure steady-state throughput using the REAL Trainer (fused AdamW, TF32,
pin_memory, non_blocking). This is the config the full 60k run will use."""
import sys, time
from pathlib import Path
AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+\core")
sys.path.insert(0, str(AGENT_ROOT.parent))
import torch
from core.train_new_model import MixedZigRuDataset, Trainer
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m
from torch.utils.data import DataLoader

SEQ, BS, N = 1024, 2, 12
if not torch.cuda.is_available():
    raise RuntimeError("CUDA required")
TOK = r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json"
tok = ZigTokenizer.load(TOK)
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=8_000_000)
tr, _ = torch.utils.data.random_split(ds, [len(ds)-200, 200])
dl = DataLoader(tr, batch_size=BS, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)
model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000)
trainer = Trainer(model, tok, lr=3e-4, warmup_steps=2, total_steps=N)
print("DEVICE:", trainer.device, "fused_opt:", True, flush=True)
it = iter(dl)
t0 = time.monotonic()
for i in range(N):
    batch = next(it)
    loss = trainer.train_step(batch)
dt = time.monotonic() - t0
print(f"steps={N} dt={dt:.1f}s  steps/sec={N/dt:.3f}  tok/sec={int(N*SEQ*BS/dt)}", flush=True)
print(f"ETA(60000 steps, seq={SEQ}, bs={BS}) = {60000/(N/dt)/3600:.1f}h", flush=True)
