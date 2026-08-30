"""
Fast specification-based dataset builder (no compile verification during build).
Verification done separately on a sample.
"""
import json, re, os, hashlib, time
from pathlib import Path
from collections import defaultdict

AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+")
CORPUS = AGENT_ROOT / "knowledge" / "corpus"
INDEX_PATH = CORPUS / "source_index.json"
OUT_DIR = AGENT_ROOT / "knowledge" / "dataset"
ZIG_ROOTS = [Path(r"C:\B-Plus\zig"), Path(r"C:\Users\Local\zig")]
EXCLUDED_DIRS = {"zig-cache", "zig-out", ".git", "node_modules", "build", "build-debug", "build-release", "CMakeFiles"}

MAX_OUTPUT = 2048


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


def parse_sig(sig):
    params = []
    ret_type = "void"
    m = re.search(r'\((.*?)\)', sig)
    if m:
        for p in m.group(1).split(","):
            p = p.strip()
            if ":" in p:
                n, t = p.split(":", 1)
                params.append((n.strip(), t.strip()))
    m = re.search(r'\)\s*(!?\S+)', sig)
    if m:
        ret_type = m.group(1)
    return params, ret_type


def gen_spec(fn_name, sig, code):
    params, ret = parse_sig(sig)
    param_desc = ", ".join(f"{n}: {t}" for n, t in params)
    spec = f"Реализуй функцию `{fn_name}` на языке Zig.\n\nСигнатура: `pub fn {fn_name}({param_desc}) {ret}`\n\n"
    hints = []
    if "return" in code: hints.append("Возвращает значение")
    if "if" in code or "switch" in code: hints.append("Обрабатывает различные случаи")
    if "error" in code or "try" in code: hints.append("Обрабатывает ошибки")
    if "for" in code or "while" in code: hints.append("Использует циклы")
    if "allocator" in code.lower(): hints.append("Использует аллокатор")
    if hints:
        spec += "Требования:\n" + "\n".join(f"- {h}" for h in hints) + "\n"
    return spec.strip()


def make_id(kind, path, name=""):
    return hashlib.sha256(f"{kind}:{path}:{name}".encode()).hexdigest()[:16]


def main():
    print("FAST SPEC DATASET BUILDER")
    print("=" * 60)
    t0 = time.time()

    index = load_index()
    all_examples = []
    stats = defaultdict(int)

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
                if fn["lines"] < 3 or fn["lines"] > 100:
                    continue
                if fn_count > 15:
                    break

                code = extract_function(content, fn["name"])
                if not code or len(code) < 30 or len(code) > MAX_OUTPUT:
                    continue

                sig = fn.get("sig", "")
                spec = gen_spec(fn["name"], sig, code)

                # code_write
                all_examples.append({
                    "id": make_id("sw", rel, fn["name"]),
                    "type": "instruction_write",
                    "instruction": spec,
                    "context": f"Файл: {rel}",
                    "output": code,
                    "category": "code_write",
                    "source_tag": source_tag,
                    "file": rel,
                    "symbol": fn["name"],
                    "evidence": f"{rel}:{sig}",
                    "verified": False,
                })
                stats["code_write"] += 1

                # code_complete
                all_examples.append({
                    "id": make_id("sc", rel, fn["name"]),
                    "type": "instruction_complete",
                    "instruction": f"Допиши реализацию {fn['name']} по спецификации:\n{spec}",
                    "context": f"Сигнатура: `{sig}`\nНачало:\n```zig\n{code.split(chr(10))[0]}\n```",
                    "output": code,
                    "category": "code_complete",
                    "source_tag": source_tag,
                    "file": rel,
                    "symbol": fn["name"],
                    "evidence": f"{rel}:{sig}",
                    "verified": False,
                })
                stats["code_complete"] += 1

                # code_explain
                all_examples.append({
                    "id": make_id("se", rel, fn["name"]),
                    "type": "instruction_explain",
                    "instruction": f"Объясни, что делает функция {fn['name']} в {rel}. Покажи код.",
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

                if is_bplus:
                    all_examples.append({
                        "id": make_id("bl", rel, fn["name"]),
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
                        "id": make_id("ba", rel, fn["name"]),
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
                if test["lines"] < 3 or test["lines"] > 60:
                    continue
                lines = content.split("\n")
                test_code = "\n".join(lines[test["line"]-1:test["end_line"]])
                if test_code and len(test_code) <= MAX_OUTPUT:
                    all_examples.append({
                        "id": make_id("st", rel, test["name"]),
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
                    })
                    stats["code_test"] += 1

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
            "id": make_id("zs", "", inst), "type": "instruction_syntax",
            "instruction": inst, "context": "", "output": out,
            "category": "zig_syntax", "source_tag": "Zig",
            "file": "", "symbol": "", "evidence": "", "verified": True,
        })
        stats["zig_syntax"] += 1

    # Split
    by_file = defaultdict(list)
    for ex in all_examples:
        by_file[ex.get("file", "")].append(ex)
    files_list = sorted(by_file.keys())
    split_idx = int(len(files_list) * 0.9)
    train = [ex for ex in all_examples if ex.get("file", "") in set(files_list[:split_idx])]
    val = [ex for ex in all_examples if ex.get("file", "") in set(files_list[split_idx:])]

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, data in [("instruction_train", train), ("instruction_val", val)]:
        with open(OUT_DIR / f"{name}.jsonl", "w", encoding="utf-8") as f:
            for ex in data:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")

    elapsed = time.time() - t0
    print(f"\n{'='*60}")
    print(f"DONE in {elapsed:.0f}s")
    for c, n in sorted(stats.items(), key=lambda x: -x[1]):
        print(f"  {c}: {n}")
    v = sum(1 for ex in train if ex.get("verified"))
    print(f"  Verified: {v}/{len(train)} ({v/max(1,len(train))*100:.0f}%)")
    print(f"  Train: {len(train)} | Val: {len(val)}")


if __name__ == "__main__":
    main()
