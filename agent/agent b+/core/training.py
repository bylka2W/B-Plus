import os
import sys
import json
import hashlib
import time
import math
from pathlib import Path
from collections import Counter

import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader

AGENT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(AGENT_ROOT))

from core.model import build_model
from knowledge.tokenizer import ZigTokenizer

CHECKPOINT_DIR = AGENT_ROOT / "checkpoints"
LOG_DIR = AGENT_ROOT / "logs"
CORPUS_DIR = AGENT_ROOT / "knowledge" / "corpus"

EXCLUDED_DIRS = {
    "zig-cache", "zig-out", ".git", "node_modules", "build",
    "build-debug", "build-release", "CMakeFiles",
}


def iter_zig_files(root):
    root = Path(root)
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDED_DIRS and not d.startswith("."))
        for name in sorted(filenames):
            if name.endswith(".zig"):
                files.append(os.path.join(dirpath, name))
    return files


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except (OSError, IOError):
        return ""


class ZigDataset(Dataset):
    def __init__(self, tokenizer, seq_len=512):
        self.seq_len = seq_len
        self.examples = []

        zig_roots = [Path(r"C:\Users\Local\zig"), Path(r"C:\B-Plus\zig")]
        all_ids = []

        for root in zig_roots:
            files = iter_zig_files(root)
            for fp in files:
                content = read_file(fp)
                if content:
                    ids = tokenizer.encode(content)
                    all_ids.extend(ids)
                    all_ids.append(tokenizer.token_to_id.get("\n", 0))

        chunk_size = seq_len + 1
        n_chunks = len(all_ids) // chunk_size
        for i in range(n_chunks):
            start = i * chunk_size
            chunk = all_ids[start:start + chunk_size]
            if len(chunk) == chunk_size:
                self.examples.append(chunk)

    def __len__(self):
        return len(self.examples)

    def __getitem__(self, idx):
        chunk = self.examples[idx]
        x = torch.tensor(chunk[:-1], dtype=torch.long)
        y = torch.tensor(chunk[1:], dtype=torch.long)
        return x, y


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
    def __init__(self, model, tokenizer, lr=3e-4, warmup_steps=200, total_steps=5000):
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.model = model.to(self.device)
        self.tokenizer = tokenizer
        self.optimizer = torch.optim.AdamW(model.parameters(), lr=lr, betas=(0.9, 0.95), weight_decay=0.1)
        self.scheduler = CosineScheduler(lr, warmup_steps, total_steps)
        self.step = 0
        self.best_val_loss = float("inf")
        self.train_losses = []
        self.val_losses = []
        CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
        LOG_DIR.mkdir(parents=True, exist_ok=True)

    def train_step(self, batch):
        self.model.train()
        x, y = batch[0].to(self.device), batch[1].to(self.device)
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
            _, loss = self.model(x, targets=y)
            total += loss.item()
            count += 1
        return total / max(count, 1)

    def save_checkpoint(self, tag=None):
        path = CHECKPOINT_DIR / f"step_{self.step:06d}.pt" if tag is None else CHECKPOINT_DIR / f"{tag}.pt"
        torch.save({
            "step": self.step,
            "model_state": self.model.state_dict(),
            "optimizer_state": self.optimizer.state_dict(),
            "train_losses": self.train_losses[-200:],
            "val_losses": self.val_losses[-200:],
            "best_val_loss": self.best_val_loss,
            "config": self.model.get_config(),
        }, path)
        return path

    def load_checkpoint(self, path):
        ckpt = torch.load(path, map_location=self.device, weights_only=False)
        self.model.load_state_dict(ckpt["model_state"])
        self.optimizer.load_state_dict(ckpt["optimizer_state"])
        self.step = ckpt.get("step", 0)
        self.best_val_loss = ckpt.get("best_val_loss", float("inf"))

    def train(self, train_loader, val_loader, max_steps=5000, log_interval=10, val_interval=100, save_interval=500):
        t0 = time.monotonic()
        batch_iter = iter(train_loader)

        while self.step < max_steps:
            try:
                batch = next(batch_iter)
            except StopIteration:
                batch_iter = iter(train_loader)
                batch = next(batch_iter)

            train_loss = self.train_step(batch)
            self.step += 1
            self.train_losses.append(train_loss)

            lr = self.scheduler.get_lr(self.step)
            for pg in self.optimizer.param_groups:
                pg["lr"] = lr

            if self.step % log_interval == 0:
                elapsed = (time.monotonic() - t0) * 1000
                print(f"step={self.step:5d} loss={train_loss:.4f} lr={lr:.6f} elapsed={elapsed:.0f}ms")

            if self.step % val_interval == 0:
                val_loss = self.validate(val_loader)
                self.val_losses.append(val_loss)
                if val_loss < self.best_val_loss:
                    self.best_val_loss = val_loss
                    self.save_checkpoint("best")
                print(f"  val_loss={val_loss:.4f} best={self.best_val_loss:.4f}")

            if self.step % save_interval == 0:
                self.save_checkpoint()

        self.save_checkpoint("final")
        return {"step": self.step, "best_val_loss": self.best_val_loss}


