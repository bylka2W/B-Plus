"""
Fix dataset: remove truncated code, rebalance, expand B+/syntax.
"""
import json, re, os, hashlib
from pathlib import Path
from collections import defaultdict

DATASET = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset")
ZIG_ROOTS = [Path(r"C:\B-Plus\zig"), Path(r"C:\Users\Local\zig")]
MAX_OUTPUT = 4096

EXCLUDED_DIRS = {"zig-cache", "zig-out", ".git", "node_modules", "build", "build-debug", "build-release"}


def is_truncated(code):
    if not code or len(code) < 20:
        return True
    depth = 0
    for c in code:
        if c == "{": depth += 1
        elif c == "}": depth -= 1
    if depth != 0:
        return True
    lines = code.strip().split("\n")
    last = lines[-1].strip() if lines else ""
    if last.endswith((",", "+", "-", "*", "|", "&", ">", "<")):
        return True
    if last.endswith("{"):
        return True
    return False


def extract_zig(text):
    blocks = re.findall(r'```zig\n(.*?)```', text, re.DOTALL)
    if blocks:
        return blocks[0].strip()
    lines = text.split("\n")
    if lines and lines[0].strip().startswith(("pub fn ", "fn ", "test ", "pub const ")):
        return text.strip()
    return text.strip()


def load_jsonl(p):
    return [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]


