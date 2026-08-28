import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from answer import AnswerEngine

ZIG_ROOT = Path(r"C:\B-Plus\zig")

REQUIRED_KEYS = {
    "schema", "version", "question", "answer_type", "direct_answer",
    "entities", "facts", "relations", "evidence", "confidence",
    "unresolved", "limitations", "provenance", "status",
}


def zig_tree_digest():
    h = hashlib.sha256()
    for p in sorted(ZIG_ROOT.rglob("*")):
        if p.is_file():
            h.update(str(p).encode("utf-8"))
            h.update(p.read_bytes())
    return h.hexdigest()


class TestAnswerEngine(unittest.TestCase):
    ae = None
    zig_before = None

    @classmethod
    def setUpClass(cls):
        cls.ae = AnswerEngine.load()
        cls.zig_before = zig_tree_digest()

    @classmethod
    def tearDownClass(cls):
        if cls.zig_before is not None:
            assert cls.zig_before == zig_tree_digest(), \
                "B+ source tree changed during tests"

    def test_schema_complete(self):
        m = self.ae.answer("DEFINITION", "foldConstantOp")
        self.assertEqual(m["schema"], "answer_model")
        self.assertEqual(m["version"], 1)
        self.assertTrue(REQUIRED_KEYS.issubset(m.keys()))

    def test_definition_direct_answer(self):
        m = self.ae.answer("DEFINITION", "foldConstantOp",
                           question="Where is foldConstantOp?")
        self.assertEqual(m["answer_type"], "DEFINITION")
        self.assertEqual(m["confidence"], "VERIFIED")
        self.assertIn("foldConstantOp is defined at", m["direct_answer"])
        self.assertGreater(len(m["facts"]), 0)
        self.assertGreater(len(m["evidence"]), 0)

    def test_callers_relation_answer(self):
        m = self.ae.answer("CALLERS", "emit")
        self.assertEqual(m["status"], "AMBIGUOUS")

    def test_every_claim_has_fact_and_evidence(self):
        m = self.ae.answer("CALLEES", "foldConstantOp")
        for f in m["facts"]:
            self.assertTrue(f.get("fact_id"), "claim without fact_id")
            self.assertTrue(f.get("evidence_id"),
                            "material claim without evidence")
            self.assertTrue(f.get("file"))
        for r in m["relations"]:
            self.assertTrue(r.get("relation_id"))
            self.assertIn("verification_status", r)
            self.assertIn("evidence_fact_ids", r)

    def test_not_found_never_becomes_answer(self):
        m = self.ae.answer("CALLERS", "ghost_function_xyz")
        self.assertEqual(m["status"], "NOT_FOUND")
        self.assertIsNone(m["direct_answer"])
        self.assertEqual(m["facts"], [])
        self.assertEqual(m["relations"], [])
        self.assertEqual(m["evidence"], [])
        self.assertEqual(m["confidence"], "UNSUPPORTED")
        joined = " ".join(m["limitations"])
        self.assertIn("not found", joined.lower())

    def test_ambiguous_never_silently_resolved(self):
        m = self.ae.answer("CALLERS", "emit",
                           question="Who calls emit?")
        self.assertEqual(m["status"], "AMBIGUOUS")
        self.assertIsNone(m["direct_answer"])
        self.assertGreaterEqual(len(m["entities"]), 2,
                                "expected multiple emit candidates")
        self.assertEqual(m["facts"], [],
                         "ambiguous entity must not produce claims")
        self.assertEqual(m["confidence"], "UNSUPPORTED")
        joined = " ".join(m["limitations"]).lower()
        self.assertIn("disambiguate", joined)

    def test_unknown_intent_passthrough(self):
        m = self.ae.answer("TELEPORT", "foldConstantOp")
        self.assertEqual(m["status"], "UNKNOWN_INTENT")
        self.assertIsNone(m["direct_answer"])
        self.assertEqual(m["confidence"], "UNSUPPORTED")

    def test_partial_never_promoted(self):
        target = None
        for cid, c in self.ae.cb.qe.search.concepts.items():
            if c["verification_status"] != "UNRESOLVED":
                continue
            has_verified = False
            for fid in c["fact_ids"]:
                f = self.ae.cb.facts.get(fid)
                if f and f["verification_status"] == "VERIFIED":
                    has_verified = True
                    break
            if not has_verified:
                continue
            qr = self.ae.cb.qe.query("DEFINITION", c["name"])
            if qr["status"] != "RESOLVED":
                continue
            target = c["name"]
            break
        if not target:
            self.skipTest("no uniquely-resolvable mixed-status concept")
        m = self.ae.answer("DEFINITION", target)
        self.assertNotEqual(
            m["confidence"], "VERIFIED",
            f"{target} has non-VERIFIED facts but answer claims VERIFIED")
        self.assertGreater(len(m["unresolved"]), 0)
        for u in m["unresolved"]:
            self.assertNotEqual(u["status"], "VERIFIED")

    def test_no_evidence_implies_no_verified(self):
        m = self.ae.answer("DEPENDENCIES", "x64gen.zig")
        if m["status"] != "RESOLVED":
            self.skipTest("module unavailable")
        if not m["evidence"] and m["confidence"] == "VERIFIED":
            self.fail("VERIFIED without any evidence chunk")

    def test_determinism(self):
        a = self.ae.answer("CALLERS", "foldConstantOp",
                           question="q1")
        b = self.ae.answer("CALLERS", "foldConstantOp",
                           question="q1")
        self.assertEqual(json.dumps(a, sort_keys=True),
                         json.dumps(b, sort_keys=True))

    def test_evidence_matches_disk(self):
        m = self.ae.answer("DEFINITION", "foldConstantOp")
        ev0 = m["evidence"][0]
        text = Path(ev0["file"]).read_text(encoding="utf-8").splitlines()
        chunk = "\n".join(text[ev0["line_start"] - 1:ev0["line_end"]])
        self.assertEqual(chunk, ev0["text"])

    def test_read_only_provenance(self):
        m = self.ae.answer("MODULE", "x64gen.zig")
        self.assertFalse(m["provenance"]["read_only"] is not True)
        self.assertTrue(m["provenance"]["read_only"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
