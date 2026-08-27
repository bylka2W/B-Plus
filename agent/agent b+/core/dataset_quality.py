import os
import sys
import json
import hashlib
from pathlib import Path
from collections import Counter

AGENT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(AGENT_ROOT))

EXCLUDED_DIRS = {
    "zig-cache", "zig-out", ".git", "node_modules", "build",
    "build-debug", "build-release", "CMakeFiles",
}


def iter_zig_files(root):
    root = Path(root)
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDED_DIRS and not d.startswith("."))
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


class DatasetQuality:
    def __init__(self):
        self.zig_roots = [Path(r"C:\Users\Local\zig"), Path(r"C:\B-Plus\zig")]
        self.files = {}
        self.content_hashes = {}
        self.line_hashes = Counter()

    def scan(self):
        for root in self.zig_roots:
            for fp in iter_zig_files(root):
                rel = str(fp).replace(str(root), "").replace("\\", "/")
                source = "bplus" if "B-Plus" in str(root) else "zig_compiler"
                content = read_file(fp)
                if not content:
                    continue
                content_hash = hashlib.sha256(content.encode("utf-8")).hexdigest()
                self.files[rel] = {
                    "source": source,
                    "path": fp,
                    "content_hash": content_hash,
                    "lines": content.count("\n") + 1,
                    "bytes": len(content),
                }
                if content_hash not in self.content_hashes:
                    self.content_hashes[content_hash] = []
                self.content_hashes[content_hash].append(rel)

    def find_exact_duplicates(self):
        dupes = {h: paths for h, paths in self.content_hashes.items() if len(paths) > 1}
        return dupes

    def find_near_duplicates(self, threshold=0.9):
        all_contents = {}
        for rel, info in self.files.items():
            content = read_file(info["path"])
            lines = set(content.split("\n"))
            all_contents[rel] = lines

        near_dupes = []
        rels = list(all_contents.keys())
        for i in range(len(rels)):
            for j in range(i + 1, min(i + 50, len(rels))):
                a, b = rels[i], rels[j]
                la, lb = all_contents[a], all_contents[b]
                if not la or not lb:
                    continue
                common = len(la & lb)
                total = len(la | lb)
                if total > 0 and common / total > threshold:
                    near_dupes.append((a, b, common / total))
        return near_dupes

    def file_level_split(self, val_ratio=0.1):
        by_source = {"bplus": [], "zig_compiler": []}
        for rel, info in self.files.items():
            by_source[info["source"]].append(rel)

        train, val = [], []
        for source, files in by_source.items():
            n_val = max(1, int(len(files) * val_ratio))
            val.extend(files[:n_val])
            train.extend(files[n_val:])

        val_files = set(val)
        train_files = set(train)
        leakage = train_files & val_files

        return {
            "train": len(train),
            "val": len(val),
            "total": len(train) + len(val),
            "train_files": train,
            "val_files": val,
            "leakage": list(leakage),
            "leakage_count": len(leakage),
            "by_source": {s: len(f) for s, f in by_source.items()},
        }

    def audit(self):
        self.scan()
        exact_dupes = self.find_exact_duplicates()
        split = self.file_level_split()

        total_files = len(self.files)
        total_lines = sum(f["lines"] for f in self.files.values())
        total_bytes = sum(f["bytes"] for f in self.files.values())
        by_source = Counter(f["source"] for f in self.files.values())

        small_files = [rel for rel, f in self.files.items() if f["lines"] < 5]
        large_files = [rel for rel, f in self.files.items() if f["lines"] > 1000]

        return {
            "total_files": total_files,
            "total_lines": total_lines,
            "total_bytes": total_bytes,
            "by_source": dict(by_source),
            "exact_duplicates_groups": len(exact_dupes),
            "exact_duplicates_files": sum(len(v) for v in exact_dupes.values()),
            "small_files": len(small_files),
            "large_files": len(large_files),
            "split": split,
        }


def main():
    print("C.6.7 DATASET QUALITY AUDIT")
    print("=" * 60)
    dq = DatasetQuality()
    result = dq.audit()
    print(f"  total_files: {result['total_files']}")
    print(f"  total_lines: {result['total_lines']:,}")
    print(f"  total_bytes: {result['total_bytes']:,}")
    print(f"  by_source: {result['by_source']}")
    print(f"  exact_duplicates_groups: {result['exact_duplicates_groups']}")
    print(f"  exact_duplicates_files: {result['exact_duplicates_files']}")
    print(f"  small_files: {result['small_files']}")
    print(f"  large_files: {result['large_files']}")
    split = result["split"]
    print(f"\nFILE-LEVEL SPLIT:")
    print(f"  train: {split['train']}")
    print(f"  val: {split['val']}")
    print(f"  leakage: {split['leakage_count']}")
    print(f"  by_source: {split['by_source']}")

    report_path = AGENT_ROOT / "knowledge" / "corpus" / "quality_audit.json"
    with open(report_path, "w") as f:
        json.dump(result, f, indent=2, default=str)
    print(f"\nSaved: {report_path}")

    sys.exit(0)


if __name__ == "__main__":
    main()
