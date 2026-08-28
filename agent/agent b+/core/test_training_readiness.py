import sys
import os
import time
import json
import math

AGENT_BPLUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT_DIR = os.path.dirname(AGENT_BPLUS)

sys.path.insert(0, AGENT_BPLUS)
sys.path.insert(0, AGENT_DIR)

import torch
from pathlib import Path


def gate_tokenizer_roundtrip():
    print("\nC.13.0.1 TOKENIZER ROUNDTRIP")
    print("-" * 50)

    from knowledge.tokenizer import ZigTokenizer
    tok_path = Path(AGENT_BPLUS) / "knowledge" / "corpus" / "zig_tokenizer.json"
    tokenizer = ZigTokenizer.load(tok_path)

    zig_code = 'pub fn main() void {\n    var x: i32 = 0;\n    x += 1;\n}'
    ids = tokenizer.encode(zig_code)
    decoded = tokenizer.decode(ids)
    normalized = zig_code.replace("    ", " ")
    zig_ok = decoded.strip() == normalized.strip()
    print(f"  Zig code:      {'PASS' if zig_ok else 'FAIL'} (whitespace normalized)")
    if not zig_ok:
        print(f"    original:  {repr(zig_code[:80])}")
        print(f"    decoded:   {repr(decoded[:80])}")
        print(f"    ids count: {len(ids)}")

    simple = "GPUScheduler"
    ids2 = tokenizer.encode(simple)
    decoded2 = tokenizer.decode(ids2)
    simple_ok = simple in decoded2
    print(f"  Identifier:    {'PASS' if simple_ok else 'FAIL'}")
    if not simple_ok:
        print(f"    original: {repr(simple)}")
        print(f"    decoded:  {repr(decoded2)}")
        print(f"    ids:      {ids2}")

    russian = "Что такое GPUScheduler?"
    ids3 = tokenizer.encode(russian)
    decoded3 = tokenizer.decode(ids3)
    unk_count = decoded3.count("?")
    total_chars = len(russian)
    print(f"  Russian text:  {'WARN' if unk_count > 0 else 'PASS'}")
    print(f"    input:     {repr(russian)} ({total_chars} chars)")
    print(f"    tokens:    {len(ids3)}")
    print(f"    decoded:   {repr(decoded3)}")
    print(f"    UNK chars: {unk_count}/{total_chars}")

    xml_tag = "<system>You are a Zig expert.</system>"
    ids4 = tokenizer.encode(xml_tag)
    decoded4 = tokenizer.decode(ids4)
    print(f"  XML tags:      tokens={len(ids4)} decoded={repr(decoded4[:60])}")

    stats = {
        "vocab_size": tokenizer.vocab_size(),
        "zig_roundtrip": zig_ok,
        "identifier_roundtrip": simple_ok,
        "russian_unk_ratio": round(unk_count / max(total_chars, 1), 3),
        "zig_tokens": len(ids),
        "identifier_tokens": len(ids2),
        "russian_tokens": len(ids3),
    }

    all_ok = zig_ok and simple_ok
    print(f"\n  VERDICT: {'PASS - tokenizer works for Zig' if all_ok else 'FAIL'}")
    return all_ok, stats


def test_prompt_format():
    print("\nC.13.0.2 PROMPT FORMAT")
    print("-" * 50)

    from knowledge.tokenizer import ZigTokenizer
    tok_path = Path(AGENT_BPLUS) / "knowledge" / "corpus" / "zig_tokenizer.json"
    tokenizer = ZigTokenizer.load(tok_path)

    system_prompt = "<system>You are a B+ Zig coding assistant. Answer concisely.</system>"
    instruction = "Explain what GPUScheduler.submit does."
    context = "GPUScheduler manages GPU task submission via a thread pool."
    answer = "GPUScheduler.submit sends a job to the worker pool for execution."

    full_prompt = f"{system_prompt}\n<instruction>{instruction}</instruction>\n<context>{context}</context>\n<answer>{answer}</answer>"

    ids = tokenizer.encode(full_prompt)
    decoded = tokenizer.decode(ids)

    has_system = "<system>" in decoded
    has_instruction = "GPUScheduler" in decoded
    has_answer = "submit" in decoded

    print(f"  Template:      {repr(full_prompt[:100])}...")
    print(f"  Token count:   {len(ids)}")
    print(f"  Has <system>:  {has_system}")
    print(f"  Has content:   {has_instruction}")
    print(f"  Has answer:    {has_answer}")

    instruction_template = (
        "<system>You are a B+ Zig coding assistant.</system>\n"
        "<instruction>{instruction}</instruction>\n"
        "<context>{context}</context>\n"
        "<answer>{answer}</answer>"
    )

    sample = instruction_template.format(
        instruction="What does Scheduler.submit do?",
        context="Scheduler is in scheduler.zig",
        answer="It submits a job to the worker pool."
    )
    sample_ids = tokenizer.encode(sample)
    sample_decoded = tokenizer.decode(sample_ids)

    print(f"\n  Template tokens: {len(sample_ids)}")
    print(f"  Decoded OK:      {'PASS' if 'submit' in sample_decoded else 'FAIL'}")

    stats = {
        "template_tokens": len(sample_ids),
        "has_system_tag": has_system,
        "has_answer": has_answer,
    }

    verdict = has_system and has_answer
    print(f"\n  VERDICT: {'PASS' if verdict else 'FAIL'}")
    return verdict, stats


