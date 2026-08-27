import hashlib
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import MEMORY_DIR, ZIG_ROOT, sha256_file

SNAPSHOT_PATH = MEMORY_DIR / "source_snapshot.json"

EXCLUDED_DIRS = {
    "node_modules", "zig-cache", "zig-out", ".git", "venv", "dist",
    "build",
}


class SourceSnapshot:
    def __init__(self, root, files=None, created_at=None):
        self.root = str(root)
        self.files = files or {}
        self.created_at = created_at or time.strftime("%Y-%m-%dT%H:%M:%S")

    @classmethod
    def build(cls, root=None):
        root = Path(root or ZIG_ROOT)
        files = {}
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(
                d for d in dirnames
                if d not in EXCLUDED_DIRS and not d.startswith(".")
            )
            for name in sorted(filenames):
                fp = os.path.join(dirpath, name)
                rel = os.path.relpath(fp, root).replace("\\", "/")
                files[rel] = {
                    "size": os.path.getsize(fp),
                    "sha256": sha256_file(fp),
                }
        return cls(root, files)

    @classmethod
    def load(cls, path=None):
        path = Path(path or SNAPSHOT_PATH)
        if not path.exists():
            return None
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
        files = {k: v for k, v in doc["files"].items()}
        return cls(doc["root"], files, doc.get("created_at"))

    def save(self, path=None):
        path = Path(path or SNAPSHOT_PATH)
        doc = {
            "schema": "source_snapshot",
            "version": 1,
            "root": self.root,
            "created_at": self.created_at,
            "file_count": len(self.files),
            "tree_sha": self.tree_sha(),
            "files": self.files,
        }
        tmp = Path(str(path) + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)

    def tree_sha(self):
        h = hashlib.sha256()
        for rel in sorted(self.files):
            h.update(rel.encode("utf-8"))
            h.update(self.files[rel]["sha256"].encode("utf-8"))
        return h.hexdigest()

    def compare(self, other):
        old = set(self.files.keys())
        new = set(other.files.keys())
        added = sorted(new - old)
        removed = sorted(old - new)
        common = sorted(old & new)
        modified = [
            r for r in common
            if self.files[r]["sha256"] != other.files[r]["sha256"]
        ]
        unchanged = [
            r for r in common
            if self.files[r]["sha256"] == other.files[r]["sha256"]
        ]
        added_shas = {other.files[r]["sha256"] for r in added}
        removed_shas = {self.files[r]["sha256"] for r in removed}
        renames = [
            (r_rem, r_add)
            for r_rem in removed
            for r_add in added
            if self.files[r_rem]["sha256"] == other.files[r_add]["sha256"]
        ]
        renames_used_a = {r for _, r in renames}
        renames_used_r = {r for r, _ in renames}
        added_pure = [r for r in added if r not in renames_used_a]
        removed_pure = [r for r in removed if r not in renames_used_r]
        return {
            "added": added_pure,
            "removed": removed_pure,
            "modified": modified,
            "unchanged": unchanged,
            "renamed": renames,
            "dirty": bool(added_pure or removed_pure or modified),
            "dirty_count": len(added_pure) + len(removed_pure) + len(modified),
            "total": len(other.files),
            "old_tree_sha": self.tree_sha(),
            "new_tree_sha": other.tree_sha(),
            "tree_sha_changed": self.tree_sha() != other.tree_sha(),
        }

    def __len__(self):
        return len(self.files)


def main():
    snap = SourceSnapshot.build()
    snap.save()
    print("SNAPSHOT:", len(snap.files), "files")
    print("TREE_SHA:", snap.tree_sha()[:32] + "...")
    print("SAVED:", SNAPSHOT_PATH)
    old = SourceSnapshot.load()
    if old:
        diff = old.compare(snap)
        print("COMPARED:", diff["dirty_count"], "dirty",
              "renamed:", len(diff["renamed"]))
    sys.exit(0)


if __name__ == "__main__":
    main()
