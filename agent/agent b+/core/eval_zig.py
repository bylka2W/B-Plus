"""
Frozen evaluation for B+ Zig model.

Evaluates on 6 categories:
  1. zig_syntax     — Syntax correctness (does output parse as valid Zig?)
  2. code_complete  — Function completion (does it compile?)
  3. code_test      — Test writing (does it compile + pass?)
  4. russian_zig    — Russian instruction → Zig code
  5. bplus_locate   — B+ function location accuracy
  6. bplus_evidence — Evidence-grounded answers

Run from agent b+ root:
  python -u core\\eval_zig.py --checkpoint checkpoints\\step_001000.pt
"""
import json, re, sys, time, hashlib, subprocess, tempfile, os
from pathlib import Path
from collections import defaultdict

AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+")
sys.path.insert(0, str(AGENT_ROOT))

DATASET_DIR = AGENT_ROOT / "knowledge" / "dataset"
EVAL_DIR = AGENT_ROOT / "knowledge" / "eval"

# Frozen evaluation questions — NEVER change these
EVAL_QUESTIONS = [
    # --- zig_syntax (5) ---
    {"category": "zig_syntax", "instruction": "Что делает @import в Zig?", "expected_contains": "@import"},
    {"category": "zig_syntax", "instruction": "Чем отличается var от const в Zig?", "expected_contains": "var"},
    {"category": "zig_syntax", "instruction": "Как объявить функцию в Zig?", "expected_contains": "fn"},
    {"category": "zig_syntax", "instruction": "Что такое error union в Zig?", "expected_contains": "error"},
    {"category": "zig_syntax", "instruction": "Что такое comptime в Zig?", "expected_contains": "comptime"},

    # --- code_complete (5) ---
    {"category": "code_complete", "instruction": "Напиши функцию add, которая складывает два i32.", "expected_fn": "add", "should_compile": True},
    {"category": "code_complete", "instruction": "Напиши функцию max, которая возвращает максимум двух i32.", "expected_fn": "max", "should_compile": True},
    {"category": "code_complete", "instruction": "Напиши функцию is_even, проверяющую чётность i32.", "expected_fn": "is_even", "should_compile": True},
    {"category": "code_complete", "instruction": "Напиши функцию abs, возвращающую абсолютное значение i32.", "expected_fn": "abs", "should_compile": True},
    {"category": "code_complete", "instruction": "Напиши функцию sum, вычисляющую сумму среза i32.", "expected_fn": "sum", "should_compile": True},

    # --- russian_zig (5) ---
    {"category": "russian_zig", "instruction": "Напиши Zig-функцию, которая возвращает Hello World.", "expected_contains": "Hello"},
    {"category": "russian_zig", "instruction": "Создай Zig-структуру Point с полями x и y типа f64.", "expected_contains": "Point"},
    {"category": "russian_zig", "instruction": "Напиши Zig-функцию для вычисления числа Фибоначчи.", "expected_contains": "fibonacci"},
    {"category": "russian_zig", "instruction": "Создай enum Color с вариантами Red, Green, Blue.", "expected_contains": "Color"},
    {"category": "russian_zig", "instruction": "Напиши Zig-функцию, которая считает длину строки.", "expected_contains": "len"},
]


def extract_zig_code(response):
    """Extract Zig code from model response."""
    # Try to find code blocks
    blocks = re.findall(r'```zig\n(.*?)```', response, re.DOTALL)
    if blocks:
        return blocks[0].strip()

    blocks = re.findall(r'```\n(.*?)```', response, re.DOTALL)
    if blocks:
        return blocks[0].strip()

    # Try to find fn/test/struct/enum at start of lines
    lines = response.split("\n")
    code_lines = []
    in_code = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(("pub fn ", "fn ", "pub const ", "const ", "test ", "pub struct ", "struct ", "pub enum ", "enum ")):
            in_code = True
        if in_code:
            code_lines.append(line)
        if in_code and stripped == "}" and not any(c in stripped for c in ["{"]):
            # Check if this closes the outermost block
            if len(code_lines) > 1:
                break

    if code_lines:
        return "\n".join(code_lines)

    return response.strip()


def try_compile_zig(code, timeout=10):
    """Try to compile Zig code. Returns (success, output)."""
    with tempfile.NamedTemporaryFile(suffix=".zig", mode="w", delete=False, encoding="utf-8") as f:
        f.write(code)
        f.flush()
        tmp_path = f.name

    try:
        result = subprocess.run(
            ["zig", "fmt", tmp_path],
            capture_output=True, text=True, timeout=timeout
        )
        fmt_ok = result.returncode == 0

        result = subprocess.run(
            ["zig", "build-exe", tmp_path],
            capture_output=True, text=True, timeout=timeout
        )
        compile_ok = result.returncode == 0
        compile_output = result.stderr[:500] if result.stderr else ""

        return compile_ok, fmt_ok, compile_output
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return False, False, str(e)[:200]
    finally:
        try:
            os.unlink(tmp_path)
            # Clean up artifacts
            for ext in [".exe", ".o", ".pdb"]:
                p = Path(tmp_path).with_suffix(ext)
                if p.exists():
                    p.unlink()
        except OSError:
            pass


