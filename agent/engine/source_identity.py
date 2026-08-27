import os
import sys
import time
import hashlib
import json
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import ZIG_ROOT, MEMORY_DIR, sha256_file, iter_zig_files, load_json, save_json

SNAPSHOT_PATH = MEMORY_DIR / "source_identity.json"

SOURCE_BPLUS = "bplus"
SOURCE_ZIG = "zig_upstream"
SOURCE_UNKNOWN = "unknown"

ALL_SOURCES = {SOURCE_BPLUS, SOURCE_ZIG, SOURCE_UNKNOWN}


class SourceSnapshot:
    __slots__ = (
        "source_id", "root_path", "zig_root", "commit_hash",
        "file_count", "total_lines", "total_bytes", "tree_sha256",
        "manifest_files", "file_hashes", "created_at", "verified_at",
        "evidence_count", "stale_count", "verified_count",
        "schema_version", "is_current",
    )

    def __init__(self):
        self.source_id = SOURCE_UNKNOWN
        self.root_path = ""
        self.zig_root = ""
        self.commit_hash = ""
        self.file_count = 0
        self.total_lines = 0
        self.total_bytes = 0
        self.tree_sha256 = ""
        self.manifest_files = []
        self.file_hashes = {}
        self.created_at = ""
        self.verified_at = ""
        self.evidence_count = 0
        self.stale_count = 0
        self.verified_count = 0
        self.schema_version = 1
        self.is_current = False

    def to_dict(self):
        return {
            "source_id": self.source_id,
            "root_path": self.root_path,
            "zig_root": self.zig_root,
            "commit_hash": self.commit_hash,
            "file_count": self.file_count,
            "total_lines": self.total_lines,
            "total_bytes": self.total_bytes,
            "tree_sha256": self.tree_sha256,
            "manifest_files": self.manifest_files,
            "file_hashes": self.file_hashes,
            "created_at": self.created_at,
            "verified_at": self.verified_at,
            "evidence_count": self.evidence_count,
            "stale_count": self.stale_count,
            "verified_count": self.verified_count,
            "schema_version": self.schema_version,
            "is_current": self.is_current,
        }

    @classmethod
    def from_dict(cls, d):
        s = cls()
        for k in self.__slots__:
            if k in d:
                setattr(s, k, d[k])
        return s


