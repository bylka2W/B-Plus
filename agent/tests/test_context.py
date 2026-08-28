import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from common import FACTS_PATH, SEMANTIC_RELATIONS_PATH, load_json
from context import ContextBuilder

MEMORY = Path(r"C:\B-Plus\agent\memory")
UPSTREAM = [
    "source_index.json",
    "source_evidence.json",
    "source_symbols.json",
    "source_relations.json",
    "facts.json",
    "concepts.json",
    "semantic_relations.json",
    "graph.json",
]


def upstream_hashes():
    return {
        n: hashlib.sha256((MEMORY / n).read_bytes()).hexdigest()
        for n in UPSTREAM
    }


class TestContextBuilder(unittest.TestCase):
    cb = None
    hashes_before = None
    facts_by_id = None
    rels_by_id = None

    @classmethod
    def setUpClass(cls):
        cls.hashes_before = upstream_hashes()
        cls.cb = ContextBuilder.load()
        cls.facts_by_id = {
            f["fact_id"]: f for f in load_json(FACTS_PATH)["items"]
        }
        cls.rels_by_id = {
            r["relation_id"]: r
            for r in load_json(SEMANTIC_RELATIONS_PATH)["items"]
        }

    def _pack_callers(self):
        qr = self.cb.qe.query("CALLERS", "emit")
        return self.cb.build(qr)

    def test_pack_schema(self):
        pack = self._pack_callers()
        for key in (
            "schema", "version", "intent", "entity", "status", "knowledge",
            "target", "claims", "relation_ids", "confidence", "evidence",
            "items_head", "count_items",
        ):
            self.assertIn(key, pack)
        self.assertEqual(pack["schema"], "context_pack")
        self.assertEqual(pack["knowledge"]["concepts"], 9636)

    def test_claims_traceable(self):
        pack = self._pack_callers()
        self.assertGreater(len(pack["claims"]), 0)
        for c in pack["claims"]:
            self.assertIn(c["fact_id"], self.facts_by_id)
            src = self.facts_by_id[c["fact_id"]]
            self.assertEqual(c["status"], src["verification_status"])
            self.assertEqual(c["evidence_id"], src["evidence_id"])

    def test_evidence_matches_disk(self):
        pack = self._pack_callers()
        self.assertGreater(len(pack["evidence"]), 0)
        index = load_json(MEMORY / "source_index.json")
        file_sha = {f["path"]: f["sha256"] for f in index["files"]}
        checked = 0
        for ev in pack["evidence"]:
            real = open(ev["file"], "rb").read().decode(
                "utf-8", "ignore"
            ).splitlines()
            sl = "\n".join(real[ev["line_start"] - 1:ev["line_end"]])
            self.assertEqual(sl, ev["text"], ev["evidence_id"])
            self.assertEqual(file_sha[ev["file"]], ev["sha256"])
            checked += 1
        self.assertGreaterEqual(checked, 3)

    def test_relation_ids_valid(self):
        pack = self._pack_callers()
        self.assertGreater(len(pack["relation_ids"]), 0)
        target = pack["target"]["concept_id"]
        for r in pack["relation_ids"]:
            src = self.rels_by_id.get(r["relation_id"])
            self.assertIsNotNone(src, r["relation_id"])
            endpoints = {src["from_concept"], src["to_concept"]}
            self.assertIn(target, endpoints)
            self.assertEqual(r["verification_status"],
                             src["verification_status"])

    def test_confidence_rules(self):
        good = self._pack_callers()
        self.assertEqual(good["confidence"], "VERIFIED")
        qr = self.cb.qe.query("DEFINITION", "__ghost__")
        empty = self.cb.build(qr)
        self.assertEqual(empty["confidence"], "UNSUPPORTED")
        self.assertEqual(empty["claims"], [])
        self.assertIsNone(empty["target"])

    def test_caps_respected(self):
        qr = self.cb.qe.query("CALLEES", "emit")
        tiny = self.cb.build(qr, max_claims=2, max_evidence=1)
        self.assertLessEqual(len(tiny["claims"]), 2)
        self.assertLessEqual(len(tiny["evidence"]), 1)

    def test_deterministic_pack(self):
        a = self._pack_callers()
        b = self._pack_callers()
        self.assertEqual(
            json.dumps(a, sort_keys=True), json.dumps(b, sort_keys=True)
        )

    def test_artifacts_read_only(self):
        current = upstream_hashes()
        for n in UPSTREAM:
            self.assertEqual(current[n], self.hashes_before[n], n)


if __name__ == "__main__":
    unittest.main(verbosity=2)
