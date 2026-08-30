import os
import sys
import json
import time
import math
import random
from pathlib import Path
from collections import Counter

import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader

AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+")
sys.path.insert(0, str(AGENT_ROOT))

from core.model import build_model_600m
from knowledge.tokenizer import ZigTokenizer, iter_zig_files, read_file

CHECKPOINT_DIR = AGENT_ROOT / "checkpoints"
LOG_DIR = AGENT_ROOT / "logs"
CORPUS_DIR = AGENT_ROOT / "knowledge" / "corpus"

ZIG_ROOTS = [Path(r"C:\Users\Local\zig"), Path(r"C:\B-Plus\zig")]
RU_CORPUS = CORPUS_DIR / "russian_corpus.jsonl"
TOK_PATH = CORPUS_DIR / "ru_zig_tokenizer.json"

SEQ_LEN = 1024
RU_RATIO = 0.10  # 10% conversation (Russian), 90% code (Zig)


def read_russian_texts(path):
    texts = []
    if path.exists():
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    texts.append(obj.get("text", ""))
                except json.JSONDecodeError:
                    texts.append(line)
    return texts


class MixedZigRuDataset(Dataset):
    """90% Zig next-token chunks, 10% Russian next-token chunks.

    Zig source dominates, so Russian chunks are repeated (shuffled) until they
    make up RU_RATIO of the total chunk count. Both streams are pure
    next-token language modelling on the Russian+Zig tokenizer.

    Token streams are stored as a single flat int64 tensor with chunk offsets
    (no per-chunk Python int lists) so memory stays bounded on a 17GB GPU.
    """

    def __init__(self, tokenizer, seq_len=SEQ_LEN, max_zig_tokens=80_000_000):
        self.seq_len = seq_len
        chunk = seq_len + 1
        nl = tokenizer.token_to_id.get("\n", 0)

        # --- Zig stream (capped for local memory) ---
        zig_ids = []
        for root in ZIG_ROOTS:
            for fp in iter_zig_files(root):
                content = read_file(fp)
                if content:
                    ids = tokenizer.encode(content)
                    if ids:
                        zig_ids.extend(ids)
                        zig_ids.append(nl)
                if len(zig_ids) >= max_zig_tokens:
                    break
            if len(zig_ids) >= max_zig_tokens:
                break
        zig_t = torch.tensor(zig_ids, dtype=torch.long)
        del zig_ids
        zig_offsets = list(range(0, max(0, len(zig_t) - chunk + 1), chunk))
        print(f"  zig tokens={len(zig_t):,}  zig chunks={len(zig_offsets):,}")

        # --- Russian stream ---
        ru_ids = []
        for text in read_russian_texts(RU_CORPUS):
            ids = tokenizer.encode(text)
            if ids:
                ru_ids.extend(ids)
                ru_ids.append(nl)
        ru_t = torch.tensor(ru_ids, dtype=torch.long) if ru_ids else torch.zeros(0, dtype=torch.long)
        ru_offsets = list(range(0, max(0, len(ru_t) - chunk + 1), chunk))

        # Oversample Russian to reach RU_RATIO of total chunks.
        target_ru = int(len(zig_offsets) * RU_RATIO / (1.0 - RU_RATIO))
        if ru_offsets and target_ru > 0:
            mult = target_ru // len(ru_offsets) + 1
            repeated = (ru_offsets * mult)[:target_ru]
            random.shuffle(repeated)
        else:
            repeated = []
        print(f"  russian tokens={len(ru_t):,}  russian chunks={len(ru_offsets):,}  oversampled->{len(repeated):,}")

        self.samples = [(zig_t, s) for s in zig_offsets] + [(ru_t, s) for s in repeated]
        random.shuffle(self.samples)
        self._zig_t = zig_t
        self._ru_t = ru_t
        print(f"  TOTAL chunks={len(self.samples):,}")

    def __len__(self):
        return len(self.samples)

    def __getitem__(self, idx):
        tensor, start = self.samples[idx]
        chunk = tensor[start:start + self.seq_len + 1]
        return chunk[:-1].clone(), chunk[1:].clone()


class CosineScheduler:
    def __init__(self, lr, warmup_steps, total_steps, min_lr_ratio=0.1):
        self.lr = lr
        self.warmup_steps = warmup_steps
        self.total_steps = total_steps
        self.min_lr_ratio = min_lr_ratio

    def get_lr(self, step):
        if step < self.warmup_steps:
            return self.lr * (step + 1) / self.warmup_steps
        progress = (step - self.warmup_steps) / max(self.total_steps - self.warmup_steps, 1)
        return self.lr * (self.min_lr_ratio + (1 - self.min_lr_ratio) * 0.5 * (1 + math.cos(math.pi * progress)))