class Evaluator:
    def __init__(self, model, tokenizer):
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.model = model.to(self.device).eval()
        self.tokenizer = tokenizer

    @torch.no_grad()
    def perplexity(self, text):
        ids = self.tokenizer.encode(text)
        if len(ids) < 2:
            return float("inf")
        x = torch.tensor([ids[:-1]], dtype=torch.long, device=self.device)
        y = torch.tensor([ids[1:]], dtype=torch.long, device=self.device)
        _, loss = self.model(x, targets=y)
        return math.exp(loss.item())

    @torch.no_grad()
    def complete(self, prompt, max_tokens=64, temperature=0.2):
        ids = self.tokenizer.encode(prompt)
        x = torch.tensor([ids], dtype=torch.long, device=self.device)
        gen = self.model.generate(x, max_new_tokens=max_tokens, temperature=temperature)
        return self.tokenizer.decode(gen[0].tolist())

    def evaluate(self):
        prompts = [
            'const std = @import("std");\npub fn ',
            "fn compute(",
            "pub const Node = struct {\n    ",
            'test "basic" {\n    ',
            "if (x) |val| {\n        ",
            "pub fn main() !void {\n    ",
            "comptime {\n    ",
            "return try ",
        ]
        completions = []
        for p in prompts:
            c = self.complete(p, max_tokens=32)
            completions.append(c)

        has_fn = sum(1 for c in completions if "fn " in c) / len(completions)
        has_return = sum(1 for c in completions if "return" in c) / len(completions)
        has_struct = sum(1 for c in completions if "struct" in c or "enum" in c) / len(completions)

        perplexities = []
        for text in ['const std = @import("std");', "pub fn main() !void {}", "comptime { }"]:
            p = self.perplexity(text)
            perplexities.append(p)

        return {
            "zig_syntax_score": (has_fn + has_return + has_struct) / 3.0,
            "avg_perplexity": sum(perplexities) / len(perplexities),
            "completions": completions[:3],
        }


def main():
    print("B+ ZIG AGENT - PRODUCTION TRAINING")
    print("=" * 60)

    tokenizer = ZigTokenizer.load(CORPUS_DIR / "zig_tokenizer.json")
    print(f"Tokenizer: vocab={tokenizer.vocab_size()}")

    print("Loading dataset...")
    dataset = ZigDataset(tokenizer, seq_len=512)
    print(f"Dataset: {len(dataset)} examples")

    if len(dataset) == 0:
        print("ERROR: empty dataset")
        return

    val_size = min(len(dataset) // 20, 200)
    train_size = len(dataset) - val_size
    train_ds, val_ds = torch.utils.data.random_split(dataset, [train_size, val_size])

    train_loader = DataLoader(train_ds, batch_size=4, shuffle=True, drop_last=True, num_workers=0)
    val_loader = DataLoader(val_ds, batch_size=4, shuffle=False, num_workers=0)
    print(f"Train: {len(train_ds)}, Val: {len(val_ds)}")

    model = build_model()
    config = model.get_config()
    print(f"Model: {config['parameters']:,} params ({config['parameters'] / 1e6:.1f}M)")
    for k, v in config.items():
        if k != "parameters":
            print(f"  {k}: {v}")

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Device: {device}")

    trainer = Trainer(model, tokenizer, lr=3e-4, warmup_steps=200, total_steps=5000)

    print(f"\nStarting 50-step smoke test...")
    results = trainer.train(train_loader, val_loader, max_steps=50, log_interval=10, val_interval=25, save_interval=50)
    print(f"\nSmoke test done: step={results['step']}, best_val_loss={results['best_val_loss']:.4f}")

    print("\nEvaluation:")
    evaluator = Evaluator(model, tokenizer)
    eval_results = evaluator.evaluate()
    print(f"  zig_syntax_score: {eval_results['zig_syntax_score']:.2%}")
    print(f"  avg_perplexity: {eval_results['avg_perplexity']:.2f}")
    for i, c in enumerate(eval_results["completions"]):
        print(f"  completion[{i}]: {c[:80]}...")

    print(f"\nCheckpoints: {CHECKPOINT_DIR}")
    print(f"Logs: {LOG_DIR}")


if __name__ == "__main__":
    main()
