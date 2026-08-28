import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from audit import Auditor, GATE_KEYS, EXTRA_KEYS

ZIG_ROOT = Path(r"C:\B-Plus\zig")


def zig_tree_digest():
    h = hashlib.sha256()
    for p in sorted(ZIG_ROOT.rglob("*")):
        if p.is_file():
            h.update(str(p).encode("utf-8"))
            h.update(p.read_bytes())
    return h.hexdigest()


class TestProvenanceAudit(unittest.TestCase):
    rep = None
    zig_before = None

    @classmethod
    def setUpClass(cls):
        cls.zig_before = zig_tree_digest()
        cls.rep = Auditor().audit()

    @classmethod
    def tearDownClass(cls):
        if cls.zig_before is not None:
            assert cls.zig_before == zig_tree_digest(), \
                "B+ source tree changed during audit"

    def test_audit_status_pass(self):
        self.assertEqual(self.rep["status"], "PASS",
                         json.dumps(self.rep["samples"], indent=1)[:2000])

    def test_all_gate_counters_zero(self):
        for k in GATE_KEYS + EXTRA_KEYS:
            self.assertEqual(
                self.rep["counters"][k], 0,
                f"{k} = {self.rep['counters'][k]}: "
                f"{self.rep['samples'].get(k, [])}")

    def test_counts_complete_and_nonzero(self):
        c = self.rep["counts"]
        for key, minimum in [("FILES", 100), ("SYMBOLS", 1000),
                             ("FACTS", 1000), ("RELATIONS", 1000),
                             ("EVIDENCE", 1000), ("CONCEPTS", 1000)]:
            self.assertIn(key, c)
            self.assertGreaterEqual(c[key], minimum, key)

    def test_report_schema_and_json_safe(self):
        self.assertEqual(self.rep["schema"], "provenance_audit")
        self.assertEqual(self.rep["version"], 1)
        self.assertEqual(
            sorted(self.rep["counters"].keys()),
            sorted(GATE_KEYS + EXTRA_KEYS))
        json.dumps(self.rep)


if __name__ == "__main__":
    unittest.main(verbosity=2)
