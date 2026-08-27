import os
import sys
import json
import hashlib
from pathlib import Path

AGENT_ROOT = Path(__file__).parent.parent
CORPUS_DIR = Path(__file__).parent / "corpus"
ZIG_ROOT = Path(r"C:\Users\Local\zig")
BPLUS_ROOT = Path(r"C:\B-Plus\zig")

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
                files.append(os.path.join(dirpath, name))
    return files


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except (OSError, IOError):
        return ""


def split_into_functions(content):
    functions = []
    lines = content.split("\n")
    current_fn = []
    current_name = ""
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
                depth = line.count("{") - line.count("}")
            continue

        current_fn.append(line)
        depth += line.count("{") - line.count("}")
        if depth <= 0 and len(current_fn) > 1:
            functions.append({
                "name": current_name,
                "code": "\n".join(current_fn),
                "lines": len(current_fn),
            })
            current_fn = []
            current_name = ""
            in_fn = False
            depth = 0

    return functions


def split_into_tests(content):
    tests = []
    lines = content.split("\n")
    current_test = []
    current_name = ""
    depth = 0
    in_test = False

    for line in lines:
        stripped = line.strip()
        if not in_test:
            if stripped.startswith('test "'):
                in_test = True
                current_test = [line]
                parts = stripped.split('"')
                current_name = parts[1] if len(parts) > 1 else "unnamed"
                depth = line.count("{") - line.count("}")
            continue

        current_test.append(line)
        depth += line.count("{") - line.count("}")
        if depth <= 0 and len(current_test) > 1:
            tests.append({
                "name": current_name,
                "code": "\n".join(current_test),
                "lines": len(current_test),
            })
            current_test = []
            current_name = ""
            in_test = False
            depth = 0

    return tests


class CorpusBuilder:
    def __init__(self):
        self.examples = []
        self.stats = {
            "total_files": 0,
            "total_lines": 0,
            "total_bytes": 0,
            "functions": 0,
            "tests": 0,
            "examples": 0,
        }

    def build_zig_corpus(self, roots, output_path=None):
        output = Path(output_path) if output_path else CORPUS_DIR / "zig_corpus.jsonl"
        output.parent.mkdir(parents=True, exist_ok=True)

        for root in roots:
            root = Path(root)
            files = iter_zig_files(root)
            self.stats["total_files"] += len(files)

            for fp in files:
                content = read_file(fp)
                if not content:
                    continue

                rel = str(fp).replace(str(root), "").replace("\\", "/")
                lines = content.split("\n")
                self.stats["total_lines"] += len(lines)
                self.stats["total_bytes"] += len(content)

                self._add_full_file_example(rel, content, root)
                funcs = split_into_functions(content)
                self.stats["functions"] += len(funcs)
                for fn in funcs:
                    self._add_function_example(rel, fn)

                tests = split_into_tests(content)
                self.stats["tests"] += len(tests)
                for t in tests:
                    self._add_test_example(rel, t)

        with open(output, "w", encoding="utf-8") as f:
            for ex in self.examples:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")

        self.stats["examples"] = len(self.examples)
        return self.examples, self.stats

    def build_russian_corpus(self, output_path=None):
        output = Path(output_path) if output_path else CORPUS_DIR / "russian_corpus.jsonl"
        output.parent.mkdir(parents=True, exist_ok=True)

        instructions = [
            {"task": "Найди определение функции", "template": "Где определена функция {name}?"},
            {"task": "Кто вызывает функцию", "template": "Кто вызывает {name}?"},
            {"task": "Найди все использования", "template": "Найди все ссылки на {name}"},
            {"task": "Добавь функцию", "template": "Добавь функцию {name} в модуль {module}"},
            {"task": "Исправь ошибку", "template": "Исправь ошибку компиляции в {file}"},
            {"task": "Напиши тест", "template": "Напиши тест для функции {name}"},
            {"task": "Объясни код", "template": "Объясни что делает функция {name}"},
            {"task": "Рефакторинг", "template": "Проведи рефакторинг кода в {file}"},
            {"task": "Найди зависимость", "template": "От чего зависит модуль {module}?"},
            {"task": "Проследи вызовы", "template": "Проследи цепочку вызовов от {name}"},
        ]

        for inst in instructions:
            ex = {
                "type": "russian_instruction",
                "task": inst["task"],
                "template": inst["template"],
                "language": "ru",
                "category": "instruction",
            }
            self.examples.append(ex)

        with open(output, "w", encoding="utf-8") as f:
            for ex in self.examples[len(self.examples) - len(instructions):]:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")

        return self.examples, self.stats

    def _add_full_file_example(self, rel, content, root):
        source = "bplus" if "B-Plus" in str(root) else "zig_compiler"
        ex = {
            "id": hashlib.sha256(f"full:{rel}".encode()).hexdigest()[:16],
            "type": "code_continue",
            "source": source,
            "file": rel,
            "input": f"// File: {rel}\n",
            "output": content[:4096],
            "lines": len(content.split("\n")),
            "category": "zig",
        }
        self.examples.append(ex)

    def _add_function_example(self, rel, fn):
        ex = {
            "id": hashlib.sha256(f"fn:{rel}:{fn['name']}".encode()).hexdigest()[:16],
            "type": "code_complete",
            "source": "bplus",
            "file": rel,
            "function_name": fn["name"],
            "input": f"// Complete function {fn['name']}\n",
            "output": fn["code"][:2048],
            "lines": fn["lines"],
            "category": "zig",
        }
        self.examples.append(ex)

    def _add_test_example(self, rel, test):
        ex = {
            "id": hashlib.sha256(f"test:{rel}:{test['name']}".encode()).hexdigest()[:16],
            "type": "code_test",
            "source": "bplus",
            "file": rel,
            "test_name": test["name"],
            "input": f'// Write test "{test["name"]}"\n',
            "output": test["code"][:1024],
            "lines": test["lines"],
            "category": "zig",
        }
        self.examples.append(ex)


_instance = None


def get_corpus_builder():
    global _instance
    if _instance is None:
        _instance = CorpusBuilder()
    return _instance


def main():
    print("BUILDING TRAINING CORPUS...")
    builder = CorpusBuilder()

    zig_examples, stats = builder.build_zig_corpus([BPLUS_ROOT, ZIG_ROOT])
    print(f"\nZIG CORPUS:")
    print(f"  files: {stats['total_files']}")
    print(f"  lines: {stats['total_lines']}")
    print(f"  bytes: {stats['total_bytes']}")
    print(f"  functions: {stats['functions']}")
    print(f"  tests: {stats['tests']}")
    print(f"  examples: {stats['examples']}")

    all_examples = builder.examples[:]
    builder.build_russian_corpus()
    ru_count = len(builder.examples) - len(all_examples)
    print(f"\nRUSSIAN CORPUS:")
    print(f"  instructions: {ru_count}")

    total = len(builder.examples)
    zig_pct = len(all_examples) / max(total, 1) * 100
    ru_pct = ru_count / max(total, 1) * 100
    print(f"\nMIXTURE:")
    print(f"  total: {total}")
    print(f"  zig: {len(all_examples)} ({zig_pct:.1f}%)")
    print(f"  russian: {ru_count} ({ru_pct:.1f}%)")

    if zig_examples:
        ex = zig_examples[0]
        print(f"\nSAMPLE:")
        print(f"  type: {ex['type']}")
        print(f"  file: {ex['file']}")
        print(f"  output[:100]: {ex['output'][:100]}")

    sys.exit(0)


if __name__ == "__main__":
    main()
