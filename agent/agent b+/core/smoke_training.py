import sys
import os
import json
import time
import math
import random

AGENT_BPLUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT_DIR = os.path.dirname(AGENT_BPLUS)
sys.path.insert(0, AGENT_BPLUS)
sys.path.insert(0, AGENT_DIR)

import torch
from pathlib import Path


def load_knowledge():
    kb_dir = Path(AGENT_DIR) / "memory"
    with open(kb_dir / "concepts.json", encoding="utf-8") as f:
        concepts = json.load(f)["items"]
    with open(kb_dir / "source_evidence.json", encoding="utf-8") as f:
        evidence = json.load(f)["items"]
    with open(kb_dir / "facts.json", encoding="utf-8") as f:
        facts = json.load(f)["items"]
    return concepts, evidence, facts


def build_concept_index(concepts):
    by_name = {}
    for c in concepts:
        name = c.get("name", "")
        if name:
            by_name[name] = c
    return by_name


def get_evidence_for_concept(concept, evidence_by_id):
    ev_ids = concept.get("evidence_ids", [])
    texts = []
    for eid in ev_ids:
        ev = evidence_by_id.get(eid)
        if ev and ev.get("text"):
            texts.append(ev["text"][:500])
    return texts


def get_facts_for_concept(concept, facts_by_id):
    fid = concept.get("fact_ids", [])
    result = []
    for fact_id in fid[:5]:
        f = facts_by_id.get(fact_id)
        if f:
            result.append(f)
    return result


def load_source_snippets(source_files, max_snippets=3):
    snippets = []
    for sf in source_files[:max_snippets]:
        if os.path.exists(sf):
            try:
                with open(sf, encoding="utf-8", errors="replace") as f:
                    lines = f.readlines()
                start = random.randint(0, max(0, len(lines) - 20))
                chunk = "".join(lines[start:start+20])
                snippets.append(f"File: {os.path.basename(sf)}\n{chunk}")
            except Exception:
                pass
    return snippets


def generate_training_pairs(concepts, evidence, facts, n_pairs=200):
    evidence_by_id = {e["id"]: e for e in evidence}
    facts_by_id = {f["fact_id"]: f for f in facts}
    concept_index = build_concept_index(concepts)

    question_templates_ru = [
        "Что такое {name}?",
        "Где находится {name}?",
        "Что делает {name}?",
        "Как работает {name}?",
        "Объясни {name}.",
        "Покажи код {name}.",
    ]
    question_templates_en = [
        "What is {name}?",
        "Where is {name}?",
        "What does {name} do?",
        "How does {name} work?",
        "Explain {name}.",
        "Show me the code for {name}.",
    ]

    pairs = []
    concept_names = list(concept_index.keys())
    random.shuffle(concept_names)

    for name in concept_names[:n_pairs]:
        concept = concept_index[name]
        ev_texts = get_evidence_for_concept(concept, evidence_by_id)
        if not ev_texts:
            continue

        source_files = concept.get("source_files", [])
        snippets = load_source_snippets(source_files, max_snippets=1)

        context_parts = []
        if ev_texts:
            code_ctx = "\n".join(ev_texts[:2])
            context_parts.append(f"Source code:\n{code_ctx}")
        if snippets:
            context_parts.append(f"File context:\n{snippets[0]}")

        context = "\n".join(context_parts)
        if not context.strip():
            continue

        use_ru = random.random() < 0.3
        templates = question_templates_ru if use_ru else question_templates_en
        template = random.choice(templates)
        question = template.format(name=name)

        answer_parts = [f"{name} is defined in the B+ Zig codebase."]
        if ev_texts:
            answer_parts.append(f"It involves: {ev_texts[0][:200]}")
        if source_files:
            sf_names = [os.path.basename(sf) for sf in source_files[:2]]
            answer_parts.append(f"Found in: {', '.join(sf_names)}")
        answer = " ".join(answer_parts)

        prompt = (
            f"<system>You are a B+ Zig coding assistant. Answer concisely based on source code.</system>\n"
            f"<instruction>{question}</instruction>\n"
            f"<context>{context[:1500]}</context>\n"
            f"<answer>{answer}</answer>"
        )

        pairs.append({
            "question": question,
            "context": context[:1500],
            "answer": answer,
            "prompt": prompt,
            "concept": name,
        })

    return pairs


