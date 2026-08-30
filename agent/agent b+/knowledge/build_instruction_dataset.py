"""
Build instruction→code training pairs from Zig source files.

Generates 9 categories:
  1. code_write     — "Напиши функцию X" → function code
  2. code_complete  — "Допиши функцию X" → function body
  3. code_fix       — "Исправь ошибку" → fixed code
  4. code_explain   — "Объясни код" → explanation + code
  5. code_test      — "Напиши тест" → test code
  6. zig_syntax     — "Что делает X в Zig?" → explanation
  7. bplus_locate   — "Где в B+ реализовано X?" → file + symbol
  8. bplus_arch     — "Как устроен X в B+?" → explanation
  9. bplus_evidence — "Покажи реализацию X" → file + code + explanation
"""
import json, re, hashlib, os, sys
from pathlib import Path
from collections import defaultdict

AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+")
CORPUS_DIR = AGENT_ROOT / "knowledge" / "corpus"
ZIG_ROOTS = [Path(r"C:\B-Plus\zig"), Path(r"C:\Users\Local\zig")]
OUT_DIR = AGENT_ROOT / "knowledge" / "dataset"

EXCLUDED_DIRS = {
    "zig-cache", "zig-out", ".git", "node_modules", "build",
    "build-debug", "build-release", "CMakeFiles",
}


def iter_zig_files(root):
    root = Path(root)
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(
            d for d in dirnames
            if d not in EXCLUDED_DIRS and not d.startswith(".")
        )
        for name in sorted(filenames):
            if name.endswith(".zig"):
                files.append(Path(dirpath) / name)
    return files


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except (OSError, IOError):
        return ""


def extract_functions(content):
    """Extract functions with their full signatures and bodies."""
    functions = []
    lines = content.split("\n")
    current_fn = []
    current_name = ""
    current_sig = ""
    depth = 0
    in_fn = False

    for line in lines:
        stripped = line.strip()
        if not in_fn:
            if stripped.startswith("pub fn ") or stripped.startswith("fn "):
                in_fn = True
                current_fn = [line]
                parts = stripped.split()
                idx = 1 if parts[0] == "pub" else 0
                if idx + 1 < len(parts):
                    current_name = parts[idx + 1].split("(")[0]
                else:
                    current_name = "anonymous"
                current_sig = stripped.split("{")[0].strip() if "{" in stripped else stripped
                depth = line.count("{") - line.count("}")
            continue

        current_fn.append(line)
        depth += line.count("{") - line.count("}")
        if depth <= 0 and len(current_fn) > 1:
            functions.append({
                "name": current_name,
                "signature": current_sig,
                "code": "\n".join(current_fn),
                "lines": len(current_fn),
            })
            current_fn = []
            current_name = ""
            current_sig = ""
            in_fn = False
            depth = 0

    return functions


def extract_structs(content):
    """Extract struct definitions."""
    structs = []
    lines = content.split("\n")
    current = []
    name = ""
    depth = 0
    in_struct = False

    for line in lines:
        stripped = line.strip()
        if not in_struct:
            if "pub struct " in stripped or ("struct " in stripped and ":" in stripped):
                in_struct = True
                current = [line]
                m = re.search(r'struct\s+(\w+)', stripped)
                name = m.group(1) if m else "anonymous"
                depth = line.count("{") - line.count("}")
            continue
        current.append(line)
        depth += line.count("{") - line.count("}")
        if depth <= 0 and len(current) > 1:
            structs.append({
                "name": name,
                "code": "\n".join(current),
                "lines": len(current),
            })
            current = []
            name = ""
            in_struct = False
            depth = 0

    return structs


def extract_enums(content):
    """Extract enum definitions."""
    enums = []
    lines = content.split("\n")
    current = []
    name = ""
    depth = 0
    in_enum = False

    for line in lines:
        stripped = line.strip()
        if not in_enum:
            if "pub enum " in stripped or ("enum " in stripped and "{" in stripped):
                in_enum = True
                current = [line]
                m = re.search(r'enum\s+(\w+)', stripped)
                name = m.group(1) if m else "anonymous"
                depth = line.count("{") - line.count("}")
            continue
        current.append(line)
        depth += line.count("{") - line.count("}")
        if depth <= 0 and len(current) > 1:
            enums.append({
                "name": name,
                "code": "\n".join(current),
                "lines": len(current),
            })
            current = []
            name = ""
            in_enum = False
            depth = 0

    return enums