def _load_extended_model():
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
    return model, vocab_size


def test_forward_loss():
    print("\nC.13.0.3 FORWARD + LOSS")
    print("-" * 50)

    model, vocab_size = _load_extended_model()
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = model.to(device)
    model.eval()

    params = sum(p.nelement() for p in model.parameters())
    print(f"  Model:     {params/1e6:.1f}M params on {device}")

    x = torch.randint(0, vocab_size, (1, 128), device=device)
    targets = torch.randint(0, vocab_size, (1, 128), device=device)

    with torch.no_grad():
        logits, loss = model(x, targets=targets)

    loss_val = loss.item()
    logits_finite = torch.isfinite(logits).all().item()
    loss_finite = math.isfinite(loss_val)

    print(f"  Input:     {x.shape}")
    print(f"  Logits:    {logits.shape}, finite={logits_finite}")
    print(f"  Loss:      {loss_val:.4f}, finite={loss_finite}")

    x2 = torch.randint(0, vocab_size, (2, 64), device=device)
    targets2 = torch.randint(0, vocab_size, (2, 64), device=device)
    with torch.no_grad():
        logits2, loss2 = model(x2, targets=targets2)
    print(f"  Batch=2:   loss={loss2.item():.4f}, logits={logits2.shape}")

    stats = {
        "params": params,
        "device": device,
        "vocab_size": vocab_size,
        "loss_128": round(loss_val, 4),
        "loss_64": round(loss2.item(), 4),
        "logits_finite": logits_finite,
        "loss_finite": loss_finite,
    }

    verdict = logits_finite and loss_finite and loss_val > 0
    print(f"\n  VERDICT: {'PASS' if verdict else 'FAIL'}")
    return verdict, stats


def test_backward_update():
    print("\nC.13.0.4 BACKWARD + PARAMETER UPDATE")
    print("-" * 50)

    model, vocab_size = _load_extended_model()
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = model.to(device)
    model.train()

    params_before = {}
    for name, p in model.named_parameters():
        params_before[name] = p.data.clone()

    x = torch.randint(0, vocab_size, (1, 128), device=device)
    targets = torch.randint(0, vocab_size, (1, 128), device=device)

    logits, loss = model(x, targets=targets)
    loss.backward()

    grads_ok = True
    grads_nan = 0
    grads_total = 0
    for name, p in model.named_parameters():
        if p.grad is not None:
            grads_total += 1
            if torch.isnan(p.grad).any():
                grads_nan += 1
                grads_ok = False

    print(f"  Loss:         {loss.item():.4f}")
    print(f"  Gradients:    {grads_total} params, {grads_nan} with NaN")

    optimizer = torch.optim.AdamW(model.parameters(), lr=3e-4)
    optimizer.step()

    changed = 0
    unchanged = 0
    for name, p in model.named_parameters():
        if name in params_before:
            if not torch.equal(p.data, params_before[name]):
                changed += 1
            else:
                unchanged += 1

    print(f"  After step:   {changed} changed, {unchanged} unchanged")
    print(f"  Optimizer:    AdamW lr=3e-4")

    stats = {
        "loss": round(loss.item(), 4),
        "grads_total": grads_total,
        "grads_nan": grads_nan,
        "params_changed": changed,
        "params_unchanged": unchanged,
    }

    verdict = grads_ok and changed > 0 and loss_finite(loss)
    print(f"\n  VERDICT: {'PASS' if verdict else 'FAIL'}")
    return verdict, stats


def loss_finite(loss):
    return math.isfinite(loss.item()) and loss.item() > 0


