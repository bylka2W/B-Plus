import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from knowledge import Knowledge
from verify import VerifyEngine

GOLDEN_PATH = Path(r"C:\B-Plus\agent\golden\knowledge_cases.json")
ZIG_ROOT = Path(r"C:\B-Plus\zig")


def zig_tree_digest():
    h = hashlib.sha256()
    for p in sorted(ZIG_ROOT.rglob("*")):
        if p.is_file():
            h.update(str(p).encode("utf-8"))
            h.update(p.read_bytes())
    return h.hexdigest()


def semantic_fingerprint(model):
    return {
        "status": model["status"],
        "confidence": model["confidence"],
        "answer_type": model["answer_type"],
        "direct_answer": model["direct_answer"],
        "fact_ids": sorted(f["fact_id"] for f in model["facts"]),
        "relation_ids": sorted(r["relation_id"]
                               for r in model["relations"]),
        "evidence_ids": sorted(e["evidence_id"]
                               for e in model["evidence"]),
    }


class TestGolden(unittest.TestCase):
    k = None
    ve = None
    cases = None
    zig_before = None

    @classmethod
    def setUpClass(cls):
        cls.k = Knowledge.load()
        cls.ve = VerifyEngine(cls.k.ae.cb)
        cls.cases = json.loads(
            GOLDEN_PATH.read_text(encoding="utf-8"))["cases"]
        cls.zig_before = zig_tree_digest()

    @classmethod
    def tearDownClass(cls):
        if cls.zig_before is not None:
            assert cls.zig_before == zig_tree_digest(), \
                "B+ source tree changed during golden tests"

    def _ask(self, case):
        q = case["question"]
        d = self.k.route(q)
        a = self.k.ask(q)
        return d, a

    def test_cases_contract(self):
        for case in self.cases:
            with self.subTest(case=case["id"]):
                e = case["expect"]
                d, a = self._ask(case)

                if "intent" in e:
                    self.assertEqual(d["intent"], e["intent"],
                                     f"{case['id']} intent")
                if "entity" in e:
                    self.assertEqual(d["entity"], e["entity"],
                                     f"{case['id']} entity")
                if "routing_status" in e:
                    self.assertEqual(d["status"], e["routing_status"],
                                     f"{case['id']} routing")
                if "min_candidates" in e:
                    self.assertGreaterEqual(len(d["candidates"]),
                                            e["min_candidates"],
                                            case["id"])
                if "status" in e:
                    self.assertEqual(a["status"], e["status"],
                                     f"{case['id']} status")
                if "answer_type" in e:
                    self.assertEqual(a["answer_type"], e["answer_type"],
                                     case["id"])
                if "confidence" in e:
                    self.assertEqual(a["confidence"], e["confidence"],
                                     case["id"])
                if "confidence_ne" in e:
                    self.assertNotEqual(a["confidence"],
                                        e["confidence_ne"], case["id"])

                if "zero_claims" in e and e["zero_claims"]:
                    self.assertEqual(a["facts"], [], case["id"])
                if "direct_answer_null" in e and e["direct_answer_null"]:
                    self.assertIsNone(a["direct_answer"], case["id"])

                if a["facts"] or a["relations"]:
                    for f in a["facts"]:
                        self.assertTrue(f.get("fact_id"), case["id"])
                        self.assertTrue(f.get("evidence_id"), case["id"])
                    for r in a["relations"]:
                        self.assertTrue(r.get("relation_id"), case["id"])
                        self.assertTrue(
                            r.get("evidence_fact_ids"), case["id"])

                if "min_facts" in e:
                    self.assertGreaterEqual(len(a["facts"]),
                                            e["min_facts"], case["id"])
                if "min_relations" in e:
                    self.assertGreaterEqual(len(a["relations"]),
                                            e["min_relations"],
                                            case["id"])
                if "exact_relation_count" in e:
                    self.assertEqual(len(a["relations"]),
                                     e["exact_relation_count"],
                                     case["id"])
                if "min_evidence" in e:
                    self.assertGreaterEqual(len(a["evidence"]),
                                            e["min_evidence"], case["id"])

                if "required_entity_names" in e:
                    names = {it["name"] for it in a["entities"]}
                    for want in e["required_entity_names"]:
                        self.assertIn(want, names,
                                      f"{case['id']}: {want}")

                if "direct_answer_contains" in e \
                        and a["direct_answer"] is not None:
                    for frag in e["direct_answer_contains"]:
                        self.assertIn(frag, a["direct_answer"],
                                      f"{case['id']}: {frag!r}")

                vres = self.ve.verify_answer(a)
                self.assertEqual(vres["overall"], e["verify_overall"],
                                 f"{case['id']} verification: "
                                 f"{vres['reason']}")

    def test_relation_provenance_walk(self):
        a = self.k.ask("Кто вызывает foldConstantOp?")
        rel_entry = a["relations"][0]
        rid = rel_entry["relation_id"]
        sr = self.ve.cb.relations[rid]
        from common import short_id
        self.assertEqual(rid, short_id("SR", sr["relation_type"],
                                       sr["from_concept"],
                                       sr["to_concept"]))
        self.assertGreater(len(sr["evidence_fact_ids"]), 0)
        fid = sorted(sr["evidence_fact_ids"])[0]
        fact = self.ve.cb.facts[fid]
        self.assertEqual(fact["verification_status"], "VERIFIED")
        ev = self.ve.cb.store.evidence_by_id[fact["evidence_id"]]
        lines = Path(ev["source_file"]).read_text(
            encoding="utf-8").splitlines()
        chunk = "\n".join(lines[ev["line_start"] - 1:ev["line_end"]])
        self.assertEqual(chunk, ev["text"])
        self.assertIn(fact["line_start"],
                      range(ev["line_start"], ev["line_end"] + 1))

    def test_determinism_10x_semantic_structure(self):
        q = "Кто вызывает foldConstantOp?"
        base = semantic_fingerprint(self.k.ask(q))
        for i in range(9):
            fp = semantic_fingerprint(self.k.ask(q))
            self.assertEqual(fp, base, f"iteration {i}")

    def test_reproducibility_second_load_same_ids(self):
        k2 = Knowledge.load()
        q = "От чего зависит x64gen.zig?"
        fp1 = semantic_fingerprint(self.k.ask(q))
        d2 = k2.route(q)
        self.assertEqual(d2["intent"], "DEPENDENCIES")
        self.assertEqual(d2["status"], "ROUTED")
        fp2 = semantic_fingerprint(k2.ask(q))
        self.assertEqual(fp1, fp2)
        json.dumps(fp1)

    def test_missing_evidence_yields_unverified(self):
        a = self.k.ask("Кто вызывает foldConstantOp?")
        claim = dict(a["facts"][0])
        fid = claim["fact_id"]
        fact = self.ve.cb.facts[fid]
        orig = fact["evidence_id"]
        fact["evidence_id"] = "EV-" + "0" * 16
        try:
            v = self.ve.verify_claim({
                "claim": claim["claim"],
                "fact_id": fid,
                "evidence_id": fact["evidence_id"],
                "file": claim["file"],
                "line_start": claim["line_start"],
                "line_end": claim["line_end"],
                "status": claim["status"]})
        finally:
            fact["evidence_id"] = orig
        self.assertEqual(v["status"], "UNVERIFIED")
        self.assertIn("evidence not found", v["reason"])

    def test_golden_file_schema(self):
        doc = json.loads(GOLDEN_PATH.read_text(encoding="utf-8"))
        self.assertEqual(doc["schema"], "golden_knowledge_cases")
        self.assertGreaterEqual(len(doc["cases"]), 14)


if __name__ == "__main__":
    unittest.main(verbosity=2)
