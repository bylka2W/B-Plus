import sys, time
from pathlib import Path
AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+")
sys.path.insert(0, str(AGENT_ROOT))
import torch
from core.train_new_model import MixedZigRuDataset, Trainer
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m
from torch.utils.data import DataLoader

SEQ, BS = 1024, 2
tok = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json")
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=8_000_000)
tr, va = torch.utils.data.random_split(ds, [len(ds)-min(len(ds)//20,200), min(len(ds)//20,200)])
tl = DataLoader(tr, batch_size=BS, shuffle=True, drop_last=True, num_workers=0)
vl = DataLoader(va, batch_size=BS, shuffle=False, num_workers=0)
model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000)
trainer = Trainer(model, tok, lr=3e-4, warmup_steps=1, total_steps=2)
print("DEVICE:", next(model.parameters()).device, "trainer.device=", trainer.device, flush=True)
batch = next(iter(tl))
t0 = time.monotonic()
loss = trainer.train_step(batch)
dt = time.monotonic() - t0
print(f"ONE STEP time = {dt:.3f}s  loss={loss:.4f}", flush=True)
print(f"=> speed {1/dt:.3f} steps/s ; ETA 60000 steps = {60000*dt/3600:.1f} h", flush=True)
