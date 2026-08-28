import hashlib
import json
import sys
import unittest
from pathlib import Path

ENGINE = Path(r"C:\B-Plus\agent\engine")
sys.path.insert(0, str(ENGINE))

from common import FACTS_PATH, load_json, save_json
from facts import build_facts, fact_id_for, validate_facts
from source_store import SourceStore

MEMORY = Path(r"C:\B-Plus\agent\memory")
SOURCE_ARTIFACTS = [
    "source_index.json",
    "source_evidence.json",
    "source_symbols.json",
    "source_relations.json",
]


def source_hashes():
    return {
        n: hashlib.sha256((MEMORY / n).read_bytes()).hexdigest()
        for n in SOURCE_ARTIFACTS
    }


class TestFacts(unittest.TestCase):
    store = None
    items = None
    hashes_before = None

    @classmethod
    def setUpClass(cls):
        cls.hashes_before = source_hashes()
        cls.store = SourceStore.load()
        errs = cls.store.validate(deep=True)
        assert not errs, "source layer invalid"
        cls.items = build_facts(cls.store)

    def test_load(self):
        doc = load_json(FACTS_PATH)
        self.assertEqual(doc["schema"], "facts")
        self.assertEqual(doc["version"], 1)

    def test_counts(self):
        doc = load_json(FACTS_PATH)
        self.assertEqual(doc["fact_count"], len(doc["items"]))
        self.assertEqual(len(self.items), doc["fact_count"])
        defines = [i for i in self.items if i["fact_type"] == "DEFINES"]
        self.assertEqual(len(defines), self.store.symbol_count())
        rel_derived = len(self.items) - len(defines)
        self.assertLessEqual(rel_derived, self.store.relation_count())

    def test_fact_ids_deterministic(self):
        for it in self.items:
            expected = fact_id_for(
                it["fact_type"], it["subject_id"], it["object_id"],
                it.get("object_value", ""), it["evidence_id"], it["line_start"],
            )
            self.assertEqual(expected, it["fact_id"])
        ids = [i["fact_id"] for i in self.items]
        self.assertEqual(len(ids), len(set(ids)))

    def test_subject_exists(self):
        bad = [
            i["fact_id"] for i in self.items
            if i["subject_id"] not in self.store.symbols_by_id
            and i["subject_id"] not in self.store.files_by_id
        ]
        self.assertEqual(bad, [])

    def test_object_exists(self):
        bad = []
        for i in self.items:
            if i["object_id"]:
                if i["object_id"] not in self.store.symbols_by_id:
                    bad.append(i["fact_id"])
            elif i["verification_status"] == "VERIFIED":
                if i["fact_type"] != "IMPORTS" or not i.get("object_value"):
                    bad.append(i["fact_id"])
        self.assertEqual(bad, [])

    def test_evidence_exists(self):
        bad = [i["fact_id"] for i in self.items if i["evidence_id"] not in self.store.evidence_by_id]
        self.assertEqual(bad, [])

    def test_source_location_valid(self):
        bad = 0
        for i in self.items:
            entry = self.store.find_file_by_path(i["source_file"])
            if entry is None or not (1 <= i["line_start"] <= i["line_end"] <= entry["line_count"]):
                bad += 1
        self.assertEqual(bad, 0)

    def test_verified_fact_requires_evidence(self):
        bad = 0
        for i in self.items:
            if i["verification_status"] != "VERIFIED":
                continue
            ev = self.store.get_evidence(i["evidence_id"])
            if ev is None:
                bad += 1
        self.assertEqual(bad, 0)

    def test_unknown_symbol_rejected(self):
        counters = validate_facts([{
            "fact_id": fact_id_for("CALLS", "SY-bogus", "SY-bogus2", "", "EV-bogus", 5),
            "fact_type": "CALLS",
            "predicate": "CALLS",
            "subject_id": "SY-bogus",
            "object_id": "SY-bogus2",
            "evidence_id": "EV-bogus",
            "source_file": r"C:\B-Plus\zig\nope.zig",
            "line_start": 5,
            "line_end": 5,
            "verification_status": "VERIFIED",
        }], self.store)
        self.assertGreater(counters["missing_subjects"], 0)
        self.assertGreater(counters["missing_objects"], 0)
        self.assertGreater(counters["missing_evidence"], 0)

    def test_artifacts_read_only(self):
        current = source_hashes()
        for n in SOURCE_ARTIFACTS:
            self.assertEqual(current[n], self.hashes_before[n], n)

    def test_rebuild_is_byte_identical(self):
        a = build_facts(self.store)
        b = build_facts(self.store)
        sa = json.dumps(a, ensure_ascii=False, sort_keys=False)
        sb = json.dumps(b, ensure_ascii=False, sort_keys=False)
        self.assertEqual(sa, sb)
        self.assertEqual(hashlib.sha256(sa.encode()).hexdigest(),
                         hashlib.sha256(sb.encode()).hexdigest())


if __name__ == "__main__":
    unittest.main(verbosity=2)
