"""Fast quality gate: validate SAMPLE of each category (100 each)."""
import json, subprocess, tempfile, os, re
from pathlib import Path
from collections import defaultdict

DATASET = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset")
SAMPLE = 100


def extract_zig(text):
    blocks = re.findall(r'```zig\n(.*?)```', text, re.DOTALL)
    if blocks: return blocks[0].strip()
    lines = text.split("\n")
    if lines and lines[0].strip().startswith(("pub fn ", "fn ", "test ", "pub const ")):
        return text.strip()
    return ""


def compile_zig(code, timeout=5):
    with tempfile.NamedTemporaryFile(suffix=".zig", mode="w", delete=False, encoding="utf-8") as f:
        w = code
        if code.strip().startswith(("pub fn ", "fn ")) and "pub fn main" not in code and "const std" not in code:
            w = 'const std = @import("std");\nconst testing = std.testing;\n' + code
        f.write(w); f.flush(); tmp = f.name
    try:
        r = subprocess.run(["zig", "build-obj", tmp], capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0
    except: return False
    finally:
        try: os.unlink(tmp)
        except: pass


def load_jsonl(p):
    return [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]


def main():
    train = load_jsonl(DATASET / "instruction_train.jsonl")
    val = load_jsonl(DATASET / "instruction_val.jsonl")

    by_cat = defaultdict(list)
    for r in train:
        by_cat[r.get("category","?")].append(r)

    print("CATEGORY VALIDATION (sampled)")
    print("=" * 60)

    for cat in sorted(by_cat.keys()):
        records = by_cat[cat]
        sample = records[:SAMPLE]
        ok = 0; fail = 0; skip = 0
        reasons = defaultdict(int)

        for r in sample:
            out = r.get("output", "")
            code = extract_zig(out)
            if not code or len(code) < 20:
                skip += 1
                reasons["no_code"] += 1
                continue

            if cat in ("code_write", "code_complete", "code_test"):
                # These should compile standalone
                c = compile_zig(code)
                if c: ok += 1
                else: fail += 1; reasons["compile_fail"] += 1
            elif cat == "zig_syntax":
                # Should have explanation + optional code
                has_text = len(out) > 50
                if has_text: ok += 1
                else: fail += 1; reasons["too_short"] += 1
            elif cat == "code_explain":
                # Should have code block + explanation
                has_code = bool(re.search(r'```', out))
                has_text = len(out) > 100
                if has_text: ok += 1
                else: fail += 1; reasons["insufficient"] += 1
            elif cat in ("bplus_locate", "bplus_arch"):
                # Should reference files/functions
                has_ref = bool(re.search(r'\.zig|fn |struct ', out))
                if has_ref and len(out) > 50: ok += 1
                else: fail += 1; reasons["no_reference"] += 1
            else:
                skip += 1; reasons["unknown_cat"] += 1

        total = ok + fail
        rate = ok / max(1, total) * 100
        print(f"\n  {cat} ({len(records)} total, {len(sample)} sampled):")
        print(f"    VALID={ok} FAIL={fail} SKIP={skip} RATE={rate:.0f}%")
        if reasons:
            print(f"    reasons: {dict(reasons)}")

    # Also check: how many code_write/complete outputs are raw code vs explanation
    print(f"\n{'='*60}")
    print("CODE OUTPUT FORMAT CHECK")
    print(f"{'='*60}")
    for cat in ["code_write", "code_complete"]:
        records = by_cat.get(cat, [])[:200]
        raw_code = 0
        with_explanation = 0
        for r in records:
            out = r.get("output", "")
            if out.strip().startswith(("pub fn ", "fn ", "pub const ", "const ", "test ")):
                raw_code += 1
            elif re.search(r'```zig', out):
                with_explanation += 1
            else:
                with_explanation += 1
        print(f"  {cat}: raw_code={raw_code} with_explanation={with_explanation}")


if __name__ == "__main__":
    main()
