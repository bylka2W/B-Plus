"""
Correct quality gate for instruction dataset.
Checks what matters for TRAINING, not standalone compilation.

Quality dimensions:
  1. SYNTAX — balanced braces, valid Zig structure
  2. INSTRUCTION MATCH — output matches what was asked
  3. COMPLETENESS — code is not truncated mid-statement
  4. COVERAGE — all categories represented
  5. BALANCE — distribution matches target
"""
import json, re
from pathlib import Path
from collections import defaultdict

DATASET = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset")


def check_syntax(code):
    """Check Zig code structural validity."""
    if not code or len(code) < 20:
        return False, "too_short"
    # Balanced braces
    depth = 0
    for c in code:
        if c == "{": depth += 1
        elif c == "}": depth -= 1
    if depth != 0:
        return False, f"unbalanced_braces({depth})"
    # Has fn/test/struct/enum
    if not re.search(r'(pub\s+)?(fn|test|struct|enum|const)\s+', code):
        return False, "no_declaration"
    return True, "ok"


def check_truncation(code):
    """Check if code is truncated mid-statement."""
    lines = code.strip().split("\n")
    last_line = lines[-1].strip() if lines else ""
    # Truncation indicators
    if last_line.endswith((",", "+", "-", "*", "|", "&", ">", "<", "=")):
        return True, f"trailing_operator({last_line[-1]})"
    if last_line.endswith("{"):
        return True, "trailing_open_brace"
    if last_line.endswith(("fn ", "const ", "var ", "pub ")):
        return True, "trailing_keyword"
    return False, "ok"


def check_instruction_match(record):
    """Check if output matches instruction intent."""
    instr = record.get("instruction", "").lower()
    output = record.get("output", "")
    cat = record.get("category", "")

    if cat in ("code_write", "code_complete"):
        # Should contain Zig code
        return bool(re.search(r'(pub\s+)?fn\s+\w+', output)), "has_function"
    elif cat == "code_test":
        return output.strip().startswith("test "), "is_test_block"
    elif cat == "code_explain":
        return len(output) > 50, "has_explanation"
    elif cat in ("bplus_locate", "bplus_arch"):
        return bool(re.search(r'\.zig|fn \w+', output)), "has_reference"
    elif cat == "zig_syntax":
        return len(output) > 30, "has_content"
    return True, "unchecked"


def main():
    print("DATASET QUALITY GATE (training-relevant)")
    print("=" * 60)

    for split_name in ["instruction_train", "instruction_val"]:
        path = DATASET / f"{split_name}.jsonl"
        records = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
        print(f"\n{split_name}: {len(records)} records")

        by_cat = defaultdict(list)
        for r in records:
            by_cat[r.get("category", "?")].append(r)

        # Target distribution (from user's spec)
        total = len(records)
        targets = {
            "code_write": 0.30,
            "code_complete": 0.20,
            "code_test": 0.15,
            "code_explain": 0.10,
            "bplus_locate": 0.15,
            "bplus_arch": 0.10,
            "zig_syntax": 0.05,
        }

        print(f"\n  {'Category':<16} {'Count':>6} {'Actual%':>8} {'Target%':>8} {'Syntax%':>8} {'Trunc%':>8} {'Match%':>8}")
        print(f"  {'-'*16} {'-'*6} {'-'*8} {'-'*8} {'-'*8} {'-'*8} {'-'*8}")

        for cat in sorted(by_cat.keys()):
            cat_records = by_cat[cat]
            actual_pct = len(cat_records) / max(1, total) * 100
            target_pct = targets.get(cat, 0) * 100

            # Syntax check
            syntax_ok = 0
            trunc_count = 0
            match_ok = 0
            for r in cat_records:
                output = r.get("output", "")
                code = re.findall(r'```zig\n(.*?)```', output, re.DOTALL)
                code = code[0] if code else output

                if cat in ("code_write", "code_complete", "code_test"):
                    s, _ = check_syntax(code)
                    t, _ = check_truncation(code)
                    if s: syntax_ok += 1
                    if t: trunc_count += 1
                else:
                    syntax_ok += 1  # non-code categories pass syntax

                m, _ = check_instruction_match(r)
                if m: match_ok += 1

            n = len(cat_records)
            syntax_pct = syntax_ok / max(1, n) * 100
            trunc_pct = trunc_count / max(1, n) * 100
            match_pct = match_ok / max(1, n) * 100

            print(f"  {cat:<16} {n:>6} {actual_pct:>7.1f}% {target_pct:>7.1f}% {syntax_pct:>7.0f}% {trunc_pct:>7.0f}% {match_pct:>7.0f}%")

        # Find worst records for inspection
        print(f"\n  WORST RECORDS (truncated code):")
        worst = []
        for r in records:
            cat = r.get("category", "")
            if cat not in ("code_write", "code_complete", "code_test"):
                continue
            output = r.get("output", "")
            code = re.findall(r'```zig\n(.*?)```', output, re.DOTALL)
            code = code[0] if code else output
            trunc, reason = check_truncation(code)
            if trunc:
                worst.append((r, reason))
        for r, reason in worst[:5]:
            print(f"    cat={r.get('category')} file={r.get('file','?')[:40]} reason={reason}")
            print(f"      output[-80:]: ...{r.get('output','')[-80:]}")

    # Rebalance summary
    print(f"\n{'='*60}")
    print("REBALANCING NEEDED")
    print(f"{'='*60}")
    train = [json.loads(l) for l in open(DATASET / "instruction_train.jsonl", encoding="utf-8") if l.strip()]
    cats = defaultdict(int)
    for r in train: cats[r.get("category","?")] += 1
    total = len(train)
    for cat in sorted(cats.keys(), key=lambda x: -cats[x]):
        actual = cats[cat] / total * 100
        target = targets.get(cat, 0) * 100
        diff = actual - target
        print(f"  {cat}: {cats[cat]} ({actual:.1f}%) target={target:.1f}% diff={diff:+.1f}%")


if __name__ == "__main__":
    main()