class Trainer:
    def __init__(self, model, tokenizer, lr=2e-4, warmup_steps=200, total_steps=20000):
        if not torch.cuda.is_available():
            raise RuntimeError("CUDA is required for training; refusing to fall back to CPU")
        # TF32 for supported matmuls (faster fp32/optimizer math on NVIDIA)
        torch.backends.cuda.matmul.allow_tf32 = True
        torch.backends.cudnn.allow_tf32 = True
        torch.backends.cudnn.benchmark = True
        # On this PyTorch/CUDA build the FlashAttention kernel is broken (returns
        # "OK" but takes ~12s/layer). Force the mem-efficient backend instead.
        torch.backends.cuda.enable_flash_sdp(False)
        torch.backends.cuda.enable_mem_efficient_sdp(True)
        torch.backends.cuda.enable_math_sdp(True)
        self.device = "cuda:0"
        # Train in BF16. CRITICAL PERFORMANCE FIX: this RTX 5060 Ti / CUDA build
        # has a VRAM threshold (~7-8GB) above which every GEMM runs ~30x slower.
        # FP32 AdamW state is 4.8GB and pushes us over; BF16 params -> BF16 state
        # (~1.2GB) keeps total VRAM ~1.7GB and yields ~4000 tok/s instead of ~140.
        self.model = model.to(self.device, dtype=torch.bfloat16)
        self.tokenizer = tokenizer
        # torch.compile fuses the forward/backward graph (~1.6x over eager bf16).
        # mode="default" only; fullgraph=True and tf32='high' both REGRESS badly.
        self.model = torch.compile(self.model, mode="default")
        self.optimizer = torch.optim.AdamW(self.model.parameters(), lr=lr, betas=(0.9, 0.95),
                                          weight_decay=0.1, fused=True)
        self.scheduler = CosineScheduler(lr, warmup_steps, total_steps)
        self.step = 0
        self.best_val_loss = float("inf")
        self.train_losses = []
        self.val_losses = []
        CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        self.scaler = None

    def train_step(self, batch):
        self.model.train()
        x = batch[0].to(self.device, non_blocking=True)
        y = batch[1].to(self.device, non_blocking=True)
        with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
            _, loss = self.model(x, targets=y)
        loss.backward()
        nn.utils.clip_grad_norm_(self.model.parameters(), 1.0)
        self.optimizer.step()
        self.optimizer.zero_grad()
        return loss.item()

    @torch.no_grad()
    def validate(self, val_loader, max_batches=20):
        self.model.eval()
        total = 0.0
        count = 0
        for i, batch in enumerate(val_loader):
            if i >= max_batches:
                break
            x, y = batch[0].to(self.device), batch[1].to(self.device)
            with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
                _, loss = self.model(x, targets=y)
            total += loss.item()
            count += 1
        return total / max(count, 1)

    def _raw_model(self):
        # torch.compile wraps the model in OptimizedModule; checkpoint the inner module
        return self.model._orig_mod if hasattr(self.model, "_orig_mod") else self.model

    def save_checkpoint(self, tag=None):
        path = CHECKPOINT_DIR / f"step_{self.step:06d}.pt" if tag is None else CHECKPOINT_DIR / f"{tag}.pt"
        torch.save({
            "step": self.step,
            "model_state": self._raw_model().state_dict(),
            "optimizer_state": self.optimizer.state_dict(),
            "train_losses": self.train_losses[-200:],
            "val_losses": self.val_losses[-200:],
            "best_val_loss": self.best_val_loss,
            "config": self.model.get_config(),
        }, path)
        # sidecar: lets the agent loader verify config WITHOUT loading the .pt
        import json
        sidecar = path.with_suffix(".config.json")
        with open(sidecar, "w", encoding="utf-8") as f:
            json.dump(self.model.get_config(), f, indent=2)
        return path

    def load_latest(self):
        cands = sorted(CHECKPOINT_DIR.glob("step_*.pt"))
        if cands:
            ckpt = torch.load(cands[-1], map_location=self.device, weights_only=False)
            # refuse to resume into a shape-incompatible (e.g. 1280 vs 1440) checkpoint
            cfg = ckpt.get("config") or {}
            if cfg.get("dim") != self.model.get_config().get("dim"):
                print(f"  SKIP resume: {cands[-1].name} dim={cfg.get('dim')} "
                      f"!= model dim={self.model.get_config().get('dim')} (incompatible)")
                return False
            try:
                target = self._raw_model()
                # normalize torch.compile "_orig_mod." prefix so checkpoints are portable
                sd = {k.replace("_orig_mod.", ""): v for k, v in ckpt["model_state"].items()}
                target.load_state_dict(sd)
                self.step = ckpt.get("step", 0)
                self.best_val_loss = ckpt.get("best_val_loss", float("inf"))
                print(f"  resumed from {cands[-1].name} (step {self.step})")
                return True
            except Exception as e:
                print(f"  SKIP resume: {cands[-1].name}: {type(e).__name__}: {str(e)[:80]}")
                return False
        return False

    def train(self, train_loader, val_loader, max_steps=5000, log_interval=10, val_interval=200, save_interval=500):
        self.total_steps = max_steps
        self._t0 = time.monotonic()
        batch_iter = iter(train_loader)
        while self.step < max_steps:
            try:
                batch = next(batch_iter)
            except StopIteration:
                batch_iter = iter(train_loader)
                batch = next(batch_iter)

            loss = self.train_step(batch)
            self.step += 1
            # store the scalar only -- appending the loss tensor would retain the
            # whole autograd graph (a per-step VRAM/RAM leak that thrashes training)
            self.train_losses.append(loss)
            lr = self.scheduler.get_lr(self.step)
            for pg in self.optimizer.param_groups:
                pg["lr"] = lr

            if self.step % log_interval == 0:
                now = time.monotonic()
                spd = self.step / (now - self._t0) if now > self._t0 else 0.0
                eta = (max_steps - self.step) / spd if spd > 0 else 0.0
                print(f"step={self.step:6d} loss={loss:.4f} lr={lr:.6f} "
                      f"{spd:.2f} step/s ETA={eta/3600:.1f}h", flush=True)

            if self.step % val_interval == 0:
                val_loss = self.validate(val_loader)
                self.val_losses.append(val_loss)
                if val_loss < self.best_val_loss:
                    self.best_val_loss = val_loss
                    self.save_checkpoint("best_v1")
                print(f"  val_loss={val_loss:.4f} best={self.best_val_loss:.4f}", flush=True)

            if self.step % save_interval == 0:
                self.save_checkpoint()

        self.save_checkpoint("final_v1")
        return {"step": self.step, "best_val_loss": self.best_val_loss}


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", type=int, default=60000)
    ap.add_argument("--seq", type=int, default=SEQ_LEN)
    ap.add_argument("--bs", type=int, default=2)
    args = ap.parse_args()

    print("B+ ZIG AGENT - TRAIN NEW 600M MODEL (Russian + Zig, local)")
    print("=" * 64)

    print("Tokenizer:")
    tokenizer = ZigTokenizer.load(TOK_PATH)
    print(f"  vocab={tokenizer.vocab_size()}")

    print(f"Building mixed dataset (90% Zig / 10% Russian), seq={args.seq}...")
    dataset = MixedZigRuDataset(tokenizer, seq_len=args.seq)
    if len(dataset) == 0:
        print("ERROR: empty dataset")
        return

    val_size = min(len(dataset) // 20, 400)
    train_size = len(dataset) - val_size
    train_ds, val_ds = torch.utils.data.random_split(dataset, [train_size, val_size])
    train_loader = DataLoader(train_ds, batch_size=args.bs, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)
    val_loader = DataLoader(val_ds, batch_size=args.bs, shuffle=False, num_workers=0, pin_memory=True)
    print(f"Train={len(train_ds)} Val={len(val_ds)}")

    print("Model:")
    model = build_model_600m(vocab_size=tokenizer.vocab_size(), max_seq_len=256000)
    cfg = model.get_config()
    print(f"  params={cfg['parameters']/1e6:.1f}M dim={cfg['dim']} layers={cfg['n_layers']} maxseq={cfg['max_seq_len']}")
    print(f"  device: {'cuda' if torch.cuda.is_available() else 'cpu'}")

    trainer = Trainer(model, tokenizer, lr=2e-4, warmup_steps=200, total_steps=args.steps)
    trainer.load_latest()

    print(f"\nStarting training (target steps={args.steps})...")
    results = trainer.train(
        train_loader, val_loader,
        max_steps=args.steps, log_interval=10, val_interval=500, save_interval=1000,
    )
    print(f"\nDone: step={results['step']} best_val_loss={results['best_val_loss']:.4f}", flush=True)


if __name__ == "__main__":
    main()
