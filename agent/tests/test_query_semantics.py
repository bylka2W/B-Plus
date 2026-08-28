import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "engine"))

from answer import ANSWER_TYPES
from knowledge import Knowledge
from verify import VerifyEngine

CASES_PATH = os.path.join(os.path.dirname(HERE),
                          "golden", "query_semantics.json")


class TestQuerySemantics(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.k = Knowledge.load()
        cls.ve = VerifyEngine.load()
        with open(CASES_PATH, encoding="utf-8") as f:
            doc = json.load(f)
        cls.doc = doc
        cls.cases = doc["cases"]

    def test_contract_schema_frozen(self):
        self.assertEqual(self.doc["schema"], "query_semantics")
        self.assertEqual(self.doc["version"], 1)
        self.assertEqual(set(self.doc["vocabulary"]), set(ANSWER_TYPES))
        for intent, spec in self.doc["vocabulary"].items():
            self.assertEqual(spec["answer_type"], ANSWER_TYPES[intent])

    def _route_expectations(self, c):
        r = self.k.route(c["question"])
        self.assertEqual(r["intent"], c["intent"], c["id"])
        if "expected_entity" in c:
            self.assertEqual(r["entity"], c["expected_entity"], c["id"])
        return r

    def _ask_no_material_claims(self, a, c):
        self.assertEqual(a["facts"], [], c["id"])
        self.assertEqual(a["relations"], [], c["id"])
        self.assertEqual(a["evidence"], [], c["id"])

    def test_semantic_matrix(self):
        for c in self.cases:
            with self.subTest(case=c["id"]):
                klass = c["class"]
                r = self._route_expectations(c)
                if klass == "positive" or (klass == "quoted"
                                           and "candidates" not in c):
                    self.assertEqual(r["status"], "ROUTED", c["id"])
                    a = self.k.ask(c["question"])
                    self.assertEqual(a["status"], "RESOLVED", c["id"])
                    self.assertEqual(a["answer_type"],
                                     ANSWER_TYPES[c["intent"]], c["id"])
                    self.assertGreater(len(a["facts"])
                                       + len(a["relations"]), 0, c["id"])
                    v = self.ve.verify_answer(a)
                    self.assertEqual(v["overall"], "VERIFIED", c["id"])
                elif klass in ("negative",):
                    self.assertEqual(r["status"], "ENTITY_NOT_FOUND",
                                     c["id"])
                    a = self.k.ask(c["question"])
                    self.assertEqual(a["status"], "NOT_FOUND", c["id"])
                    self._ask_no_material_claims(a, c)
                elif klass in ("ambiguous",) or (
                        klass == "quoted" and "candidates" in c):
                    self.assertEqual(r["status"], "AMBIGUOUS_ENTITY",
                                     c["id"])
                    self.assertEqual(len(r["candidates"]),
                                     c["candidates"], c["id"])
                    a = self.k.ask(c["question"])
                    self.assertEqual(a["status"], "AMBIGUOUS", c["id"])
                    self._ask_no_material_claims(a, c)
                    self.assertIsNone(a["direct_answer"], c["id"])
                elif klass == "unknown":
                    self.assertIsNone(r["intent"], c["id"])
                    self.assertEqual(r["status"], "UNKNOWN_INTENT",
                                     c["id"])
                    a = self.k.ask(c["question"])
                    self.assertEqual(a["status"], "UNKNOWN_INTENT",
                                     c["id"])
                    self._ask_no_material_claims(a, c)
                else:
                    self.fail(f"unknown case class {klass}")

    def test_vocabulary_coverage_both_languages(self):
        seen = {}
        for c in self.cases:
            if c["class"] != "positive":
                continue
            key = (c["intent"], c["language"])
            seen.setdefault(key, 0)
            seen[key] += 1
        for intent in self.doc["vocabulary"]:
            for lang in ("RU", "EN"):
                self.assertGreaterEqual(
                    seen.get((intent, lang), 0), 1,
                    f"{intent} has no {lang} positive case")

    def test_ambiguity_stops_claim_generation(self):
        inv = self.doc["ambiguity_invariant"]
        for c in self.cases:
            if c["class"] == "ambiguous":
                a = self.k.ask(c["question"])
                self.assertEqual(a["facts"], inv["facts"], c["id"])
                self.assertEqual(a["relations"], inv["relations"],
                                 c["id"])
                self.assertEqual(a["evidence"], inv["evidence"], c["id"])
                self.assertIsNone(a["direct_answer"], c["id"])
                v = self.ve.verify_answer(a)
                self.assertEqual(v["overall"], "UNSUPPORTED", c["id"])

    def test_not_found_keeps_intent(self):
        for c in self.cases:
            if c["class"] == "negative":
                r = self.k.route(c["question"])
                self.assertIsNotNone(r["intent"], c["id"])
                self.assertNotEqual(r["status"], "UNKNOWN_INTENT",
                                    c["id"])

    def test_same_intent_across_phrasings_is_stable(self):
        groups = {}
        for c in self.cases:
            if c["class"] != "positive":
                continue
            groups.setdefault(c["intent"], []).append(c)
        for intent, cs in groups.items():
            outcomes = set()
            for c in cs:
                r = self.k.route(c["question"])
                self.assertEqual((r["intent"], r["entity"]),
                                 (intent, c["expected_entity"]),
                                 f"{intent}/{c['id']} not deterministic")
                a = self.k.ask(c["question"])
                outcomes.add(
                    (a["status"], a["answer_type"],
                     len(a["facts"]) + len(a["relations"])))
            self.assertEqual(len(outcomes), 1,
                             f"{intent} yields different answer "
                             f"outcomes across phrasings: {outcomes}")


if __name__ == "__main__":
    unittest.main()
