"""
Category-specific validators for instruction dataset.
1. Fix capping: complete functions only, never truncate mid-brace
2. Validate each category with its own logic
3. Score records: valid / broken / needs_context
"""
import json, subprocess, tempfile, os, re, hashlib
from pathlib import Path
from collections import defaultdict

DATASET = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset")
ZIG_ROOTS = [Path(r"C:\B-Plus\zig"), Path(r"C:\Users\Local\zig")]
MAX_OUTPUT = 4096


def find_complete_block(code):
    """Find the last complete syntactic block (fn/test/struct/enum) that fits in MAX_OUTPUT."""
    lines = code.split("\n")
    # Find all top-level block starts
    block_starts = []
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith(("pub fn ", "fn ", "pub const ", "const ", "test ", "pub struct ", "struct ", "pub enum ", "enum ")):
            block_starts.append(i)

    if not block_starts:
        # No blocks found — return as-is if short enough
        return code if len(code) <= MAX_OUTPUT else ""

    # Find the last block that fits completely
    for start_idx in reversed(block_starts):
        # Count braces from start
        depth = 0
        end_idx = start_idx
        for j in range(start_idx, len(lines)):
            depth += lines[j].count("{") - lines[j].count("}")
            if depth <= 0 and j > start_idx:
                end_idx = j
                break
        candidate = "\n".join(lines[start_idx:end_idx + 1])
        if len(candidate) <= MAX_OUTPUT:
            return candidate

    # Try fitting just the last complete block
    last_start = block_starts[-1]
    depth = 0
    end_idx = last_start
    for j in range(last_start, len(lines)):
        depth += lines[j].count("{") - lines[j].count("}")
        if depth <= 0 and j > last_start:
            end_idx = j
            break
    candidate = "\n".join(lines[last_start:end_idx + 1])
    if len(candidate) <= MAX_OUTPUT:
        return candidate

    return ""


def extract_zig_code(text):
    """Extract Zig code blocks from text."""
    blocks = re.findall(r'```zig\n(.*?)```', text, re.DOTALL)
    if blocks:
        return blocks[0].strip()
    blocks = re.findall(r'```\n(.*?)```', text, re.DOTALL)
    if blocks:
        return blocks[0].strip()
    lines = text.split("\n")
    if lines and lines[0].strip().startswith(("pub fn ", "fn ", "pub const ", "const ", "test ")):
        return text.strip()
    return ""