def smoke_train(
    n_samples=200,
    n_epochs=15,
    batch_size=4,
    lr=3e-4,
    max_seq_len=512,
):
    print("C.13.1 SMOKE TRAINING")
    print("=" * 60)

    from knowledge.tokenizer import ZigTokenizer
    from core.model import build_model

    tok_path = Path(AGENT_BPLUS) / "knowledge" / "corpus" / "zig_tokenizer.json"
    tokenizer = ZigTokenizer.load(tok_path)
    vocab_size = tokenizer.vocab_size()

    ext_ckpt = Path(AGENT_BPLUS) / "checkpoints" / "model_extended.pt"
    model = build_model(vocab_size=vocab_size)
    if ext_ckpt.exists():
        print(f"  Loading extended model (vocab={vocab_size})...")
        ckpt = torch.load(ext_ckpt, map_location="cpu", weights_only=True)
        state_dict = {k: v for k, v in ckpt.items() if k != "optimizer_state"}
        model.load_state_dict(state_dict, strict=False)
    else:
        print(f"  Using base model (vocab={vocab_size})...")

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = model.to(device)
    print(f"  Device: {device}")

    print("\n  Generating training data...")
    concepts, evidence, facts = load_knowledge()
    pairs = generate_training_pairs(concepts, evidence, facts, n_pairs=n_samples)
    print(f"  Generated {len(pairs)} training pairs")
    print(f"  Concepts used: {len(set(p['concept'] for p in pairs))}")

    encodings = []
    for p in pairs:
        ids = tokenizer.encode(p["prompt"])
        if len(ids) > max_seq_len:
            ids = ids[:max_seq_len]
        encodings.append(ids)

    max_len = max(len(ids) for ids in encodings)
    pad_id = tokenizer.encode(" ")[0] if tokenizer.encode(" ") else 0

    padded = []
    masks = []
    for ids in encodings:
        mask = [1] * len(ids) + [0] * (max_len - len(ids))
        padded_ids = ids + [pad_id] * (max_len - len(ids))
        padded.append(padded_ids)
        masks.append(mask)

    input_tensor = torch.tensor(padded, device=device)
    mask_tensor = torch.tensor(masks, device=device, dtype=torch.float)

    print(f"  Input shape: {input_tensor.shape}")
    print(f"  Max seq len: {max_len}")

    model.train()
    optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=0.01)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=n_epochs)

    print(f"\n  Training: {n_epochs} epochs, batch_size={batch_size}, lr={lr}")
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
            m = mask_tensor[batch_idx]

            logits, loss = model(x, targets=targets)

            if m.sum() > 0:
                mask_loss = (loss * m.mean(dim=-1)).mean()
            else:
                mask_loss = loss

            optimizer.zero_grad()
            mask_loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()

            epoch_loss += mask_loss.item()
            n_batches += 1

        scheduler.step()
        avg_loss = epoch_loss / max(n_batches, 1)
        losses.append(avg_loss)

        elapsed = time.monotonic() - t0
        if epoch % 3 == 0 or epoch == n_epochs - 1:
            print(f"  Epoch {epoch+1:3d}/{n_epochs} loss={avg_loss:.4f} lr={scheduler.get_last_lr()[0]:.2e} [{elapsed:.0f}s]")

    total_time = time.monotonic() - t0
    print(f"\n  Training complete: {total_time:.0f}s")
    print(f"  Initial loss: {losses[0]:.4f}")
    print(f"  Final loss: {losses[-1]:.4f}")
    print(f"  Loss reduction: {(1 - losses[-1]/losses[0])*100:.1f}%")

    ckpt_dir = Path(AGENT_BPLUS) / "checkpoints"
    ckpt_dir.mkdir(parents=True, exist_ok=True)
    smoke_ckpt = ckpt_dir / "smoke_trained.pt"
    torch.save({
        "model_state_dict": model.state_dict(),
        "vocab_size": vocab_size,
        "losses": losses,
        "n_epochs": n_epochs,
        "n_samples": len(pairs),
    }, smoke_ckpt)
    print(f"  Checkpoint: {smoke_ckpt}")

    return model, tokenizer, losses, pairs