def save_jsonl(p, records):
    with open(p, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def make_id(kind, path, name=""):
    return hashlib.sha256(f"{kind}:{path}:{name}".encode()).hexdigest()[:16]


def gen_zig_syntax():
    """Generate Zig syntax Q&A from real patterns."""
    qas = [
        ("Что делает @import в Zig?", "@import позволяет импортировать модули. Пример:\n```zig\nconst std = @import(\"std\");\n```"),
        ("Чем отличается var от const в Zig?", "var — изменяемая переменная, const — нет:\n```zig\nvar x: i32 = 0;\nx += 1;\nconst y: i32 = 5;\n```"),
        ("Как объявить функцию в Zig?", "Через fn:\n```zig\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n```"),
        ("Что такое error union в Zig?", "Комбинирует успешный результат и ошибку:\n```zig\nfn parse(s: []const u8) !i32 {\n    return std.fmt.parseInt(i32, s, 10);\n}\n```"),
        ("Как обработать ошибку в Zig?", "try для пропуска, catch для обработки:\n```zig\nconst v = try parse(s);\nconst v2 = parse(s) catch 0;\n```"),
        ("Что такое comptime в Zig?", "Вычисления во время компиляции:\n```zig\nfn fib(comptime n: u32) u32 {\n    if (n <= 1) return n;\n    return fib(n - 1) + fib(n - 2);\n}\n```"),
        ("Как работают указатели в Zig?", "* (mutable) и *const (immutable):\n```zig\nvar x: i32 = 42;\nconst ptr: *i32 = &x;\nptr.* = 100;\n```"),
        ("Что такое optional type в Zig?", "Optional (?)表示 значение может быть null:\n```zig\nvar maybe: ?i32 = null;\nmaybe = 42;\nconst v = maybe orelse 0;\n```"),
        ("Как определить структуру в Zig?", "Через struct:\n```zig\nconst Point = struct {\n    x: f64,\n    y: f64,\n    pub fn distance(self: Point, other: Point) f64 {\n        return @sqrt((self.x - other.x) * (self.x - other.x) + (self.y - other.y) * (self.y - other.y));\n    }\n};\n```"),
        ("Что такое allocator в Zig?", "Интерфейс для управления памятью:\n```zig\nconst allocator = std.heap.page_allocator;\nvar list = std.ArrayList(u8).init(allocator);\ndefer list.deinit();\n```"),
        ("Как написать тест в Zig?", "Через test:\n```zig\ntest \"basic\" {\n    try std.testing.expect(1 + 1 == 2);\n}\n```"),
        ("Что делает defer в Zig?", "Откладывает выполнение до выхода из области видимости:\n```zig\nconst file = try std.fs.cwd().openFile(\"data.txt\", .{});\ndefer file.close();\n```"),
        ("Как работает switch в Zig?", "Паттерн-матчинг:\n```zig\nconst result = switch (value) {\n    0 => \"zero\",\n    1...10 => \"small\",\n    else => \"other\",\n};\n```"),
        ("Что такое enum в Zig?", "Перечисление с фиксированными вариантами:\n```zig\nconst Color = enum { red, green, blue };\nconst c: Color = .red;\n```"),
        ("Как использовать срезы (slices) в Zig?", "Срез — это указатель на непрерывную память:\n```zig\nconst arr = [_]i32{ 1, 2, 3, 4, 5 };\nconst slice = arr[1..4]; // [2, 3, 4]\n```"),
        ("Что делает catch в Zig?", "Перехватывает ошибку:\n```zig\nconst file = std.fs.cwd().openFile(\"x\", .{}) catch |err| {\n    std.debug.print(\"Error: {}\\n\", .{err});\n    return;\n};\n```"),
        ("Как объявить константу в Zig?", "Через const:\n```zig\nconst pi: f64 = 3.14159;\nconst max_size: usize = 1024;\n```"),
        ("Что такое union в Zig?", "Объединение типов:\n```zig\nconst Value = union(enum) {\n    int: i64,\n    float: f64,\n    bool_val: bool,\n};\n```"),
        ("Как работают циклы в Zig?", "while и for:\n```zig\nvar i: usize = 0;\nwhile (i < 10) : (i += 1) {}\nfor (array) |item| {}\n```"),
        ("Что делает @intCast в Zig?", "Приведение целочисленного типа:\n```zig\nconst x: u8 = @intCast(42);\n```"),
        ("Как импортировать свой модуль в Zig?", "Создайте файл .zig и импортируйте:\n```zig\n// lib.zig\npub fn hello() void {}\n// main.zig\nconst lib = @import(\"lib.zig\");\n```"),
        ("Что такое comptimeptime в Zig?", "Проверка типов во время компиляции:\n```zig\nfn safelyMultiply(a: anytype, b: @TypeOf(a)) @TypeOf(a) {\n    return a * b;\n}\n```"),
        ("Как обработать несколько ошибок в Zig?", "Можно перечислить типы ошибок:\n```zig\nfn process() !void {\n    const file = try openFile() catch |err| switch (err) {\n        error.NotFound => return,\n        error.AccessDenied => return,\n    };\n}\n```"),
        ("Как использовать allocators в Zig?", "Стандартные аллокаторы:\n```zig\nconst gpa = std.heap.GeneralPurposeAllocator(.{}){};\ndefer _ = gpa.deinit();\nconst allocator = gpa.allocator();\n```"),
        ("Что делает @sizeOf в Zig?", "Возвращает размер типа в байтах:\n```zig\nconst size = @sizeOf(i32); // 4\n```"),
        ("Как создать массив в Zig?", "Массивы фиксированного размера:\n```zig\nconst arr = [_]i32{ 1, 2, 3, 4, 5 };\nvar buf: [100]u8 = undefined;\n```"),
        ("Как работают строки в Zig?", "Строки — это []const u8:\n```zig\nconst hello: []const u8 = \"Hello, World!\";\n```"),
        ("Что делает @as в Zig?", "Явное приведение типа:\n```zig\nconst x: f64 = @as(f64, 42);\n```"),
        ("Как использовать optional chaining в Zig?", "orelse и .? для извлечения:\n```zig\nconst val: ?i32 = maybeorelse 0;\nconst unwrapped = maybe.?;\n```"),
        ("Что такое payload errors в Zig?", "Ошибки с полезной нагрузкой:\n```zig\nconst Error = error{OutOfMemory}!u32;\n```"),
    ]
    results = []
    for inst, out in qas:
        results.append({
            "id": make_id("zig_syntax", "", inst),
            "type": "instruction_syntax",
            "instruction": inst,
            "context": "",
            "output": out,
            "category": "zig_syntax",
            "source_tag": "Zig",
        })
    return results


def main():
    print("FIXING DATASET")
    print("=" * 60)

    train = load_jsonl(DATASET / "instruction_train.jsonl")
    val = load_jsonl(DATASET / "instruction_val.jsonl")
    print(f"Loaded: train={len(train)} val={len(val)}")

    # Step 1: Remove truncated code
    print(f"\nStep 1: Remove truncated code...")
    before = len(train)
    clean = []
    for r in train:
        cat = r.get("category", "")
        if cat in ("code_write", "code_complete", "code_test"):
            code = extract_zig(r.get("output", ""))
            if is_truncated(code):
                continue
        clean.append(r)
    train = clean
    print(f"  Removed {before - len(train)} truncated records")
    print(f"  Train: {len(train)}")

    # Step 2: Expand zig_syntax
    print(f"\nStep 2: Expand zig_syntax...")
    syntax = gen_zig_syntax()
    # Add to train
    existing_syntax = [r for r in train if r.get("category") == "zig_syntax"]
    print(f"  Existing zig_syntax: {len(existing_syntax)}")
    train.extend(syntax)
    print(f"  Added {len(syntax)} zig_syntax records")
    print(f"  Train: {len(train)}")

    # Step 3: Balance — subsample over-represented categories
    print(f"\nStep 3: Rebalance...")
    targets = {
        "code_write": 0.30,
        "code_complete": 0.20,
        "code_test": 0.15,
        "code_explain": 0.10,
        "bplus_locate": 0.15,
        "bplus_arch": 0.10,
        "zig_syntax": 0.05,
    }

    by_cat = defaultdict(list)
    for r in train:
        by_cat[r.get("category", "?")].append(r)

    total_target = len(train)
    balanced = []
    for cat, records in by_cat.items():
        target_n = int(total_target * targets.get(cat, 0.05))
        if len(records) <= target_n:
            balanced.extend(records)
            print(f"  {cat}: keeping all {len(records)} (target={target_n})")
        else:
            # Keep first N (already roughly shuffled)
            balanced.extend(records[:target_n])
            print(f"  {cat}: {len(records)} -> {target_n} (subsampled)")

    train = balanced
    print(f"  Balanced train: {len(train)}")

    # Step 4: Save
    save_jsonl(DATASET / "instruction_train.jsonl", train)
    print(f"\nSaved: train={len(train)} val={len(val)}")

    # Final stats
    print(f"\n{'='*60}")
    print("FINAL DISTRIBUTION")
    print(f"{'='*60}")
    cats = defaultdict(int)
    for r in train: cats[r.get("category","?")] += 1
    total = len(train)
    for c, n in sorted(cats.items(), key=lambda x: -x[1]):
        pct = n / total * 100
        target = targets.get(c, 0) * 100
        print(f"  {c}: {n} ({pct:.1f}%) target={target:.1f}%")


if __name__ == "__main__":
    main()