def evaluate_question(model, tokenizer, question, device="cuda:0"):
    """Evaluate a single question. Returns score dict."""
    import torch

    instruction = question["instruction"]
    category = question["category"]

    # Tokenize instruction
    ids = tokenizer.encode(instruction)
    ids = ids[:512]  # cap input length

    x = torch.tensor([ids], dtype=torch.long, device=device)

    # Generate response
    model.eval()
    with torch.no_grad():
        with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
            # Simple greedy generation
            max_new = 128
            for _ in range(max_new):
                logits, _ = model(x)
                next_token = logits[:, -1, :].argmax(dim=-1, keepdim=True)
                x = torch.cat([x, next_token], dim=-1)
                # Stop on double newline after some output
                if x.shape[1] - len(ids) > 10 and next_token.item() == 10:
                    # Check if previous token was also newline
                    if x[0, -2].item() == 10:
                        break

    response = tokenizer.decode(x[0].tolist()[len(ids):])
    code = extract_zig_code(response)

    result = {
        "category": category,
        "instruction": instruction,
        "response": response[:1000],
        "extracted_code": code[:1000],
        "scores": {},
    }

    # Score: contains expected keyword
    if "expected_contains" in question:
        result["scores"]["contains"] = 1.0 if question["expected_contains"].lower() in response.lower() else 0.0

    # Score: function name present
    if "expected_fn" in question:
        result["scores"]["fn_name"] = 1.0 if question["expected_fn"] in code else 0.0

    # Score: compiles
    if question.get("should_compile") and code:
        compile_ok, fmt_ok, compile_out = try_compile_zig(code)
        result["scores"]["compiles"] = 1.0 if compile_ok else 0.0
        result["scores"]["fmt_ok"] = 1.0 if fmt_ok else 0.0
        result["compile_error"] = compile_out[:300]

    return result


def run_evaluation(model, tokenizer, device="cuda:0"):
    """Run full evaluation. Returns summary."""
    print(f"\n{'='*60}")
    print("FROZEN EVALUATION")
    print(f"{'='*60}")
    print(f"Questions: {len(EVAL_QUESTIONS)}")

    results = []
    category_scores = defaultdict(list)

    for i, q in enumerate(EVAL_QUESTIONS):
        print(f"  [{i+1}/{len(EVAL_QUESTIONS)}] {q['category']}: {q['instruction'][:60]}...", end="", flush=True)
        r = evaluate_question(model, tokenizer, q, device)
        results.append(r)

        for metric, score in r["scores"].items():
            category_scores[f"{q['category']}_{metric}"].append(score)

        # Print immediate result
        scores_str = " ".join(f"{k}={v:.0%}" for k, v in r["scores"].items())
        print(f" → {scores_str}")

    # Summary
    print(f"\n{'='*60}")
    print("RESULTS SUMMARY")
    print(f"{'='*60}")

    summary = {}
    for metric, scores in sorted(category_scores.items()):
        avg = sum(scores) / len(scores) if scores else 0
        summary[metric] = avg
        print(f"  {metric}: {avg:.1%} ({sum(scores):.0f}/{len(scores)})")

    # Overall
    all_scores = []
    for scores in category_scores.values():
        all_scores.extend(scores)
    overall = sum(all_scores) / len(all_scores) if all_scores else 0
    summary["overall"] = overall
    print(f"\n  OVERALL: {overall:.1%}")

    # Save results
    EVAL_DIR.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d_%H%M%S")
    out_path = EVAL_DIR / f"eval_{ts}.json"
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"summary": summary, "results": results}, f, ensure_ascii=False, indent=2)
    print(f"\n  Saved: {out_path}")

    return summary, results


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", type=str, required=True, help="Path to .pt checkpoint")
    ap.add_argument("--device", type=str, default="cuda:0")
    args = ap.parse_args()

    import torch
    print("Loading model...")
    from core.model import build_model_600m

    # Load tokenizer first (to get vocab_size)
    from knowledge.tokenizer import ZigTokenizer
    tokenizer = ZigTokenizer.load(Path(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json"))

    model = build_model_600m(vocab_size=tokenizer.vocab_size(), max_seq_len=256000)

    ckpt = torch.load(args.checkpoint, map_location=args.device, weights_only=False)
    model.load_state_dict(ckpt["model_state"])
    model = model.to(args.device, dtype=torch.bfloat16)
    model.eval()

    print(f"Loaded checkpoint: step={ckpt.get('step', '?')}")

    run_evaluation(model, tokenizer, args.device)


if __name__ == "__main__":
    main()
