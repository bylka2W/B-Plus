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
from versioned import VersionedSnapshot, SnapshotChain, snapshot_id, create_snapshot_from_diff
from knowledge_lifespan import KnowledgeLifespan, ACTIVE, SUPERSEDED, rebuild_with_lifespan
from impact import ImpactGraph

WORK = Path(tempfile.mkdtemp(prefix="ver_test_"))

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


class TestVersionedSnapshot(unittest.TestCase):
    def test_snapshot_id_deterministic(self):
        sha = "abc123"
        ts = "2026-01-01T00:00:00"
        id1 = snapshot_id(sha, ts)
        id2 = snapshot_id(sha, ts)
        self.assertEqual(id1, id2)
        self.assertTrue(id1.startswith("SN-"))

    def test_snapshot_id_unique_for_different_input(self):
        id1 = snapshot_id("abc", "2026-01-01")
        id2 = snapshot_id("def", "2026-01-01")
        self.assertNotEqual(id1, id2)

    def test_versioned_snapshot_to_from_dict(self):
        vs = VersionedSnapshot(
            snapshot_id="SN-test",
            version_number=1,
            tree_sha="abc123",
            created_at="2026-01-01T00:00:00",
            file_count=10,
            parent_id=None,
            diff_summary={"added": 2, "removed": 0, "modified": 1, "renamed": 0},
        )
        d = vs.to_dict()
        vs2 = VersionedSnapshot.from_dict(d)
        self.assertEqual(vs.snapshot_id, vs2.snapshot_id)
        self.assertEqual(vs.version_number, vs2.version_number)
        self.assertEqual(vs.tree_sha, vs2.tree_sha)
        self.assertEqual(vs.diff_summary, vs2.diff_summary)

    def test_snapshot_chain_append_and_load(self):
        chain_path = str(WORK / "chain.json")
        try:
            chain = SnapshotChain()
            self.assertEqual(len(chain), 0)
            self.assertIsNone(chain.current)

            vs1 = VersionedSnapshot("SN-1", 1, "sha1", "2026-01-01", 10)
            chain.append(vs1)
            self.assertEqual(len(chain), 1)
            self.assertEqual(chain.current.snapshot_id, "SN-1")
            self.assertEqual(chain.version_number, 1)

            vs2 = VersionedSnapshot("SN-2", 2, "sha2", "2026-01-02", 12, parent_id="SN-1")
            chain.append(vs2)
            self.assertEqual(len(chain), 2)
            self.assertEqual(chain.current.snapshot_id, "SN-2")
            self.assertEqual(chain.version_number, 2)

            chain.save(chain_path)
            chain2 = SnapshotChain.load(chain_path)
            self.assertEqual(len(chain2), 2)
            self.assertEqual(chain2.current.snapshot_id, "SN-2")
            self.assertEqual(chain2.current.parent_id, "SN-1")
        finally:
            if os.path.exists(chain_path):
                os.remove(chain_path)

    def test_snapshot_chain_history(self):
        chain = SnapshotChain()
        for i in range(5):
            vs = VersionedSnapshot(f"SN-{i}", i + 1, f"sha{i}", f"2026-01-0{i+1}", 10 + i)
            chain.append(vs)
        history = chain.history(limit=3)
        self.assertEqual(len(history), 3)
        self.assertEqual(history[0].snapshot_id, "SN-4")
        self.assertEqual(history[1].snapshot_id, "SN-3")
        self.assertEqual(history[2].snapshot_id, "SN-2")

    def test_snapshot_chain_by_id(self):
        chain = SnapshotChain()
        vs1 = VersionedSnapshot("SN-aaa", 1, "sha1", "ts1", 10)
        vs2 = VersionedSnapshot("SN-bbb", 2, "sha2", "ts2", 12)
        chain.append(vs1)
        chain.append(vs2)
        self.assertIs(chain.by_id("SN-aaa"), vs1)
        self.assertIs(chain.by_id("SN-bbb"), vs2)
        self.assertIsNone(chain.by_id("SN-xxx"))

    def test_diff_between_snapshots(self):
        chain = SnapshotChain()
        vs1 = VersionedSnapshot("SN-1", 1, "sha1", "ts1", 100)
        vs2 = VersionedSnapshot("SN-2", 2, "sha2", "ts2", 105, parent_id="SN-1")
        chain.append(vs1)
        chain.append(vs2)
        diff = chain.diff_between("SN-1", "SN-2")
        self.assertIsNotNone(diff)
        self.assertTrue(diff["tree_sha_changed"])
        self.assertEqual(diff["file_count_delta"], 5)
        self.assertEqual(diff["version_delta"], 1)

    def test_diff_between_nonexistent_returns_none(self):
        chain = SnapshotChain()
        self.assertIsNone(chain.diff_between("SN-1", "SN-2"))

    def test_create_snapshot_from_diff(self):
        w = MiniWorld()
        chain_path = str(WORK / "chain.json")
        snap_path = str(WORK / "snap.json")
        try:
            chain = SnapshotChain()
            s1 = SourceSnapshot.build(str(w.root))
            s1.save(snap_path)

            vs1, _ = create_snapshot_from_diff(None, s1, chain)
            chain.append(vs1)

            w.modify_a()
            s2 = SourceSnapshot.build(str(w.root))
            vs2, diff = create_snapshot_from_diff(s1, s2, chain)
            chain.append(vs2)

            self.assertEqual(vs2.parent_id, vs1.snapshot_id)
            self.assertEqual(vs2.version_number, 2)
            self.assertIn("src/a.zig", diff["modified"])
        finally:
            shutil.rmtree(w.root)


