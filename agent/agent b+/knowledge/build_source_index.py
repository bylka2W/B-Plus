"""
Build source_index.json — catalog ALL Zig files with symbols.
Foundation for evidence-grounded instruction generation.

Output:
  source_index.json — {
    "files": {
      "/path/to/file.zig": {
        "lines": 1234,
        "source": "bplus"|"zig_compiler",
        "functions": [{"name": "foo", "line": 42, "pub": true, "sig": "pub fn foo(...) ..."}],
        "structs": [...],
        "enums": [...],
        "tests": [...],
        "imports": ["std", "other_module"],
      }
    },
    "symbols": {
      "functionName": ["/path/file.zig:42"],
    }
  }
"""
import json, re, os, sys, time
from pathlib import Path
from collections import defaultdict

ZIG_ROOTS = [Path(r"C:\B-Plus\zig"), Path(r"C:\Users\Local\zig")]
OUT = Path(r"C:\B-Plus\agent\agent b+\knowledge\corpus\source_index.json")

EXCLUDED_DIRS = {"zig-cache", "zig-out", ".git", "node_modules", "build", "build-debug", "build-release", "CMakeFiles"}


def iter_zig_files(root):
    root = Path(root)
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDED_DIRS and not d.startswith("."))
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


def extract_imports(content):
    """Extract @import statements."""
    return re.findall(r'@import\("([^"]+)"\)', content)


def extract_symbols(content):
    """Extract functions, structs, enums, tests with line numbers."""
    functions = []
    structs = []
    enums = []
    tests = []

    lines = content.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Function
        if re.match(r'(pub\s+)?fn\s+\w+', stripped):
            m = re.match(r'(pub\s+)?fn\s+(\w+)', stripped)
            pub = stripped.startswith("pub ")
            name = m.group(2) if m else "anon"
            sig_parts = stripped.split("{")[0].strip() if "{" in stripped else stripped
            # Find end of function
            depth = 0
            end = i
            started = False
            for j in range(i, min(i + 500, len(lines))):
                depth += lines[j].count("{") - lines[j].count("}")
                if "{" in lines[j]:
                    started = True
                if started and depth <= 0:
                    end = j
                    break
            functions.append({
                "name": name,
                "line": i + 1,
                "end_line": end + 1,
                "pub": pub,
                "sig": sig_parts[:200],
                "lines": end - i + 1,
            })
            i = end + 1
            continue

        # Struct
        if re.match(r'(pub\s+)?struct\s+\w+', stripped):
            m = re.match(r'(pub\s+)?struct\s+(\w+)', stripped)
            name = m.group(2) if m else "anon"
            depth = 0
            end = i
            started = False
            for j in range(i, min(i + 300, len(lines))):
                depth += lines[j].count("{") - lines[j].count("}")
                if "{" in lines[j]:
                    started = True
                if started and depth <= 0:
                    end = j
                    break
            structs.append({"name": name, "line": i + 1, "end_line": end + 1, "lines": end - i + 1})
            i = end + 1
            continue

        # Enum
        if re.match(r'(pub\s+)?enum\s+\w+', stripped):
            m = re.match(r'(pub\s+)?enum\s+(\w+)', stripped)
            name = m.group(2) if m else "anon"
            depth = 0
            end = i
            started = False
            for j in range(i, min(i + 200, len(lines))):
                depth += lines[j].count("{") - lines[j].count("}")
                if "{" in lines[j]:
                    started = True
                if started and depth <= 0:
                    end = j
                    break
            enums.append({"name": name, "line": i + 1, "end_line": end + 1, "lines": end - i + 1})
            i = end + 1
            continue

        # Test
        if stripped.startswith('test "'):
            m = re.search(r'test\s+"([^"]+)"', stripped)
            name = m.group(1) if m else "unnamed"
            depth = 0
            end = i
            started = False
            for j in range(i, min(i + 200, len(lines))):
                depth += lines[j].count("{") - lines[j].count("}")
                if "{" in lines[j]:
                    started = True
                if started and depth <= 0:
                    end = j
                    break
            tests.append({"name": name, "line": i + 1, "end_line": end + 1, "lines": end - i + 1})
            i = end + 1
            continue

        i += 1

    return functions, structs, enums, tests


def main():
    print("BUILDING SOURCE INDEX")
    print("=" * 60)
    t0 = time.time()

    index = {"files": {}, "symbols": defaultdict(list)}
    total_files = 0

    for root in ZIG_ROOTS:
        is_bplus = "B-Plus" in str(root)
        source = "bplus" if is_bplus else "zig_compiler"
        files = iter_zig_files(root)
        print(f"  {root}: {len(files)} files ({source})")

        for fp in files:
            content = read_file(fp)
            if not content:
                continue

            rel = str(fp).replace(str(root), "").replace("\\", "/")
            lines_count = content.count("\n") + 1
            imports = extract_imports(content)
            functions, structs, enums, tests = extract_symbols(content)

            index["files"][rel] = {
                "lines": lines_count,
                "source": source,
                "functions": functions,
                "structs": structs,
                "enums": enums,
                "tests": tests,
                "imports": imports,
            }

            # Build symbol index
            for fn in functions:
                index["symbols"][fn["name"]].append(f"{rel}:{fn['line']}")
            for st in structs:
                index["symbols"][st["name"]].append(f"{rel}:{st['line']}")
            for en in enums:
                index["symbols"][en["name"]].append(f"{rel}:{en['line']}")

            total_files += 1

    # Convert defaultdict to dict for JSON
    index["symbols"] = dict(index["symbols"])

    # Save
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=1)

    elapsed = time.time() - t0
    print(f"\n{'='*60}")
    print(f"SOURCE INDEX BUILT")
    print(f"{'='*60}")
    print(f"  Files: {total_files}")
    print(f"  Unique symbols: {len(index['symbols'])}")
    print(f"  Total functions: {sum(len(f['functions']) for f in index['files'].values())}")
    print(f"  Total structs: {sum(len(f['structs']) for f in index['files'].values())}")
    print(f"  Total enums: {sum(len(f['enums']) for f in index['files'].values())}")
    print(f"  Total tests: {sum(len(f['tests']) for f in index['files'].values())}")
    print(f"  B+ files: {sum(1 for f in index['files'].values() if f['source'] == 'bplus')}")
    print(f"  Time: {elapsed:.1f}s")
    print(f"  Output: {OUT}")
    print(f"  Size: {OUT.stat().st_size // 1024}KB")


if __name__ == "__main__":
    main()
