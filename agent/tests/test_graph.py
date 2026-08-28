import hashlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from common import (
    CONCEPTS_PATH,
    GRAPH_PATH,
    SEMANTIC_RELATIONS_PATH,
    load_json,
)
from graph import KnowledgeGraph, build_graph, validate_graph
from source_store import SourceStore

MEMORY = Path(r"C:\B-Plus\agent\memory")
UPSTREAM = [
    "source_index.json",
    "source_evidence.json",
    "source_symbols.json",
    "source_relations.json",
    "facts.json",
    "concepts.json",
    "semantic_relations.json",
]

PAIR_SECTIONS = [
    ("callees", "callers"),
    ("references", "referenced_by"),
    ("types_used", "type_users"),
    ("dependencies", "dependents"),
]


def upstream_hashes():
    return {
        n: hashlib.sha256((MEMORY / n).read_bytes()).hexdigest()
        for n in UPSTREAM
    }


class TestKnowledgeGraph(unittest.TestCase):
    store = None
    concepts_doc = None
    relations_doc = None
    doc = None
    kg = None
    hashes_before = None

    @classmethod
    def setUpClass(cls):
        cls.hashes_before = upstream_hashes()
        cls.store = SourceStore.load()
        assert not cls.store.validate(deep=True)
        cls.concepts_doc = load_json(CONCEPTS_PATH)
        cls.relations_doc = load_json(SEMANTIC_RELATIONS_PATH)
        cls.doc = load_json(GRAPH_PATH)
        cls.kg = KnowledgeGraph(cls.doc, cls.concepts_doc)

    def test_load(self):
        self.assertEqual(self.doc["schema"], "knowledge_graph")
        self.assertEqual(self.doc["version"], 1)
        self.assertEqual(
            self.doc["concept_count"], self.concepts_doc["concept_count"]
        )
        self.assertEqual(
            self.doc["relation_count"], self.relations_doc["relation_count"]
        )

    def test_required_sections(self):
        required = {
            "by_name", "by_name_lower", "file_module", "file_paths",
            "concept_module", "module_concepts", "concept_evidence",
            "callees", "callers", "references", "referenced_by",
            "types_used", "type_users", "dependencies", "dependents",
            "contains",
        }
        self.assertTrue(required.issubset(self.doc["indexes"].keys()))

    def test_pair_symmetry(self):
        idx = self.doc["indexes"]
        for fwd, rev in PAIR_SECTIONS:
            for k, arr in idx[fwd].items():
                for x in arr:
                    self.assertIn(k, idx[rev].get(x, []), (fwd, k, x))

    def test_adjacency_matches_relations(self):
        idx = self.doc["indexes"]
        for r in self.relations_doc["items"][:5000]:
            t = r["relation_type"]
            a, b = r["from_concept"], r["to_concept"]
            if t == "CALLS":
                self.assertIn(b, idx["callees"].get(a, []))
                self.assertIn(a, idx["callers"].get(b, []))
            elif t == "DEPENDS_ON":
                self.assertIn(b, idx["dependencies"].get(a, []))
                self.assertIn(a, idx["dependents"].get(b, []))

    def test_endpoints_exist(self):
        cids = {c["concept_id"] for c in self.concepts_doc["items"]}
        idx = self.doc["indexes"]
        bad = 0
        for sec in ("callers", "callees"):
            for k, arr in idx[sec].items():
                if k not in cids:
                    bad += 1
                bad += sum(1 for x in arr if x not in cids)
        self.assertEqual(bad, 0)

    def test_name_index_resolves(self):
        hits = self.kg.find_symbol("foldConstantOp")
        self.assertGreater(len(hits), 0)
        c = self.kg.get_concept(hits[0])
        self.assertEqual(c["canonical_name"], "foldConstantOp")
        ci = self.kg.find_symbol("FOLDCONSTANTOP", ignore_case=True)
        self.assertEqual(len(ci), len(hits))

    def test_module_membership_consistent(self):
        mods = {
            c["concept_id"]: c
            for c in self.concepts_doc["items"]
            if c["concept_type"] == "MODULE"
        }
        total_members = sum(
            len(v) for v in self.doc["indexes"]["module_concepts"].values()
        )
        non_modules = len(self.concepts_doc["items"]) - len(mods)
        self.assertEqual(total_members, non_modules)
        sample_mid = next(iter(mods))
        for cid in self.kg.module_concepts(sample_mid):
            self.assertEqual(self.kg.get_module(cid), sample_mid)

    def test_api_smoke(self):
        hits = self.kg.find_symbol("foldConstantOp")
        cid = hits[0]
        self.assertTrue(self.kg.exists(cid))
        self.assertFalse(self.kg.exists("CN-doesnotexist"))
        self.assertIsNotNone(self.kg.get_module(cid))
        self.assertIsInstance(self.kg.callers(cid), list)
        self.assertIsInstance(self.kg.callees(cid), list)
        mid = self.kg.module_of_file(
            next(iter(self.doc["indexes"]["file_module"]))
        )
        self.assertIsNotNone(mid)

    def test_evidence_chain_to_disk(self):
        facts = load_json(Path(r"C:\B-Plus\agent\memory\facts.json"))
        f2e = {f["fact_id"]: f["evidence_id"] for f in facts["items"]}
        checked = 0
        for c in self.concepts_doc["items"][:300]:
            for eid in self.kg.evidence_ids(c["concept_id"]):
                if checked >= 40:
                    break
                ev = self.store.get_evidence(eid)
                real = open(ev["source_file"], "rb").read().decode(
                    "utf-8", "ignore"
                ).splitlines()
                sl = "\n".join(real[ev["line_start"] - 1:ev["line_end"]])
                self.assertEqual(sl, ev["text"], eid)
                checked += 1
        self.assertEqual(checked, 40)

    def test_artifacts_read_only(self):
        current = upstream_hashes()
        for n in UPSTREAM:
            self.assertEqual(current[n], self.hashes_before[n], n)

    def test_rebuild_identical(self):
        facts = load_json(Path(r"C:\B-Plus\agent\memory\facts.json"))
        a = build_graph(
            facts, self.concepts_doc, self.relations_doc,
            files=self.store.files_by_path,
        )
        b = build_graph(
            facts, self.concepts_doc, self.relations_doc,
            files=self.store.files_by_path,
        )
        self.assertEqual(a["indexes"], b["indexes"])
        loaded = self.doc["indexes"]
        self.assertEqual(
            sorted(a["indexes"].keys()), sorted(loaded.keys())
        )
        for k in a["indexes"]:
            self.assertEqual(a["indexes"][k], loaded[k], k)

    def test_validation_rejects_bogus(self):
        bogus = {
            "indexes": dict(self.doc["indexes"]),
        }
        bogus["indexes"]["callers"] = dict(bogus["indexes"]["callers"])
        bogus["indexes"]["callers"]["CN-bogus"] = ["CN-alsobogus"]
        counters, _ = validate_graph(
            bogus, self.store, self.concepts_doc, self.relations_doc
        )
        self.assertGreater(counters["unknown_ids"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
