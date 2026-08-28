import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from agent_tools import AgentTools

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


class TestAgentTools(unittest.TestCase):
    t = None
    hashes_before = None

    @classmethod
    def setUpClass(cls):
        cls.hashes_before = upstream_hashes()
        cls.t = AgentTools.load()

    def test_registry(self):
        expected = {
            "search_symbol", "search_symbols", "find_callers", "find_callees",
            "find_references", "find_type_users", "find_dependencies",
            "find_dependents", "inspect_symbol", "inspect_module",
            "get_evidence", "trace_dependency",
        }
        for name in expected:
            self.assertTrue(
                getattr(getattr(self.t, name), "_is_tool", False), name
            )

    def test_unknown_tool(self):
        r = self.t.call("delete_everything")
        self.assertEqual(r["status"], "UNKNOWN_TOOL")
        self.assertIn("error", r)

    def test_search_symbol_tool(self):
        r = self.t.call("search_symbol", name="foldConstantOp")
        self.assertEqual(r["status"], "RESOLVED")
        self.assertEqual(r["data"]["count"], 1)
        self.assertIn("provenance", r)
        json.dumps(r)

    def test_inspect_symbol_pack(self):
        r = self.t.call("inspect_symbol", symbol="foldConstantOp")
        self.assertEqual(r["status"], "RESOLVED")
        pack = r["data"]
        self.assertGreater(len(pack["claims"]), 0)
        self.assertEqual(pack["confidence"], "VERIFIED")
        self.assertTrue(pack["evidence"][0]["file"].endswith(".zig"))
        json.dumps(r)

    def test_find_tools_json_safe(self):
        for tool, argname in (
            ("find_callers", "symbol"), ("find_callees", "symbol"),
            ("find_references", "symbol"), ("find_type_users", "type_ref"),
            ("find_dependencies", "module"), ("find_dependents", "module"),
        ):
            r = self.t.call(tool, **{argname: "__ghost__"})
            self.assertEqual(r["status"], "NOT_FOUND", tool)
            json.dumps(r)

    def test_get_evidence_chunks_on_disk(self):
        r = self.t.call("get_evidence", concept="foldConstantOp")
        self.assertEqual(r["status"], "RESOLVED")
        checked = 0
        for ev in r["data"][:3]:
            real = open(ev["file"], "rb").read().decode(
                "utf-8", "ignore"
            ).splitlines()
            sl = "\n".join(real[ev["line_start"] - 1:ev["line_end"]])
            self.assertEqual(sl, ev["text"])
            checked += 1
        self.assertGreater(checked, 0)

    def test_trace_dependency_one_hop(self):
        deps_idx = self.t.search.kg.idx["dependencies"]
        start = max(deps_idx, key=lambda k: len(deps_idx[k]))
        goal = sorted(deps_idx[start])[0]
        a = self.t.search.concepts[start]["canonical_name"]
        b = self.t.search.concepts[goal]["canonical_name"]
        r = self.t.call("trace_dependency", from_module=a, to_module=b)
        self.assertEqual(r["status"], "RESOLVED")
        chain = r["data"][0]
        self.assertEqual(chain["hops"], 1)
        self.assertEqual(chain["modules"][0]["concept_id"], start)
        self.assertEqual(chain["modules"][-1]["concept_id"], goal)

    def test_trace_unreachable_not_found(self):
        mods = [
            cid
            for cid, c in self.t.search.concepts.items()
            if c["concept_type"] == "MODULE"
        ]
        iso = None
        dep_keys = set(self.t.search.kg.idx["dependencies"].keys())
        dep_vals = {
            v for arr in self.t.search.kg.idx["dependencies"].values()
            for v in arr
        }
        for m in mods:
            if m not in dep_keys and m not in dep_vals:
                iso = m
                break
        if iso is None:
            self.skipTest("no isolated module in graph")
        name = self.t.search.concepts[iso]["canonical_name"]
        r = self.t.call(
            "trace_dependency", from_module=name,
            to_module=next(iter(dep_keys)),
        )
        self.assertIn(r["status"], ("NOT_FOUND",))

    def test_deterministic_envelopes(self):
        a = self.t.call("search_symbol", name="emit")
        b = self.t.call("search_symbol", name="emit")
        self.assertEqual(json.dumps(a, sort_keys=True),
                         json.dumps(b, sort_keys=True))

    def test_artifacts_read_only(self):
        current = upstream_hashes()
        for n in UPSTREAM:
            self.assertEqual(current[n], self.hashes_before[n], n)


if __name__ == "__main__":
    unittest.main(verbosity=2)
