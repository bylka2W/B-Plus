"""Combine verified self-contained + spec-based B+ datasets."""
import json, hashlib
from pathlib import Path
from collections import defaultdict

OUT_DIR = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset")
SELF_CONTAINED = OUT_DIR / "self_contained_train.jsonl"
SPEC_BASED = OUT_DIR / "instruction_train.jsonl"
COMBINED_TRAIN = OUT_DIR / "combined_train.jsonl"
COMBINED_VAL = OUT_DIR / "combined_val.jsonl"


def make_id(kind, name):
    return hashlib.sha256(f"{kind}:{name}".encode()).hexdigest()[:16]


def main():
    # Load self-contained (high quality, compile-verified)
    sc_examples = []
    if SELF_CONTAINED.exists():
        for line in open(SELF_CONTAINED, encoding="utf-8"):
            if line.strip():
                sc_examples.append(json.loads(line))

    # Load spec-based
    spec_examples = []
    if SPEC_BASED.exists():
        for line in open(SPEC_BASED, encoding="utf-8"):
            if line.strip():
                spec_examples.append(json.loads(line))

    print(f"Self-contained: {len(sc_examples)}")
    print(f"Spec-based: {len(spec_examples)}")

    # Strategy: self-contained for code_write/complete/test, spec-based for bplus/syntax/explain
    # Keep only verified examples from spec-based for code categories
    combined = []

    # 1. All self-contained (verified)
    for ex in sc_examples:
        combined.append(ex)

    # 2. Spec-based: keep bplus and syntax
    for ex in spec_examples:
        cat = ex.get("category", "")
        if cat in ("bplus_locate", "bplus_arch", "zig_syntax", "code_explain"):
            combined.append(ex)

    # Deduplicate by instruction
    seen = set()
    deduped = []
    for ex in combined:
        key = ex.get("instruction", "")[:100]
        if key not in seen:
            seen.add(key)
            deduped.append(ex)

    # Split 80/20
    split_idx = int(len(deduped) * 0.8)
    train = deduped[:split_idx]
    val = deduped[split_idx:]

    # Save
    for name, data in [("combined_train", train), ("combined_val", val)]:
        with open(OUT_DIR / f"{name}.jsonl", "w", encoding="utf-8") as f:
            for ex in data:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")

    # Stats
    cats = defaultdict(int)
    for ex in train: cats[ex.get("category", "?")] += 1
    v = sum(1 for ex in train if ex.get("verified"))
    print(f"\nCombined: {len(deduped)} (deduped from {len(combined)})")
    print(f"Train: {len(train)} | Val: {len(val)}")
    print(f"Verified: {v}/{len(train)} ({v*100//max(1,len(train))}%)")
    for c, n in sorted(cats.items(), key=lambda x: -x[1]):
        print(f"  {c}: {n}")


if __name__ == "__main__":
    main()
