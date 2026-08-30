import json, collections, re, hashlib
from pathlib import Path

CORPUS = Path(r"C:\B-Plus\agent\agent b+\knowledge\corpus")
OUT = CORPUS

def has_cjk(text):
    return bool(re.search(r'[\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufaff]', text))

def classify_short(code):
    code = code.strip()
    if len(code) < 5:
        return "tiny"
    if code.startswith("//") or code.startswith("///"):
        return "comment_only"
    if code.startswith("pub const") or code.startswith("const "):
        return "const_decl"
    lines = code.split("\n")
    if len(lines) <= 2 and "{" not in code:
        return "single_line"
    if all(l.strip().startswith("//") or l.strip() == "" for l in lines):
        return "all_comments"
    if code.startswith("test ") or code.startswith('test "'):
        return "test_wrapper"
    return "other_short"

print("=" * 70)
print("STEP 1: FIND CJK ENTRIES")
print("=" * 70)
cjk_entries = []
with open(CORPUS / "zig_corpus.jsonl", encoding="utf-8") as f:
    for i, line in enumerate(f):
        r = json.loads(line)
        combined = r.get("input", "") + r.get("output", "")
        if has_cjk(combined):
            cjk_entries.append((i, r))
            print(f"  line {i+1}: type={r.get('type')} file={r.get('file','?')[:60]}")
            cjk_chars = [c for c in combined if '\u4e00' <= c <= '\u9fff']
            print(f"    CJK chars found: {len(cjk_chars)} (U+{' U+'.join(format(ord(c),'04X') for c in cjk_chars[:5])})")
            print(f"    output[:100]: {r.get('output','')[:100]}")
print(f"  Total CJK: {len(cjk_entries)}")

print(f"\n{'='*70}")
print("STEP 2: ANALYZE DUPLICATES")
print("=" * 70)
hash_map = collections.defaultdict(list)
with open(CORPUS / "zig_corpus.jsonl", encoding="utf-8") as f:
    for i, line in enumerate(f):
        r = json.loads(line)
        h = hashlib.md5((r.get("input","") + r.get("output","")).encode()).hexdigest()
        hash_map[h].append((i, r))

dup_groups = {h: entries for h, entries in hash_map.items() if len(entries) > 1}
print(f"  Unique hashes: {len(hash_map)}")
print(f"  Duplicate groups: {len(dup_groups)}")
print(f"  Total duplicate records: {sum(len(e) for e in dup_groups.values())}")

# Show top 5 duplicate groups
print(f"\n  Top 5 duplicate groups:")
for h, entries in sorted(dup_groups.items(), key=lambda x: -len(x[1]))[:5]:
    print(f"    hash={h[:8]} count={len(entries)} type={entries[0][1].get('type')} file={entries[0][1].get('file','?')[:50]}")
    # Check if all are from same source
    sources = set(e[1].get("source","?") for e in entries)
    print(f"      sources={sources}")

# Group duplicates by type and source
dup_by_type = collections.Counter()
dup_by_source = collections.Counter()
for h, entries in dup_groups.items():
    t = entries[0][1].get("type", "?")
    s = entries[0][1].get("source", "?")
    dup_by_type[t] += len(entries) - 1
    dup_by_source[s] += len(entries) - 1
print(f"\n  Duplicates by type: {dict(dup_by_type)}")
print(f"  Duplicates by source: {dict(dup_by_source)}")

print(f"\n{'='*70}")
print("STEP 3: CLASSIFY SHORT OUTPUTS (<50 chars)")
print("=" * 70)
short_classes = collections.Counter()
short_examples = collections.defaultdict(list)
with open(CORPUS / "zig_corpus.jsonl", encoding="utf-8") as f:
    for i, line in enumerate(f):
        r = json.loads(line)
        out = r.get("output", "")
        if len(out) < 50:
            cls = classify_short(out)
            short_classes[cls] += 1
            if len(short_examples[cls]) < 3:
                short_examples[cls].append((i, r.get("file","?")[:40], out[:80]))

for cls, count in short_classes.most_common():
    print(f"  {cls}: {count}")
    for idx, fp, ex in short_examples[cls]:
        print(f"    [{idx}] file={fp}")
        print(f"      output: {ex}")

print(f"\n{'='*70}")
print("STEP 4: PRODUCE CLEAN CORPUS")
print("=" * 70)
# Build set of CJK line numbers to skip
cjk_lines = set(i for i, _ in cjk_entries)

# Build dedup: keep first occurrence of each hash
seen_hashes = set()
removed = collections.Counter()
kept = 0
clean_records = []

with open(CORPUS / "zig_corpus.jsonl", encoding="utf-8") as f:
    for i, line in enumerate(f):
        r = json.loads(line)
        combined = r.get("input", "") + r.get("output", "")
        h = hashlib.md5(combined.encode()).hexdigest()
        
        if i in cjk_lines:
            removed["cjk"] += 1
            continue
        if h in seen_hashes:
            removed["duplicate"] += 1
            continue
        seen_hashes.add(h)
        
        # Skip very short outputs (but keep const_decl and single_line which are valid)
        out = r.get("output", "")
        if len(out) < 50:
            cls = classify_short(out)
            if cls in ("tiny", "comment_only", "all_comments"):
                removed[f"short_{cls}"] += 1
                continue
        
        clean_records.append(r)
        kept += 1

# Write clean corpus
out_path = OUT / "zig_corpus_clean.jsonl"
with open(out_path, "w", encoding="utf-8") as f:
    for r in clean_records:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")

print(f"  Original: 37376 records")
print(f"  Removed:")
for reason, count in removed.most_common():
    print(f"    {reason}: {count}")
print(f"  Kept: {kept} records")
print(f"  Written to: {out_path}")

# Final stats
src_counter = collections.Counter()
type_counter = collections.Counter()
for r in clean_records:
    src_counter[r.get("source", "?")] += 1
    type_counter[r.get("type", "?")] += 1
print(f"\n  Clean corpus sources: {dict(src_counter)}")
print(f"  Clean corpus types: {dict(type_counter)}")
print(f"  B+ ratio: {src_counter.get('bplus',0)/max(1,src_counter.get('zig_compiler',1))*100:.0f}%")
