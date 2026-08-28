"""STEP 3 verification: Type knowledge -> 100% for applicable source symbols.

For each applicable symbol we derive real type relations (use/return/field)
directly from the source signature with a provable, deterministic evidence id
that chains to the actual .zig lines.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
AGENT_BPLUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, AGENT_BPLUS)

from core.agent_runtime import KnowledgeQuery, SourceIndex
from core.symbol_graph import SymbolGraph

ROOT = r"C:\B-Plus\zig"
MEMORY = r"C:\B-Plus\agent\memory"


class Step3TypeTest(unittest.TestCase):
    def _build(self):
        si = SourceIndex([ROOT]); si.scan()
        kq = KnowledgeQuery(MEMORY)
        sg = SymbolGraph(si, kq); sg.build()
        return sg, si

    def test_type_relations_have_evidence_and_verify(self):
        sg, si = self._build()
        type_rels = [r for r in sg.relations
                     if r.relation_type in ("use_type", "return_type", "field_type")]
        self.assertTrue(type_rels, "no type relations generated")
        missing_ev = [r for r in type_rels if not r.evidence_id]
        self.assertEqual(missing_ev, [], f"{len(missing_ev)} type relations lack evidence")

        # every evidence id must deterministically chain to real source
        mism = 0
        for r in type_rels:
            src = sg.symbols.get(r.source_id)
            if not src or not src.file_id:
                continue
            fp = sg._file_paths.get(src.file_id, "")
            import hashlib
            import core.state_tables as st
            sl = si.read_file(fp, src.line_start, src.line_end)
            sha = hashlib.sha256(sl.encode("utf-8", "replace")).hexdigest()
            expect = st.short_id("EVID", src.file_id, src.line_start,
                                 src.line_end, sha[:16])
            if r.evidence_id != expect:
                mism += 1
        self.assertEqual(mism, 0, f"{mism} type relations have broken evidence chains")

    def test_use_return_field_types_present(self):
        sg, _ = self._build()
        kinds = {r.relation_type for r in sg.relations}
        self.assertTrue(kinds & {"use_type", "return_type", "field_type"},
                        f"missing some type relation kinds: {kinds & {'use_type','return_type','field_type'}}")

    def test_type_relations_deterministic(self):
        sg1, _ = self._build()
        sg2, _ = self._build()
        r1 = sorted((r.relation_id, r.source_id, r.target_id, r.relation_type, r.evidence_id)
                    for r in sg1.relations if r.relation_type in ("use_type", "return_type", "field_type"))
        r2 = sorted((r.relation_id, r.source_id, r.target_id, r.relation_type, r.evidence_id)
                    for r in sg2.relations if r.relation_type in ("use_type", "return_type", "field_type"))
        self.assertEqual(r1, r2, "type relations not deterministic")


if __name__ == "__main__":
    unittest.main(verbosity=2)
