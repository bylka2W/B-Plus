import sys, os, json, time, math, random
AGENT_BPLUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT_DIR = os.path.dirname(AGENT_BPLUS)
sys.path.insert(0, AGENT_BPLUS)
sys.path.insert(0, AGENT_DIR)
import torch
from pathlib import Path

print("C.13.1 SMOKE TRAINING")
print("=" * 60)

print("Loading tokenizer...")
from knowledge.tokenizer import ZigTokenizer
tok_path = Path(AGENT_BPLUS) / "knowledge" / "corpus" / "zig_tokenizer.json"
tokenizer = ZigTokenizer.load(tok_path)
vocab_size = tokenizer.vocab_size()
print(f"  vocab={vocab_size}")

print("Loading extended model...")
from core.model import build_model
ext_ckpt = Path(AGENT_BPLUS) / "checkpoints" / "model_extended.pt"
model = build_model(vocab_size=vocab_size)
ckpt = torch.load(ext_ckpt, map_location="cpu", weights_only=True)
state_dict = {k: v for k, v in ckpt.items() if k != "optimizer_state"}
model.load_state_dict(state_dict, strict=False)
device = "cuda" if torch.cuda.is_available() else "cpu"
model = model.to(device)
params = sum(p.nelement() for p in model.parameters())
print(f"  device={device}, params={params/1e6:.1f}M")

print("Generating training data...")
from core.smoke_training import load_knowledge, generate_training_pairs
concepts, evidence, facts = load_knowledge()
pairs = generate_training_pairs(concepts, evidence, facts, n_pairs=200)
print(f"  Generated {len(pairs)} training pairs")

max_seq_len = 512
encodings = []
for p in pairs:
    ids = tokenizer.encode(p["prompt"])
    if len(ids) > max_seq_len:
        ids = ids[:max_seq_len]
    encodings.append(ids)

max_len = max(len(ids) for ids in encodings)
pad_id = tokenizer.encode(" ")[0]
padded = [ids + [pad_id] * (max_len - len(ids)) for ids in encodings]
input_tensor = torch.tensor(padded, device=device)
print(f"  Input shape: {input_tensor.shape}")

n_epochs = 15
batch_size = 4
lr = 3e-4

model.train()
optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=0.01)
scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=n_epochs)

print(f"\nTraining: {n_epochs} epochs, batch={batch_size}, lr={lr}")
print("-" * 60)

losses = []
t0 = time.monotonic()

for epoch in range(n_epochs):
    model.train()
    epoch_loss = 0.0
    n_batches = 0
    indices = list(range(len(input_tensor)))
    random.shuffle(indices)

    for i in range(0, len(indices), batch_size):
        batch_idx = indices[i:i+batch_size]
        x = input_tensor[batch_idx]
        targets = x.clone()
        logits, loss = model(x, targets=targets)
        optimizer.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step()
        epoch_loss += loss.item()
        n_batches += 1

    scheduler.step()
    avg = epoch_loss / max(n_batches, 1)
    losses.append(avg)
    elapsed = time.monotonic() - t0
    if epoch % 3 == 0 or epoch == n_epochs - 1:
        print(f"  Epoch {epoch+1:3d}/{n_epochs} loss={avg:.4f} lr={scheduler.get_last_lr()[0]:.2e} [{elapsed:.0f}s]")

total_time = time.monotonic() - t0
print(f"\nTraining complete: {total_time:.0f}s")
print(f"  Initial loss: {losses[0]:.4f}")
print(f"  Final loss:   {losses[-1]:.4f}")
print(f"  Reduction:    {(1 - losses[-1]/losses[0])*100:.1f}%")

ckpt_dir = Path(AGENT_BPLUS) / "checkpoints"
ckpt_dir.mkdir(parents=True, exist_ok=True)
torch.save({"model_state_dict": model.state_dict(), "vocab_size": vocab_size, "losses": losses}, ckpt_dir / "smoke_trained.pt")
print(f"  Saved: {ckpt_dir / 'smoke_trained.pt'}")

print("\nQUESTION TESTS")
print("-" * 60)

baseline_path = ckpt_dir / "pre_training_baseline.json"
baseline = {}
if baseline_path.exists():
    with open(baseline_path, encoding="utf-8") as f:
        for item in json.load(f):
            baseline[item["question"]] = item

model.eval()
questions = ["привет", "Что такое GPUScheduler?", "Где находится GPUScheduler?", "Что делает Scheduler.submit?"]

results = []
for q in questions:
    prompt = f"<system>You are a B+ Zig coding assistant. Answer concisely.</system>\n<instruction>{q}</instruction>\n<answer>"
    ids = tokenizer.encode(prompt)
    inp = torch.tensor([ids], device=device)
    with torch.no_grad():
        out = model.generate(inp, max_new_tokens=80, temperature=0.7, top_k=50)
    resp = tokenizer.decode(out[0].tolist())
    ans = resp.split("<answer>")[-1] if "<answer>" in resp else resp[-300:]
    ans = ans.split("</answer>")[0].strip()

    b = baseline.get(q, {})
    b_ans = b.get("answer", "N/A")[:120]
    b_ok = b.get("success", False)

    has_code = any(kw in ans for kw in ["fn", "pub", "const", "var", "struct", "import", "void", "zig"])
    has_punctuation = sum(1 for c in ans if c in ".,;:(){}[]") > 3
    looks_random = len(set(ans.split())) < 5 and not has_code

    print(f"\n  Q: {q}")
    print(f"  BEFORE: {b_ans[:120]} ({'OK' if b_ok else 'FAIL'})")
    print(f"  AFTER:  {ans[:300]}")
    print(f"  Code tokens: {has_code}, Structured: {has_punctuation}, Random: {looks_random}")

    results.append({
        "question": q,
        "before": b_ans,
        "before_ok": b_ok,
        "after": ans[:500],
        "has_code": has_code,
        "looks_random": looks_random,
    })

passed = sum(1 for r in results if not r["looks_random"])
total = len(results)

print("\n" + "=" * 60)
print("VERDICT:")
print(f"  Samples:    {len(pairs)}")
print(f"  Epochs:     {len(losses)}")
print(f"  Init loss:  {losses[0]:.4f}")
print(f"  Final loss: {losses[-1]:.4f}")
print(f"  Reduction:  {(1 - losses[-1]/losses[0])*100:.1f}%")
print(f"  Questions:  {passed}/{total} non-random")
print(f"  Time:       {total_time:.0f}s")

report = {
    "samples": len(pairs),
    "epochs": len(losses),
    "initial_loss": round(losses[0], 4),
    "final_loss": round(losses[-1], 4),
    "reduction_pct": round((1 - losses[-1]/losses[0])*100, 1),
    "question_results": results,
    "non_random_count": passed,
    "total_questions": total,
    "training_time_s": round(total_time, 1),
}
with open(ckpt_dir / "smoke_training_report.json", "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)

if passed >= total * 0.5 and losses[-1] < losses[0] * 0.7:
    print("\n  SMOKE TRAINING: PASS")
    print("  Ready for C.13.2 full training.")
else:
    print("\n  SMOKE TRAINING: NEEDS REVIEW")

print("=" * 60)
