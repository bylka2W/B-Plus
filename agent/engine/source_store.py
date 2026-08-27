import hashlib
import os
import sys

from common import (
    EVIDENCE_PATH,
    INDEX_PATH,
    MEMORY_DIR,
    RELATIONS_PATH,
    SYMBOLS_PATH,
    load_json,
)

ALLOWED_STATUSES = {"VERIFIED", "UNRESOLVED", "AMBIGUOUS"}


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _read_lines(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", errors="ignore").splitlines()


class SourceStore:
    def __init__(self, index_doc, evidence_doc, symbols_doc, relations_doc):
        self.index_doc = index_doc
        self.evidence_doc = evidence_doc
        self.symbols_doc = symbols_doc
        self.relations_doc = relations_doc

        self.files_by_path = {f["path"]: f for f in index_doc["files"]}
        self.files_by_id = {f["id"]: f for f in index_doc["files"]}
        self.symbols_by_id = {s["symbol_id"]: s for s in symbols_doc["items"]}
        self.relations_by_id = {r["relation_id"]: r for r in relations_doc["items"]}
        self.evidence_by_id = {e["id"]: e for e in evidence_doc["items"]}

        self.symbols_by_file = {}
        for s in symbols_doc["items"]:
            self.symbols_by_file.setdefault(s["source_file"], []).append(s)

        self.relations_by_source = {}
        self.relations_by_target = {}
        for r in relations_doc["items"]:
            self.relations_by_source.setdefault(r["source_symbol_id"], []).append(r)
            if r["target_symbol_id"]:
                self.relations_by_target.setdefault(r["target_symbol_id"], []).append(r)

        self.errors = []

    @classmethod
    def load(cls, root=MEMORY_DIR):
        index_doc = load_json(root / "source_index.json")
        evidence_doc = load_json(root / "source_evidence.json")
        symbols_doc = load_json(root / "source_symbols.json")
        relations_doc = load_json(root / "source_relations.json")
        return cls(index_doc, evidence_doc, symbols_doc, relations_doc)

    def file_count(self):
        return len(self.files_by_path)

    def symbol_count(self):
        return len(self.symbols_by_id)

    def relation_count(self):
        return len(self.relations_by_id)

    def evidence_count(self):
        return len(self.evidence_by_id)

    def get_file(self, file_id):
        return self.files_by_id.get(file_id)

    def find_file_by_path(self, path):
        return self.files_by_path.get(path)

    def get_symbol(self, symbol_id):
        return self.symbols_by_id.get(symbol_id)

    def get_relation(self, relation_id):
        return self.relations_by_id.get(relation_id)

    def get_evidence(self, evidence_id):
        return self.evidence_by_id.get(evidence_id)

    def symbols_in_file(self, path):
        return list(self.symbols_by_file.get(path, []))

    def relations_from(self, symbol_id):
        return list(self.relations_by_source.get(symbol_id, []))

    def relations_to(self, symbol_id):
        return list(self.relations_by_target.get(symbol_id, []))

    def evidence_for_symbol(self, symbol_id):
        s = self.symbols_by_id.get(symbol_id)
        if s is None:
            return None
        return self.evidence_by_id.get(s["evidence_id"])

    def evidence_for_relation(self, relation_id):
        r = self.relations_by_id.get(relation_id)
        if r is None:
            return None
        return self.evidence_by_id.get(r["evidence_id"])

    def get_source_excerpt(self, evidence_id):
        ev = self.evidence_by_id.get(evidence_id)
        if ev is None:
            return None
        return {
            "source_file": ev["source_file"],
            "line_start": ev["line_start"],
            "line_end": ev["line_end"],
            "text": ev["text"],
        }

    def validate(self, deep=True):
        errs = []

        changed_files = []
        file_lines = {}
        for path, entry in self.files_by_path.items():
            if not os.path.isfile(path):
                errs.append(f"missing file: {path}")
                continue
            if deep and _sha256(path) != entry["sha256"]:
                changed_files.append(path)
                errs.append(f"source changed: {path}")
            file_lines[path] = _read_lines(path)

        for ev in self.evidence_doc["items"]:
            path = ev["source_file"]
            lines = file_lines.get(path)
            if lines is None:
                continue
            total = len(lines)
            if not (1 <= ev["line_start"] <= ev["line_end"] <= total):
                errs.append(f"bad evidence range {ev['id']}")
                continue
            if deep and "\n".join(lines[ev["line_start"] - 1:ev["line_end"]]) != ev["text"]:
                errs.append(f"evidence text mismatch {ev['id']}")

        for s in self.symbols_doc["items"]:
            path = s["source_file"]
            if path not in self.files_by_path:
                errs.append(f"symbol file unknown {s['symbol_id']}")
                continue
            total = len(file_lines.get(path, []))
            if not (1 <= s["line_start"] <= s["line_end"] <= max(total, 1)) and total:
                errs.append(f"bad symbol range {s['symbol_id']}")
            ev = self.evidence_by_id.get(s["evidence_id"])
            if ev is None:
                errs.append(f"symbol evidence missing {s['symbol_id']}")
            elif ev["source_file"] != path:
                errs.append(f"symbol evidence foreign file {s['symbol_id']}")

        for r in self.relations_doc["items"]:
            if r["source_symbol_id"] not in self.symbols_by_id:
                errs.append(f"relation source missing {r['relation_id']}")
            if r["target_symbol_id"] and r["target_symbol_id"] not in self.symbols_by_id:
                errs.append(f"relation target missing {r['relation_id']}")
            if r["verification_status"] not in ALLOWED_STATUSES:
                errs.append(f"relation bad status {r['relation_id']}")
            if r["verification_status"] == "VERIFIED":
                if r["relation_type"] != "IMPORTS" and not r["target_symbol_id"]:
                    errs.append(f"verified relation without target {r['relation_id']}")
                if r["relation_type"] == "IMPORTS" and not r.get("target_file"):
                    errs.append(f"verified import without target_file {r['relation_id']}")
            ev = self.evidence_by_id.get(r["evidence_id"])
            if ev is None:
                errs.append(f"relation evidence missing {r['relation_id']}")
            elif ev["source_file"] != r["source_file"]:
                errs.append(f"relation evidence foreign file {r['relation_id']}")
            elif not (ev["line_start"] <= r["line_start"] <= ev["line_end"]):
                errs.append(f"relation outside evidence {r['relation_id']}")

        self.errors = errs
        self.changed_files = changed_files
        return errs

    def summary(self):
        return {
            "files": self.file_count(),
            "symbols": self.symbol_count(),
            "relations": self.relation_count(),
            "evidence": self.evidence_count(),
            "errors": len(self.errors),
        }


def main():
    store = SourceStore.load()
    print("LOADING: OK")
    print("FILES:", store.file_count())
    print("SYMBOLS:", store.symbol_count())
    print("RELATIONS:", store.relation_count())
    print("EVIDENCE:", store.evidence_count())

    errs = store.validate(deep=True)
    print("VALIDATION_ERRORS:", len(errs))
    for e in errs[:20]:
        print("  ", e)
    print("SOURCE_INTEGRITY:", "PASS" if not store.changed_files else "FAIL")

    probe_sym = next(iter(store.symbols_by_id.values()))
    ok_api = True
    if store.get_symbol(probe_sym["symbol_id"]) is None:
        ok_api = False
    if store.get_symbol("SY-does-not-exist") is not None:
        ok_api = False
    if store.evidence_for_symbol(probe_sym["symbol_id"]) is None:
        ok_api = False
    rel = next(iter(store.relations_by_id.values()))
    if store.evidence_for_relation(rel["relation_id"]) is None:
        ok_api = False
    if not store.symbols_in_file(probe_sym["source_file"]):
        ok_api = False
    print("API_SMOKE:", "PASS" if ok_api else "FAIL")

    ok = not errs and ok_api
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
