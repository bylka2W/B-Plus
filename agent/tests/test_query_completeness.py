import copy
import hashlib
import json
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "engine"))

from answer import ANSWER_TYPES
from knowledge import Knowledge
from verify import VerifyEngine, ZIG_ROOT

CASES_PATH = os.path.join(os.path.dirname(HERE),
                          "golden", "query_completeness.json")


def tree_manifest(root):
    manifest = {}
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, root).lower()
            with open(p, "rb") as f:
                manifest[rel] = hashlib.sha256(f.read()).hexdigest()
    return manifest


class TestQueryCompleteness(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.k = Knowledge.load()
        cls.ve = VerifyEngine.load()
        cls.store = cls.ve.cb.store
        with open(CASES_PATH, encoding="utf-8") as f:
            cls.doc = json.load(f)
        cls._before = tree_manifest(ZIG_ROOT)
        cls.addClassCleanup(cls._check_tree_unchanged)

    @classmethod
    def _check_tree_unchanged(cls):
        if tree_manifest(ZIG_ROOT) != cls._before:
            raise AssertionError("B+ source tree changed during tests")

    def _walk_fact_to_source(self, fact, checks):
        fid = fact["fact_id"]
        self.assertIn(fid, self.ve.cb.facts)
        stored = self.ve.cb.facts[fid]
        eid = stored["evidence_id"]
        ev = self.store.evidence_by_id[eid]
        path = ev["source_file"]
        norm = os.path.normpath(path)
        root = os.path.normpath(ZIG_ROOT)
        checks.append(fid)
        self.assertTrue(norm.startswith(root), fid)
        self.assertTrue(os.path.isfile(path), fid)
        pin = self.store.files_by_path.get(path)
        self.assertIsNotNone(pin, fid)
        with open(path, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        self.assertEqual(digest, ev["sha256"], fid)
        self.assertEqual(digest, pin["sha256"], fid)
        ls, le = ev["line_start"], ev["line_end"]
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        self.assertGreaterEqual(ls, 1, fid)
        self.assertLessEqual(le, len(lines), fid)
        self.assertEqual("\n".join(lines[ls - 1:le]), ev["text"], fid)
        fl, fe = int(stored["line_start"]), int(stored["line_end"])
        self.assertGreaterEqual(fl, 1, fid)
        self.assertLessEqual(fe, len(lines), fid)

    def test_capability_chain_per_intent(self):
        matrix = self.doc["capability_matrix"]
        for c in self.doc["cases"]:
            with self.subTest(case=c["id"]):
                spec = matrix[c["intent"]]
                a = self.k.ask(c["question"])
                self.assertEqual(a["status"], "RESOLVED", c["id"])
                self.assertEqual(a["answer_type"],
                                 c["expected_answer_type"], c["id"])
                self.assertEqual(c["expected_answer_type"],
                                 ANSWER_TYPES[c["intent"]], c["id"])
                self.assertEqual(a["confidence"], "VERIFIED", c["id"])
                self.assertGreaterEqual(len(a["facts"]),
                                        spec["min_facts"], c["id"])
                self.assertGreaterEqual(len(a["relations"]),
                                        spec["min_relations"], c["id"])
                self.assertTrue(spec["requires_evidence"])
                self.assertGreater(len(a["evidence"]), 0, c["id"])
                v = self.ve.verify_answer(a)
                self.assertEqual(v["overall"], "VERIFIED", c["id"])
                checked = []
                for claim in a["facts"]:
                    cv = self.ve.verify_claim(claim)
                    self.assertEqual(cv["status"], "VERIFIED",
                                     (c["id"], claim.get("fact_id")))
                    self._walk_fact_to_source(claim, checked)
                for rel in a["relations"]:
                    rv = self.ve.verify_relation_entry(rel)
                    self.assertEqual(rv["status"], "VERIFIED",
                                     (c["id"], rel.get("relation_id")))
                    self.assertGreater(len(rel["evidence_fact_ids"]),
                                       0, c["id"])
                    for fid in rel["evidence_fact_ids"]:
                        self.assertIn(fid, self.ve.cb.facts, c["id"])
                        f = self.ve.cb.facts[fid]
                        self.assertEqual(f["verification_status"],
                                         "VERIFIED", (c["id"], fid))
                        self._walk_fact_to_source(f, checked)
                self.assertGreater(len(checked), 0, c["id"])

    def test_frozen_anchors_still_resolve(self):
        for c in self.doc["cases"]:
            with self.subTest(case=c["id"]):
                anchor = c.get("anchor")
                if not anchor:
                    continue
                fid = anchor["fact_id"]
                f = self.ve.cb.facts[fid]
                self.assertEqual(f["verification_status"], "VERIFIED",
                                 c["id"])
                ev = self.store.evidence_by_id[f["evidence_id"]]
                self.assertEqual(f["evidence_id"], anchor["evidence_id"],
                                 c["id"])
                self.assertEqual(ev["source_file"], anchor["file"],
                                 c["id"])
                self.assertEqual(int(f["line_start"]),
                                 anchor["line_start"], c["id"])
                self.assertEqual(int(f["line_end"]),
                                 anchor["line_end"], c["id"])
                rel_id = c.get("anchor_relation")
                if rel_id:
                    stored = self.ve.cb.relations.get(rel_id)
                    self.assertIsNotNone(stored, c["id"])
                    self.assertEqual(stored["relation_type"],
                                     c["anchor_relation_type"], c["id"])

    def _injected_world(self, facts=None, relations=None, evidence=None,
                        files=None):
        base_ev = dict(self.store.evidence_by_id)
        base_files = dict(self.store.files_by_path)
        ev = base_ev if evidence is None else evidence
        fl = base_files if files is None else files
        store_ns = types.SimpleNamespace(evidence_by_id=ev,
                                         files_by_path=fl,
                                         files_by_id={})
        rel_map = (dict(self.ve.cb.relations)
                   if relations is None else relations)
        cb_ns = types.SimpleNamespace(
            store=store_ns,
            facts=(dict(self.ve.cb.facts) if facts is None else facts),
            relations=rel_map)
        return VerifyEngine(cb_ns, root=ZIG_ROOT)

    def _first_materials(self):
        a = self.k.ask("Кто вызывает foldConstantOp?")
        fact = copy.deepcopy(self.ve.cb.facts[a["facts"][0]["fact_id"]])
        rid = a["relations"][0]["relation_id"]
        rel = copy.deepcopy(self.ve.cb.relations[rid])
        return a, fact, rel

    def _assert_unverified_claim(self, ve, fact):
        v = ve.verify_claim({
            "claim": "corruption probe",
            "fact_id": fact["fact_id"],
            "file": fact["source_file"],
            "line_start": fact["line_start"],
            "line_end": fact["line_end"],
            "status": "VERIFIED"})
        self.assertEqual(v["status"], "UNVERIFIED")
        return v

    def test_adversarial_missing_evidence(self):
        _, fact, _ = self._first_materials()
        ev = dict(self.store.evidence_by_id)
        del ev[fact["evidence_id"]]
        ve = self._injected_world(evidence=ev)
        v = self._assert_unverified_claim(ve, fact)
        self.assertIn("not found", v["reason"])

    def test_adversarial_invalid_line_range(self):
        _, fact, _ = self._first_materials()
        ev = copy.deepcopy(self.store.evidence_by_id)
        entry = ev[fact["evidence_id"]]
        entry["line_start"] = 10 ** 6
        entry["line_end"] = 10 ** 6 + 5
        ve = self._injected_world(evidence=ev)
        v = self._assert_unverified_claim(ve, fact)
        self.assertIn("exceeds file length", v["reason"])

    def test_adversarial_evidence_range_outside_fact_claim(self):
        _, fact, _ = self._first_materials()
        ev = copy.deepcopy(self.store.evidence_by_id)
        entry = ev[fact["evidence_id"]]
        ls, le = entry["line_start"], entry["line_end"]
        span = max(le - ls + 1, 1)
        entry["line_start"] = ls + 1000
        entry["line_end"] = ls + 999 + span
        files = dict(self.store.files_by_path)
        ve = self._injected_world(evidence=ev, files=files)
        v = self._assert_unverified_claim(ve, fact)
        self.assertIn("differs from real source", v["reason"])

    def test_adversarial_tampered_evidence_text(self):
        _, fact, _ = self._first_materials()
        ev = copy.deepcopy(self.store.evidence_by_id)
        ev[fact["evidence_id"]]["text"] += "\n// tampered"
        ve = self._injected_world(evidence=ev)
        self._assert_unverified_claim(ve, fact)

    def test_adversarial_invalid_source_path(self):
        _, fact, _ = self._first_materials()
        ev = copy.deepcopy(self.store.evidence_by_id)
        entry = ev[fact["evidence_id"]]
        entry["source_file"] = os.path.join(ZIG_ROOT, "__nope__.zig")
        files = {p: e for p, e in self.store.files_by_path.items()
                 if p != fact["source_file"]}
        ve = self._injected_world(evidence=ev, files=files)
        v = self._assert_unverified_claim(ve, fact)
        self.assertNotEqual(v["status"], "VERIFIED")

    def test_adversarial_hash_mismatch(self):
        _, fact, _ = self._first_materials()
        ev = copy.deepcopy(self.store.evidence_by_id)
        ev[fact["evidence_id"]]["sha256"] = "0" * 64
        ve = self._injected_world(evidence=ev)
        self._assert_unverified_claim(ve, fact)

    def test_adversarial_relation_without_evidence(self):
        _, _, rel = self._first_materials()
        rel["evidence_fact_ids"] = []
        ve = self._injected_world(
            relations={rel["relation_id"]: rel})
        v = ve.verify_relation_entry({"relation_id":
                                      rel["relation_id"]})
        self.assertEqual(v["status"], "UNVERIFIED")
        self.assertIn("without evidence", v["reason"])

    def test_adversarial_missing_fact_for_relation(self):
        _, _, rel = self._first_materials()
        facts = {k: v for k, v in self.ve.cb.facts.items()
                 if k not in rel["evidence_fact_ids"]}
        ve = self._injected_world(
            relations={rel["relation_id"]: rel}, facts=facts)
        v = ve.verify_relation_entry({"relation_id":
                                      rel["relation_id"]})
        self.assertEqual(v["status"], "UNVERIFIED")

    def test_adversarial_ambiguous_entity_never_verified(self):
        q = self.doc["ambiguity_case"]["question"]
        r = self.k.route(q)
        self.assertEqual(r["status"],
                         self.doc["ambiguity_case"]
                         ["expected_route_status"])
        a = self.k.ask(q)
        self.assertEqual(a["facts"], [])
        self.assertEqual(a["relations"], [])
        self.assertEqual(a["evidence"], [])
        self.assertIsNone(a["direct_answer"])
        v = self.ve.verify_answer(a)
        self.assertNotEqual(v["overall"], "VERIFIED")
        self.assertEqual(v["overall"], "UNSUPPORTED")

    def test_relations_must_not_be_invented(self):
        artifact = self.ve.cb.relations
        for c in self.doc["cases"]:
            a = self.k.ask(c["question"])
            with self.subTest(case=c["id"]):
                for rel in a["relations"]:
                    rid = rel["relation_id"]
                    self.assertIn(rid, artifact, c["id"])
                    stored = artifact[rid]
                    for key, val in stored.items():
                        self.assertEqual(rel.get(key), val,
                                         (c["id"], key))


if __name__ == "__main__":
    unittest.main()