def compile_standalone(code, timeout=5):
    """Compile Zig code as standalone file."""
    with tempfile.NamedTemporaryFile(suffix=".zig", mode="w", delete=False, encoding="utf-8") as f:
        wrapped = code
        if code.strip().startswith(("pub fn ", "fn ")) and "pub fn main" not in code and "const std" not in code:
            wrapped = 'const std = @import("std");\nconst testing = std.testing;\n' + code
        f.write(wrapped)
        f.flush()
        tmp = f.name
    try:
        r = subprocess.run(["zig", "build-obj", tmp], capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0, (r.stderr or "")[:300]
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False, "timeout/not_found"
    finally:
        try:
            os.unlink(tmp)
            for ext in [".o", ".pdb", ".exe", ".json"]:
                p = Path(tmp).with_suffix(ext)
                if p.exists():
                    p.unlink()
        except OSError:
            pass


def validate_code_write(record):
    """Validate code_write: extract Zig code, try compile."""
    output = record.get("output", "")
    code = extract_zig_code(output)
    if not code:
        code = output.strip()
    if not code or len(code) < 30:
        return {"valid": False, "reason": "no_code"}
    ok, err = compile_standalone(code)
    return {"valid": ok, "reason": "compiles" if ok else f"compile_error: {err[:80]}"}


def validate_code_complete(record):
    """Validate code_complete: code should be a valid function body."""
    output = record.get("output", "")
    code = extract_zig_code(output)
    if not code:
        code = output.strip()
    if not code or len(code) < 20:
        return {"valid": False, "reason": "no_code"}
    # Check it has balanced braces
    depth = 0
    for c in code:
        if c == "{": depth += 1
        elif c == "}": depth -= 1
    if depth != 0:
        return {"valid": False, "reason": f"unbalanced_braces depth={depth}"}
    ok, err = compile_standalone(code)
    return {"valid": ok, "reason": "compiles" if ok else f"compile_error: {err[:80]}"}


def validate_code_test(record):
    """Validate code_test: test block should compile."""
    output = record.get("output", "")
    code = extract_zig_code(output)
    if not code:
        code = output.strip()
    if not code or len(code) < 30:
        return {"valid": False, "reason": "no_code"}
    if not code.strip().startswith("test "):
        return {"valid": False, "reason": "not_a_test_block"}
    ok, err = compile_standalone(code)
    return {"valid": ok, "reason": "compiles" if ok else f"compile_error: {err[:80]}"}


def validate_code_explain(record):
    """Validate code_explain: should contain code block + explanation."""
    output = record.get("output", "")
    has_code = bool(re.search(r'```zig\n', output) or re.search(r'```\n', output))
    has_text = len(output) > 100
    code = extract_zig_code(output)
    code_ok = False
    if code and len(code) > 30:
        code_ok, _ = compile_standalone(code)
    return {"valid": has_text and (has_code or code_ok), "reason": f"has_code={has_code} has_text={has_text} code_ok={code_ok}"}


def validate_bplus_locate(record):
    """Validate bplus_locate: output should reference a .zig file."""
    output = record.get("output", "")
    has_file_ref = bool(re.search(r'\.zig', output))
    has_code = bool(re.search(r'```', output))
    return {"valid": has_file_ref or has_code, "reason": f"file_ref={has_file_ref} has_code={has_code}"}


def validate_bplus_arch(record):
    """Validate bplus_arch: output should reference files/functions."""
    output = record.get("output", "")
    has_ref = bool(re.search(r'\.zig|fn |struct |enum ', output))
    has_text = len(output) > 80
    return {"valid": has_ref and has_text, "reason": f"has_ref={has_ref} has_text={has_text}"}


def validate_zig_syntax(record):
    """Validate zig_syntax: should contain explanation of Zig concept."""
    output = record.get("output", "")
    has_code = bool(re.search(r'```', output))
    has_explanation = len(output) > 50
    return {"valid": has_explanation, "reason": f"has_code={has_code} has_explanation={has_explanation}"}


VALIDATORS = {
    "code_write": validate_code_write,
    "code_complete": validate_code_complete,
    "code_test": validate_code_test,
    "code_explain": validate_code_explain,
    "bplus_locate": validate_bplus_locate,
    "bplus_arch": validate_bplus_arch,
    "zig_syntax": validate_zig_syntax,
}


def load_jsonl(path):
    records = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                records.append(json.loads(line))
    return records


def save_jsonl(path, records):
    with open(path, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def main():
    print("CATEGORY-SPECIFIC VALIDATION")
    print("=" * 60)

    for split_name in ["instruction_train", "instruction_val"]:
        path = DATASET / f"{split_name}.jsonl"
        records = load_jsonl(path)
        print(f"\n{split_name}: {len(records)} records")

        # Group by category
        by_cat = defaultdict(list)
        for r in records:
            by_cat[r.get("category", "?")].append(r)

        valid_records = []
        removed = defaultdict(int)

        for cat, cat_records in sorted(by_cat.items()):
            validator = VALIDATORS.get(cat)
            if not validator:
                print(f"  {cat}: NO VALIDATOR — keeping all {len(cat_records)}")
                valid_records.extend(cat_records)
                continue

            # Fix capping: for code categories, keep complete blocks only
            fixed_records = []
            for r in cat_records:
                output = r.get("output", "")
                if len(output) > MAX_OUTPUT:
                    cat_type = r.get("type", "")
                    if cat_type in ("instruction_write", "instruction_complete", "instruction_test"):
                        # Code categories: find complete block
                        fixed = find_complete_block(output)
                        if fixed:
                            r["output"] = fixed
                            fixed_records.append(r)
                        else:
                            removed[cat] += 1
                    else:
                        # Text categories: truncate at paragraph boundary
                        truncated = output[:MAX_OUTPUT]
                        last_para = truncated.rfind("\n\n")
                        if last_para > MAX_OUTPUT // 2:
                            truncated = truncated[:last_para]
                        r["output"] = truncated
                        fixed_records.append(r)
                else:
                    fixed_records.append(r)

            # Validate
            ok_count = 0
            fail_count = 0
            for r in fixed_records:
                result = validator(r)
                if result["valid"]:
                    ok_count += 1
                    valid_records.append(r)
                else:
                    fail_count += 1
                    removed[cat] += 1

            total = ok_count + fail_count
            rate = ok_count / max(1, total) * 100
            print(f"  {cat}: {ok_count}/{total} valid ({rate:.0f}%) removed={removed[cat]}")

        # Save
        save_jsonl(path, valid_records)
        print(f"  SAVED: {split_name} = {len(valid_records)} records")

    # Final stats
    print(f"\n{'='*60}")
    print("FINAL DATASET")
    print(f"{'='*60}")
    train = load_jsonl(DATASET / "instruction_train.jsonl")
    val = load_jsonl(DATASET / "instruction_val.jsonl")
    cats = defaultdict(int)
    for r in train:
        cats[r.get("category", "?")] += 1
    for c, n in sorted(cats.items(), key=lambda x: -x[1]):
        print(f"  {c}: {n}")
    print(f"  Train: {len(train)} | Val: {len(val)}")


if __name__ == "__main__":
    main()
