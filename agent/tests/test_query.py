import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from query import SUPPORTED_INTENTS, QueryEngine

RESOLVED = "RESOLVED"
AMBIGUOUS = "AMBIGUOUS"
NOT_FOUND = "NOT_FOUND"


class TestQueryEngine(unittest.TestCase):
    qe = None

    @classmethod
    def setUpClass(cls):
        cls.qe = QueryEngine.load()

    def test_supported_intents_fixed(self):
        self.assertEqual(
            SUPPORTED_INTENTS,
            {
                "CALLERS", "CALLEES", "REFERENCES", "DEPENDENCIES",
                "DEPENDENTS", "USES_TYPE", "TYPE_USERS", "DEFINITION",
                "MODULE", "FILE", "CONTAINS",
            },
        )

    def test_unknown_intent_rejected(self):
        r = self.qe.query("WHO_IS_BEST", "foldConstantOp")
        self.assertEqual(r["status"], "UNKNOWN_INTENT")
        self.assertEqual(r["items"], [])

    def test_result_schema(self):
        r = self.qe.query("CALLERS", "emit")
        for key in (
            "schema", "version", "intent", "entity", "status", "targets",
            "items", "count",
        ):
            self.assertIn(key, r)
        self.assertEqual(r["schema"], "query_result")
        self.assertEqual(r["version"], 1)
        self.assertEqual(r["count"], len(r["items"]))

    def test_definition(self):
        r = self.qe.query("DEFINITION", "foldConstantOp")
        self.assertEqual(r["status"], RESOLVED)
        d = r["items"][0]
        self.assertTrue(d["file"].endswith(".zig"))
        self.assertGreater(d["line_start"], 0)
        self.assertLessEqual(d["line_start"], d["line_end"])
        self.assertTrue(d["evidence_id"].startswith("EV-"))

    def test_definition_not_found(self):
        r = self.qe.query("DEFINITION", "no_such_symbol_qqz")
        self.assertEqual(r["status"], NOT_FOUND)
        self.assertEqual(r["items"], [])

    def test_callers_resolved(self):
        callers_idx = self.qe.search.kg.idx["callers"]
        cid = max(callers_idx, key=lambda k: len(callers_idx[k]))
        name = self.qe.search.concepts[cid]["canonical_name"]
        r = self.qe.query("CALLERS", cid)
        self.assertEqual(r["status"], RESOLVED)
        self.assertEqual(
            {i["concept_id"] for i in r["items"]}, set(callers_idx[cid])
        )
        r2 = self.qe.query("CALLERS", name)
        self.assertGreaterEqual(r2["count"], 1)

    def test_callees_and_references(self):
        callees_idx = self.qe.search.kg.idx["callees"]
        cid = next(iter(callees_idx))
        r = self.qe.query("CALLEES", cid)
        self.assertEqual(
            {i["concept_id"] for i in r["items"]}, set(callees_idx[cid])
        )
        refs_idx = self.qe.search.kg.idx["references"]
        if refs_idx:
            rid = next(iter(refs_idx))
            r2 = self.qe.query("REFERENCES", rid)
            self.assertEqual(
                {i["concept_id"] for i in r2["items"]},
                set(refs_idx[rid]),
            )

    def test_type_intents(self):
        tu = self.qe.search.kg.idx["type_users"]
        tcid = max(tu, key=lambda k: len(tu[k]))
        r = self.qe.query("TYPE_USERS", tcid)
        self.assertEqual({i["concept_id"] for i in r["items"]}, set(tu[tcid]))
        users = next(iter(tu.values()))
        uid = users[0]
        r2 = self.qe.query("USES_TYPE", uid)
        self.assertGreaterEqual(r2["count"], 1)

    def test_contains_intent(self):
        contains = self.qe.search.kg.idx["contains"]
        cid = next(iter(contains))
        r = self.qe.query("CONTAINS", cid)
        self.assertEqual(
            {i["concept_id"] for i in r["items"]}, set(contains[cid])
        )

    def test_module_and_dependencies(self):
        deps_idx = self.qe.search.kg.idx["dependencies"]
        mid = max(deps_idx, key=lambda k: len(deps_idx[k]))
        mname = self.qe.search.concepts[mid]["canonical_name"]
        r_mod = self.qe.query("MODULE", mname)
        self.assertIn(r_mod["status"], (RESOLVED, AMBIGUOUS))
        r_dep = self.qe.query("DEPENDENCIES", mid)
        self.assertEqual(
            {i["concept_id"] for i in r_dep["items"]}, set(deps_idx[mid])
        )
        r_back = self.qe.query("DEPENDENTS", mid)
        self.assertEqual(
            {i["concept_id"] for i in r_back["items"]},
            set(self.qe.search.kg.idx["dependents"].get(mid, [])),
        )

    def test_file_intent(self):
        path = next(iter(self.qe.search.file_paths))
        r = self.qe.query("FILE", path)
        self.assertEqual(r["status"], RESOLVED)

    def test_entity_not_found_uniform(self):
        for intent in (
            "CALLERS", "CALLEES", "REFERENCES", "USES_TYPE", "TYPE_USERS",
            "CONTAINS", "DEPENDENCIES", "DEPENDENTS", "DEFINITION",
            "MODULE", "FILE",
        ):
            r = self.qe.query(intent, "__ghost_entity__")
            self.assertEqual(r["status"], NOT_FOUND, intent)
            self.assertEqual(r["items"], [], intent)

    def test_deterministic_results(self):
        a = self.qe.query("CALLERS", "emit")
        b = self.qe.query("CALLERS", "emit")
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main(verbosity=2)
