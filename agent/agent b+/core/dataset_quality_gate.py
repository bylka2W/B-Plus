"""
Dataset Quality Gate — fixes and validates instruction dataset.
1. Remove output-hash leakage (val → train)
2. Cap outputs at 4096 chars
3. Remove records with output < 20 chars
4. Verify sample of Zig code compiles
"""
import json, subprocess, tempfile, os, re, collections
from pathlib import Path

DATASET = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset")
MAX_OUTPUT = 4096
MIN_OUTPUT = 20


def extract_zig_code(text):
    """Extract Zig code from output text."""
    blocks = re.findall(r'```zig\n(.*?)```', text, re.DOTALL)
    if blocks:
        return blocks[0].strip()
    blocks = re.findall(r'```\n(.*?)```', text, re.DOTALL)
    if blocks:
        return blocks[0].strip()
    # If starts with fn/pub fn/test/pub const — assume it's raw code
    lines = text.split("\n")
    if lines and lines[0].strip().startswith(("pub fn ", "fn ", "pub const ", "const ", "test ")):
        return text.strip()
    return ""


def try_compile(code, timeout=5):
    """Try to compile Zig code."""
    with tempfile.NamedTemporaryFile(suffix=".zig", mode="w", delete=False, encoding="utf-8") as f:
        # Wrap in a minimal main if it's just a function
        wrapped = code
        if code.strip().startswith(("pub fn ", "fn ")) and "pub fn main" not in code:
            wrapped = 'const std = @import("std");\n' + code
        f.write(wrapped)
        f.flush()
        tmp = f.name
    try:
        r = subprocess.run(
            ["zig", "build-obj", tmp],
            capture_output=True, text=True, timeout=timeout
        )
        return r.returncode == 0, r.stderr[:300] if r.stderr else ""
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False, "timeout/not_found"
    finally:
        try:
            os.unlink(tmp)
            for ext in [".o", ".pdb", ".exe"]:
                p = Path(tmp).with_suffix(ext)
                if p.exists(): p.unlink()
        except OSError:
            pass


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
    # Load
    train = load_jsonl(DATASET / "instruction_train.jsonl")
    val = load_jsonl(DATASET / "instruction_val.jsonl")
    print(f"Loaded: train={len(train)} val={len(val)}")

    # Step 1: Remove output-hash leakage from val
    print(f"\n{'='*60}")
    print("STEP 1: Remove output-hash leakage")
    print(f"{'='*60}")
    train_hashes = set()
    for r in train:
        h = hash(r.get("output", ""))
        train_hashes.add(h)

    overlap = 0
    clean_val = []
    for r in val:
        h = hash(r.get("output", ""))
        if h in train_hashes:
            overlap += 1
        else:
            clean_val.append(r)
    print(f"  Removed {overlap} overlapping records from val")
    print(f"  Val: {len(val)} -> {len(clean_val)}")
    val = clean_val

    # Step 2: Cap outputs
    print(f"\n{'='*60}")
    print("STEP 2: Cap outputs at {MAX_OUTPUT} chars")
    print(f"{'='*60}")
    capped = 0
    for r in train + val:
        out = r.get("output", "")
        if len(out) > MAX_OUTPUT:
            r["output"] = out[:MAX_OUTPUT]
            capped += 1
    print(f"  Capped {capped} oversized outputs")

    # Step 3: Remove short outputs
    print(f"\n{'='*60}")
    print(f"STEP 3: Remove outputs < {MIN_OUTPUT} chars")
    print(f"{'='*60}")
    before_t = len(train)
    before_v = len(val)
    train = [r for r in train if len(r.get("output", "")) >= MIN_OUTPUT]
    val = [r for r in val if len(r.get("output", "")) >= MIN_OUTPUT]
    print(f"  Train: {before_t} -> {len(train)}")
    print(f"  Val: {before_v} -> {len(val)}")

    # Step 4: Verify Zig code compiles (sample 50 from each category)
    print(f"\n{'='*60}")
    print("STEP 4: Compile verification (sample 30 per category)")
    print(f"{'='*60}")
    compile_stats = collections.defaultdict(lambda: {"ok": 0, "fail": 0, "skip": 0})

    by_cat = collections.defaultdict(list)
    for r in train:
        by_cat[r.get("category", "?")].append(r)

    for cat, records in by_cat.items():
        sample = records[:30]
        for r in sample:
            code = extract_zig_code(r.get("output", ""))
            if not code or len(code) < 20:
                compile_stats[cat]["skip"] += 1
                continue
            ok, err = try_compile(code)
            if ok:
                compile_stats[cat]["ok"] += 1
            else:
                compile_stats[cat]["fail"] += 1

    for cat in sorted(compile_stats.keys()):
        s = compile_stats[cat]
        total = s["ok"] + s["fail"] + s["skip"]
        rate = s["ok"] / max(1, s["ok"] + s["fail"]) * 100
        print(f"  {cat}: {s['ok']}/{s['ok']+s['fail']} compile ({rate:.0f}%) skip={s['skip']}")

    # Step 5: Save cleaned dataset
    print(f"\n{'='*60}")
    print("STEP 5: Save cleaned dataset")
    print(f"{'='*60}")
    save_jsonl(DATASET / "instruction_train.jsonl", train)
    save_jsonl(DATASET / "instruction_val.jsonl", val)
    print(f"  Saved: train={len(train)} val={len(val)}")

    # Step 6: Summary
    print(f"\n{'='*60}")
    print("FINAL SUMMARY")
    print(f"{'='*60}")
    cats = collections.Counter(r.get("category","?") for r in train)
    for c, n in cats.most_common():
        print(f"  {c}: {n}")
    tags = collections.Counter(r.get("source_tag","?") for r in train)
    print(f"  Tags: {dict(tags)}")
    print(f"  Train: {len(train)} | Val: {len(val)}")


if __name__ == "__main__":
    main()
