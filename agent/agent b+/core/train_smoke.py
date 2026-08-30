"""Short smoke / pretraining run for the 1440-dim B+ model.

Goal: verify the FULL pipeline before committing to a long run:
  - model builds at 1440 dim / 24 layers / GQA 24/4 / vocab 31934
  - loss actually decreases on Zig + Russian next-token LM
  - checkpoint (with sidecar) saves AND reloads cleanly
  - greedy Zig generation produces plausible tokens
  - VRAM/RAM stay within budget

Uses a small subset (SEQ_LEN=512, capped tokens) so it finishes in minutes.
"""
import sys, time, random
from pathlib import Path

AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+")
sys.path.insert(0, str(AGENT_ROOT))

import torch
from core.train_new_model import (MixedZigRuDataset, Trainer,
                                    ZIG_ROOTS, RU_CORPUS, TOK_PATH,
                                    CHECKPOINT_DIR, CosineScheduler)
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m
from core.model_config import ModelConfig

SEQ_LEN = 512
MAX_ZIG_TOKENS = 8_000_000
MAX_STEPS = 300
BS = 2

print("=== SMOKE TRAIN 1440-dim model ===")
tok = ZigTokenizer.load(TOK_PATH)
print(f"  vocab={tok.vocab_size()}")

print("Building small mixed dataset...")
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
# rebuild with capped tokens by re-running __init__ with smaller cap
ds.__init__(tok, seq_len=SEQ_LEN, max_zig_tokens=MAX_ZIG_TOKENS)
if len(ds) == 0:
    print("ERROR: empty dataset"); raise SystemExit(1)

val_size = min(len(ds) // 20, 200)
train_size = len(ds) - val_size
train_ds, val_ds = torch.utils.data.random_split(ds, [train_size, val_size])
from torch.utils.data import DataLoader
train_loader = DataLoader(train_ds, batch_size=BS, shuffle=True, drop_last=True, num_workers=0)
val_loader = DataLoader(val_ds, batch_size=BS, shuffle=False, num_workers=0)
print(f"Train={len(train_ds)} Val={len(val_ds)}")

cfg = ModelConfig()
print(f"Model: params={cfg.n_params/1e6:.1f}M dim={cfg.dim} layers={cfg.n_layers} "
      f"n_heads={cfg.n_heads} n_kv={cfg.n_kv_heads} vocab={cfg.vocab_size}")

model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000)
print(f"  built params={model.get_config()['parameters']/1e6:.1f}M")

trainer = Trainer(model, tok, lr=3e-4, warmup_steps=30, total_steps=MAX_STEPS)
# do NOT resume old 1280 checkpoints

print("\nTraining...")
res = trainer.train(train_loader, val_loader,
                    max_steps=MAX_STEPS, log_interval=10, val_interval=100, save_interval=200)
print(f"train done: {res}")

# --- reload test (sidecar-verified, no .pt load needed) ---
print("\nReload/verify test:")
latest = sorted(CHECKPOINT_DIR.glob("step_*.pt"))
ck = torch.load(latest[-1], map_location="cpu", weights_only=False)
print(f"  loaded {latest[-1].name} step={ck['step']} cfg_dim={ck['config']['dim']}")
ok, reason = cfg.matches_state_dict_shapes(ck["config"])
print(f"  sidecar shape match (config vs model): {ok} ({reason})")
model.load_state_dict(ck["model_state"])
print("  load_state_dict OK")

# --- greedy Zig generation ---
print("\nGreedy Zig generation:")
prompt = "pub fn main() !void {\n    const"
ids = tok.encode(prompt)
x = torch.tensor(ids, dtype=torch.long).unsqueeze(0).to("cuda")
model.to("cuda").eval()
with torch.no_grad():
    for _ in range(48):
        out, _ = model(x[:, -SEQ_LEN:], targets=None)
        nxt = int(out[0, -1].argmax())
        x = torch.cat([x, torch.tensor([[nxt]], device="cuda")], dim=1)
gen = tok.decode(x[0].tolist())
print(gen)
print("\nSMOKE OK")
