"""
Production quality gate + rebalance.
1. Validate each record by category
2. Remove failures
3. Rebalance to target distribution
4. Save final dataset
"""
import json, re, subprocess, tempfile, os
from pathlib import Path
from collections import defaultdict

DATASET = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset")

TARGETS = {
    "code_write": 0.25,
    "code_complete": 0.15,
    "code_test": 0.15,
    "code_explain": 0.10,
    "bplus_locate": 0.15,
    "bplus_arch": 0.10,
    "zig_syntax": 0.05,
    "hard_example": 0.05,
}


def validate_record(r):
    """Validate a single record. Returns (pass, reason)."""
    cat = r.get("category", "")
    output = r.get("output", "")
    instruction = r.get("instruction", "")

    # Universal checks
    if not output or len(output) < 20:
        return False, "empty_output"
    if not instruction or len(instruction) < 10:
        return False, "empty_instruction"

    # Category-specific
    if cat in ("code_write", "code_complete", "code_test"):
        # Extract code
        blocks = re.findall(r'```zig\n(.*?)```', output, re.DOTALL)
        code = blocks[0].strip() if blocks else output.strip()
        if not code or len(code) < 30:
            return False, "no_code"
        # Balanced braces
        depth = 0
        for c in code:
            if c == "{": depth += 1
            elif c == "}": depth -= 1
        if depth != 0:
            return False, f"unbalanced_braces({depth})"
        # No trailing operators
        last_line = code.strip().split("\n")[-1].strip()
        if last_line.endswith((",", "+", "-", "*", "|", "&")):
            return False, "trailing_operator"
        # Has declaration
        if not re.search(r'(pub\s+)?(fn|test|struct|enum)\s+', code):
            return False, "no_declaration"

    elif cat == "code_explain":
        if len(output) < 80:
            return False, "too_short"
        if not re.search(r'```', output):
            return False, "no_code_block"

    elif cat in ("bplus_locate", "bplus_arch"):
        if not re.search(r'\.zig|fn \w+', output):
            return False, "no_file_reference"
        if len(output) < 50:
            return False, "too_short"

    elif cat == "zig_syntax":
        if len(output) < 30:
            return False, "too_short"

    elif cat == "hard_example":
        if not re.search(r'```', output):
            return False, "no_code_block"
        if not r.get("file"):
            return False, "no_file_reference"

    # Check evidence field
    if cat in ("bplus_locate", "bplus_arch", "hard_example"):
        if not r.get("evidence"):
            return False, "no_evidence"

    return True, "ok"


def load_jsonl(p):
    return [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]


def save_jsonl(p, records):
    with open(p, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def main():
    print("PRODUCTION QUALITY GATE")
    print("=" * 60)

    for split in ["instruction_train", "instruction_val"]:
        path = DATASET / f"{split}.jsonl"
        records = load_jsonl(path)
        print(f"\n{split}: {len(records)} records")

        # Validate
        valid = []
        removed = defaultdict(int)
        for r in records:
            ok, reason = validate_record(r)
            if ok:
                valid.append(r)
            else:
                removed[reason] += 1

        print(f"  Passed: {len(valid)}")
        print(f"  Removed: {len(records) - len(valid)}")
        for reason, count in sorted(removed.items(), key=lambda x: -x[1]):
            print(f"    {reason}: {count}")

        # Save validated
        save_jsonl(path, valid)

        # Rebalance (only for train)
        if split == "instruction_train":
            print(f"\n  Rebalancing...")
            by_cat = defaultdict(list)
            for r in valid:
                by_cat[r.get("category", "?")].append(r)

            total = len(valid)
            balanced = []
            for cat, cat_records in by_cat.items():
                target_n = int(total * TARGETS.get(cat, 0.05))
                if len(cat_records) <= target_n:
                    balanced.extend(cat_records)
                else:
                    balanced.extend(cat_records[:target_n])

            save_jsonl(path, balanced)
            print(f"  Balanced: {len(balanced)}")

            # Final stats
            cats = defaultdict(int)
            for r in balanced: cats[r.get("category", "?")] += 1
            t = len(balanced)
            for c, n in sorted(cats.items(), key=lambda x: -x[1]):
                pct = n / t * 100
                target = TARGETS.get(c, 0) * 100
                print(f"    {c}: {n} ({pct:.1f}%) target={target:.1f}%")


if __name__ == "__main__":
    main()