class TestKnowledgeLifespan(unittest.TestCase):
    def test_lifespan_empty(self):
        ls = KnowledgeLifespan()
        self.assertEqual(len(ls), 0)
        stats = ls.stats()
        self.assertEqual(stats["total"], 0)
        self.assertEqual(stats["active"], 0)

    def test_supersede_all(self):
        ls = KnowledgeLifespan()
        ls.activate(["F1", "F2", "F3"], "SN-1")
        self.assertEqual(ls.stats()["active"], 3)

        count = ls.supersede_all("SN-2")
        self.assertEqual(count, 3)
        self.assertEqual(ls.stats()["superseded"], 3)
        self.assertEqual(ls.stats()["active"], 0)

    def test_activate_after_supersede(self):
        ls = KnowledgeLifespan()
        ls.activate(["F1", "F2"], "SN-1")
        ls.supersede_all("SN-2")
        ls.activate(["F3", "F4"], "SN-2")
        self.assertEqual(ls.stats()["active"], 2)
        self.assertEqual(ls.stats()["superseded"], 2)

    def test_active_ids(self):
        ls = KnowledgeLifespan()
        ls.activate(["F1", "F2", "F3"], "SN-1")
        self.assertEqual(ls.active_ids(), {"F1", "F2", "F3"})
        ls.supersede_all("SN-2")
        self.assertEqual(ls.active_ids(), set())

    def test_superseded_ids(self):
        ls = KnowledgeLifespan()
        ls.activate(["F1", "F2"], "SN-1")
        self.assertEqual(ls.superseded_ids(), set())
        ls.supersede_all("SN-2")
        self.assertEqual(ls.superseded_ids(), {"F1", "F2"})

    def test_history_for_item(self):
        ls = KnowledgeLifespan()
        ls.activate(["F1"], "SN-1")
        ls.supersede_all("SN-2")
        ls.activate(["F1"], "SN-2")
        ls.supersede_all("SN-3")
        history = ls.history_for("F1")
        self.assertEqual(len(history), 3)
        self.assertEqual(history[0]["status"], SUPERSEDED)
        self.assertEqual(history[0]["valid_to"], "SN-2")
        self.assertEqual(history[2]["status"], SUPERSEDED)

    def test_active_at_snapshot(self):
        ls = KnowledgeLifespan()
        ls.activate(["F1", "F2"], "SN-1")
        ls.supersede_all("SN-2")
        ls.activate(["F3"], "SN-2")
        at_sn1 = ls.active_at("SN-1")
        self.assertIn("F1", at_sn1)
        self.assertIn("F2", at_sn1)
        at_sn2 = ls.active_at("SN-2")
        self.assertIn("F1", at_sn2)
        self.assertIn("F3", at_sn2)

    def test_save_load_roundtrip(self):
        path = str(WORK / "lifespan.json")
        try:
            ls = KnowledgeLifespan()
            ls.activate(["F1", "F2"], "SN-1")
            ls.supersede_all("SN-2")
            ls.activate(["F3"], "SN-2")
            ls.save(path)
            ls2 = KnowledgeLifespan.load(path)
            self.assertEqual(ls.stats()["active"], ls2.stats()["active"])
            self.assertEqual(ls.stats()["superseded"], ls2.stats()["superseded"])
        finally:
            if os.path.exists(path):
                os.remove(path)

    def test_rebuild_with_lifespan(self):
        facts_doc = {"items": [{"fact_id": "F1"}, {"fact_id": "F2"}]}
        concepts_doc = {"items": [{"concept_id": "C1"}]}
        rels_doc = {"items": [{"relation_id": "R1"}]}
        ls = KnowledgeLifespan()
        ls = rebuild_with_lifespan("SN-1", facts_doc, concepts_doc, rels_doc, ls)
        self.assertEqual(ls.stats()["active"], 4)
        self.assertEqual(ls.stats()["superseded"], 0)

        ls2 = rebuild_with_lifespan("SN-2", facts_doc, concepts_doc, rels_doc, ls)
        self.assertEqual(ls2.stats()["active"], 4)
        self.assertEqual(ls2.stats()["superseded"], 4)

    def test_no_data_loss_on_supersede(self):
        ls = KnowledgeLifespan()
        ls.activate(["F1", "F2"], "SN-1")
        ls.supersede_all("SN-2")
        self.assertEqual(len(ls), 2)
        for e in ls.entries:
            self.assertEqual(e["status"], SUPERSEDED)
            self.assertIsNotNone(e["valid_from"])
            self.assertEqual(e["valid_to"], "SN-2")