def test_questions(model, tokenizer, baseline_path):
    print("\n  QUESTION TESTS")
    print("-" * 60)

    device = next(model.parameters()).device
    model.eval()

    baseline = {}
    if baseline_path.exists():
        with open(baseline_path, encoding="utf-8") as f:
            for item in json.load(f):
                baseline[item["question"]] = item

    questions = [
        "привет",
        "Что такое GPUScheduler?",
        "Где находится GPUScheduler?",
        "Что делает Scheduler.submit?",
    ]

    results = []
    for q in questions:
        prompt = (
            f"<system>You are a B+ Zig coding assistant. Answer concisely.</system>\n"
            f"<instruction>{q}</instruction>\n"
            f"<answer>"
        )

        ids = tokenizer.encode(prompt)
        input_tensor = torch.tensor([ids], device=device)

        with torch.no_grad():
            output = model.generate(input_tensor, max_new_tokens=100, temperature=0.7, top_k=50)

        response = tokenizer.decode(output[0].tolist())
        answer_part = response.split("<answer>")[-1] if "<answer>" in response else response
        answer_part = answer_part.split("</answer>")[0].strip()
        if not answer_part:
            answer_part = response[-200:]

        baseline_entry = baseline.get(q, {})
        baseline_answer = baseline_entry.get("answer", "N/A")[:120]
        baseline_ok = baseline_entry.get("success", False)

        print(f"\n  Q: {q}")
        print(f"  BEFORE: {baseline_answer} ({'OK' if baseline_ok else 'FAIL'})")
        print(f"  AFTER:  {answer_part[:200]}")

        is_random = len(set(answer_part.split())) < 3 or answer_part.count("?") > len(answer_part) * 0.3
        results.append({
            "question": q,
            "before": baseline_answer,
            "before_ok": baseline_ok,
            "after": answer_part[:500],
            "looks_random": is_random,
        })

    return results


def main():
    print("C.13.1 SMOKE TRAINING")
    print("=" * 60)
    print()

    model, tokenizer, losses, pairs = smoke_train(
        n_samples=200,
        n_epochs=15,
        batch_size=4,
        lr=3e-4,
        max_seq_len=512,
    )

    baseline_path = Path(AGENT_BPLUS) / "checkpoints" / "pre_training_baseline.json"
    results = test_questions(model, tokenizer, baseline_path)

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
    print()

    if passed >= total * 0.5 and losses[-1] < losses[0] * 0.7:
        print("  SMOKE TRAINING: PASS")
        print("  Model learned from context. Ready for C.13.2 full training.")
    else:
        print("  SMOKE TRAINING: NEEDS REVIEW")
        print("  Model may need more samples or epochs.")

    report = {
        "samples": len(pairs),
        "epochs": len(losses),
        "initial_loss": round(losses[0], 4),
        "final_loss": round(losses[-1], 4),
        "reduction_pct": round((1 - losses[-1]/losses[0])*100, 1),
        "question_results": results,
        "non_random_count": passed,
        "total_questions": total,
    }
    report_path = Path(AGENT_BPLUS) / "checkpoints" / "smoke_training_report.json"
    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    print(f"\n  Report: {report_path}")
    print("=" * 60)


if __name__ == "__main__":
    main()