def extract_tests(content):
    """Extract test blocks."""
    tests = []
    lines = content.split("\n")
    current = []
    name = ""
    depth = 0
    in_test = False

    for line in lines:
        stripped = line.strip()
        if not in_test:
            if stripped.startswith('test "'):
                in_test = True
                current = [line]
                parts = stripped.split('"')
                name = parts[1] if len(parts) > 1 else "unnamed"
                depth = line.count("{") - line.count("}")
            continue
        current.append(line)
        depth += line.count("{") - line.count("}")
        if depth <= 0 and len(current) > 1:
            tests.append({
                "name": name,
                "code": "\n".join(current),
                "lines": len(current),
            })
            current = []
            name = ""
            in_test = False
            depth = 0

    return tests


def make_id(kind, path, name=""):
    raw = f"{kind}:{path}:{name}"
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def gen_instruction_variants(func_name, signature, source, rel_path, is_bplus):
    """Generate multiple instruction variants for a function."""
    source_tag = "B+" if is_bplus else "Zig"
    results = []

    # 1. Write the function
    results.append({
        "type": "instruction_write",
        "instruction": f"Напиши функцию {func_name} на языке Zig.",
        "context": f"Файл: {rel_path}",
        "output": source,
        "category": "code_write",
        "source_tag": source_tag,
    })

    # 2. Complete the function (signature only)
    results.append({
        "type": "instruction_complete",
        "instruction": f"Допиши реализацию функции:\n{signature}",
        "context": f"Файл: {rel_path}",
        "output": source,
        "category": "code_complete",
        "source_tag": source_tag,
    })

    # 3. Explain the function
    first_line = source.split("\n")[0] if source else ""
    results.append({
        "type": "instruction_explain",
        "instruction": f"Объясни, что делает функция {func_name} в файле {rel_path}. Покажи код.",
        "context": "",
        "output": f"Функция `{func_name}` определена как:\n```zig\n{source}\n```\n\nОна {first_line.lower() if first_line else 'выполняет операцию'}.",
        "category": "code_explain",
        "source_tag": source_tag,
    })

    return results


def gen_struct_variants(name, code, rel_path, is_bplus):
    source_tag = "B+" if is_bplus else "Zig"
    return [{
        "type": "instruction_struct",
        "instruction": f"Определи структуру {name} на языке Zig в файле {rel_path}.",
        "context": f"Файл: {rel_path}",
        "output": code,
        "category": "code_write",
        "source_tag": source_tag,
    }]


def gen_enum_variants(name, code, rel_path, is_bplus):
    source_tag = "B+" if is_bplus else "Zig"
    return [{
        "type": "instruction_enum",
        "instruction": f"Определи enum {name} на языке Zig.",
        "context": f"Файл: {rel_path}",
        "output": code,
        "category": "code_write",
        "source_tag": source_tag,
    }]


def gen_test_variants(name, code, rel_path, is_bplus):
    source_tag = "B+" if is_bplus else "Zig"
    return [{
        "type": "instruction_test",
        "instruction": f'Напиши тест "{name}" для файла {rel_path}.',
        "context": f"Файл: {rel_path}",
        "output": code,
        "category": "code_test",
        "source_tag": source_tag,
    }]


def gen_bplus_archVariants(func_name, rel_path, code):
    """B+ architecture questions."""
    module = rel_path.split("/")[-1].replace(".zig", "") if rel_path else "module"
    return [
        {
            "type": "bplus_locate",
            "instruction": f"Где в B+ реализована функция {func_name}?",
            "context": "",
            "output": f"Функция `{func_name}` находится в файле `{rel_path}`.\n\n```zig\n{code[:500]}\n```",
            "category": "bplus_locate",
            "source_tag": "B+",
        },
        {
            "type": "bplus_arch",
            "instruction": f"Как устроен модуль {module} в B+? Опиши его основные функции.",
            "context": f"Файл: {rel_path}",
            "output": f"Модуль `{module}` ({rel_path}) содержит функцию `{func_name}`.\n\n```zig\n{code[:500]}\n```\n\nЭтот модуль отвечает за логику {module.replace('_', ' ')}.",
            "category": "bplus_arch",
            "source_tag": "B+",
        },
    ]


