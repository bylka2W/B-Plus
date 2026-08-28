import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from router import Router

ZIG_ROOT = Path(r"C:\B-Plus\zig")

TABLE = [
    ("Кто вызывает foldConstantOp?", "CALLERS", "foldConstantOp"),
    ("Что вызывает foldConstantOp?", "CALLEES", "foldConstantOp"),
    ("Где определён foldConstantOp?", "DEFINITION", "foldConstantOp"),
    ("Где находится manager.zig?", "DEFINITION", "manager.zig"),
    ("От чего зависит x64gen.zig?", "DEPENDENCIES", "x64gen.zig"),
    ("Кто зависит от x64gen.zig?", "DEPENDENTS", "x64gen.zig"),
    ("Какие типы использует foldConstantOp?",
     "USES_TYPE", "foldConstantOp"),
    ("Кто использует тип Token?", "TYPE_USERS", "Token"),
    ("Что содержит ConstantValue?", "CONTAINS", "ConstantValue"),
]


def zig_tree_digest():
    h = hashlib.sha256()
    for p in sorted(ZIG_ROOT.rglob("*")):
        if p.is_file():
            h.update(str(p).encode("utf-8"))
            h.update(p.read_bytes())
    return h.hexdigest()


class TestRouter(unittest.TestCase):
    r = None
    zig_before = None

    @classmethod
    def setUpClass(cls):
        cls.r = Router.load()
        cls.zig_before = zig_tree_digest()

    @classmethod
    def tearDownClass(cls):
        if cls.zig_before is not None:
            assert cls.zig_before == zig_tree_digest(), \
                "B+ source tree changed during tests"

    def test_intent_table_ru_en(self):
        for q, want_intent, want_ent in TABLE:
            d = self.r.route(q)
            self.assertEqual(
                d["intent"], want_intent,
                f"{q!r}: got {d['intent']}, want {want_intent}")
            self.assertEqual(d["entity"], want_ent,
                             f"entity mismatch for {q!r}")

    def test_routed_statuses(self):
        for q, _, _ in TABLE:
            d = self.r.route(q)
            if d["entity"] in ("Token", "ConstantValue"):
                continue
            self.assertIn(d["status"],
                          ("ROUTED", "AMBIGUOUS_ENTITY",
                           "ENTITY_NOT_FOUND"), q)

    def test_english_variants(self):
        cases = [
            ("who calls foldConstantOp?", "CALLERS"),
            ("What does foldConstantOp call?", "CALLEES"),
            ("What does x64enc depend on?", "DEPENDENCIES"),
            ("where is emit defined", "DEFINITION"),
        ]
        for q, want in cases:
            d = self.r.route(q)
            self.assertEqual(d["intent"], want, q)

    def test_backtick_entity_wins(self):
        d = self.r.route("Кто вызывает `emit`?")
        self.assertEqual(d["intent"], "CALLERS")
        self.assertEqual(d["entity"], "emit")
        self.assertEqual(d["status"], "AMBIGUOUS_ENTITY")
        self.assertGreaterEqual(len(d["candidates"]), 2)

    def test_ambiguous_guard_no_selection(self):
        d = self.r.route("Покажи emit")
        self.assertEqual(d["status"], "AMBIGUOUS_ENTITY")
        self.assertGreaterEqual(len(d["candidates"]), 2)
        names = {c["name"] for c in d["candidates"]}
        self.assertGreaterEqual(len(names), 1)
        self.assertNotIn("chosen_concept_id", d,
                         "router must not silently pick a candidate")

    def test_not_found(self):
        d = self.r.route("Кто вызывает ghost_xyz_99999?")
        self.assertEqual(d["status"], "ENTITY_NOT_FOUND")
        self.assertEqual(d["candidates"], [])

    def test_unknown_intent_never_guesses(self):
        for q in ["???", "", "   ", "!!!"]:
            d = self.r.route(q)
            self.assertEqual(d["status"], "UNKNOWN_INTENT", repr(q))
            self.assertIsNone(d["intent"])

    def test_gibberish_with_noun_is_not_found_not_invented(self):
        d = self.r.route("абракадабра симулякрум")
        self.assertIn(d["status"],
                      ("ENTITY_NOT_FOUND", "UNKNOWN_INTENT"))
        if d["status"] == "ENTITY_NOT_FOUND":
            self.assertEqual(d["candidates"], [])

    def test_decision_json_safe_and_schema(self):
        d = self.r.route("Кто вызывает `emit`?")
        self.assertEqual(d["schema"], "route_decision")
        self.assertEqual(d["version"], 1)
        json.dumps(d)

    def test_determinism(self):
        a = self.r.route("Кто зависит от x64gen.zig?")
        b = self.r.route("Кто зависит от x64gen.zig?")
        self.assertEqual(json.dumps(a, sort_keys=True),
                         json.dumps(b, sort_keys=True))

    def test_dependencies_route_resolves_module(self):
        d = self.r.route("От чего зависит x64gen.zig?")
        self.assertEqual(d["status"], "ROUTED")
        self.assertEqual(d["intent"], "DEPENDENCIES")


if __name__ == "__main__":
    unittest.main(verbosity=2)
