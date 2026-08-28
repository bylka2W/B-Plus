import sys
import os
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from engine.source_identity import (
    SourceIdentity, SourceSnapshot, get_source_identity,
    SNAPSHOT_PATH, SOURCE_BPLUS, SOURCE_ZIG, SOURCE_UNKNOWN, ALL_SOURCES,
)

PASS = 0
FAIL = 0


def check(name, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print("PASS:", name)
    else:
        FAIL += 1
        print("FAIL:", name, "-", detail)


def test_constants():
    check("ALL_SOURCES has 3", len(ALL_SOURCES) == 3)
    check("SOURCE_BPLUS", SOURCE_BPLUS in ALL_SOURCES)
    check("SOURCE_ZIG", SOURCE_ZIG in ALL_SOURCES)


def test_snapshot_slots():
    s = SourceSnapshot()
    s.source_id = "test"
    s.root_path = "C:\\test"
    s.file_count = 10
    s.tree_sha256 = "abc123"
    d = s.to_dict()
    check("snapshot.to_dict source_id", d["source_id"] == "test")
    check("snapshot.to_dict file_count", d["file_count"] == 10)
    check("snapshot.to_dict has schema_version", "schema_version" in d)


def test_load():
    si = SourceIdentity.load()
    check("SI loads", si is not None)
    check("SI has snapshots", isinstance(si.snapshots, list))


def test_singleton():
    s1 = get_source_identity()
    s2 = get_source_identity()
    check("Singleton", s1 is s2)


def test_create_snapshot():
    si = SourceIdentity.load()
    snap = si.create_snapshot(r"C:\B-Plus\zig", SOURCE_BPLUS)
    check("snapshot created", snap is not None)
    check("snapshot source_id", snap.source_id == SOURCE_BPLUS)
    check("snapshot root_path", snap.root_path == r"C:\B-Plus\zig")
    check("snapshot file_count > 0", snap.file_count > 0)
    check("snapshot total_lines > 0", snap.total_lines > 0)
    check("snapshot total_bytes > 0", snap.total_bytes > 0)
    check("snapshot tree_sha256 set", snap.tree_sha256 != "")
    check("snapshot manifest_files", len(snap.manifest_files) > 0)
    check("snapshot is_current", snap.is_current is True)
    check("snapshot created_at set", snap.created_at != "")
    d = snap.to_dict()
    check("snapshot roundtrip", d["source_id"] == SOURCE_BPLUS)


def test_current_snapshot():
    si = SourceIdentity.load()
    check("current snapshot set", si.current_snapshot is not None)
    check("current is bplus", si.current_snapshot.source_id == SOURCE_BPLUS)


def test_verify_clean():
    si = SourceIdentity.load()
    snap, status = si.verify_snapshot(SOURCE_BPLUS)
    check("verify returns snap", snap is not None)
    check("verify CLEAN", status == "CLEAN")
    check("verify verified_at updated", snap.verified_at != "")


def test_get_tree_hash():
    si = SourceIdentity.load()
    h = si.get_tree_hash(SOURCE_BPLUS)
    check("tree hash exists", h is not None and h != "")


def test_is_source_current():
    si = SourceIdentity.load()
    check("bplus is current", si.is_source_current(SOURCE_BPLUS) is True)
    check("unknown not current", si.is_source_current("nonexistent") is False)


def test_get_file_hash():
    si = SourceIdentity.load()
    h = si.get_file_hash("/build.zig", SOURCE_BPLUS)
    check("file hash exists", h is not None and h != "")


def test_persistence():
    si = SourceIdentity.load()
    snap = si.create_snapshot(r"C:\B-Plus\zig", SOURCE_BPLUS)
    old_tree = snap.tree_sha256
    si2 = SourceIdentity.load()
    check("persisted snapshots", len(si2.snapshots) >= 1)
    found = any(s.source_id == SOURCE_BPLUS for s in si2.snapshots)
    check("persisted bplus snapshot", found)


def test_snapshot_file_hashes():
    si = SourceIdentity.load()
    snap = si.current_snapshot
    if snap:
        check("file_hashes is dict", isinstance(snap.file_hashes, dict))
        check("file_hashes not empty", len(snap.file_hashes) > 0)
        build_hash = snap.file_hashes.get("/build.zig")
        check("build.zig in hashes", build_hash is not None)
    else:
        check("snapshot file_hashes skip", True)


def test_latency():
    si = SourceIdentity.load()
    t0 = time.monotonic()
    si.verify_snapshot(SOURCE_BPLUS)
    elapsed = (time.monotonic() - t0) * 1000
    check(f"verify latency {elapsed:.0f}ms < 5000ms", elapsed < 5000)


if __name__ == "__main__":
    test_constants()
    test_snapshot_slots()
    test_load()
    test_singleton()
    test_create_snapshot()
    test_current_snapshot()
    test_verify_clean()
    test_get_tree_hash()
    test_is_source_current()
    test_get_file_hash()
    test_persistence()
    test_snapshot_file_hashes()
    test_latency()
    print()
    print(f"SOURCE IDENTITY: {PASS} PASS / {FAIL} FAIL")
    sys.exit(0 if FAIL == 0 else 1)
