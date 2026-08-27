import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from indexes import get_fast_index

ENTITY_FUNCTION = "FUNCTION"
ENTITY_STRUCT = "STRUCT"
ENTITY_ENUM = "ENUM"
ENTITY_UNION = "UNION"
ENTITY_ERROR_SET = "ERROR_SET"
ENTITY_CONST = "CONST"
ENTITY_VARIABLE = "VARIABLE"
ENTITY_FIELD = "FIELD"
ENTITY_IMPORT = "IMPORT"
ENTITY_MODULE = "MODULE"
ENTITY_FILE = "FILE"
ENTITY_CONCEPT = "CONCEPT"
ENTITY_UNKNOWN = "UNKNOWN"

ALL_ENTITY_TYPES = {
    ENTITY_FUNCTION, ENTITY_STRUCT, ENTITY_ENUM, ENTITY_UNION,
    ENTITY_ERROR_SET, ENTITY_CONST, ENTITY_VARIABLE, ENTITY_FIELD,
    ENTITY_IMPORT, ENTITY_MODULE, ENTITY_FILE, ENTITY_CONCEPT,
    ENTITY_UNKNOWN,
}

CONCEPT_TYPE_TO_ENTITY = {
    "FUNCTION": ENTITY_FUNCTION,
    "STRUCT": ENTITY_STRUCT,
    "ENUM": ENTITY_ENUM,
    "UNION": ENTITY_UNION,
    "ERROR_SET": ENTITY_ERROR_SET,
    "CONST": ENTITY_CONST,
    "VARIABLE": ENTITY_VARIABLE,
    "FIELD": ENTITY_FIELD,
    "IMPORT": ENTITY_IMPORT,
    "MODULE": ENTITY_MODULE,
}

ENTITY_TYPE_TO_CONCEPT = {v: k for k, v in CONCEPT_TYPE_TO_ENTITY.items()}

RESOLVED = "RESOLVED"
AMBIGUOUS = "AMBIGUOUS"
NOT_FOUND = "NOT_FOUND"
TYPE_MISMATCH = "TYPE_MISMATCH"

_LINE_RE = re.compile(r"^(.+?):(\d+)$")
_QUOTE_RE = re.compile(r'^"(.+)"$')


class ResolvedEntity:
    __slots__ = (
        "name", "entity_type", "concept_id", "canonical_name",
        "file", "line_start", "line_end", "module_id", "module_name",
        "evidence_ids", "fact_ids", "status", "candidates",
    )

    def __init__(self):
        self.name = ""
        self.entity_type = ENTITY_UNKNOWN
        self.concept_id = ""
        self.canonical_name = ""
        self.file = ""
        self.line_start = None
        self.line_end = None
        self.module_id = ""
        self.module_name = ""
        self.evidence_ids = []
        self.fact_ids = []
        self.status = NOT_FOUND
        self.candidates = []

    def to_dict(self):
        return {
            "name": self.name,
            "entity_type": self.entity_type,
            "concept_id": self.concept_id,
            "canonical_name": self.canonical_name,
            "file": self.file,
            "line_start": self.line_start,
            "line_end": self.line_end,
            "module_id": self.module_id,
            "module_name": self.module_name,
            "evidence_ids": self.evidence_ids,
            "fact_ids": self.fact_ids,
            "status": self.status,
            "candidates": self.candidates,
        }