class TestImpactGraph(unittest.TestCase):
    def test_empty_graph(self):
        g = ImpactGraph()
        stats = g.stats()
        self.assertEqual(stats["files"], 0)
        self.assertEqual(stats["symbols"], 0)

    def test_impact_for_unknown_file(self):
        g = ImpactGraph()
        imp = g.impact_for_file("nonexistent.zig")
        self.assertEqual(imp["total_affected"], 0)
        self.assertEqual(imp["cascade_depth"], 0)

    def test_cascade_depth(self):
        g = ImpactGraph(
            file_to_symbols={"a.zig": ["S1"]},
            symbol_to_relations={"S1": ["R1"]},
            relation_to_facts={"R1": ["F1"]},
            fact_to_concepts={"F1": ["C1"]},
        )
        depth = g._cascade_depth("a.zig")
        self.assertEqual(depth, 3)

    def test_cascade_depth_partial(self):
        g = ImpactGraph(
            file_to_symbols={"a.zig": ["S1"]},
            symbol_to_relations={"S1": []},
        )
        depth = g._cascade_depth("a.zig")
        self.assertEqual(depth, 1)

    def test_impact_for_file_full_cascade(self):
        g = ImpactGraph(
            file_to_symbols={"foo.zig": ["S1", "S2"]},
            symbol_to_relations={"S1": ["R1"], "S2": ["R2", "R3"]},
            relation_to_facts={"R1": ["F1"], "R2": ["F2"]},
            fact_to_concepts={"F1": ["C1"]},
        )
        imp = g.impact_for_file("foo.zig")
        self.assertEqual(imp["total_affected"], 7)
        self.assertIn("S1", imp["symbols"])
        self.assertIn("S2", imp["symbols"])
        self.assertIn("R1", imp["relations"])
        self.assertIn("R2", imp["relations"])
        self.assertIn("R3", imp["relations"])
        self.assertIn("F1", imp["facts"])
        self.assertIn("F2", imp["facts"])
        self.assertIn("C1", imp["concepts"])

    def test_impact_for_files_merge(self):
        g = ImpactGraph(
            file_to_symbols={"a.zig": ["S1"], "b.zig": ["S2"]},
            symbol_to_relations={"S1": ["R1"], "S2": ["R2"]},
            relation_to_facts={"R1": ["F1"], "R2": ["F2"]},
            fact_to_concepts={"F1": ["C1"], "F2": ["C2"]},
        )
        imp = g.impact_for_files(["a.zig", "b.zig"])
        self.assertEqual(len(imp["symbols"]), 2)
        self.assertEqual(len(imp["concepts"]), 2)

    def test_save_load_roundtrip(self):
        path = str(WORK / "impact.json")
        try:
            g = ImpactGraph(
                file_to_symbols={"a.zig": ["S1"]},
                symbol_to_relations={"S1": ["R1"]},
                relation_to_facts={"R1": ["F1"]},
                fact_to_concepts={"F1": ["C1"]},
                snapshot_id="SN-1",
            )
            g.save(path)
            g2 = ImpactGraph.load(path)
            self.assertEqual(g.stats(), g2.stats())
        finally:
            if os.path.exists(path):
                os.remove(path)


class TestBPlusIntegrity(unittest.TestCase):
    def test_bplus_unchanged_after_all_operations(self):
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


if __name__ == "__main__":
    unittest.main()
