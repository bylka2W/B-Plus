import hashlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from common import GRAPH_PATH, load_json
from graph import KnowledgeGraph
from search import AMBIGUOUS, NOT_FOUND, RESOLVED, Search

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


class TestSearch(unittest.TestCase):
    kg = None
    s = None
    hashes_before = None
    some_struct = None

    @classmethod
    def setUpClass(cls):
        cls.hashes_before = upstream_hashes()
        cls.kg = KnowledgeGraph.load()
        cls.s = Search(cls.kg)
        contains = cls.kg.idx["contains"]
        for k, v in contains.items():
            if len(v) >= 3:
                cls.some_struct = (k, v)
                break

    def test_load_stats(self):
        self.assertEqual(len(self.s.concepts), 9636)
        self.assertGreater(len(self.s.by_name), 4000)
        self.assertGreater(len(self.s._modules), 400)

    def test_find_symbol_exact(self):
        r = self.s.find_symbol("foldConstantOp")
        self.assertEqual(r["status"], RESOLVED)
        self.assertEqual(r["count"], 1)
        node = r["items"][0]
        self.assertEqual(node["concept_type"], "FUNCTION")
        self.assertIsNotNone(node["module_id"])

    def test_find_symbol_not_found(self):
        r = self.s.find_symbol("definitely_not_a_real_symbol_xyz")
        self.assertEqual(r["status"], NOT_FOUND)
        self.assertEqual(r["items"], [])

    def test_find_symbol_ambiguous(self):
        ambiguous_name = next(
            name
            for name, ids in self.s.by_name.items()
            if len(ids) > 1
        )
        r = self.s.find_symbol(ambiguous_name)
        self.assertEqual(r["status"], AMBIGUOUS)
        self.assertGreaterEqual(r["count"], 2)

    def test_find_symbols_prefix(self):
        r = self.s.find_symbols("emit", limit=1000)
        self.assertEqual(r["status"], RESOLVED)
        self.assertFalse(r["truncated"])
        names = [i["name"] for i in r["items"]]
        self.assertTrue(all(n.lower().startswith("emit") for n in names))
        self.assertEqual(names, sorted(names, key=str.lower))

    def test_find_symbols_limit_and_truncated_flag(self):
        r = self.s.find_symbols("e", limit=5)
        self.assertEqual(r["count"], 5)
        self.assertTrue(r["truncated"])

    def test_find_module_by_basename(self):
        r = self.s.find_module("x64enc.zig")
        self.assertIn(
            r["status"], (RESOLVED, AMBIGUOUS), "x64enc.zig expected in db"
        )
        mods = [c for c in self.concepts_doc_modules() if c.endswith("x64enc.zig")]
        self.assertGreater(len(mods), 0)

    def concepts_doc_modules(self):
        return [
            c["canonical_name"]
            for c in load_json(MEMORY / "concepts.json")["items"]
            if c["concept_type"] == "MODULE"
        ]

    def test_find_file_roundtrip(self):
        path = next(iter(self.s.file_paths))
        r = self.s.find_file(path)
        self.assertEqual(r["status"], RESOLVED)
        mid = self.s.file_paths[path]
        self.assertEqual(r["items"][0]["concept_id"], mid)

    def test_find_callers_matches_graph(self):
        callers_idx = self.kg.idx["callers"]
        cid = next(iter(callers_idx))
        r = self.s.find_callers(cid)
        got = {i["concept_id"] for i in r["items"]}
        self.assertEqual(got, set(callers_idx[cid]))

    def test_find_callees_matches_graph(self):
        callees_idx = self.kg.idx["callees"]
        cid = next(iter(callees_idx))
        r = self.s.find_callees(cid)
        got = {i["concept_id"] for i in r["items"]}
        self.assertEqual(got, set(callees_idx[cid]))

    def test_find_dependencies_and_dependents(self):
        deps_idx = self.kg.idx["dependencies"]
        mid = max(deps_idx, key=lambda k: len(deps_idx[k]))
        r = self.s.find_dependencies(mid)
        got = {i["concept_id"] for i in r["items"]}
        self.assertEqual(got, set(deps_idx[mid]))
        back = self.s.find_dependents(mid)
        self.assertEqual(
            {i["concept_id"] for i in back["items"]},
            set(self.kg.idx["dependents"].get(mid, [])),
        )

    def test_types_used_and_users_symmetry(self):
        tu = self.kg.idx["types_used"]
        cid = next(iter(tu))
        r = self.s.find_types_used(cid)
        self.assertEqual(
            {i["concept_id"] for i in r["items"]}, set(tu[cid])
        )

    def test_contains_returns_fields(self):
        self.assertIsNotNone(self.some_struct)
        cid, kids = self.some_struct
        r = self.s.find_contains(cid)
        self.assertEqual({i["concept_id"] for i in r["items"]}, set(kids))
        self.assertTrue(
            all(i["concept_type"] == "FIELD" for i in r["items"])
        )

    def test_deterministic_answers(self):
        s2 = Search(KnowledgeGraph.load())
        probes = ["foldConstantOp", "emit", next(iter(self.s.file_paths))]
        for p in probes:
            a = self.s.find_symbol(p) if not p.startswith("C:") else self.s.find_file(p)
            b = s2.find_symbol(p) if not p.startswith("C:") else s2.find_file(p)
            self.assertEqual(a, b)

    def test_artifacts_read_only(self):
        current = upstream_hashes()
        for n in UPSTREAM:
            self.assertEqual(current[n], self.hashes_before[n], n)


if __name__ == "__main__":
    unittest.main(verbosity=2)
