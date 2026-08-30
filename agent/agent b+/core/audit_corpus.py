import json, collections, re, hashlib, sys
from pathlib import Path

CORPUS = Path(r"C:\B-Plus\agent\agent b+\knowledge\corpus")

def has_cyrillic(text):
    return bool(re.search(r'[\u0400-\u04FF]', text))

def has_cjk(text):
    return bool(re.search(r'[\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufaff]', text))

def has_control(text):
    return bool(re.search(r'[\x00-\x08\x0e-\x1f]', text))

def strip_comments(code):
    result = []
    i = 0
    while i < len(code):
        if code[i:i+2] == '//':
            while i < len(code) and code[i] != '\n':
                i += 1
        elif code[i:i+2] == '/*':
            i += 2
            depth = 1
            while i < len(code) and depth > 0:
                if code[i:i+2] == '/*': depth += 1; i += 2
                elif code[i:i+2] == '*/': depth -= 1; i += 2
                else: i += 1
        else:
            result.append(code[i])
            i += 1
    return ''.join(result)

print("=" * 60)
print("CORPUS AUDIT")
print("=" * 60)

# --- ZIG CORPUS ---
zig_path = CORPUS / "zig_corpus.jsonl"
stats = {
    "total": 0, "types": collections.Counter(), "sources": collections.Counter(),
    "cjk": 0, "control": 0, "empty_output": 0, "short_output": 0,
    "bplus": 0, "zig_compiler": 0, "duplicate_hash": 0,
    "line_counts": [], "output_lens": [],
}
seen_hashes = set()

with open(zig_path, encoding="utf-8") as f:
    for i, line in enumerate(f):
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            print(f"  BAD JSON at line {i+1}")
            continue
        stats["total"] += 1
        stats["types"][r.get("type", "?")] += 1
        src = r.get("source", "?")
        stats["sources"][src] += 1
        if src == "bplus": stats["bplus"] += 1
        elif src == "zig_compiler": stats["zig_compiler"] += 1
        
        out = r.get("output", "")
        inp = r.get("input", "")
        combined = inp + out
        
        if not out: stats["empty_output"] += 1
        elif len(out) < 50: stats["short_output"] += 1
        
        h = hashlib.md5(combined.encode()).hexdigest()
        if h in seen_hashes: stats["duplicate_hash"] += 1
        seen_hashes.add(h)
        
        if has_cjk(combined): stats["cjk"] += 1
        if has_control(combined): stats["control"] += 1
        
        stats["line_counts"].append(r.get("lines", 0))
        stats["output_lens"].append(len(out))

print(f"\nZIG CORPUS ({zig_path.name}):")
print(f"  total records: {stats['total']}")
print(f"  types: {dict(stats['types'])}")
print(f"  sources: {dict(stats['sources'])}")
print(f"  B+ files: {stats['bplus']}")
print(f"  Zig compiler files: {stats['zig_compiler']}")
print(f"  CJK text found: {stats['cjk']}")
print(f"  Control chars: {stats['control']}")
print(f"  Empty output: {stats['empty_output']}")
print(f"  Short output (<50 chars): {stats['short_output']}")
print(f"  Duplicate hashes: {stats['duplicate_hash']}")
if stats["line_counts"]:
    lc = stats["line_counts"]
    ol = stats["output_lens"]
    print(f"  lines: min={min(lc)} max={max(lc)} avg={sum(lc)/len(lc):.0f}")
    print(f"  output chars: min={min(ol)} max={max(ol)} avg={sum(ol)/len(ol):.0f}")

# --- RUSSIAN CORPUS ---
ru_path = CORPUS / "russian_corpus.jsonl"
ru_stats = {
    "total": 0, "keys": collections.Counter(), "cjk": 0,
    "cyrillic": 0, "no_cyrillic": 0, "templates_only": 0,
    "empty": 0, "short": 0,
}
template_patterns = [
    r"Где определена функция",
    r"Кто вызывает",
    r"Найди все ссылки",
    r"Добавь функцию",
    r"Исправь ошибку",
    r"Напиши тест",
    r"Объясни что делает",
    r"Проведи рефакторинг",
    r"От чего зависит",
    r"Проследи цепочку",
]

