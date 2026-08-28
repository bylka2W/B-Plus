"""STEP 2 verification: Evidence -> 100% for applicable (source-backed) symbols.

TF rules:
 - every real symbol with a source location gets provenance from real .zig only
 - evidence has file_id, line_start, line_end, text, sha256, deterministic id
 - no synthetic facts
 - integrity: file exists, range valid, text+hash match, deterministic id
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
AGENT_BPLUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, AGENT_BPLUS)

from core.agent_runtime import KnowledgeQuery, SourceIndex
from core.symbol_graph import SymbolGraph
from core.knowledge_web import KnowledgeWebEngine

ROOT = r"C:\B-Plus\zig"
MEMORY = r"C:\B-Plus\agent\memory"
TOP = {"function", "struct", "enum", "union", "const", "module", "test", "var", "field", "symbol"}


class Step2EvidenceTest(unittest.TestCase):
    def _build(self):
        si = SourceIndex([ROOT]); si.scan()
        kq = KnowledgeQuery(MEMORY)
        sg = SymbolGraph(si, kq); sg.build()
        web = KnowledgeWebEngine(si, sg, kq); web.build()
        return web, si

    def test_applicable_symbols_have_evidence(self):
        web, _ = self._build()
        active = [n for n in web._active_nodes().values() if n.kind in TOP]
        applicable = [n for n in active if n.line_start >= 1]
        self.assertTrue(applicable, "no applicable symbols found")
        missing = [n for n in applicable if not n.evidence_ids]
        self.assertEqual(missing, [],
                         f"{len(missing)} applicable symbols lack evidence")

    def test_source_evidence_integrity(self):
        web, si = self._build()
        self.assertTrue(web._source_evidence, "no source evidence generated")
        for evid in list(web._source_evidence.keys()):
            ok, reason = web.is_source_evidence_valid(evid)
            self.assertTrue(ok, f"evidence {evid} invalid: {reason}")
        # unknown id must be reported invalid
        ok, reason = web.is_source_evidence_valid("EVID-deadbeef00000000")
        self.assertFalse(ok)
        self.assertEqual(reason, "unknown_evidence_id")

    def test_evidence_ids_deterministic(self):
        web1, _ = self._build()
        web2, _ = self._build()
        self.assertEqual(sorted(web1._source_evidence.keys()),
                         sorted(web2._source_evidence.keys()),
                         "source evidence ids not deterministic across rebuilds")


if __name__ == "__main__":
    unittest.main(verbosity=2)
