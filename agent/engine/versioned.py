import hashlib
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import MEMORY_DIR, ZIG_ROOT, save_json, load_json, short_id
from source_snapshot import SourceSnapshot, SNAPSHOT_PATH

CHAIN_PATH = MEMORY_DIR / "snapshot_chain.json"

EXCLUDED_DIRS = {
    "node_modules", "zig-cache", "zig-out", ".git", "venv", "dist",
    "build",
}


def snapshot_id(tree_sha, created_at):
    return short_id("SN", tree_sha, created_at)


class VersionedSnapshot:
    def __init__(self, snapshot_id, version_number, tree_sha,
                 created_at, file_count, parent_id=None,
                 diff_summary=None):
        self.snapshot_id = snapshot_id
        self.version_number = version_number
        self.tree_sha = tree_sha
        self.created_at = created_at
        self.file_count = file_count
        self.parent_id = parent_id
        self.diff_summary = diff_summary or {}

    def to_dict(self):
        d = {
            "snapshot_id": self.snapshot_id,
            "version_number": self.version_number,
            "tree_sha": self.tree_sha,
            "created_at": self.created_at,
            "file_count": self.file_count,
            "parent_id": self.parent_id,
        }
        if self.diff_summary:
            d["diff_summary"] = self.diff_summary
        return d

    @classmethod
    def from_dict(cls, d):
        return cls(
            snapshot_id=d["snapshot_id"],
            version_number=d["version_number"],
            tree_sha=d["tree_sha"],
            created_at=d["created_at"],
            file_count=d["file_count"],
            parent_id=d.get("parent_id"),
            diff_summary=d.get("diff_summary"),
        )


class SnapshotChain:
    def __init__(self, snapshots=None, current_id=None):
        self.snapshots = snapshots or []
        self.current_id = current_id

    @classmethod
    def load(cls, path=None):
        path = Path(path or CHAIN_PATH)
        if not path.exists():
            return cls()
        doc = load_json(path)
        snapshots = [VersionedSnapshot.from_dict(s) for s in doc["snapshots"]]
        return cls(snapshots, doc.get("current_id"))

    def save(self, path=None):
        path = Path(path or CHAIN_PATH)
        doc = {
            "schema": "snapshot_chain",
            "version": 1,
            "current_id": self.current_id,
            "count": len(self.snapshots),
            "snapshots": [s.to_dict() for s in self.snapshots],
        }
        save_json(path, doc)

    @property
    def current(self):
        if not self.snapshots or self.current_id is None:
            return None
        for s in reversed(self.snapshots):
            if s.snapshot_id == self.current_id:
                return s
        return None

    @property
    def version_number(self):
        if not self.snapshots:
            return 0
        return self.snapshots[-1].version_number

    def append(self, vs):
        self.snapshots.append(vs)
        self.current_id = vs.snapshot_id

    def by_id(self, sid):
        for s in self.snapshots:
            if s.snapshot_id == sid:
                return s
        return None

    def history(self, limit=None):
        result = list(reversed(self.snapshots))
        if limit:
            result = result[:limit]
        return result

    def diff_between(self, id_a, id_b):
        a = self.by_id(id_a)
        b = self.by_id(id_b)
        if a is None or b is None:
            return None
        return {
            "from": a.to_dict(),
            "to": b.to_dict(),
            "tree_sha_changed": a.tree_sha != b.tree_sha,
            "file_count_delta": b.file_count - a.file_count,
            "version_delta": b.version_number - a.version_number,
        }

    def __len__(self):
        return len(self.snapshots)


def create_snapshot_from_diff(old_snap, new_snap, chain):
    diff = old_snap.compare(new_snap) if old_snap else {
        "added": list(new_snap.files.keys()),
        "removed": [],
        "modified": [],
        "renamed": [],
    }
    created_at = time.strftime("%Y-%m-%dT%H:%M:%S")
    tree_sha = new_snap.tree_sha()
    sid = snapshot_id(tree_sha, created_at)
    vs = VersionedSnapshot(
        snapshot_id=sid,
        version_number=chain.version_number + 1,
        tree_sha=tree_sha,
        created_at=created_at,
        file_count=len(new_snap),
        parent_id=chain.current_id,
        diff_summary={
            "added": len(diff["added"]),
            "removed": len(diff["removed"]),
            "modified": len(diff["modified"]),
            "renamed": len(diff["renamed"]),
        },
    )
    return vs, diff


def main():
    chain = SnapshotChain.load()
    old_snap = SourceSnapshot.load()
    new_snap = SourceSnapshot.build()

    if old_snap and old_snap.tree_sha() == new_snap.tree_sha():
        print("UNCHANGED:", chain.version_number)
        sys.exit(0)

    vs, diff = create_snapshot_from_diff(old_snap, new_snap, chain)
    chain.append(vs)
    chain.save()
    new_snap.save()

    print("SNAPSHOT:", vs.snapshot_id)
    print("VERSION:", vs.version_number)
    print("TREE_SHA:", vs.tree_sha[:32] + "...")
    print("FILES:", vs.file_count)
    print("DIFF:", json.dumps(vs.diff_summary))
    print("CHAIN_LENGTH:", len(chain))
    sys.exit(0)


if __name__ == "__main__":
    main()
