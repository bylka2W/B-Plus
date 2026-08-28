import copy
import hashlib
import json
import os
import shutil
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from common import short_id
from audit import Auditor, GATE_KEYS, EXTRA_KEYS
from verify import VerifyEngine

WORK = Path(r"C:\Users\Local\AppData\Local\Temp\opencode\adv_root")

FILE_A_LINES = [
    "const std = @import(\"std\");",
    "pub fn foo(x: u32) u32 {",
    "    return bar(x) + 1;",
    "}",
    "",
    "pub fn helper() void {}",
]
FILE_B_LINES = [
    "const Bar = struct { v: u32 };",
    "pub const LIMIT: u32 = 7;",
]


class MiniWorld:
    def __init__(self):
        self.root = WORK
        if WORK.exists():
            shutil.rmtree(WORK)
        (WORK / "src").mkdir(parents=True)
        self.path_a = str(WORK / "src" / "a.zig")
        self.path_b = str(WORK / "src" / "b.zig")
        (WORK / "src" / "a.zig").write_text(
            "\n".join(FILE_A_LINES) + "\n", encoding="utf-8")
        (WORK / "src" / "b.zig").write_text(
            "\n".join(FILE_B_LINES) + "\n", encoding="utf-8")

        self.fe_a = self._file_entry(self.path_a)
        self.fe_b = self._file_entry(self.path_b)

        self.ev = {}
        ev_a1 = self._chunk(self.path_a, 1, 4)
        ev_a2 = self._chunk(self.path_a, 5, 6)
        ev_b1 = self._chunk(self.path_b, 1, 2)

        self.sym_foo = {
            "symbol_id": short_id("SY", "foo", self.path_a, 2),
            "name": "foo", "kind": "function",
            "evidence_id": ev_a1["id"],
            "source_file": self.path_a,
            "line_start": 2, "line_end": 4,
            "verification_status": "VERIFIED",
        }
        self.sym_bar = {
            "symbol_id": short_id("SY", "Bar", self.path_b, 1),
            "name": "Bar", "kind": "struct",
            "evidence_id": ev_b1["id"],
            "source_file": self.path_b,
            "line_start": 1, "line_end": 2,
            "verification_status": "VERIFIED",
        }

        def fact(ftype, subj, obj, objval, evid, line, status):
            fid = short_id("FACT", ftype, subj, obj or "", objval or "",
                           evid["id"], line)
            return {
                "fact_id": fid, "fact_type": ftype, "predicate": ftype,
                "subject_id": subj, "object_id": obj or "",
                "object_value": objval or "",
                "evidence_id": evid["id"],
                "source_file": evid["source_file"],
                "line_start": line, "line_end": line,
                "verification_status": status,
            }

        f_def = fact("DEFINES", self.fe_a["id"], self.sym_foo[
            "symbol_id"], "", ev_a1, 2, "VERIFIED")
        f_ref = fact("REFERENCES", self.sym_foo["symbol_id"],
                     self.sym_bar["symbol_id"], "", ev_a1, 3, "VERIFIED")
        f_imp = fact("IMPORTS", self.sym_foo["symbol_id"], "",
                     "missing.zig", ev_a2, 6, "UNRESOLVED")
        f_defb = fact("DEFINES", self.fe_b["id"],
                      self.sym_bar["symbol_id"], "", ev_b1, 1, "VERIFIED")

        self.facts = {f["fact_id"]: f
                      for f in [f_def, f_ref, f_imp, f_defb]}

        cid_foo = short_id("CN", "FUNCTION", "foo",
                           self.fe_a["id"], self.sym_foo["symbol_id"])
        cid_bar = short_id("CN", "STRUCT", "Bar",
                           self.fe_b["id"], self.sym_bar["symbol_id"])
        cid_imp = short_id("CN", "IMPORT", "missing.zig",
                           self.fe_a["id"], "")
        self.concepts = {
            cid_foo: {
                "concept_id": cid_foo, "concept_type": "FUNCTION",
                "canonical_name": "foo", "name": "foo",
                "file_id": self.fe_a["id"],
                "fact_ids": [f_def["fact_id"], f_ref["fact_id"]],
                "source_files": [self.path_a],
                "source_symbol_ids": [self.sym_foo["symbol_id"]],
                "verification_status": "VERIFIED",
            },
            cid_bar: {
                "concept_id": cid_bar, "concept_type": "STRUCT",
                "canonical_name": "Bar", "name": "Bar",
                "file_id": self.fe_b["id"],
                "fact_ids": [f_defb["fact_id"]],
                "source_files": [self.path_b],
                "source_symbol_ids": [self.sym_bar["symbol_id"]],
                "verification_status": "VERIFIED",
            },
            cid_imp: {
                "concept_id": cid_imp, "concept_type": "IMPORT",
                "canonical_name": "missing.zig", "name": "missing.zig",
                "file_id": self.fe_a["id"],
                "fact_ids": [f_imp["fact_id"]],
                "source_files": [self.path_a],
                "source_symbol_ids": [],
                "verification_status": "UNRESOLVED",
            },
        }
        rid = short_id("SR", "REFERENCES", cid_foo, cid_bar)
        self.relations = [{
            "relation_id": rid, "relation_type": "REFERENCES",
            "predicate": "REFERENCES",
            "from_concept": cid_foo, "to_concept": cid_bar,
            "verification_status": "VERIFIED",
            "evidence_fact_ids": [f_ref["fact_id"]],
        }]

    def _file_entry(self, path):
        raw = Path(path).read_bytes()
        lines = raw.decode("utf-8").splitlines()
        return {
            "id": short_id("FI", path),
            "path": path,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "size": len(raw),
            "line_count": len(lines),
            "non_empty_lines": sum(1 for l in lines if l.strip()),
            "imports": [],
            "language": "zig",
            "type": "file",
        }

    def _chunk(self, path, ls, le):
        lines = Path(path).read_text(encoding="utf-8").splitlines()
        eid = short_id("EV", path, ls, le)
        chunk = {
            "id": eid, "file_id": None,
            "source_file": path,
            "line_start": ls, "line_end": le,
            "text": "\n".join(lines[ls - 1:le]),
            "sha256": hashlib.sha256(
                Path(path).read_bytes()).hexdigest(),
            "verification_status": "VERIFIED",
        }
        self.ev[eid] = chunk
        return chunk

    def auditor(self, facts=None, evidence_items=None, relations=None,
                concepts=None):
        facts = facts if facts is not None else self.facts
        ev_items = evidence_items if evidence_items is not None \
            else list(self.ev.values())
        relations = relations if relations is not None \
            else self.relations
        concepts = concepts if concepts is not None else self.concepts
        store = SimpleNamespace(
            evidence_by_id=dict(self.ev),
            symbols_by_id={
                self.sym_foo["symbol_id"]: self.sym_foo,
                self.sym_bar["symbol_id"]: self.sym_bar,
            },
            files_by_path={self.path_a: self.fe_a,
                           self.path_b: self.fe_b},
            files_by_id={self.fe_a["id"]: self.fe_a,
                         self.fe_b["id"]: self.fe_b},
        )
        cb = SimpleNamespace(store=store, facts=facts,
                             knowledge={"facts": len(facts)})
        cb.qe = SimpleNamespace(search=SimpleNamespace(concepts=concepts))
        index_doc = {"files": [self.fe_a, self.fe_b]}
        return Auditor(cb=cb, root=self.root, index_doc=index_doc,
                       evidence_doc={"items": ev_items},
                       facts_doc=facts, relations_items=relations,
                       concepts_map=concepts).audit()

    def verify_engine(self, relations=None):
        store = SimpleNamespace(
            evidence_by_id=dict(self.ev),
            files_by_path={self.path_a: self.fe_a,
                           self.path_b: self.fe_b},
            files_by_id={self.fe_a["id"]: self.fe_a,
                         self.fe_b["id"]: self.fe_b},
        )
        rels = relations if relations is not None else self.relations
        cb = SimpleNamespace(store=store, facts=self.facts,
                             relations={r["relation_id"]: r
                                        for r in rels})
        return VerifyEngine(cb, root=self.root)


