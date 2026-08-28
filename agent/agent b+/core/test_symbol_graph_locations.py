"""STEP 1 verification: AST -> SymbolGraph deterministic locations.

TF roadmap: locations must be correct (balanced braces, string/comment
aware), free of false symbols, and fully deterministic across rebuilds.
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


class Step1LocationsTest(unittest.TestCase):
    def _build(self):
        si = SourceIndex([ROOT]); si.scan()
        kq = KnowledgeQuery(MEMORY)
        sg = SymbolGraph(si, kq); sg.build()
        return sg, si

    def test_locations_deterministic_and_valid(self):
        sg1, si = self._build()
        fps = {fp: info["lines"] for fp, info in si.files.items()}

        in_code_kinds = {"fn", "struct", "enum", "union", "const", "var", "test"}
        keyword_for = {"fn": "fn", "struct": "struct", "enum": "enum",
                       "union": "union", "const": "const", "var": "var",
                       "test": "test"}
        bad_range = 0
        false_symbol = 0
        # Build a one-pass code mask per file (mirrors production code path).
        masks = {}
        for fp, lines in fps.items():
            masks[fp] = SymbolGraph._compute_code_mask("\n".join(lines))
        for nid, n in sg1.symbols.items():
            if n.kind not in in_code_kinds or not n.file_id:
                continue
            fp = sg1._file_paths.get(n.file_id, "")
            lines = fps.get(fp)
            if lines is None or n.line_start < 1:
                continue
            # invariant: 1 <= line_start <= line_end <= file_lines
            if n.line_end > len(lines) or n.line_end < n.line_start:
                bad_range += 1
                continue
            # false-symbol guard: declaration keyword position not in string/comment
            # (mirrors production: the match start at the keyword must be real code).
            decl_line = lines[n.line_start - 1]
            kw = keyword_for[n.kind]
            off_in_line = decl_line.find(kw)
            if off_in_line == -1:
                continue
            abs_pos = len("\n".join(lines[:n.line_start - 1])) + 1 + off_in_line
            if masks[fp][abs_pos]:
                false_symbol += 1

        self.assertEqual(bad_range, 0, f"invalid line ranges: {bad_range}")
        self.assertEqual(false_symbol, 0, f"false symbols in strings/comments: {false_symbol}")

    def test_no_false_enum_from_test_strings(self):
        sg, _ = self._build()
        names = {n.name for n in sg.symbols.values()}
        self.assertNotIn("has", names, "false 'enum has' symbol leaked from test string")

    def test_deterministic_ids_and_ranges(self):
        sg1, _ = self._build()
        sg2, _ = self._build()
        k1 = sorted(sg1.symbols.keys())
        k2 = sorted(sg2.symbols.keys())
        self.assertEqual(k1, k2, "symbol ids not deterministic")
        mism = [sid for sid in k1
                if (sg1.symbols[sid].line_start, sg1.symbols[sid].line_end)
                != (sg2.symbols[sid].line_start, sg2.symbols[sid].line_end)]
        self.assertEqual(mism, [], f"unstable line ranges for {len(mism)} symbols")
        r1 = sorted((r.relation_id, r.source_id, r.target_id, r.relation_type)
                    for r in sg1.relations)
        r2 = sorted((r.relation_id, r.source_id, r.target_id, r.relation_type)
                    for r in sg2.relations)
        self.assertEqual(r1, r2, "relations not deterministic")


if __name__ == "__main__":
    unittest.main(verbosity=2)
