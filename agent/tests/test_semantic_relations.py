import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from common import (
    CONCEPTS_PATH,
    FACTS_PATH,
    SEMANTIC_RELATIONS_PATH,
    load_json,
)
from relations import build_relations, relation_id_for, validate_relations
from source_store import SourceStore

MEMORY = Path(r"C:\B-Plus\agent\memory")
UPSTREAM = [
    "source_index.json",
    "source_evidence.json",
    "source_symbols.json",
    "source_relations.json",
    "facts.json",
    "concepts.json",
]

ENDPOINT_RULES = {
    "DEFINES": ("MODULE", None),
    "BELONGS_TO": (None, "MODULE"),
    "CONTAINS": ({"STRUCT", "UNION", "ENUM", "ERROR_SET"}, "FIELD"),
    "CALLS": ({"FUNCTION", "CONST", "VAR"}, {"FUNCTION", "CONST", "VAR"}),
    "IMPORTS": ("MODULE", "MODULE"),
    "DEPENDS_ON": ("MODULE", "MODULE"),
}
STRUCTURAL_TYPES = {"DEFINES", "BELONGS_TO", "CONTAINS", "IMPORTS", "DEPENDS_ON"}


def upstream_hashes():
    return {
        n: hashlib.sha256((MEMORY / n).read_bytes()).hexdigest()
        for n in UPSTREAM
    }


