"""Measure real training throughput at the FULL-run config (seq=1024, bs=2).

Per-step speed is independent of dataset size, so we use a small 8M-token
subset to get steps/sec + ETA for 60000 steps quickly. Unbuffered (-u).
"""
import sys, time, random
from pathlib import Path
AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+")
sys.path.insert(0, str(AGENT_ROOT))
import torch
from core.train_new_model import MixedZigRuDataset, Trainer
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m

SEQ, BS, STEPS = 1024, 2, 150
tok = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json")
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=8_000_000)
val = min(len(ds)//20, 200); tr = len(ds)-val
tr_ds, va_ds = torch.utils.data.random_split(ds, [tr, val])
from torch.utils.data import DataLoader
tl = DataLoader(tr_ds, batch_size=BS, shuffle=True, drop_last=True, num_workers=0)
vl = DataLoader(va_ds, batch_size=BS, shuffle=False, num_workers=0)
print(f"dataset chunks={len(ds)} seq={SEQ} bs={BS}", flush=True)

model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000)
print(f"params={model.get_config()['parameters']/1e6:.1f}M", flush=True)
trainer = Trainer(model, tok, lr=3e-4, warmup_steps=20, total_steps=STEPS)

t0 = time.monotonic()
res = trainer.train(tl, vl, max_steps=STEPS, log_interval=10, val_interval=100000, save_interval=100000)
dt = time.monotonic() - t0
spd = STEPS / dt
print(f"\nMEASURE: {STEPS} steps in {dt:.1f}s -> {spd:.3f} steps/s", flush=True)
print(f"ETA for 60000 steps @ seq={SEQ} bs={BS}: {60000/spd/3600:.1f} h ({60000/spd/60:.0f} min)", flush=True)
vh = torch.cuda.memory_allocated()/1e9
print(f"VRAM allocated: {vh:.1f} GB (torch); total reserved {torch.cuda.memory_reserved()/1e9:.1f} GB", flush=True)
