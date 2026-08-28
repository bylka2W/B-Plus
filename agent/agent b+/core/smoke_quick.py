import sys, os, json, time, math, random
AGENT_BPLUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT_DIR = os.path.dirname(AGENT_BPLUS)
sys.path.insert(0, AGENT_BPLUS)
sys.path.insert(0, AGENT_DIR)
import torch
from pathlib import Path

print("Step 1: Load tokenizer")
from knowledge.tokenizer import ZigTokenizer
tok_path = Path(AGENT_BPLUS) / "knowledge" / "corpus" / "zig_tokenizer.json"
tokenizer = ZigTokenizer.load(tok_path)
print(f"  vocab={tokenizer.vocab_size()}")

print("Step 2: Load extended model")
from core.model import build_model
ext_ckpt = Path(AGENT_BPLUS) / "checkpoints" / "model_extended.pt"
model = build_model(vocab_size=tokenizer.vocab_size())
ckpt = torch.load(ext_ckpt, map_location="cpu", weights_only=True)
state_dict = {k: v for k, v in ckpt.items() if k != "optimizer_state"}
model.load_state_dict(state_dict, strict=False)
device = "cuda" if torch.cuda.is_available() else "cpu"
model = model.to(device)
print(f"  device={device}, params={sum(p.nelement() for p in model.parameters())/1e6:.1f}M")

print("Step 3: Generate 50 training pairs")
from core.smoke_training import load_knowledge, generate_training_pairs
concepts, evidence, facts = load_knowledge()
pairs = generate_training_pairs(concepts, evidence, facts, n_pairs=50)
print(f"  pairs={len(pairs)}")

print("Step 4: Encode")
max_seq_len = 256
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
print(f"  shape={input_tensor.shape}")

print("Step 5: Train 5 epochs")
model.train()
optimizer = torch.optim.AdamW(model.parameters(), lr=3e-4)
losses = []
t0 = time.monotonic()
for epoch in range(5):
    epoch_loss = 0.0
    n = 0
    indices = list(range(len(input_tensor)))
    random.shuffle(indices)
    for i in range(0, len(indices), 4):
        batch_idx = indices[i:i+4]
        x = input_tensor[batch_idx]
        targets = x.clone()
        logits, loss = model(x, targets=targets)
        optimizer.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step()
        epoch_loss += loss.item()
        n += 1
    avg = epoch_loss / max(n, 1)
    losses.append(avg)
    print(f"  Epoch {epoch+1}/5 loss={avg:.4f} [{time.monotonic()-t0:.0f}s]")

print(f"Step 6: Save checkpoint")
ckpt_dir = Path(AGENT_BPLUS) / "checkpoints"
torch.save({"model_state_dict": model.state_dict(), "vocab_size": tokenizer.vocab_size(), "losses": losses}, ckpt_dir / "smoke_trained.pt")

print("Step 7: Test 4 questions")
model.eval()
questions = ["привет", "Что такое GPUScheduler?", "Где находится GPUScheduler?", "Что делает Scheduler.submit?"]
for q in questions:
    prompt = f"<system>You are a B+ Zig coding assistant.</system>\n<instruction>{q}</instruction>\n<answer>"
    ids = tokenizer.encode(prompt)
    inp = torch.tensor([ids], device=device)
    with torch.no_grad():
        out = model.generate(inp, max_new_tokens=60, temperature=0.7, top_k=50)
    resp = tokenizer.decode(out[0].tolist())
    ans = resp.split("<answer>")[-1] if "<answer>" in resp else resp[-200:]
    ans = ans.split("</answer>")[0].strip()
    print(f"  Q: {q}")
    print(f"  A: {ans[:200]}")
    print()

print(f"Done. losses={losses}")