class EntityResolver:
    def __init__(self):
        self.idx = get_fast_index()

    @classmethod
    def load(cls):
        return cls()

    def resolve(self, name, expected_type=None):
        clean = self._clean_name(name)
        if not clean:
            return self._not_found(name)

        file_result = self._try_file(name)
        if file_result is not None:
            return file_result

        line_result = self._try_file_line(name)
        if line_result is not None:
            return line_result

        cids = self.idx.resolve_concept(clean)
        if not cids:
            cids = self.idx.resolve_concept(name)

        if not cids:
            return self._not_found(name)

        if len(cids) == 1:
            return self._build_resolved(cids[0], clean, expected_type)

        return self._build_ambiguous(cids, clean, expected_type)

    def _clean_name(self, name):
        if not name:
            return ""
        m = _QUOTE_RE.match(name.strip())
        if m:
            return m.group(1).strip()
        return name.strip()

    def _try_file(self, name):
        if not (".zig" in name or "/" in name or "\\" in name):
            return None
        entry = self.idx.file_by_path.get(name)
        if not entry:
            base = name.rsplit("/", 1)[-1] if "/" in name else name
            entry = self.idx.file_by_base.get(base)
        if not entry:
            return None
        r = ResolvedEntity()
        r.name = name
        r.entity_type = ENTITY_FILE
        r.canonical_name = entry.get("path", "")
        r.file = entry.get("path", "")
        r.status = RESOLVED
        module_id = self.idx.file_to_module.get(entry["id"])
        if module_id:
            mc = self.idx.concept_by_id.get(module_id)
            if mc:
                r.module_id = module_id
                r.module_name = mc["canonical_name"].rsplit("/", 1)[-1]
        return r

    def _try_file_line(self, name):
        m = _LINE_RE.match(name)
        if not m:
            return None
        fname = m.group(1)
        line = int(m.group(2))
        file_result = self._try_file(fname)
        if file_result is None:
            return None
        file_result.name = name
        file_result.line_start = line
        file_result.line_end = line
        return file_result

    def _build_resolved(self, cid, clean_name, expected_type):
        c = self.idx.concept_by_id.get(cid)
        if not c:
            return self._not_found(clean_name)

        entity_type = CONCEPT_TYPE_TO_ENTITY.get(c["concept_type"], ENTITY_CONCEPT)

        if expected_type and entity_type != expected_type and expected_type != ENTITY_CONCEPT:
            r = ResolvedEntity()
            r.name = clean_name
            r.entity_type = entity_type
            r.concept_id = cid
            r.canonical_name = c["canonical_name"]
            r.status = TYPE_MISMATCH
            r.candidates = [{
                "concept_id": cid,
                "entity_type": entity_type,
                "name": c["canonical_name"].rsplit("/", 1)[-1],
            }]
            return r

        r = ResolvedEntity()
        r.name = clean_name
        r.entity_type = entity_type
        r.concept_id = cid
        r.canonical_name = c["canonical_name"]

        file_entry = self.idx.file_by_id.get(c.get("file_id", ""))
        if file_entry:
            r.file = file_entry.get("path", "")

        evidence_ids = self.idx.get_concept_evidence(cid)
        r.evidence_ids = evidence_ids[:5]

        if evidence_ids:
            ev = self.idx.get_evidence(evidence_ids[0])
            if ev:
                r.line_start = ev.get("line_start")
                r.line_end = ev.get("line_end")

        module_id = self.idx.get_module_of(cid)
        if module_id:
            r.module_id = module_id
            mc = self.idx.concept_by_id.get(module_id)
            if mc:
                r.module_name = mc["canonical_name"].rsplit("/", 1)[-1]

        fact_ids = self.idx.get_facts_by_subject(cid)
        r.fact_ids = fact_ids[:10]

        r.status = RESOLVED
        return r

    def _build_ambiguous(self, cids, clean_name, expected_type):
        candidates = []
        for cid in cids[:12]:
            c = self.idx.concept_by_id.get(cid)
            if not c:
                continue
            et = CONCEPT_TYPE_TO_ENTITY.get(c["concept_type"], ENTITY_CONCEPT)
            file_entry = self.idx.file_by_id.get(c.get("file_id", ""))
            file_path = file_entry.get("path", "") if file_entry else ""
            candidates.append({
                "concept_id": cid,
                "entity_type": et,
                "name": c["canonical_name"].rsplit("/", 1)[-1],
                "canonical_name": c["canonical_name"],
                "file": file_path.replace("\\", "/").rsplit("/", 1)[-1] if file_path else "",
            })

        if expected_type:
            filtered = [c for c in candidates if c["entity_type"] == expected_type]
            if len(filtered) == 1:
                cid = filtered[0]["concept_id"]
                return self._build_resolved(cid, clean_name, expected_type)

        r = ResolvedEntity()
        r.name = clean_name
        r.entity_type = ENTITY_UNKNOWN
        r.status = AMBIGUOUS
        r.candidates = candidates
        return r

    def _not_found(self, name):
        r = ResolvedEntity()
        r.name = name
        r.entity_type = ENTITY_UNKNOWN
        r.status = NOT_FOUND
        return r

    def resolve_file(self, path):
        entry = self.idx.file_by_path.get(path)
        if not entry:
            base = path.rsplit("/", 1)[-1] if "/" in path else path
            entry = self.idx.file_by_base.get(base)
        if not entry:
            return None
        return {
            "file_id": entry["id"],
            "path": entry.get("path", ""),
            "sha256": entry.get("sha256", ""),
            "line_count": entry.get("line_count", 0),
        }


_instance = None


def get_entity_resolver():
    global _instance
    if _instance is None:
        _instance = EntityResolver.load()
    return _instance


def main():
    resolver = EntityResolver.load()
    tests = [
        ("foldConstantOp", None),
        ("FoldConstantOp", None),
        ("FOLDCONSTANTOP", None),
        ("manager.zig", None),
        ("build.zig", None),
        ("nonexistentXYZ", None),
        ("emit", None),
        ("std", None),
    ]
    for name, etype in tests:
        r = resolver.resolve(name, expected_type=etype)
        print("  %-30s -> %-12s type=%-10s file=%s" % (
            name, r.status, r.entity_type,
            r.file.replace("\\", "/").rsplit("/", 1)[-1] if r.file else ""))
    print("\nENTITY RESOLVER READY")
    sys.exit(0)


if __name__ == "__main__":
    main()
