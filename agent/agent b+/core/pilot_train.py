"""
Pilot training: 500 steps on instruction dataset.
Then frozen evaluation.
Usage: python -u core\pilot_train.py
"""
import sys, time, torch
from pathlib import Path

AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+")
sys.path.insert(0, str(AGENT_ROOT))

from core.model import build_model_600m
from core.instruction_dataset import build_instruction_dataloaders
from knowledge.tokenizer import ZigTokenizer

TOK_PATH = AGENT_ROOT / "knowledge" / "corpus" / "ru_zig_tokenizer.json"
CKPT_DIR = AGENT_ROOT / "checkpoints"
CKPT_DIR.mkdir(exist_ok=True)

STEPS = 500
BATCH_SIZE = 2
SEQ_LEN = 1024
LR = 2e-4
WARMUP = 100
LOG_INTERVAL = 10
EVAL_INTERVAL = 100
SAVE_INTERVAL = 100


def main():
    print("PILOT TRAINING — Instruction Dataset")
    print("=" * 60)

    # Load tokenizer
    print("Loading tokenizer...")
    tokenizer = ZigTokenizer.load(TOK_PATH)
    print(f"  vocab: {tokenizer.vocab_size()}")

    # Build model
    print("Building model...")
    model = build_model_600m(vocab_size=tokenizer.vocab_size(), max_seq_len=256000)
    model = model.to("cuda:0", dtype=torch.bfloat16)
    model = torch.compile(model, mode="default")
    print(f"  params: {model.get_config()['parameters']/1e6:.1f}M")

    # Build dataset
    print("Loading instruction dataset...")
    train_loader, train_len = build_instruction_dataloaders(
        tokenizer, seq_len=SEQ_LEN, batch_size=BATCH_SIZE, split="train"
    )
    val_loader, val_len = build_instruction_dataloaders(
        tokenizer, seq_len=SEQ_LEN, batch_size=BATCH_SIZE, split="val"
    )
    print(f"  train: {train_len} chunks ({train_len * SEQ_LEN} tokens)")
    print(f"  val: {val_len} chunks")

    # Optimizer
    optimizer = torch.optim.AdamW(model.parameters(), lr=LR, betas=(0.9, 0.95),
                                  weight_decay=0.1, fused=True)

    # Cosine schedule
    def get_lr(step):
        if step < WARMUP:
            return LR * step / WARMUP
        progress = (step - WARMUP) / max(1, STEPS - WARMUP)
        return LR * 0.5 * (1 + torch.cos(torch.tensor(progress * 3.14159)).item())

    # Training loop
    print(f"\nStarting {STEPS} steps...")
    model.train()
    batch_iter = iter(train_loader)
    t0 = time.time()
    losses = []

    for step in range(1, STEPS + 1):
        # Get batch
        try:
            batch = next(batch_iter)
        except StopIteration:
            batch_iter = iter(train_loader)
            batch = next(batch_iter)

        x = batch[0].to("cuda:0", non_blocking=True)
        y = batch[1].to("cuda:0", non_blocking=True)

        # Forward
        with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
            _, loss = model(x, targets=y)

        # Backward
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step()
        optimizer.zero_grad()

        # LR
        lr = get_lr(step)
        for pg in optimizer.param_groups:
            pg["lr"] = lr

        losses.append(loss.item())

        # Log
        if step % LOG_INTERVAL == 0:
            elapsed = time.time() - t0
            spd = step / elapsed
            avg_loss = sum(losses[-LOG_INTERVAL:]) / LOG_INTERVAL
            tok_s = BATCH_SIZE * SEQ_LEN * spd
            eta = (STEPS - step) / spd / 3600
            print(f"  step={step:4d} loss={avg_loss:.4f} lr={lr:.6f} "
                  f"{spd:.2f} step/s {tok_s:.0f} tok/s ETA={eta:.2f}h")

        # Save checkpoint
        if step % SAVE_INTERVAL == 0:
            ckpt_path = CKPT_DIR / f"pilot_step_{step:06d}.pt"
            torch.save({
                "step": step,
                "model_state": model._orig_mod.state_dict() if hasattr(model, "_orig_mod") else model.state_dict(),
                "optimizer_state": optimizer.state_dict(),
                "losses": losses[-100:],
                "config": model.get_config(),
            }, ckpt_path)
            print(f"  Saved: {ckpt_path.name}")

    # Final save
    final_path = CKPT_DIR / "pilot_final.pt"
    torch.save({
        "step": STEPS,
        "model_state": model._orig_mod.state_dict() if hasattr(model, "_orig_mod") else model.state_dict(),
        "optimizer_state": optimizer.state_dict(),
        "losses": losses[-100:],
        "config": model.get_config(),
    }, final_path)
    print(f"\nSaved final: {final_path.name}")

    # Summary
    elapsed = time.time() - t0
    avg_loss = sum(losses[10:]) / max(1, len(losses) - 10)
    print(f"\n{'='*60}")
    print(f"PILOT COMPLETE")
    print(f"{'='*60}")
    print(f"  Steps: {STEPS}")
    print(f"  Time: {elapsed:.0f}s ({elapsed/60:.1f}min)")
    print(f"  Final loss: {losses[-1]:.4f}")
    print(f"  Avg loss (excl warmup): {avg_loss:.4f}")
    print(f"  Speed: {STEPS/elapsed:.2f} step/s")
    print(f"  Tok/s: {BATCH_SIZE*SEQ_LEN*STEPS/elapsed:.0f}")
    print(f"\n  Next: run frozen evaluation")
    print(f"  python -u core\\eval_zig.py --checkpoint {final_path}")


if __name__ == "__main__":
    main()
