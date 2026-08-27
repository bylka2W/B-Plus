import hashlib
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import load_json, short_id
from common import INDEX_PATH, EVIDENCE_PATH, SEMANTIC_RELATIONS_PATH
from context import ContextBuilder

ZIG_ROOT = os.path.normpath("C:\\B-Plus\\zig")

ID_RE = {
    "FI": re.compile(r"^FI-[0-9a-f]{16}$"),
    "EV": re.compile(r"^EV-[0-9a-f]{16}$"),
    "SY": re.compile(r"^SY-[0-9a-f]{16}$"),
    "FACT": re.compile(r"^FACT-[0-9a-f]{16}$"),
    "CN": re.compile(r"^CN-[0-9a-f]{16}$"),
    "SR": re.compile(r"^SR-[0-9a-f]{16}$"),
}

GATE_KEYS = [
    "ORPHAN_FACTS",
    "ORPHAN_RELATIONS",
    "MISSING_EVIDENCE",
    "BROKEN_SOURCE_PATHS",
    "INVALID_LINE_RANGES",
    "TEXT_MISMATCHES",
    "DUPLICATE_IDS",
    "UNVERIFIED_AS_VERIFIED",
]

EXTRA_KEYS = [
    "STALE_SHA256",
    "BAD_ID_FORMAT",
    "ID_INSTABILITY",
]


def _worst(statuses):
    s = set(statuses)
    if not s:
        return "UNRESOLVED"
    if "AMBIGUOUS" in s:
        return "AMBIGUOUS"
    if "UNRESOLVED" in s:
        return "UNRESOLVED"
    if s == {"VERIFIED"}:
        return "VERIFIED"
    return "UNRESOLVED"