class TestSemanticRelations(unittest.TestCase):
    store = None
    facts_doc = None
    concepts_doc = None
    items = None
    hashes_before = None

    @classmethod
    def setUpClass(cls):
        cls.hashes_before = upstream_hashes()
        cls.store = SourceStore.load()
        assert not cls.store.validate(deep=True)
        cls.facts_doc = load_json(FACTS_PATH)
        cls.concepts_doc = load_json(CONCEPTS_PATH)
        cls.items, _ = build_relations(
            cls.store, cls.facts_doc, cls.concepts_doc
        )

    def test_load(self):
        doc = load_json(SEMANTIC_RELATIONS_PATH)
        self.assertEqual(doc["schema"], "semantic_relations")
        self.assertEqual(doc["version"], 1)
        self.assertEqual(doc["relation_count"], len(doc["items"]))
        self.assertEqual(doc["concept_count"], self.concepts_doc["concept_count"])

    def test_schema_fields(self):
        required = {
            "relation_id", "relation_type", "from_concept", "to_concept",
            "evidence_fact_ids", "verification_status",
        }
        for r in self.items[:1000]:
            self.assertTrue(required.issubset(r.keys()), r.get("relation_id"))

    def test_unique_ids(self):
        ids = [r["relation_id"] for r in self.items]
        self.assertEqual(len(ids), len(set(ids)))

    def test_ids_deterministic(self):
        for r in self.items:
            expected = relation_id_for(
                r["relation_type"], r["from_concept"], r["to_concept"]
            )
            self.assertEqual(expected, r["relation_id"])

    def test_endpoints_exist(self):
        cids = {c["concept_id"] for c in self.concepts_doc["items"]}
        bad = [
            r["relation_id"] for r in self.items
            if r["from_concept"] not in cids or r["to_concept"] not in cids
        ]
        self.assertEqual(bad, [])

    def test_evidence_facts_exist(self):
        fids = {f["fact_id"] for f in self.facts_doc["items"]}
        bad = [
            fid for r in self.items for fid in r["evidence_fact_ids"]
            if fid not in fids
        ]
        self.assertEqual(bad, [])

    def test_no_structural_self_loops(self):
        bad = [
            r["relation_id"] for r in self.items
            if r["from_concept"] == r["to_concept"]
            and r["relation_type"] in STRUCTURAL_TYPES
        ]
        self.assertEqual(bad, [])

    def test_recursion_represented(self):
        recursive = [
            r for r in self.items
            if r["from_concept"] == r["to_concept"]
            and r["relation_type"] == "CALLS"
        ]
        self.assertGreater(len(recursive), 0)

    def test_imports_present(self):
        imports = [r for r in self.items if r["relation_type"] == "IMPORTS"]
        self.assertGreater(len(imports), 100)

    def test_endpoint_constraints(self):
        cons = {c["concept_id"]: c for c in self.concepts_doc["items"]}
        violations = []
        for r in self.items:
            rule = ENDPOINT_RULES.get(r["relation_type"])
            if r["relation_type"] == "USES_TYPE":
                if cons[r["to_concept"]]["concept_type"] == "MODULE":
                    violations.append(r["relation_id"])
                continue
            if r["relation_type"] == "REFERENCES":
                ft = cons[r["from_concept"]]["concept_type"]
                tt = cons[r["to_concept"]]["concept_type"]
                if ft == "MODULE" or tt == "MODULE":
                    violations.append(r["relation_id"])
                continue
            ft_rule, tt_rule = rule
            ft = cons[r["from_concept"]]["concept_type"]
            tt = cons[r["to_concept"]]["concept_type"]
            ok = True
            if isinstance(ft_rule, set):
                ok = ok and ft in ft_rule
            elif ft_rule is not None:
                ok = ok and ft == ft_rule
            if isinstance(tt_rule, set):
                ok = ok and tt in tt_rule
            elif tt_rule is not None:
                ok = ok and tt == tt_rule
            if not ok:
                violations.append(r["relation_id"])
        self.assertEqual(violations, [])

    def test_verified_requires_evidence(self):
        bad = [
            r["relation_id"] for r in self.items
            if r["verification_status"] == "VERIFIED"
            and not r["evidence_fact_ids"]
        ]
        self.assertEqual(bad, [])

    def test_status_matches_worst_fact(self):
        facts = {f["fact_id"]: f for f in self.facts_doc["items"]}
        order = {"AMBIGUOUS": 0, "UNRESOLVED": 1, "VERIFIED": 2}
        for r in self.items:
            worst = min(
                (order[facts[fid]["verification_status"]]
                 for fid in r["evidence_fact_ids"]),
                default=2,
            )
            expected = [k for k, v in order.items() if v == worst][0]
            self.assertEqual(r["verification_status"], expected)

    def test_artifacts_read_only(self):
        current = upstream_hashes()
        for n in UPSTREAM:
            self.assertEqual(current[n], self.hashes_before[n], n)

    def test_rebuild_identical(self):
        a, _ = build_relations(self.store, self.facts_doc, self.concepts_doc)
        b, _ = build_relations(self.store, self.facts_doc, self.concepts_doc)
        ha = hashlib.sha256(json.dumps(a).encode()).hexdigest()
        hb = hashlib.sha256(json.dumps(b).encode()).hexdigest()
        self.assertEqual(ha, hb)
        loaded = load_json(SEMANTIC_RELATIONS_PATH)["items"]
        self.assertEqual(
            [r["relation_id"] for r in a],
            [r["relation_id"] for r in loaded],
        )

    def test_unknown_rejected(self):
        bogus = [{
            "relation_id": "SR-bogus",
            "relation_type": "DEPENDS_ON",
            "from_concept": "CN-bogus1",
            "to_concept": "CN-bogus2",
            "evidence_fact_ids": ["FA-bogus"],
            "verification_status": "VERIFIED",
        }]
        counters, _ = validate_relations(
            bogus, self.store, self.facts_doc, self.concepts_doc
        )
        self.assertGreater(counters["missing_from"], 0)
        self.assertGreater(counters["missing_facts"], 0)
        self.assertGreater(counters["invalid_ids"], 0)

    def test_depends_on_provenance_chain(self):
        facts = {f["fact_id"]: f for f in self.facts_doc["items"]}
        deps = [
            r for r in self.items
            if r["relation_type"] == "DEPENDS_ON"
            and len(r["evidence_fact_ids"]) >= 3
        ]
        self.assertGreater(len(deps), 50)
        checked = 0
        for r in deps[:20]:
            for fid in r["evidence_fact_ids"]:
                f = facts[fid]
                ev = self.store.get_evidence(f["evidence_id"])
                self.assertIsNotNone(ev)
                real = open(ev["source_file"], "rb").read().decode(
                    "utf-8", "ignore"
                ).splitlines()
                sl = "\n".join(real[ev["line_start"] - 1:ev["line_end"]])
                self.assertEqual(sl, ev["text"], fid)
                checked += 1
        self.assertGreater(checked, 60)


if __name__ == "__main__":
    unittest.main(verbosity=2)
