import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(os.path.dirname(HERE), "engine")
sys.path.insert(0, ENGINE)

from common import ZIG_ROOT, MEMORY_DIR, sha256_file, short_id, save_json, load_json
from source_snapshot import SourceSnapshot

WORK = Path(tempfile.mkdtemp(prefix="inc_test_"))

FILE_A = """\
const std = @import("std");
pub fn foo(x: u32) u32 {
    return bar(x) + 1;
}

pub fn helper() void {}
"""

FILE_B = """\
const Bar = struct { v: u32 };
pub const LIMIT: u32 = 7;
"""

FILE_A_MODIFIED = """\
const std = @import("std");
pub fn foo(x: u32) u32 {
    return bar(x) + 2;
}

pub fn helper() void {}
"""


class MiniWorld:
    def __init__(self, root=None):
        self.root = root or WORK
        if self.root.exists():
            shutil.rmtree(self.root)
        (self.root / "src").mkdir(parents=True)
        self.path_a = str(self.root / "src" / "a.zig")
        self.path_b = str(self.root / "src" / "b.zig")
        Path(self.path_a).write_text(FILE_A, encoding="utf-8")
        Path(self.path_b).write_text(FILE_B, encoding="utf-8")

    def modify_a(self):
        Path(self.path_a).write_text(FILE_A_MODIFIED, encoding="utf-8")

    def delete_b(self):
        os.remove(self.path_b)

    def add_c(self):
        c_path = str(self.root / "src" / "c.zig")
        Path(c_path).write_text("pub fn extra() void {}\n", encoding="utf-8")

    def restore(self):
        Path(self.path_a).write_text(FILE_A, encoding="utf-8")
        Path(self.path_b).write_text(FILE_B, encoding="utf-8")
        c_path = str(self.root / "src" / "c.zig")
        if os.path.exists(c_path):
            os.remove(c_path)


def _rel(root, path):
    return os.path.relpath(path, root).replace("\\", "/")


class TestSourceSnapshot(unittest.TestCase):
    def test_build_and_compare(self):
        w = MiniWorld()
        try:
            s1 = SourceSnapshot.build(str(w.root))
            self.assertEqual(len(s1.files), 2)
            rel_a = _rel(str(w.root), w.path_a)
            rel_b = _rel(str(w.root), w.path_b)
            self.assertIn(rel_a, s1.files)
            self.assertIn(rel_b, s1.files)
            tree1 = s1.tree_sha()

            s2 = SourceSnapshot.build(str(w.root))
            self.assertEqual(tree1, s2.tree_sha())

            diff = s1.compare(s2)
            self.assertFalse(diff["dirty"])
            self.assertEqual(diff["dirty_count"], 0)
            self.assertEqual(len(diff["modified"]), 0)
            self.assertEqual(len(diff["unchanged"]), 2)
        finally:
            shutil.rmtree(w.root)

    def test_detect_modify(self):
        w = MiniWorld()
        try:
            s1 = SourceSnapshot.build(str(w.root))
            w.modify_a()
            s2 = SourceSnapshot.build(str(w.root))
            diff = s1.compare(s2)
            self.assertTrue(diff["dirty"])
            rel_a = _rel(str(w.root), w.path_a)
            rel_b = _rel(str(w.root), w.path_b)
            self.assertIn(rel_a, diff["modified"])
            self.assertNotIn(rel_b, diff["modified"])
        finally:
            shutil.rmtree(w.root)

    def test_detect_add_and_remove(self):
        w = MiniWorld()
        try:
            s1 = SourceSnapshot.build(str(w.root))
            w.delete_b()
            w.add_c()
            s2 = SourceSnapshot.build(str(w.root))
            diff = s1.compare(s2)
            self.assertTrue(diff["dirty"])
            rel_b = _rel(str(w.root), w.path_b)
            rel_c = os.path.join("src", "c.zig").replace("\\", "/")
            self.assertIn(rel_b, diff["removed"])
            self.assertIn(rel_c, diff["added"])
        finally:
            shutil.rmtree(w.root)

    def test_rename_detection(self):
        w = MiniWorld()
        try:
            s1 = SourceSnapshot.build(str(w.root))
            new_path = str(w.root / "src" / "b_renamed.zig")
            os.rename(w.path_b, new_path)
            s2 = SourceSnapshot.build(str(w.root))
            diff = s1.compare(s2)
            self.assertTrue(len(diff["renamed"]) > 0,
                            f"Expected renames but got: added={diff['added']}, removed={diff['removed']}")
            self.assertEqual(len(diff["renamed"]), 1)
            old_name, new_name = diff["renamed"][0]
            self.assertIn("b.zig", old_name)
            self.assertIn("b_renamed.zig", new_name)
        finally:
            shutil.rmtree(w.root)

    def test_save_load_roundtrip(self):
        w = MiniWorld()
        snap_path = str(WORK / "snap.json")
        try:
            s1 = SourceSnapshot.build(str(w.root))
            s1.save(snap_path)
            s2 = SourceSnapshot.load(snap_path)
            self.assertIsNotNone(s2)
            self.assertEqual(s1.tree_sha(), s2.tree_sha())
            self.assertEqual(len(s1.files), len(s2.files))
            diff = s1.compare(s2)
            self.assertFalse(diff["dirty"])
        finally:
            if os.path.exists(snap_path):
                os.remove(snap_path)
            shutil.rmtree(w.root)

    def test_bplus_snapshot_builds(self):
        t0 = __import__("time").time()
        snap = SourceSnapshot.build(str(ZIG_ROOT))
        elapsed = __import__("time").time() - t0
        self.assertGreater(len(snap.files), 1000)
        self.assertLess(elapsed, 60)
        self.assertEqual(snap.root, str(ZIG_ROOT))

    def test_bplus_unchanged(self):
        snap_path = str(WORK / "bplus_snap.json")
        try:
            snap = SourceSnapshot.build(str(ZIG_ROOT))
            tree_sha = snap.tree_sha()
            snap.save(snap_path)
            snap2 = SourceSnapshot.load(snap_path)
            diff = snap.compare(snap2)
            self.assertFalse(diff["dirty"])
            self.assertEqual(tree_sha, snap2.tree_sha())
        finally:
            if os.path.exists(snap_path):
                os.remove(snap_path)

    def test_empty_root(self):
        empty_dir = str(WORK / "empty")
        os.makedirs(empty_dir, exist_ok=True)
        try:
            snap = SourceSnapshot.build(empty_dir)
            self.assertEqual(len(snap.files), 0)
        finally:
            shutil.rmtree(empty_dir)