class Auditor:
    def __init__(self, cb=None, root=None, index_doc=None,
                 evidence_doc=None, facts_doc=None, relations_items=None,
                 concepts_map=None):
        self.root = os.path.normpath(root) if root else ZIG_ROOT
        self.cb = cb if cb is not None else ContextBuilder.load()
        self.index = index_doc if index_doc is not None \
            else load_json(INDEX_PATH)
        self._evdoc_injected = evidence_doc
        self.evidence_doc = evidence_doc \
            if evidence_doc is not None else load_json(EVIDENCE_PATH)
        self.facts = facts_doc if facts_doc is not None else self.cb.facts
        self.concepts = concepts_map \
            if concepts_map is not None else self.cb.qe.search.concepts
        self.relations_override = relations_items
        self.counters = {k: 0 for k in GATE_KEYS + EXTRA_KEYS}
        self.samples = {}
        self._files = {}
        self.bad_evidence = set()

    def _bump(self, key, detail=""):
        self.counters[key] += 1
        if key not in self.samples:
            self.samples[key] = []
        if len(self.samples[key]) < 5 and detail:
            self.samples[key].append(str(detail)[:200])

    def _file_data(self, path):
        if path in self._files:
            return self._files[path]
        try:
            with open(path, "rb") as fh:
                raw = fh.read()
            digest = hashlib.sha256(raw).hexdigest()
            lines = raw.decode("utf-8", "ignore").splitlines()
        except OSError:
            self._files[path] = None
            return None
        self._files[path] = (digest, lines)
        return self._files[path]

    def _path_ok(self, path):
        norm = os.path.normpath(path)
        root = self.root
        return (norm.startswith(root + os.sep) or norm == root) \
            and os.path.isfile(norm)

    def _dup_check(self, items, idkey, label):
        seen = set()
        dups = 0
        for it in items:
            i = it[idkey]
            if i in seen:
                dups += 1
                self._bump("DUPLICATE_IDS", f"{label} {i}")
            seen.add(i)
        return seen

    def _fmt_check(self, iid, prefix, label):
        rx = ID_RE.get(prefix)
        if rx and not rx.match(iid or ""):
            self._bump("BAD_ID_FORMAT", f"{label} {iid!r}")
            return False
        return True

    def audit(self):
        files = self.index["files"]
        entries = {}
        for fe in files:
            entries[fe["path"]] = fe
            if not self._fmt_check(fe["id"], "FI", "FILE"):
                continue
            norm = os.path.normpath(fe["path"])
            if not self._path_ok(fe["path"]):
                self._bump("BROKEN_SOURCE_PATHS", fe["path"])
                continue
            fd = self._file_data(norm)
            if fd is None:
                self._bump("BROKEN_SOURCE_PATHS", fe["path"])
                continue
            disk_digest, _ = fd
            if disk_digest != fe["sha256"]:
                self._bump("STALE_SHA256", fe["path"])

        ev_items = (
            self.evidence_doc["items"]
            if isinstance(self.evidence_doc, dict) else self.evidence_doc
        )
        ev_ids = self._dup_check(ev_items, "id", "EV")
        ev_ok = set()
        for ev in ev_items:
            eid = ev["id"]
            if not self._fmt_check(eid, "EV", "EVIDENCE"):
                continue
            path = ev["source_file"]
            if path not in entries or not self._path_ok(path):
                self._bump("BROKEN_SOURCE_PATHS", f"{eid} {path}")
                continue
            fd = self._file_data(os.path.normpath(path))
            if fd is None:
                self._bump("BROKEN_SOURCE_PATHS", f"{eid} {path}")
                continue
            digest, lines = fd
            ls, le = ev["line_start"], ev["line_end"]
            if not (isinstance(ls, int) and isinstance(le, int)
                    and 1 <= ls <= le <= len(lines)):
                self._bump("INVALID_LINE_RANGES",
                           f"{eid} {path}:{ls}-{le} len={len(lines)}")
                continue
            actual = "\n".join(lines[ls - 1:le])
            if actual != ev["text"]:
                self._bump("TEXT_MISMATCHES", f"{eid} {path}:{ls}-{le}")
                continue
            if ev.get("sha256") and ev["sha256"] != digest:
                self._bump("STALE_SHA256", f"{eid} pins {path}")
                continue
            if entries[path]["sha256"] != digest:
                self._bump("STALE_SHA256", f"index pin {path}")
                continue
            ev_ok.add(eid)

        store = self.cb.store
        symbols_by_id = getattr(store, "symbols_by_id", {}) or {}
        files_by_id = getattr(store, "files_by_id", {})
        if not files_by_id:
            files_by_id = {fe["id"]: fe for fe in self.index["files"]}

        sym_ids = self._dup_check(symbols_by_id.values(), "symbol_id",
                                  "SY")
        for s in symbols_by_id.values():
            sid = s["symbol_id"]
            if not self._fmt_check(sid, "SY", "SYMBOL"):
                continue
            if s["evidence_id"] not in ev_ok:
                self._bump("MISSING_EVIDENCE", f"{sid} -> "
                           f"{s['evidence_id']}")
                continue
            if s["source_file"] not in entries:
                self._bump("BROKEN_SOURCE_PATHS", f"{sid} "
                           f"{s['source_file']}")
                continue
            fd = self._file_data(os.path.normpath(s["source_file"]))
            if fd is None or len(fd[1]) < s["line_end"]:
                self._bump("INVALID_LINE_RANGES",
                           f"{sid} {s['source_file']}:"
                           f"{s['line_start']}-{s['line_end']}")
                continue
            ev = self.cb.store.evidence_by_id[s["evidence_id"]]
            if not (ev["line_start"] <= s["line_start"] <= ev["line_end"]):
                self._bump("INVALID_LINE_RANGES",
                           f"{sid} anchor outside chunk")

        facts = self.facts
        fact_ids = self._dup_check(facts.values(), "fact_id", "FACT")
        for f in facts.values():
            fid = f["fact_id"]
            if not self._fmt_check(fid, "FACT", "FACT"):
                continue
            expect = short_id(
                "FACT", f["fact_type"], f["subject_id"],
                f.get("object_id", ""), f.get("object_value", ""),
                f["evidence_id"], f["line_start"],
            )
            if expect != fid:
                self._bump("ID_INSTABILITY",
                           f"{fid} != {expect}")
            subj_ok = (
                f["subject_id"] in sym_ids
                or f["subject_id"] in files_by_id
            )
            obj = f.get("object_id") or ""
            obj_ok = True
            if obj and obj not in sym_ids and obj not in files_by_id:
                obj_ok = False
            if not subj_ok or not obj_ok:
                self._bump("ORPHAN_FACTS",
                           f"{fid} {f['subject_id']}->{obj}")
            if f["evidence_id"] not in ev_ids:
                self._bump("MISSING_EVIDENCE",
                           f"{fid} -> {f['evidence_id']}")
                continue
            if f["verification_status"] != "VERIFIED":
                continue
            proven_ok = (
                f["evidence_id"] in ev_ok
                and subj_ok and obj_ok
            )
            ev = self.cb.store.evidence_by_id[f["evidence_id"]]
            if not (ev["line_start"] <= f["line_start"] <= ev["line_end"]):
                proven_ok = False
            if not proven_ok:
                self._bump("UNVERIFIED_AS_VERIFIED",
                           f"FACT {fid}")

        if self.relations_override is not None:
            rels = self.relations_override
        else:
            rels_doc = load_json(SEMANTIC_RELATIONS_PATH)
            rels = rels_doc["items"] if isinstance(rels_doc, dict) \
                else rels_doc
        concept_ids = {c["concept_id"] for c in self.concepts.values()}
        self._dup_check(rels, "relation_id", "SR")
        for r in rels:
            rid = r["relation_id"]
            if not self._fmt_check(rid, "SR", "RELATION"):
                continue
            expect = short_id("SR", r["relation_type"],
                              r["from_concept"], r["to_concept"])
            if expect != rid:
                self._bump("ID_INSTABILITY", f"{rid} != {expect}")
            if r["from_concept"] not in concept_ids \
                    or r["to_concept"] not in concept_ids:
                self._bump("ORPHAN_RELATIONS",
                           f"{rid} endpoints")
                continue
            if r["verification_status"] != "VERIFIED":
                continue
            fids = r.get("evidence_fact_ids") or []
            cited_ok = bool(fids) and all(
                fid in facts
                and facts[fid]["verification_status"] == "VERIFIED"
                and facts[fid]["evidence_id"] in ev_ok
                for fid in fids
            )
            if not cited_ok:
                self._bump("UNVERIFIED_AS_VERIFIED",
                           f"RELATION {rid}")

        for c in self.concepts.values():
            cid = c["concept_id"]
            if not self._fmt_check(cid, "CN", "CONCEPT"):
                continue
            expect = short_id(
                "CN", c["concept_type"], c["canonical_name"],
                c["file_id"],
                ",".join(sorted(c.get("source_symbol_ids", []))),
            )
            if expect != cid:
                self._bump("ID_INSTABILITY", f"{cid} != {expect}")
            for p in c.get("source_files", []):
                if p not in entries:
                    self._bump("BROKEN_SOURCE_PATHS",
                               f"{cid} {p}")
            missing_fids = [fid for fid in c["fact_ids"]
                            if fid not in facts]
            if missing_fids:
                self._bump("ORPHAN_FACTS",
                           f"{cid} cites {missing_fids[:3]}")
                continue
            st = _worst(facts[fid]["verification_status"]
                        for fid in c["fact_ids"])
            if c["verification_status"] == "VERIFIED" and st != "VERIFIED":
                self._bump("UNVERIFIED_AS_VERIFIED",
                           f"CONCEPT {cid} worst={st}")

        report = {
            "schema": "provenance_audit",
            "version": 1,
            "knowledge": self.cb.knowledge,
            "counts": {
                "FILES": len(files),
                "SYMBOLS": len(sym_ids),
                "FACTS": len(fact_ids),
                "RELATIONS": len(rels),
                "EVIDENCE": len(ev_ids),
                "CONCEPTS": len(concept_ids),
            },
            "counters": self.counters,
            "samples": self.samples,
            "status": "PASS" if all(self.counters[k] == 0
                                    for k in GATE_KEYS + EXTRA_KEYS)
            else "FAIL",
        }
        return report


def main():
    rep = Auditor().audit()
    print("PROVENANCE AUDIT")
    print()
    for k, v in rep["counts"].items():
        print(f"{k}: {v}")
    print()
    for k in GATE_KEYS:
        print(f"{k}: {rep['counters'][k]}")
    for k in EXTRA_KEYS:
        print(f"{k}: {rep['counters'][k]}")
    print()
    print(f"STATUS: {rep['status']}")
    if rep["status"] == "FAIL":
        for k, samples in rep["samples"].items():
            for s in samples:
                print(f"  SAMPLE[{k}] {s}")
    sys.exit(0 if rep["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