def first_verified_fact(facts):
    for f in sorted(facts.values(), key=lambda x: x["fact_id"]):
        if f["verification_status"] == "VERIFIED":
            return f
    raise AssertionError("no verified fact in mini world")


class TestAdversarial(unittest.TestCase):
    w = None

    @classmethod
    def setUpClass(cls):
        cls.w = MiniWorld()
        rep = cls.w.auditor()
        assert rep["status"] == "PASS", json.dumps(rep, indent=1)

    def test_01_missing_evidence(self):
        ev = copy.deepcopy(list(self.w.ev.values()))
        victim = first_verified_fact(self.w.facts)["evidence_id"]
        for i, c in enumerate(ev):
            if c["id"] == victim:
                del ev[i]
        rep = self.w.auditor(evidence_items=ev)
        self.assertEqual(rep["status"], "FAIL")
        self.assertGreater(rep["counters"]["MISSING_EVIDENCE"], 0)

    def test_02_fake_evidence_id_claim_unverified(self):
        ve = self.w.verify_engine()
        f = dict(first_verified_fact(self.w.facts))
        v = ve.verify_claim({
            "claim": "forged", "fact_id": f["fact_id"],
            "evidence_id": "EV-" + "deadbeef12345678",
            "file": f["source_file"],
            "line_start": f["line_start"],
            "line_end": f["line_end"],
            "status": "VERIFIED"})
        self.assertEqual(v["status"], "UNVERIFIED")
        self.assertIn("different evidence", v["reason"])
        json.dumps(v)

    def test_03_text_tampering_detected(self):
        ev = copy.deepcopy(list(self.w.ev.values()))
        ev[0]["text"] = ev[0]["text"] + "\n// TAMPERED"
        rep = self.w.auditor(evidence_items=ev)
        self.assertEqual(rep["status"], "FAIL")
        self.assertGreater(rep["counters"]["TEXT_MISMATCHES"], 0)

    def test_04_line_range_shift_detected(self):
        ev = copy.deepcopy(list(self.w.ev.values()))
        shifted = [dict(c) for c in ev]
        target = [c for c in shifted
                  if c["line_start"] > 1][0]
        target["line_start"] -= 1
        rep = self.w.auditor(evidence_items=shifted)
        self.assertEqual(rep["status"], "FAIL")
        hit = (rep["counters"]["TEXT_MISMATCHES"]
               + rep["counters"]["INVALID_LINE_RANGES"])
        self.assertGreater(hit, 0)

    def test_05_sha_tampering_detected(self):
        ev = copy.deepcopy(list(self.w.ev.values()))
        ev[0]["sha256"] = "0" * 64
        rep = self.w.auditor(evidence_items=ev)
        self.assertGreater(rep["counters"]["STALE_SHA256"], 0)

    def test_05b_index_pin_tampering_detected(self):
        fe = copy.deepcopy(self.w.fe_a)
        fe["sha256"] = "f" * 64
        store = SimpleNamespace(
            evidence_by_id=dict(self.w.ev),
            symbols_by_id={
                self.w.sym_foo["symbol_id"]: self.w.sym_foo,
                self.w.sym_bar["symbol_id"]: self.w.sym_bar,
            },
            files_by_path={self.w.path_a: fe, self.w.path_b: self.w.fe_b},
            files_by_id={fe["id"]: fe, self.w.fe_b["id"]: self.w.fe_b},
        )
        cb = SimpleNamespace(store=store, facts=self.w.facts,
                             knowledge={})
        cb.qe = SimpleNamespace(
            search=SimpleNamespace(concepts=self.w.concepts))
        rep = Auditor(cb=cb, root=self.w.root,
                      index_doc={"files": [fe, self.w.fe_b]},
                      evidence_doc={"items": list(self.w.ev.values())},
                      facts_doc=self.w.facts,
                      relations_items=self.w.relations,
                      concepts_map=self.w.concepts).audit()
        self.assertGreater(rep["counters"]["STALE_SHA256"], 0)
        self.assertEqual(rep["status"], "FAIL")

    def test_06_orphan_fact_detected(self):
        facts = copy.deepcopy(self.w.facts)
        ghost = dict(first_verified_fact(facts))
        ghost["fact_id"] = short_id("FACT", "ORPHAN", "SY-" + "9" * 16,
                                    "", "", ghost["evidence_id"], 99)
        ghost["subject_id"] = "SY-" + "9" * 16
        facts[ghost["fact_id"]] = ghost
        rep = self.w.auditor(facts=facts)
        self.assertGreater(rep["counters"]["ORPHAN_FACTS"], 0)

    def test_07_orphan_relation_detected(self):
        rels = copy.deepcopy(self.w.relations)
        bad = dict(rels[0])
        bad["relation_id"] = short_id("SR", "CALLS",
                                      "CN-" + "1" * 16,
                                      "CN-" + "2" * 16)
        bad["relation_type"] = "CALLS"
        bad["from_concept"] = "CN-" + "1" * 16
        bad["to_concept"] = "CN-" + "2" * 16
        rels.append(bad)
        rep = self.w.auditor(relations=rels)
        self.assertGreater(rep["counters"]["ORPHAN_RELATIONS"], 0)

    def test_08_relation_without_evidence_rejected(self):
        rels = copy.deepcopy(self.w.relations)
        rels[0]["evidence_fact_ids"] = []
        rep = self.w.auditor(relations=rels)
        self.assertGreater(rep["counters"]["UNVERIFIED_AS_VERIFIED"], 0)
        ve = self.w.verify_engine(relations=rels)
        entry = {"relation_id": rels[0]["relation_id"]}
        v = ve.verify_relation_entry(entry)
        self.assertEqual(v["status"], "UNVERIFIED")
        self.assertIn("without evidence", v["reason"])
        json.dumps(v)

    def test_09_bad_id_format_and_instability(self):
        facts = copy.deepcopy(self.w.facts)
        some = next(iter(facts))
        broken = dict(facts[some])
        broken["fact_id"] = "FACT-ZZZZ"
        facts["FACT-ZZZZ"] = broken
        rep = self.w.auditor(facts=facts)
        self.assertGreater(rep["counters"]["BAD_ID_FORMAT"], 0)

        concepts = copy.deepcopy(self.w.concepts)
        cid = next(iter(concepts))
        tampered = copy.deepcopy(concepts)
        tampered[cid]["canonical_name"] = "renamed"
        rep2 = self.w.auditor(concepts=tampered)
        self.assertGreater(rep2["counters"]["ID_INSTABILITY"], 0)

    def test_10_forced_verified_without_proof_rejected(self):
        facts = copy.deepcopy(self.w.facts)
        unresolved_fid = [
            fid for fid, f in facts.items()
            if f["verification_status"] != "VERIFIED"][0]
        forged = dict(facts[unresolved_fid])
        forged["verification_status"] = "VERIFIED"
        forged["fact_id"] = short_id(
            forged["fact_type"], "X") + "forced"
        del facts[unresolved_fid]
        ve = self.w.verify_engine()
        v = ve.verify_claim({
            "claim": "forged claim",
            "fact_id": unresolved_fid,
            "evidence_id": forged["evidence_id"],
            "file": forged["source_file"],
            "line_start": forged["line_start"],
            "line_end": forged["line_end"],
            "status": "VERIFIED"})
        self.assertEqual(v["status"], "UNVERIFIED")
        self.assertIn("promotion forbidden", v["reason"])

        concepts = copy.deepcopy(self.w.concepts)
        imp_cid = [cid for cid, c in concepts.items()
                   if c["verification_status"] == "UNRESOLVED"][0]
        concepts[imp_cid]["verification_status"] = "VERIFIED"
        rep = self.w.auditor(concepts=concepts)
        self.assertGreater(rep["counters"]["UNVERIFIED_AS_VERIFIED"], 0)
        self.assertEqual(rep["status"], "FAIL")

    def test_11_invariant_all_gates_present(self):
        rep = self.w.auditor()
        for k in GATE_KEYS + EXTRA_KEYS:
            self.assertIn(k, rep["counters"])
        json.dumps(rep)


if __name__ == "__main__":
    unittest.main(verbosity=2)
