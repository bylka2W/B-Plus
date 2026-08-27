import hashlib
import json
import os
import re
from pathlib import Path

ZIG_ROOT = Path(r"C:\B-Plus\zig")
MEMORY_DIR = Path(r"C:\B-Plus\agent\memory")
INDEX_PATH = MEMORY_DIR / "source_index.json"
EVIDENCE_PATH = MEMORY_DIR / "source_evidence.json"
SYMBOLS_PATH = MEMORY_DIR / "source_symbols.json"
RELATIONS_PATH = MEMORY_DIR / "source_relations.json"
FACTS_PATH = MEMORY_DIR / "facts.json"
CONCEPTS_PATH = MEMORY_DIR / "concepts.json"
SEMANTIC_RELATIONS_PATH = MEMORY_DIR / "semantic_relations.json"
GRAPH_PATH = MEMORY_DIR / "graph.json"

EXCLUDED_DIRS = {"node_modules", "zig-cache", "zig-out", ".git", "venv", "dist", "build"}
CHUNK_SIZE = 10
IMPORT_RE = re.compile(r'@import\s*\("(.*?)"\)')


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_lines(path):
    with open(path, "rb") as f:
        data = f.read()
    return data.decode("utf-8", errors="ignore").splitlines()


def iter_zig_files(root=ZIG_ROOT):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(
            d for d in dirnames
            if d not in EXCLUDED_DIRS and not d.startswith(".")
        )
        for name in sorted(filenames):
            if name.endswith(".zig"):
                found.append(Path(dirpath) / name)
    return sorted(found)


def short_id(prefix, *parts):
    digest = hashlib.sha256("|".join(str(p) for p in parts).encode("utf-8")).hexdigest()
    return prefix + "-" + digest[:16]


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path, data):
    tmp = Path(str(path) + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
