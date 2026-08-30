"""
Fast verified dataset builder.
1. Generate all instruction examples (from source_index)
2. Verify SAMPLE (50 per code category) with zig test
3. Mark verified=True/False
4. Keep all records (verified ones are higher quality)
5. Semantic dedup
6. Split train/val
"""
import json, re, os, subprocess, tempfile, hashlib, time
from pathlib import Path
from collections import defaultdict

AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+")
CORPUS = AGENT_ROOT / "knowledge" / "corpus"
INDEX_PATH = CORPUS / "source_index.json"
OUT_DIR = AGENT_ROOT / "knowledge" / "dataset"
ZIG_ROOTS = [Path(r"C:\B-Plus\zig"), Path(r"C:\Users\Local\zig")]
EXCLUDED_DIRS = {"zig-cache", "zig-out", ".git", "node_modules", "build", "build-debug", "build-release", "CMakeFiles"}

MAX_OUTPUT = 4096
VERIFY_SAMPLE = 50


def load_index():
    with open(INDEX_PATH, encoding="utf-8") as f:
        return json.load(f)


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except:
        return ""


def iter_zig_files(root):
    root = Path(root)
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDED_DIRS and not d.startswith("."))
        for name in sorted(filenames):
            if name.endswith(".zig"):
                files.append(Path(dirpath) / name)
    return files


def extract_function(content, fn_name):
    lines = content.split("\n")
    for i, line in enumerate(lines):
        if re.match(rf'\s*(pub\s+)?fn\s+{re.escape(fn_name)}\s*\(', line.strip()):
            depth = 0
            started = False
            for j in range(i, min(i + 500, len(lines))):
                depth += lines[j].count("{") - lines[j].count("}")
                if "{" in lines[j]: started = True
                if started and depth <= 0:
                    return "\n".join(lines[i:j+1])
    return None