with open(ru_path, encoding="utf-8") as f:
    for i, line in enumerate(f):
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            print(f"  BAD JSON at line {i+1}")
            continue
        ru_stats["total"] += 1
        for k in r.keys():
            ru_stats["keys"][k] += 1
        
        text = json.dumps(r, ensure_ascii=False)
        if not text.strip():
            ru_stats["empty"] += 1
            continue
        if len(text) < 20:
            ru_stats["short"] += 1
        
        if has_cjk(text): ru_stats["cjk"] += 1
        if has_cyrillic(text): ru_stats["cyrillic"] += 1
        else: ru_stats["no_cyrillic"] += 1
        
        is_template = any(re.search(p, text) for p in template_patterns)
        if is_template: ru_stats["templates_only"] += 1

print(f"\nRUSSIAN CORPUS ({ru_path.name}):")
print(f"  total records: {ru_stats['total']}")
print(f"  keys: {dict(ru_stats['keys'])}")
print(f"  CJK text: {ru_stats['cjk']}")
print(f"  Has Cyrillic: {ru_stats['cyrillic']}")
print(f"  No Cyrillic: {ru_stats['no_cyrillic']}")
print(f"  Template-only (no real content): {ru_stats['templates_only']}")
print(f"  Empty: {ru_stats['empty']}")
print(f"  Short (<20 chars): {ru_stats['short']}")

# Show first 3 records
print("\n  First 3 records:")
with open(ru_path, encoding="utf-8") as f:
    for i, line in enumerate(f):
        if i >= 3: break
        r = json.loads(line)
        print(f"  [{i}] {json.dumps(r, ensure_ascii=False)[:200]}")

# --- QUALITY AUDIT ---
qa_path = CORPUS / "quality_audit.json"
if qa_path.exists():
    with open(qa_path, encoding="utf-8") as f:
        qa = json.load(f)
    print(f"\nQUALITY AUDIT:")
    for k, v in qa.items():
        if isinstance(v, (int, float, str, bool)):
            print(f"  {k}: {v}")
        elif isinstance(v, list):
            print(f"  {k}: [{len(v)} items]")
        elif isinstance(v, dict):
            print(f"  {k}: {len(v)} keys")

print("\n" + "=" * 60)
print("SUMMARY")
print("=" * 60)
issues = []
if stats["cjk"]: issues.append(f"CJK in Zig corpus: {stats['cjk']}")
if stats["control"]: issues.append(f"Control chars in Zig: {stats['control']}")
if stats["empty_output"]: issues.append(f"Empty outputs: {stats['empty_output']}")
if stats["duplicate_hash"]: issues.append(f"Duplicate hashes: {stats['duplicate_hash']}")
if ru_stats["cjk"]: issues.append(f"CJK in Russian: {ru_stats['cjk']}")
if ru_stats["templates_only"]: issues.append(f"Template-only Russian: {ru_stats['templates_only']}/{ru_stats['total']}")
if ru_stats["no_cyrillic"]: issues.append(f"Russian records without Cyrillic: {ru_stats['no_cyrillic']}")
if not issues:
    print("  No critical issues found.")
else:
    for iss in issues:
        print(f"  ISSUE: {iss}")

print(f"\n  B+ vs Generic Zig: {stats['bplus']}/{stats['zig_compiler']} ({stats['bplus']/max(1,stats['zig_compiler'])*100:.1f}%)")
print(f"  Instruction examples: 0 (need to build)")
print(f"  Curriculum stages: 0 (need to build)")
print(f"  Evaluation: 0 (need to build)")