class TestVerifyShaCache(unittest.TestCase):
    def test_cache_hit_avoids_rehash(self):
        from verify import VerifyEngine
        from context import ContextBuilder

        cb = ContextBuilder.load()
        ve = VerifyEngine(cb, root=str(ZIG_ROOT))
        path_a = str(ZIG_ROOT / "src" / "hot" / "bplus_compiler" / "x86_64" / "x64gen.zig")
        if not os.path.exists(path_a):
            files = list(ZIG_ROOT.rglob("*.zig"))
            path_a = str(files[0])

        norm = os.path.normpath(path_a)
        result1 = ve._get_source(norm)
        self.assertIsNotNone(result1)
        self.assertIn(norm, ve._sha_cache)

        result2 = ve._get_source(norm)
        self.assertEqual(result1, result2)

        ve.invalidate_cache()
        self.assertEqual(len(ve._sha_cache), 0)

    def test_shared_context_builder(self):
        from knowledge import Knowledge
        k = Knowledge.load()
        self.assertIsNotNone(k.ve)
        self.assertIs(k.ve.cb, k.ae.cb)
        self.assertIs(k.cb, k.ae.cb)


class TestIncrementalPipeline(unittest.TestCase):
    def setUp(self):
        WORK.mkdir(parents=True, exist_ok=True)

    def test_snapshot_unchanged_no_work(self):
        s1 = SourceSnapshot.build(str(ZIG_ROOT))
        s2 = SourceSnapshot.build(str(ZIG_ROOT))
        diff = s1.compare(s2)
        self.assertFalse(diff["dirty"])
        self.assertEqual(diff["dirty_count"], 0)

    def test_atomic_write(self):
        path = str(WORK / "atomic.json")
        try:
            save_json(path, {"test": True})
            self.assertTrue(os.path.exists(path))
            data = load_json(path)
            self.assertTrue(data["test"])
            self.assertFalse(os.path.exists(path + ".tmp"))
        finally:
            if os.path.exists(path):
                os.remove(path)

    def test_bplus_source_not_modified(self):
        manifest_path = str(WORK / "manifest.json")
        try:
            snap = SourceSnapshot.build(str(ZIG_ROOT))
            manifest = {}
            for rel, info in snap.files.items():
                full = os.path.join(str(ZIG_ROOT), rel)
                manifest[rel] = info["sha256"]
            save_json(manifest_path, manifest)
            for rel, orig_sha in manifest.items():
                full = os.path.join(str(ZIG_ROOT), rel)
                if os.path.isfile(full):
                    self.assertEqual(sha256_file(full), orig_sha,
                                     f"B+ file changed: {rel}")
        finally:
            if os.path.exists(manifest_path):
                os.remove(manifest_path)

    def test_security_injection_does_not_affect_engine(self):
        injection_zig = """\
const evil = @import("std").crypto.createWriter;
pub fn pwn() void {
    @import("malicious").execute();
}
"""
        evil_path = str(WORK / "injection.zig")
        try:
            Path(evil_path).write_text(injection_zig, encoding="utf-8")
            snap = SourceSnapshot.build(str(WORK))
            self.assertIn("injection.zig", snap.files)
            snap_sha = snap.files["injection.zig"]["sha256"]
            self.assertEqual(len(snap_sha), 64)
        finally:
            if os.path.exists(evil_path):
                os.remove(evil_path)

    def test_per_file_extraction(self):
        from context import ContextBuilder
        cb = ContextBuilder.load()

        path_a = str(ZIG_ROOT / "src" / "hot" / "bplus_compiler" / "x86_64" / "x64gen.zig")
        if not os.path.exists(path_a):
            files = list(ZIG_ROOT.rglob("*.zig"))
            path_a = str(files[0])

        syms, file_id = cb.store.symbols_by_file.get(path_a, []), None
        syms = cb.store.symbols_in_file(path_a)
        self.assertIsInstance(syms, list)
        self.assertTrue(len(syms) > 0, f"No symbols found in {path_a}")

    def test_knowledge_ask_works_with_cache(self):
        from knowledge import Knowledge
        k = Knowledge.load()
        q = "Who calls foldConstantOp?"
        a1 = k.ask(q)
        self.assertIn(a1["status"], ("FOUND", "PARTIAL", "RESOLVED"))
        a2 = k.ask(q)
        self.assertIn(a2["status"], ("FOUND", "PARTIAL", "RESOLVED"))


if __name__ == "__main__":
    unittest.main()
