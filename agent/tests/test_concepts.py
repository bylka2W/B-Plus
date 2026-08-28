import hashlib
import json
import sys
import unittest
from pathlib import Path

ENGINE = Path(r"C:\B-Plus\agent\engine")
sys.path.insert(0, str(ENGINE))

from common import CONCEPTS_PATH, FACTS_PATH, load_json
from concepts import build_concepts, concept_id_for, validate_concepts
from source_store import SourceStore

MEMORY = Path(r"C:\B-Plus\agent\memory")
SOURCE_ARTIFACTS = [
    "source_index.json",
    "source_evidence.json",
    "source_symbols.json",
    "source_relations.json",
    "facts.json",
]


def artifact_hashes():
    return {
        n: hashlib.sha256((MEMORY / n).read_bytes()).hexdigest()
        for n in SOURCE_ARTIFACTS
    }


class TestConcepts(unittest.TestCase):
    store = None
    facts_doc = None
    items = None
    hashes_before = None

    @classmethod
    def setUpClass(cls):
        cls.hashes_before = artifact_hashes()
        cls.store = SourceStore.load()
        errs = cls.store.validate(deep=True)
        assert not errs, "source layer invalid"
        cls.facts_doc = load_json(FACTS_PATH)
        cls.items = build_concepts(cls.store, cls.facts_doc)

    def test_load(self):
        doc = load_json(CONCEPTS_PATH)
        self.assertEqual(doc["schema"], "concepts")
        self.assertEqual(doc["version"], 1)
        self.assertEqual(doc["concept_count"], len(doc["items"]))

    def test_schema_fields(self):
        required = {
            "concept_id", "concept_type", "name", "canonical_name",
            "file_id", "source_symbol_ids", "fact_ids", "source_files",
            "evidence_ids", "verification_status",
        }
        for c in self.items[:500]:
            self.assertTrue(required.issubset(c.keys()), c["concept_id"])

    def test_unique_ids(self):
        ids = [c["concept_id"] for c in self.items]
        self.assertEqual(len(ids), len(set(ids)))

    def test_ids_deterministic(self):
        for c in self.items:
            expected = concept_id_for(
                c["concept_type"], c["canonical_name"], c["file_id"],
                c["source_symbol_ids"],
            )
            self.assertEqual(expected, c["concept_id"])

    def test_symbols_exist(self):
        bad = [
            sid for c in self.items for sid in c["source_symbol_ids"]
            if sid not in self.store.symbols_by_id
        ]
        self.assertEqual(bad, [])

    def test_facts_exist(self):
        fact_ids = {f["fact_id"] for f in self.facts_doc["items"]}
        bad = [fid for c in self.items for fid in c["fact_ids"] if fid not in fact_ids]
        self.assertEqual(bad, [])

    def test_evidence_exists(self):
        bad = [
            eid for c in self.items for eid in c["evidence_ids"]
            if eid not in self.store.evidence_by_id
        ]
        self.assertEqual(bad, [])

    def test_source_files_exist(self):
        bad = [
            p for c in self.items for p in c["source_files"]
            if p not in self.store.files_by_path
        ]
        self.assertEqual(bad, [])

    def test_verified_requires_evidence(self):
        bad = [
            c["concept_id"] for c in self.items
            if c["verification_status"] == "VERIFIED" and not c["evidence_ids"]
        ]
        self.assertEqual(bad, [])

    def test_unresolved_never_verified(self):
        statuses = {c["verification_status"] for c in self.items}
        self.assertIn("VERIFIED", statuses)
        self.assertIn("UNRESOLVED", statuses)
        by_id = {f["fact_id"]: f for f in self.facts_doc["items"]}
        for c in self.items:
            if c["verification_status"] != "VERIFIED":
                continue
            st = [by_id[f]["verification_status"] for f in c["fact_ids"] if f in by_id]
            self.assertNotIn("UNRESOLVED", st, c["concept_id"])

    def test_artifacts_read_only(self):
        current = artifact_hashes()
        for n in SOURCE_ARTIFACTS:
            self.assertEqual(current[n], self.hashes_before[n], n)

    def test_rebuild_identical(self):
        a = build_concepts(self.store, self.facts_doc)
        b = build_concepts(self.store, self.facts_doc)
        self.assertEqual(
            hashlib.sha256(json.dumps(a).encode()).hexdigest(),
            hashlib.sha256(json.dumps(b).encode()).hexdigest(),
        )
        loaded = load_json(CONCEPTS_PATH)["items"]
        self.assertEqual(
            [c["concept_id"] for c in a],
            [c["concept_id"] for c in loaded],
        )

    def test_unknown_rejected(self):
        bogus = [{
            "concept_id": "CN-bogus",
            "concept_type": "FUNCTION",
            "name": "x",
            "canonical_name": "x",
            "file_id": "FI-bogus",
            "source_symbol_ids": ["SY-bogus"],
            "fact_ids": ["FACT-bogus"],
            "source_files": [r"C:\B-Plus\zig\ghost.zig"],
            "evidence_ids": ["EV-bogus"],
            "verification_status": "VERIFIED",
        }]
        counters = validate_concepts(bogus, self.store, self.facts_doc)
        self.assertGreater(counters["missing_symbols"], 0)
        self.assertGreater(counters["missing_facts"], 0)
        self.assertGreater(counters["missing_evidence"], 0)

    def test_function_counts_match_symbols(self):
        sym_functions = sum(
            1 for s in self.store.symbols_by_id.values() if s["kind"] == "function"
        )
        funcs = [c for c in self.items if c["concept_type"] == "FUNCTION"]
        self.assertEqual(len(funcs), sym_functions)

    def test_verified_functions_present(self):
        funcs = [c for c in self.items if c["concept_type"] == "FUNCTION"]
        verified = [c for c in funcs if c["verification_status"] == "VERIFIED"]
        self.assertGreater(len(verified), 800)
        self.assertGreater(len(verified), len(funcs) // 2)

    def test_unresolved_concepts_traceable(self):
        facts_by_id = {f["fact_id"]: f for f in self.facts_doc["items"]}
        no_fact_unresolved = []
        for c in self.items:
            if c["verification_status"] != "UNRESOLVED":
                continue
            if not c["fact_ids"]:
                no_fact_unresolved.append(c["concept_type"])
                continue
            unresolved = [
                fid for fid in c["fact_ids"]
                if fid in facts_by_id
                and facts_by_id[fid]["verification_status"] == "UNRESOLVED"
            ]
            self.assertGreater(
                len(unresolved), 0,
                f"{c['concept_id']} UNRESOLVED without any UNRESOLVED fact",
            )
        self.assertTrue(
            set(no_fact_unresolved) <= {"MODULE"},
            no_fact_unresolved,
        )

    def test_spot_check_chain_to_source(self):
        functions = [
            c for c in self.items
            if c["concept_type"] == "FUNCTION" and c["verification_status"] == "VERIFIED"
        ]
        self.assertGreater(len(functions), 100)
        checked = 0
        for c in functions[:50]:
            sym = self.store.get_symbol(c["source_symbol_ids"][0])
            self.assertIn(sym["evidence_id"], c["evidence_ids"])
            ev = self.store.get_evidence(sym["evidence_id"])
            self.assertIsNotNone(ev)
            real = open(ev["source_file"], "rb").read().decode("utf-8", "ignore")
            lines = real.splitlines()
            sl = "\n".join(lines[ev["line_start"] - 1:ev["line_end"]])
            self.assertEqual(sl, ev["text"])
            self.assertIn(sym["name"], ev["text"])
            for eid in c["evidence_ids"]:
                e2 = self.store.get_evidence(eid)
                r2 = open(e2["source_file"], "rb").read().decode(
                    "utf-8", "ignore"
                ).splitlines()
                slice2 = "\n".join(r2[e2["line_start"] - 1:e2["line_end"]])
                self.assertEqual(slice2, e2["text"], eid)
            checked += 1
        self.assertEqual(checked, 50)


if __name__ == "__main__":
    unittest.main(verbosity=2)