def build_zig_syntax_qa():
    """Generate Zig syntax Q&A from known patterns."""
    return [
        {"instruction": "Что делает @import в Zig?", "output": "@import позволяет импортировать модули. Пример:\n```zig\nconst std = @import(\"std\");\n```"},
        {"instruction": "Чем отличается var от const в Zig?", "output": "var — изменяемая переменная, const — неизменяемая.\n```zig\nvar x: i32 = 0;\nx += 1; // OK\nconst y: i32 = 5;\n// y = 10; // Ошибка компиляции\n```"},
        {"instruction": "Как объявить функцию в Zig?", "output": "Функции объявляются через fn:\n```zig\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n```"},
        {"instruction": "Что такое error union в Zig?", "output": "Error union комбинирует успешный результат и ошибку:\n```zig\nfn parse(s: []const u8) !i32 {\n    return std.fmt.parseInt(i32, s, 10);\n}\n```"},
        {"instruction": "Как обработать ошибку в Zig?", "output": "Используй try для пропуска или catch для обработки:\n```zig\nconst value = try parse(s);\n// или\nconst value = parse(s) catch |err| blk: {\n    std.debug.print(\"Error: {}\\n\", .{err});\n    break :blk 0;\n};\n```"},
        {"instruction": "Что такое comptime в Zig?", "output": "comptime — вычисления во время компиляции:\n```zig\nfn fibonacci(comptime n: u32) u32 {\n    if (n <= 1) return n;\n    return fibonacci(n - 1) + fibonacci(n - 2);\n}\nconst result = comptime fibonacci(10);\n```"},
        {"instruction": "Как работают указатели в Zig?", "output": "Zig использует * (mutable) и *const (immutable) указатели:\n```zig\nvar x: i32 = 42;\nconst ptr: *i32 = &x;\nptr.* = 100;\n```"},
        {"instruction": "Что такое optional type в Zig?", "output": "Optional (?)表示值 может быть null:\n```zig\nvar maybe: ?i32 = null;\nmaybe = 42;\nconst unwrapped = maybe orelse 0;\n```"},
        {"instruction": "Как определить структуру в Zig?", "output": "Структуры через struct:\n```zig\nconst Point = struct {\n    x: f64,\n    y: f64,\n    pub fn distance(self: Point, other: Point) f64 {\n        return @sqrt((self.x - other.x) * (self.x - other.x) +\n                     (self.y - other.y) * (self.y - other.y));\n    }\n};\n```"},
        {"instruction": "Что такое allocator в Zig?", "output": "Allocator — интерфейс для управления памятью:\n```zig\nconst allocator = std.heap.page_allocator;\nvar list = std.ArrayList(u8).init(allocator);\ndefer list.deinit();\ntry list.appendSlice(\"hello\");\n```"},
    ]


