import hashlib
import sys
import unittest
from pathlib import Path

ENGINE = Path(r"C:\B-Plus\agent\engine")
sys.path.insert(0, str(ENGINE))

from source_store import SourceStore

MEMORY = Path(r"C:\B-Plus\agent\memory")
ARTIFACTS = [
    "source_index.json",
    "source_evidence.json",
    "source_symbols.json",
    "source_relations.json",
]


def artifact_hashes():
    return {
        name: hashlib.sha256((MEMORY / name).read_bytes()).hexdigest()
        for name in ARTIFACTS
    }


class TestSourceStore(unittest.TestCase):
    store = None
    hashes_before = None

    @classmethod
    def setUpClass(cls):
        cls.hashes_before = artifact_hashes()
        cls.store = SourceStore.load()
        errs = cls.store.validate(deep=True)
        assert not errs, f"store validation failed: {errs[:5]}"

    @classmethod
    def tearDownClass(cls):
        cls.hashes_after = artifact_hashes()
        assert cls.hashes_before == cls.hashes_after, "SourceStore modified artifacts"

    def test_load_succeeds(self):
        self.assertEqual(self.store.file_count(), 401)
        self.assertEqual(self.store.symbol_count(), 9235)
        self.assertGreater(self.store.relation_count(), 0)
        self.assertGreater(self.store.evidence_count(), 0)

    def test_file_lookup(self):
        entry = next(iter(self.store.files_by_path.values()))
        got = self.store.get_file(entry["id"])
        self.assertIsNotNone(got)
        self.assertEqual(got["path"], entry["path"])

    def test_symbol_lookup(self):
        sid = next(iter(self.store.symbols_by_id))
        self.assertIsNotNone(self.store.get_symbol(sid))

    def test_relation_lookup(self):
        rid = next(iter(self.store.relations_by_id))
        self.assertIsNotNone(self.store.get_relation(rid))

    def test_evidence_lookup(self):
        eid = next(iter(self.store.evidence_by_id))
        ev = self.store.get_evidence(eid)
        self.assertIsNotNone(ev)
        excerpt = self.store.get_source_excerpt(eid)
        self.assertEqual(excerpt["text"], ev["text"])

    def test_unknown_ids_fail_cleanly(self):
        for getter in (
            self.store.get_file,
            self.store.get_symbol,
            self.store.get_relation,
            self.store.get_evidence,
        ):
            with self.subTest(getter=getter.__name__):
                self.assertIsNone(getter("NO-SUCH-ID"))
        self.assertIsNone(self.store.evidence_for_symbol("NO-SUCH-ID"))
        self.assertIsNone(self.store.evidence_for_relation("NO-SUCH-ID"))

    def test_symbol_to_evidence(self):
        for sid in list(self.store.symbols_by_id)[:100]:
            s = self.store.get_symbol(sid)
            ev = self.store.evidence_for_symbol(sid)
            self.assertIsNotNone(ev, sid)
            self.assertEqual(ev["id"], s["evidence_id"])
            self.assertEqual(ev["source_file"], s["source_file"])
            self.assertLessEqual(s["line_start"], ev["line_end"])

    def test_relation_to_evidence(self):
        for rid in list(self.store.relations_by_id)[:200]:
            r = self.store.get_relation(rid)
            ev = self.store.evidence_for_relation(rid)
            self.assertIsNotNone(ev, rid)
            self.assertEqual(ev["id"], r["evidence_id"])
            self.assertEqual(ev["source_file"], r["source_file"])

    def test_file_to_symbols(self):
        path = next(iter(self.store.symbols_by_file))
        syms = self.store.symbols_in_file(path)
        self.assertGreater(len(syms), 0)
        expected = len(self.store.symbols_by_file[path])
        self.assertEqual(len(syms), expected)
        for s in syms:
            self.assertEqual(s["source_file"], path)

    def test_outgoing_relations(self):
        src_id = next(iter(self.store.relations_by_source))
        out = self.store.relations_from(src_id)
        self.assertGreater(len(out), 0)
        for r in out:
            self.assertEqual(r["source_symbol_id"], src_id)

    def test_incoming_relations(self):
        tgt_id = next(iter(self.store.relations_by_target))
        inc = self.store.relations_to(tgt_id)
        self.assertGreater(len(inc), 0)
        for r in inc:
            self.assertEqual(r["target_symbol_id"], tgt_id)

    def test_all_symbols_have_valid_evidence(self):
        missing = 0
        for s in self.store.symbols_doc["items"]:
            ev = self.store.evidence_by_id.get(s["evidence_id"])
            if ev is None or ev["source_file"] != s["source_file"]:
                missing += 1
        self.assertEqual(missing, 0)

    def test_all_relations_have_valid_evidence(self):
        bad = 0
        for r in self.store.relations_doc["items"]:
            ev = self.store.evidence_by_id.get(r["evidence_id"])
            if ev is None or ev["source_file"] != r["source_file"]:
                bad += 1
        self.assertEqual(bad, 0)

    def test_all_relation_targets_exist(self):
        bad = 0
        for r in self.store.relations_doc["items"]:
            if r["target_symbol_id"] and r["target_symbol_id"] not in self.store.symbols_by_id:
                bad += 1
            elif r["verification_status"] == "VERIFIED" and r["relation_type"] != "IMPORTS" and not r["target_symbol_id"]:
                bad += 1
        self.assertEqual(bad, 0)

    def test_read_only_artifacts_unchanged(self):
        current = artifact_hashes()
        for name in ARTIFACTS:
            self.assertEqual(current[name], self.hashes_before[name], name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
