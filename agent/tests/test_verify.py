import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from answer import AnswerEngine
from verify import VerifyEngine

ZIG_ROOT = Path(r"C:\B-Plus\zig")


def zig_tree_digest():
    h = hashlib.sha256()
    for p in sorted(ZIG_ROOT.rglob("*")):
        if p.is_file():
            h.update(str(p).encode("utf-8"))
            h.update(p.read_bytes())
    return h.hexdigest()


class TestVerifyEngine(unittest.TestCase):
    ve = None
    ae = None
    zig_before = None

    @classmethod
    def setUpClass(cls):
        cls.ve = VerifyEngine.load()
        cls.ae = AnswerEngine(cls.ve.cb)
        cls.zig_before = zig_tree_digest()

    @classmethod
    def tearDownClass(cls):
        if cls.zig_before is not None:
            assert cls.zig_before == zig_tree_digest(), \
                "B+ source tree changed during tests"

    def test_valid_chain_verified(self):
        m = self.ae.answer("CALLERS", "foldConstantOp")
        res = self.ve.verify_answer(m)
        self.assertEqual(res["overall"], "VERIFIED", res["reason"])
        self.assertGreater(res["claims_total"], 0)
        self.assertEqual(res["claims_verified"], res["claims_total"])
        for v in res["claim_results"]:
            self.assertEqual(v["status"], "VERIFIED")
            self.assertTrue(v["fact_id"].startswith("FACT-"))
            self.assertTrue(v["evidence_id"].startswith("EV-"))
            self.assertTrue(str(v["source_file"]).endswith(".zig"))
            self.assertIsInstance(v["line_start"], int)

    def test_missing_fact(self):
        claim = {"claim": "x", "fact_id": "FAKE-000",
                 "evidence_id": None, "file": "a.zig",
                 "line_start": 1, "line_end": 2, "status": "VERIFIED"}
        v = self.ve.verify_claim(claim)
        self.assertEqual(v["status"], "UNVERIFIED")
        self.assertIn("fact not found", v["reason"])

    def test_missing_evidence(self):
        fid = next(iter(self.ve.cb.facts))
        fact = self.ve.cb.facts[fid]
        orig = fact["evidence_id"]
        fact["evidence_id"] = "EV-" + "0" * 16
        try:
            v = self.ve.verify_claim({
                "claim": "t", "fact_id": fid,
                "evidence_id": fact["evidence_id"],
                "file": fact["source_file"],
                "line_start": fact["line_start"],
                "line_end": fact["line_end"],
                "status": "VERIFIED"})
        finally:
            fact["evidence_id"] = orig
        self.assertEqual(v["status"], "UNVERIFIED")
        self.assertIn("evidence not found", v["reason"])

    def test_missing_relation(self):
        v = self.ve.verify_relation_entry({"relation_id": "SR-nope"})
        self.assertEqual(v["status"], "UNVERIFIED")
        self.assertIn("relation not found", v["reason"])

    def test_invalid_source_path(self):
        ev = {"source_file": r"C:\Windows\evil.zig",
              "line_start": 1, "line_end": 1,
              "text": "x", "sha256": "", "id": "EV-x"}
        out = {"status": "UNVERIFIED", "reason": None}
        checks = []
        ok = self.ve._check_source(ev, checks, out)
        self.assertFalse(ok)
        self.assertIn("outside B+ tree", out["reason"])

    def test_invalid_line_start(self):
        path = next(iter(self.ve.cb.store.files_by_path.keys()))
        with open(path, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        ev = {"source_file": path, "line_start": 0,
              "line_end": 5, "text": "whatever", "sha256": digest,
              "id": "EV-y"}
        out = {"status": "UNVERIFIED", "reason": None}
        checks = []
        ok = self.ve._check_source(ev, checks, out)
        self.assertFalse(ok)
        self.assertIn("invalid line_start", out["reason"])

    def test_invalid_line_end(self):
        path = next(iter(self.ve.cb.store.files_by_path.keys()))
        with open(path, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        ev = {"source_file": path, "line_start": 3,
              "line_end": 2, "text": "", "sha256": digest, "id": "EV-z"}
        out = {"status": "UNVERIFIED", "reason": None}
        checks = []
        ok = self.ve._check_source(ev, checks, out)
        self.assertFalse(ok)
        self.assertIn("invalid line_end", out["reason"])

    def test_text_mismatch_rejected(self):
        path = next(iter(self.ve.cb.store.files_by_path.keys()))
        with open(path, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        ev = {"source_file": path, "line_start": 1, "line_end": 2,
              "text": "definitely not the real text",
              "sha256": digest, "id": "EV-m"}
        out = {"status": "UNVERIFIED", "reason": None}
        checks = []
        ok = self.ve._check_source(ev, checks, out)
        self.assertFalse(ok)
        self.assertIn("differs from real source", out["reason"])

    def test_partial_never_promoted_to_verified(self):
        target = None
        for cid, c in self.ve.cb.qe.search.concepts.items():
            if c["verification_status"] != "UNRESOLVED":
                continue
            if not any((self.ve.cb.facts.get(fid) or {}).get(
                    "verification_status") == "VERIFIED"
                    for fid in c["fact_ids"]):
                continue
            qr = self.ve.cb.qe.query("DEFINITION", c["name"])
            if qr["status"] == "RESOLVED":
                target = c["name"]
                break
        if not target:
            self.skipTest("no mixed-status concept")
        m = self.ae.answer("DEFINITION", target)
        self.assertNotEqual(m["confidence"], "VERIFIED")
        res = self.ve.verify_answer(m)
        self.assertNotEqual(res["overall"], "VERIFIED")
        self.assertIn("promotion forbidden", res["reason"])

    def test_unresolved_fact_claim_not_verified(self):
        bad_fid = None
        for fid, f in self.ve.cb.facts.items():
            if f["verification_status"] != "VERIFIED":
                bad_fid = fid
                break
        self.assertIsNotNone(bad_fid)
        f = self.ve.cb.facts[bad_fid]
        claim = {
            "claim": "forged", "fact_id": bad_fid,
            "evidence_id": f["evidence_id"],
            "file": f["source_file"],
            "line_start": f["line_start"],
            "line_end": f["line_end"],
            "status": "VERIFIED"}
        v = self.ve.verify_claim(claim)
        self.assertEqual(v["status"], "UNVERIFIED")
        self.assertIn("promotion forbidden", v["reason"])

    def test_deterministic_verification(self):
        m = self.ae.answer("CALLEES", "foldConstantOp")
        r1 = self.ve.verify_answer(m)
        r2 = self.ve.verify_answer(m)
        self.assertEqual(json.dumps(r1, sort_keys=True),
                         json.dumps(r2, sort_keys=True))

    def test_json_safe_result(self):
        m = self.ae.answer("CALLERS", "foldConstantOp")
        json.dumps(self.ve.verify_answer(m))
        v = self.ve.verify_relation_entry({"relation_id": "SR-nope"})
        json.dumps(v)

    def test_empty_answer_unsupported_never_verified(self):
        m = self.ae.answer("CALLERS", "ghost_none_999")
        res = self.ve.verify_answer(m)
        self.assertEqual(res["overall"], "UNSUPPORTED")

    def test_relations_in_answers_are_chain_verified(self):
        m = self.ae.answer("DEPENDENCIES", "x64gen.zig")
        if m["status"] != "RESOLVED":
            self.skipTest("module unavailable")
        res = self.ve.verify_answer(m)
        rels = res["relation_results"]
        self.assertGreater(len(rels), 0)
        for v in rels:
            self.assertEqual(v["status"], "VERIFIED", v["reason"])
            self.assertTrue(v["relation_id"].startswith("SR-"))
            self.assertTrue(v["evidence_id"].startswith("EV-"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