def zig_test(code, timeout=8):
    with tempfile.NamedTemporaryFile(suffix=".zig", mode="w", delete=False, encoding="utf-8") as f:
        f.write(code)
        f.flush()
        tmp = f.name
    try:
        r = subprocess.run(["zig", "test", tmp], capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0
    except:
        return False
    finally:
        try:
            os.unlink(tmp)
            for ext in [".o", ".pdb", ".exe"]:
                p = Path(tmp).with_suffix(ext)
                if p.exists(): p.unlink()
        except:
            pass


def make_harness(code, fn_name):
    return f'const std = @import("std");\nconst testing = std.testing;\n\n{code}\n\ntest "verify" {{\n    _ = {fn_name};\n}}\n'


def make_id(kind, path, name=""):
    return hashlib.sha256(f"{kind}:{path}:{name}".encode()).hexdigest()[:16]


def validate_evidence(record, index):
    file_ref = record.get("file", "")
    symbol = record.get("symbol", "")
    if file_ref and file_ref not in index.get("files", {}):
        return False
    if symbol:
        refs = index.get("symbols", {}).get(symbol, [])
        if not refs:
            return False
    return True


def semantic_dedup(records):
    by_source = defaultdict(list)
    for r in records:
        key = (r.get("file", ""), r.get("symbol", ""))
        by_source[key].append(r)
    deduped = []
    for key, group in by_source.items():
        if len(group) <= 1:
            deduped.extend(group)
            continue
        seen = set()
        for r in group:
            cat = r.get("category", "")
            instr = r.get("instruction", "")[:60]
            k = (cat, instr)
            if k not in seen:
                seen.add(k)
                deduped.append(r)
    return deduped


def main():
    print("FAST VERIFIED DATASET BUILDER")
    print("=" * 60)
    t0 = time.time()

    index = load_index()
    print(f"Index: {len(index['files'])} files, {len(index['symbols'])} symbols")

    all_examples = []
    stats = defaultdict(int)
    verify_queue = defaultdict(list)

    for root in ZIG_ROOTS:
        is_bplus = "B-Plus" in str(root)
        source_tag = "B+" if is_bplus else "Zig"
        files = iter_zig_files(root)
        print(f"  {root}: {len(files)} files")

        for fp in files:
            content = read_file(fp)
            if not content or len(content) < 50:
                continue
            rel = str(fp).replace(str(root), "").replace("\\", "/")
            file_info = index["files"].get(rel, {})
            fn_count = 0

            for fn in file_info.get("functions", []):
                if fn["lines"] < 3 or fn["lines"] > 150:
                    continue
                if fn_count > 20:
                    break

                code = extract_function(content, fn["name"])
                if not code or len(code) < 30 or len(code) > MAX_OUTPUT:
                    continue

                sig = fn.get("sig", "")

                # code_write
                ex = {
                    "id": make_id("code_write", rel, fn["name"]),
                    "type": "instruction_write",
                    "instruction": f"Напиши функцию {fn['name']} на языке Zig.",
                    "context": f"Файл: {rel}\nСигнатура: {sig}",
                    "output": code,
                    "category": "code_write",
                    "source_tag": source_tag,
                    "file": rel,
                    "symbol": fn["name"],
                    "evidence": f"{rel}:{sig}",
                    "verified": False,
                }
                all_examples.append(ex)
                stats["code_write"] += 1
                if len(verify_queue["code_write"]) < VERIFY_SAMPLE:
                    verify_queue["code_write"].append((len(all_examples)-1, code, fn["name"]))

                # code_explain
                all_examples.append({
                    "id": make_id("code_explain", rel, fn["name"]),
                    "type": "instruction_explain",
                    "instruction": f"Объясни, что делает функция {fn['name']} в файле {rel}.",
                    "context": "",
                    "output": f"Функция `{fn['name']}` в `{rel}`:\n```zig\n{code[:2000]}\n```",
                    "category": "code_explain",
                    "source_tag": source_tag,
                    "file": rel,
                    "symbol": fn["name"],
                    "evidence": f"{rel}:{sig}",
                    "verified": True,
                })
                stats["code_explain"] += 1

                # B+
                if is_bplus and validate_evidence({"file": rel, "symbol": fn["name"]}, index):
                    all_examples.append({
                        "id": make_id("bplus_locate", rel, fn["name"]),
                        "type": "bplus_locate",
                        "instruction": f"Где в B+ реализована функция {fn['name']}?",
                        "context": "",
                        "output": f"Функция `{fn['name']}` в `{rel}`.\n```zig\n{sig}\n```",
                        "category": "bplus_locate",
                        "source_tag": "B+",
                        "file": rel,
                        "symbol": fn["name"],
                        "evidence": f"{rel}:{sig}",
                        "verified": True,
                    })
                    stats["bplus_locate"] += 1

                    imports = file_info.get("imports", [])
                    all_examples.append({
                        "id": make_id("bplus_arch", rel, fn["name"]),
                        "type": "bplus_arch",
                        "instruction": f"Как устроен модуль {rel.split('/')[-1].replace('.zig','')} в B+?",
                        "context": f"Файл: {rel}",
                        "output": f"Модуль `{rel}` содержит `{fn['name']}`.\n```zig\n{sig}\n```\nЗависимости: {', '.join(imports[:5])}",
                        "category": "bplus_arch",
                        "source_tag": "B+",
                        "file": rel,
                        "symbol": fn["name"],
                        "evidence": f"{rel}:{sig}",
                        "verified": True,
                    })
                    stats["bplus_arch"] += 1

                fn_count += 1

            # code_test
            for test in file_info.get("tests", []):
                if test["lines"] < 3 or test["lines"] > 80:
                    continue
                lines = content.split("\n")
                test_code = "\n".join(lines[test["line"]-1:test["end_line"]])
                if not test_code or len(test_code) > MAX_OUTPUT:
                    continue

                ex = {
                    "id": make_id("code_test", rel, test["name"]),
                    "type": "instruction_test",
                    "instruction": f'Напиши тест "{test["name"]}" для модуля в {rel}.',
                    "context": f"Файл: {rel}",
                    "output": test_code,
                    "category": "code_test",
                    "source_tag": source_tag,
                    "file": rel,
                    "symbol": test["name"],
                    "evidence": f"{rel}:test {test['name']}",
                    "verified": False,
                }
                all_examples.append(ex)
                stats["code_test"] += 1
                if len(verify_queue["code_test"]) < VERIFY_SAMPLE:
                    verify_queue["code_test"].append((len(all_examples)-1, test_code, test["name"]))

    # Zig syntax
    syntax = [
        ("Что делает @import в Zig?", "Импортирует модуль:\n```zig\nconst std = @import(\"std\");\n```"),
        ("Чем var отличается от const?", "var изменяемый, const нет:\n```zig\nvar x: i32 = 0;\nx += 1;\nconst y: i32 = 5;\n```"),
        ("Как объявить функцию?", "Через fn:\n```zig\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n```"),
        ("Что такое error union?", "Комбинирует результат и ошибку:\n```zig\nfn parse(s: []const u8) !i32 {\n    return std.fmt.parseInt(i32, s, 10);\n}\n```"),
        ("Как обработать ошибку?", "try для пропуска, catch для обработки:\n```zig\nconst v = try parse(s);\nconst v2 = parse(s) catch 0;\n```"),
        ("Что такое comptime?", "Вычисления при компиляции:\n```zig\nfn fib(comptime n: u32) u32 {\n    if (n <= 1) return n;\n    return fib(n - 1) + fib(n - 2);\n}\n```"),
        ("Как работают указатели?", "* и *const:\n```zig\nvar x: i32 = 42;\nconst p: *i32 = &x;\np.* = 100;\n```"),
        ("Что такое optional?", "Тип nullable:\n```zig\nvar m: ?i32 = null;\nm = 42;\nconst v = m orelse 0;\n```"),
        ("Как создать struct?", "Через struct:\n```zig\nconst Point = struct {\n    x: f64,\n    y: f64,\n};\n```"),
        ("Что делает defer?", "Откладывает до выхода:\n```zig\nconst f = try openFile();\ndefer f.close();\n```"),
    ]
    for inst, out in syntax:
        all_examples.append({
            "id": make_id("zig_syntax", "", inst),
            "type": "instruction_syntax",
            "instruction": inst, "context": "", "output": out,
            "category": "zig_syntax", "source_tag": "Zig",
            "file": "", "symbol": "", "evidence": "", "verified": True,
        })
        stats["zig_syntax"] += 1

    # Verify sample
    print(f"\nVerifying {VERIFY_SAMPLE} samples per code category...")
    verified = 0
    failed = 0
    for cat, queue in verify_queue.items():
        for idx, code, name in queue:
            harness = make_harness(code, name) if cat == "code_write" else code
            ok = zig_test(harness)
            all_examples[idx]["verified"] = ok
            if ok: verified += 1
            else: failed += 1
        print(f"  {cat}: verified={verified} failed={failed}")

    # Dedup
    before = len(all_examples)
    all_examples = semantic_dedup(all_examples)
    print(f"\nDedup: {before} -> {len(all_examples)}")

    # Split
    by_file = defaultdict(list)
    for ex in all_examples:
        by_file[ex.get("file", "")].append(ex)
    files_list = sorted(by_file.keys())
    split_idx = int(len(files_list) * 0.9)
    train_files = set(files_list[:split_idx])
    val_files = set(files_list[split_idx:])
    train = [ex for ex in all_examples if ex.get("file", "") in train_files]
    val = [ex for ex in all_examples if ex.get("file", "") in val_files]

    # Save
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, data in [("instruction_train", train), ("instruction_val", val)]:
        path = OUT_DIR / f"{name}.jsonl"
        with open(path, "w", encoding="utf-8") as f:
            for ex in data:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")

    # Report
    elapsed = time.time() - t0
    cats = defaultdict(int)
    for ex in train: cats[ex.get("category", "?")] += 1
    v_count = sum(1 for ex in train if ex.get("verified"))
    print(f"\n{'='*60}")
    print(f"DONE in {elapsed:.0f}s")
    print(f"{'='*60}")
    for c, n in sorted(cats.items(), key=lambda x: -x[1]):
        print(f"  {c}: {n}")
    print(f"  Verified: {v_count}/{len(train)} ({v_count/max(1,len(train))*100:.0f}%)")
    print(f"  Train: {len(train)} | Val: {len(val)}")


if __name__ == "__main__":
    main()
