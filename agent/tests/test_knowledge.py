import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from knowledge import Knowledge


class TestKnowledgeAsk(unittest.TestCase):
    k = None

    @classmethod
    def setUpClass(cls):
        cls.k = Knowledge.load()

    def test_ask_callers_end_to_end(self):
        a = self.k.ask("Кто вызывает foldConstantOp?")
        self.assertEqual(a["schema"], "knowledge_answer")
        self.assertEqual(a["status"], "RESOLVED")
        self.assertEqual(a["routing"]["intent"], "CALLERS")
        self.assertEqual(a["confidence"], "VERIFIED")
        self.assertIsNotNone(a["direct_answer"])
        self.assertGreater(len(a["evidence"]), 0)
        self.assertGreater(len(a["facts"]), 0)

    def test_ask_definition(self):
        a = self.k.ask("Где определён foldConstantOp?")
        self.assertEqual(a["status"], "RESOLVED")
        self.assertIn("is defined at", a["direct_answer"])

    def test_ask_ambiguous_passthrough(self):
        a = self.k.ask("Покажи emit")
        self.assertEqual(a["status"], "AMBIGUOUS")
        self.assertIsNone(a["direct_answer"])
        self.assertEqual(a["facts"], [])
        self.assertGreaterEqual(len(a["entities"]), 2)
        self.assertEqual(a["routing"]["status"], "AMBIGUOUS_ENTITY")

    def test_ask_not_found(self):
        a = self.k.ask("Кто вызывает ghost_xyz_99999?")
        self.assertEqual(a["status"], "NOT_FOUND")
        self.assertIsNone(a["direct_answer"])
        self.assertEqual(a["confidence"], "UNSUPPORTED")

    def test_ask_unknown_intent(self):
        a = self.k.ask("???")
        self.assertEqual(a["status"], "UNKNOWN_INTENT")
        self.assertIsNone(a["direct_answer"])

    def test_ask_dependencies_full_chain(self):
        a = self.k.ask("От чего зависит x64gen.zig?")
        self.assertEqual(a["status"], "RESOLVED")
        self.assertGreaterEqual(len(a["entities"]), 1)
        for r in a["relations"]:
            self.assertTrue(r.get("relation_id"))
            self.assertIn("evidence_fact_ids", r)
            self.assertTrue(r["evidence_fact_ids"])

    def test_json_safe_envelope(self):
        a = self.k.ask("Кто вызывает `emit`?")
        json.dumps(a)

    def test_determinism(self):
        q = "Где определён foldConstantOp?"
        a1 = self.k.ask(q)
        a2 = self.k.ask(q)
        self.assertEqual(json.dumps(a1, sort_keys=True),
                         json.dumps(a2, sort_keys=True))


if __name__ == "__main__":
    unittest.main(verbosity=2)