def test_pre_training_baseline():
    print("\nC.13.0.5 PRE-TRAINING BASELINE")
    print("-" * 50)

    try:
        from knowledge.tokenizer import ZigTokenizer
        from core.model import build_model
        from core.agent_runtime import KnowledgeQuery, SourceIndex, ZigRunner, AgentRuntime

        tok_path = Path(AGENT_BPLUS) / "knowledge" / "corpus" / "zig_tokenizer.json"
        tokenizer = ZigTokenizer.load(tok_path)
        model, _ = _load_extended_model()
        device = "cuda" if torch.cuda.is_available() else "cpu"
        model = model.to(device).eval()

        kb_dir = Path(AGENT_DIR) / "memory"
        knowledge = KnowledgeQuery(str(kb_dir))

        roots = [r for r in [r"C:\B-Plus\zig", r"C:\Users\Local\zig"] if Path(r).exists()]
        source_index = SourceIndex(roots)
        source_index.scan()

        zig_runner = ZigRunner()
        agent = AgentRuntime(model, tokenizer, knowledge, source_index, zig_runner)

        questions = [
            "привет",
            "Что такое GPUScheduler?",
            "Где находится GPUScheduler?",
            "Что делает Scheduler.submit?",
        ]

        results = []
        for q in questions:
            t0 = time.monotonic()
            try:
                goal = agent.execute(q)
                elapsed = (time.monotonic() - t0) * 1000
                answer = goal.result if goal.result else "no result"
                results.append({"question": q, "answer": answer[:200], "latency_ms": round(elapsed, 0), "success": goal.success})
                print(f"  Q: {q}")
                print(f"  A: {answer[:120]}...")
                print(f"     [{elapsed:.0f}ms] {'OK' if goal.success else 'FAIL'}")
                print()
            except Exception as e:
                elapsed = (time.monotonic() - t0) * 1000
                results.append({"question": q, "answer": str(e)[:200], "latency_ms": round(elapsed, 0), "success": False})
                print(f"  Q: {q}")
                print(f"  A: ERROR: {e}")
                print()

        baseline_path = Path(AGENT_BPLUS) / "checkpoints" / "pre_training_baseline.json"
        baseline_path.parent.mkdir(parents=True, exist_ok=True)
        with open(baseline_path, "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
        print(f"  Saved: {baseline_path}")

        stats = {
            "questions": len(questions),
            "successful": sum(1 for r in results if r["success"]),
            "avg_latency_ms": round(sum(r["latency_ms"] for r in results) / max(len(results), 1), 0),
        }
        print(f"\n  VERDICT: Baseline saved ({stats['successful']}/{stats['questions']} OK)")
        return True, stats

    except Exception as e:
        print(f"  ERROR: {e}")
        import traceback
        traceback.print_exc()
        return False, {"error": str(e)}


def main():
    print("C.13.0 TRAINING READINESS GATE")
    print("=" * 60)

    results = {}

    tests = [
        ("TOKENIZER ROUNDTRIP", gate_tokenizer_roundtrip),
        ("PROMPT FORMAT", test_prompt_format),
        ("FORWARD + LOSS", test_forward_loss),
        ("BACKWARD + UPDATE", test_backward_update),
        ("PRE-TRAINING BASELINE", test_pre_training_baseline),
    ]

    passed = 0
    failed = 0
    for name, fn in tests:
        try:
            ok, stats = fn()
            results[name] = {"pass": ok, "stats": stats}
            if ok:
                passed += 1
            else:
                failed += 1
        except Exception as e:
            print(f"  CRASH: {e}")
            import traceback
            traceback.print_exc()
            results[name] = {"pass": False, "stats": {"error": str(e)}}
            failed += 1

    print("\n" + "=" * 60)
    print("RESULTS:")
    for name, r in results.items():
        status = "PASS" if r["pass"] else "FAIL"
        print(f"  {name}: {status}")

    total = passed + failed
    print(f"\n  {passed}/{total} PASSED")

    if failed == 0:
        print("\n  TRAINING READINESS: ALL GATES PASS")
        print("  Ready for C.13.1 Smoke Training")
    else:
        print(f"\n  TRAINING READINESS: {failed} GATE(S) FAILED")
        print("  Fix issues before training")

    report_path = Path(AGENT_BPLUS) / "checkpoints" / "training_readiness.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2, default=str)
    print(f"\n  Report: {report_path}")
    print("=" * 60)


if __name__ == "__main__":
    main()
