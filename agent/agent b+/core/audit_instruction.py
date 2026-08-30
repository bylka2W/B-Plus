"""Audit instruction dataset quality."""
import json, collections, re
from pathlib import Path

DATASET = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset")

def has_cyrillic(t):
    return bool(re.search(r'[\u0400-\u04FF]', t))

def audit_split(name, path):
    print(f"\n{'='*60}")
    print(f"AUDIT: {name}")
    print(f"{'='*60}")

    records = []
    with open(path, encoding="utf-8") as f:
        for i, line in enumerate(f):
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                print(f"  BAD JSON at line {i+1}")

    print(f"  Total records: {len(records)}")

    # Types
    types = collections.Counter(r.get("type","?") for r in records)
    print(f"  Types: {dict(types)}")

    # Categories
    cats = collections.Counter(r.get("category","?") for r in records)
    print(f"  Categories: {dict(cats)}")

    # Source tags
    tags = collections.Counter(r.get("source_tag","?") for r in records)
    print(f"  Source tags: {dict(tags)}")

    # IDs
    ids = [r.get("id","") for r in records]
    dup_ids = len(ids) - len(set(ids))
    print(f"  Duplicate IDs: {dup_ids}")

    # Empty outputs
    empty_out = sum(1 for r in records if not r.get("output","").strip())
    print(f"  Empty outputs: {empty_out}")

    # Short outputs
    short = sum(1 for r in records if len(r.get("output","")) < 20)
    print(f"  Short outputs (<20 chars): {short}")

    # Empty instructions
    empty_inst = sum(1 for r in records if not r.get("instruction","").strip())
    print(f"  Empty instructions: {empty_inst}")

    # No Cyrillic in instruction (for categories that should have it)
    ru_cats = {"instruction_write","instruction_complete","instruction_explain",
               "instruction_test","instruction_struct","instruction_enum",
               "bplus_locate","bplus_arch","zig_syntax"}
    no_ru = sum(1 for r in records if r.get("category") in ru_cats
                and not has_cyrillic(r.get("instruction","")))
    print(f"  Non-Cyrillic instructions (should be Russian): {no_ru}")

    # Files with more than 100 records
    file_counts = collections.Counter(r.get("file","") for r in records)
    hot_files = [(f,c) for f,c in file_counts.most_common(5)]
    print(f"  Top 5 files by record count:")
    for f,c in hot_files:
        print(f"    {f}: {c}")

    # Output length distribution
    lens = [len(r.get("output","")) for r in records]
    if lens:
        print(f"  Output length: min={min(lens)} max={max(lens)} avg={sum(lens)/len(lens):.0f}")

    # Sample records
    print(f"\n  Samples (first 3):")
    for r in records[:3]:
        print(f"    type={r.get('type')} cat={r.get('category')} tag={r.get('source_tag')}")
        print(f"      instruction: {r.get('instruction','')[:80]}")
        print(f"      output: {r.get('output','')[:80]}")

    return records


def check_leakage(train_records, val_records):
    """Check for data leakage between train and val."""
    print(f"\n{'='*60}")
    print("LEAKAGE CHECK")
    print(f"{'='*60}")

    train_files = set(r.get("file","") for r in train_records)
    val_files = set(r.get("file","") for r in val_records)
    overlap = train_files & val_files
    print(f"  Train files: {len(train_files)}")
    print(f"  Val files: {len(val_files)}")
    print(f"  Overlapping files: {len(overlap)}")
    if overlap:
        print(f"  WARNING: {len(overlap)} files appear in both train and val!")
        for f in list(overlap)[:5]:
            print(f"    {f}")

    # Check by output hash
    train_hashes = set()
    for r in train_records:
        h = hash(r.get("output",""))
        train_hashes.add(h)
    val_hashes = set()
    for r in val_records:
        h = hash(r.get("output",""))
        val_hashes.add(h)
    hash_overlap = train_hashes & val_hashes
    print(f"  Output hash overlap: {len(hash_overlap)}")


def main():
    train = audit_split("TRAIN", DATASET / "instruction_train.jsonl")
    val = audit_split("VAL", DATASET / "instruction_val.jsonl")
    check_leakage(train, val)


if __name__ == "__main__":
    main()