def main():
    print("BUILDING INSTRUCTION DATASET")
    print("=" * 60)

    all_instructions = []
    stats = defaultdict(int)

    # Phase 1: Process Zig source files
    print("\nPhase 1: Extracting from Zig source files...")
    bplus_count = 0
    zig_count = 0

    for root in ZIG_ROOTS:
        is_bplus = "B-Plus" in str(root)
        files = iter_zig_files(root)
        print(f"  {root}: {len(files)} files ({'B+' if is_bplus else 'Zig compiler'})")

        for fp in files:
            content = read_file(fp)
            if not content or len(content) < 50:
                continue

            rel = str(fp).replace(str(root), "").replace("\\", "/")

            # Extract components
            funcs = extract_functions(content)
            structs = extract_structs(content)
            enums = extract_enums(content)
            tests = extract_tests(content)

            # Generate instructions for functions
            for fn in funcs:
                if fn["lines"] < 2 or len(fn["code"]) < 30:
                    continue
                variants = gen_instruction_variants(
                    fn["name"], fn["signature"], fn["code"], rel, is_bplus
                )
                for v in variants:
                    v["id"] = make_id(v["type"], rel, fn["name"])
                    v["file"] = rel
                    all_instructions.append(v)
                    stats[v["category"]] += 1

                if is_bplus:
                    arch_vars = gen_bplus_archVariants(fn["name"], rel, fn["code"])
                    for v in arch_vars:
                        v["id"] = make_id(v["type"], rel, fn["name"])
                        v["file"] = rel
                        all_instructions.append(v)
                        stats[v["category"]] += 1

            # Generate instructions for structs
            for st in structs:
                if st["lines"] < 2:
                    continue
                variants = gen_struct_variants(st["name"], st["code"], rel, is_bplus)
                for v in variants:
                    v["id"] = make_id(v["type"], rel, st["name"])
                    v["file"] = rel
                    all_instructions.append(v)
                    stats[v["category"]] += 1

            # Generate instructions for enums
            for en in enums:
                if en["lines"] < 2:
                    continue
                variants = gen_enum_variants(en["name"], en["code"], rel, is_bplus)
                for v in variants:
                    v["id"] = make_id(v["type"], rel, en["name"])
                    v["file"] = rel
                    all_instructions.append(v)
                    stats[v["category"]] += 1

            # Generate instructions for tests
            for t in tests:
                if t["lines"] < 2:
                    continue
                variants = gen_test_variants(t["name"], t["code"], rel, is_bplus)
                for v in variants:
                    v["id"] = make_id(v["type"], rel, t["name"])
                    v["file"] = rel
                    all_instructions.append(v)
                    stats[v["category"]] += 1

            if is_bplus:
                bplus_count += 1
            else:
                zig_count += 1

    print(f"  B+ files processed: {bplus_count}")
    print(f"  Zig compiler files: {zig_count}")

    # Phase 2: Zig syntax Q&A
    print("\nPhase 2: Zig syntax Q&A...")
    syntax_qa = build_zig_syntax_qa()
    for qa in syntax_qa:
        ex = {
            "id": make_id("zig_syntax", "", qa["instruction"]),
            "type": "instruction_syntax",
            "instruction": qa["instruction"],
            "context": "",
            "output": qa["output"],
            "category": "zig_syntax",
            "source_tag": "Zig",
        }
        all_instructions.append(ex)
        stats["zig_syntax"] += 1

    # Phase 3: Write clean corpus
    print("\nPhase 3: Writing dataset...")
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Deduplicate by id
    seen = set()
    unique = []
    for ex in all_instructions:
        if ex["id"] not in seen:
            seen.add(ex["id"])
            unique.append(ex)

    # Split: 90% train, 10% val (by file, not random — prevent leakage)
    by_file = defaultdict(list)
    for ex in unique:
        f = ex.get("file", "")
        by_file[f].append(ex)

    files_list = sorted(by_file.keys())
    split_idx = int(len(files_list) * 0.9)
    train_files = set(files_list[:split_idx])
    val_files = set(files_list[split_idx:])

    train_data = [ex for ex in unique if ex.get("file", "") in train_files]
    val_data = [ex for ex in unique if ex.get("file", "") in val_files]

    # Add syntax Q&A to train only
    syntax_train = [ex for ex in train_data if ex["category"] == "zig_syntax"]
    syntax_val = [ex for ex in val_data if ex["category"] == "zig_syntax"]

    # Write
    for name, data in [("train", train_data), ("val", val_data)]:
        path = OUT_DIR / f"instruction_{name}.jsonl"
        with open(path, "w", encoding="utf-8") as f:
            for ex in data:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")
        print(f"  {path.name}: {len(data)} records")

    # Stats
    print(f"\n{'='*60}")
    print("DATASET STATS")
    print(f"{'='*60}")
    print(f"  Total unique instructions: {len(unique)}")
    print(f"  Train: {len(train_data)} | Val: {len(val_data)}")
    print(f"\n  By category:")
    for cat, count in sorted(stats.items(), key=lambda x: -x[1]):
        print(f"    {cat}: {count}")
    print(f"\n  By source tag:")
    tags = defaultdict(int)
    for ex in unique:
        tags[ex.get("source_tag", "?")] += 1
    for tag, count in sorted(tags.items(), key=lambda x: -x[1]):
        print(f"    {tag}: {count}")

    # Sample
    print(f"\n  Sample records:")
    for ex in unique[:3]:
        print(f"    type={ex['type']} instruction={ex['instruction'][:80]}")
        print(f"    output[:80]={ex['output'][:80]}")


if __name__ == "__main__":
    main()