class SourceIdentity:
    def __init__(self):
        self.snapshots = []
        self.current_snapshot = None

    @classmethod
    def load(cls):
        identity = cls()
        if SNAPSHOT_PATH.exists():
            doc = load_json(SNAPSHOT_PATH)
            for sd in doc.get("snapshots", []):
                snap = SourceSnapshot()
                for k, v in sd.items():
                    if hasattr(snap, k):
                        setattr(snap, k, v)
                identity.snapshots.append(snap)
            current_id = doc.get("current_snapshot_id", "")
            for s in identity.snapshots:
                if s.source_id == current_id:
                    identity.current_snapshot = s
                    s.is_current = True
        return identity

    def save(self):
        doc = {
            "schema_version": 1,
            "current_snapshot_id": self.current_snapshot.source_id if self.current_snapshot else "",
            "snapshots": [s.to_dict() for s in self.snapshots],
        }
        save_json(SNAPSHOT_PATH, doc)

    def create_snapshot(self, root_path=None, source_id=None):
        root = str(root_path or ZIG_ROOT)
        if source_id is None:
            if "bplus" in root.lower() or "B-Plus" in root:
                source_id = SOURCE_BPLUS
            else:
                source_id = SOURCE_ZIG

        for existing in self.snapshots:
            if existing.source_id == source_id and existing.root_path == root:
                self.current_snapshot = existing
                existing.is_current = True
                return existing

        t0 = time.monotonic()
        snap = SourceSnapshot()
        snap.source_id = source_id
        snap.root_path = root
        snap.zig_root = root
        snap.created_at = datetime.now(timezone.utc).isoformat()
        snap.is_current = True

        commit = self._detect_commit(root)
        snap.commit_hash = commit

        files = iter_zig_files(root)
        snap.file_count = len(files)

        total_lines = 0
        total_bytes = 0
        file_hashes = {}
        tree_hasher = hashlib.sha256()

        for fp in files:
            try:
                with open(fp, "rb") as f:
                    data = f.read()
                file_hash = hashlib.sha256(data).hexdigest()
                rel = str(fp).replace(root, "").replace("\\", "/")
                file_hashes[rel] = file_hash
                tree_hasher.update(file_hash.encode())
                total_bytes += len(data)
                total_lines += data.decode("utf-8", errors="replace").count("\n") + 1
            except (OSError, IOError):
                continue

        snap.total_lines = total_lines
        snap.total_bytes = total_bytes
        snap.tree_sha256 = tree_hasher.hexdigest()
        snap.file_hashes = file_hashes
        snap.verified_at = snap.created_at

        manifest_names = [
            "build.zig", "build.zig.zon", "CMakeLists.txt",
            "README.md", "LICENSE", ".gitignore",
        ]
        snap.manifest_files = [
            m for m in manifest_names
            if os.path.exists(os.path.join(root, m))
        ]

        for s in self.snapshots:
            s.is_current = False
        self.snapshots.append(snap)
        self.current_snapshot = snap

        elapsed = (time.monotonic() - t0) * 1000
        self.save()
        return snap

    def verify_snapshot(self, source_id=None):
        snap = self._find_snapshot(source_id)
        if not snap:
            return None, "NOT_FOUND"

        t0 = time.monotonic()
        root = snap.root_path
        if not os.path.exists(root):
            snap.verified_at = datetime.now(timezone.utc).isoformat()
            self.save()
            return snap, "MISSING_ROOT"

        files = iter_zig_files(root)
        current_hashes = {}
        for fp in files:
            try:
                with open(fp, "rb") as f:
                    data = f.read()
                rel = str(fp).replace(root, "").replace("\\", "/")
                current_hashes[rel] = hashlib.sha256(data).hexdigest()
            except (OSError, IOError):
                continue

        stored = snap.file_hashes
        changed = 0
        added = 0
        removed = 0
        for rel, h in current_hashes.items():
            if rel in stored:
                if stored[rel] != h:
                    changed += 1
            else:
                added += 1
        for rel in stored:
            if rel not in current_hashes:
                removed += 1

        snap.verified_at = datetime.now(timezone.utc).isoformat()
        snap.file_count = len(current_hashes)

        self.save()
        elapsed = (time.monotonic() - t0) * 1000

        status = "CLEAN" if (changed == 0 and added == 0 and removed == 0) else "MODIFIED"
        return snap, status

    def get_file_hash(self, rel_path, source_id=None):
        snap = self._find_snapshot(source_id)
        if not snap:
            return None
        return snap.file_hashes.get(rel_path)

    def get_tree_hash(self, source_id=None):
        snap = self._find_snapshot(source_id)
        if not snap:
            return None
        return snap.tree_sha256

    def is_source_current(self, source_id=None):
        snap = self._find_snapshot(source_id)
        if not snap:
            return False
        return snap.is_current

    def _find_snapshot(self, source_id=None):
        if source_id is None:
            return self.current_snapshot
        for s in self.snapshots:
            if s.source_id == source_id:
                return s
        return None

    def _detect_commit(self, root):
        git_dir = os.path.join(root, ".git")
        if not os.path.isdir(git_dir):
            return ""
        head_file = os.path.join(git_dir, "HEAD")
        try:
            with open(head_file, "r") as f:
                head = f.read().strip()
            if head.startswith("ref: "):
                ref_path = os.path.join(git_dir, head[5:])
                if os.path.exists(ref_path):
                    with open(ref_path, "r") as f:
                        return f.read().strip()[:40]
            return head[:40]
        except (OSError, IOError):
            return ""


_instance = None


def get_source_identity():
    global _instance
    if _instance is None:
        _instance = SourceIdentity.load()
    return _instance


def main():
    si = SourceIdentity.load()
    print("SOURCE IDENTITY READY")

    snap = si.create_snapshot(r"C:\B-Plus\zig", SOURCE_BPLUS)
    print(f"\nB+ Snapshot:")
    print(f"  source_id: {snap.source_id}")
    print(f"  root: {snap.root_path}")
    print(f"  files: {snap.file_count}")
    print(f"  lines: {snap.total_lines}")
    print(f"  bytes: {snap.total_bytes}")
    print(f"  tree_sha256: {snap.tree_sha256[:16]}...")
    print(f"  commit: {snap.commit_hash[:16] if snap.commit_hash else 'N/A'}")
    print(f"  manifest: {snap.manifest_files}")

    snap2, status = si.verify_snapshot(SOURCE_BPLUS)
    print(f"\nVerify B+: {status}")
    print(f"  files now: {snap2.file_count}")

    print(f"\nCurrent source: {si.current_snapshot.source_id if si.current_snapshot else 'NONE'}")

    sys.exit(0)


if __name__ == "__main__":
    main()
