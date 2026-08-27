import os
import sys

from common import CONCEPTS_PATH, FACTS_PATH, load_json, save_json, short_id
from facts import fact_id_for
from source_store import SourceStore

KIND_TO_CONCEPT = {
    "function": "FUNCTION",
    "struct": "STRUCT",
    "enum": "ENUM",
    "union": "UNION",
    "error_set": "ERROR_SET",
    "const": "CONST",
    "type": "SYMBOL",
    "var": "VARIABLE",
    "field": "FIELD",
    "import": "IMPORT",
}


def concept_id_for(concept_type, canonical_name, file_id, source_symbol_ids):
    return short_id(
        "CN", concept_type, canonical_name, file_id,
        ",".join(sorted(source_symbol_ids)),
    )


def _status_of(fact_statuses):
    if not fact_statuses:
        return "UNRESOLVED"
    if any(s == "AMBIGUOUS" for s in fact_statuses):
        return "AMBIGUOUS"
    if any(s == "UNRESOLVED" for s in fact_statuses):
        return "UNRESOLVED"
    return "VERIFIED"


def build_concepts(store, facts_doc):
    facts = facts_doc["items"]

    facts_by_symbol = {}
    facts_by_file = {}
    for f in facts:
        subj = f["subject_id"]
        obj = f["object_id"]
        if subj in store.symbols_by_id:
            facts_by_symbol.setdefault(subj, []).append(f)
        elif subj in store.files_by_id:
            facts_by_file.setdefault(subj, []).append(f)
        if obj and obj in store.symbols_by_id:
            facts_by_symbol.setdefault(obj, []).append(f)

    items = []
    root_prefix = store.index_doc["root"] + os.sep

    for sym in store.symbols_doc["items"]:
        flist = facts_by_symbol.get(sym["symbol_id"], [])
        ev_ids = {sym["evidence_id"]}
        files = {sym["source_file"]}
        statuses = set()
        for f in flist:
            ev_ids.add(f["evidence_id"])
            files.add(f["source_file"])
            statuses.add(f["verification_status"])
        items.append({
            "concept_id": concept_id_for(
                KIND_TO_CONCEPT[sym["kind"]], sym["name"], sym["file_id"],
                [sym["symbol_id"]],
            ),
            "concept_type": KIND_TO_CONCEPT[sym["kind"]],
            "name": sym["name"],
            "canonical_name": sym["name"],
            "file_id": sym["file_id"],
            "source_symbol_ids": [sym["symbol_id"]],
            "fact_ids": sorted(f["fact_id"] for f in flist),
            "source_files": sorted(files),
            "evidence_ids": sorted(ev_ids),
            "verification_status": _status_of(statuses | {"VERIFIED"}),
        })

    for path in sorted(store.files_by_path):
        entry = store.files_by_path[path]
        flist = facts_by_file.get(entry["id"], [])
        rel_name = path.replace(root_prefix, "").replace(os.sep, "/")
        ev_ids = set()
        sym_ids = set()
        statuses = set()
        for f in flist:
            ev_ids.add(f["evidence_id"])
            sym_ids.add(f["object_id"])
            statuses.add(f["verification_status"])
        if ev_ids:
            status = _status_of(statuses)
        else:
            status = "UNRESOLVED"
        items.append({
            "concept_id": concept_id_for(
                "MODULE", rel_name, entry["id"], sorted(sym_ids)
            ),
            "concept_type": "MODULE",
            "name": rel_name,
            "canonical_name": rel_name,
            "file_id": entry["id"],
            "source_symbol_ids": sorted(sym_ids),
            "fact_ids": sorted(f["fact_id"] for f in flist),
            "source_files": [path],
            "evidence_ids": sorted(ev_ids),
            "verification_status": status,
        })

    items.sort(key=lambda c: c["concept_id"])
    return items


def validate_concepts(items, store, facts_doc):
    counters = {
        "missing_symbols": 0,
        "missing_facts": 0,
        "missing_evidence": 0,
        "invalid_ids": 0,
        "invalid_ranges": 0,
        "fabricated": 0,
        "verified_without_evidence": 0,
        "status_violations": 0,
    }
    fact_by_id = {f["fact_id"]: f for f in facts_doc["items"]}
    seen = set()

    for c in items:
        expected = concept_id_for(
            c["concept_type"], c["canonical_name"], c["file_id"],
            c["source_symbol_ids"],
        )
        if expected != c["concept_id"] or c["concept_id"] in seen:
            counters["invalid_ids"] += 1
        seen.add(c["concept_id"])

        for sid in c["source_symbol_ids"]:
            if sid not in store.symbols_by_id:
                counters["missing_symbols"] += 1

        statuses = set()
        for fid in c["fact_ids"]:
            f = fact_by_id.get(fid)
            if f is None:
                counters["missing_facts"] += 1
                continue
            exp_fid = fact_id_for(
                f["fact_type"], f["subject_id"], f["object_id"],
                f.get("object_value", ""), f["evidence_id"], f["line_start"],
            )
            if exp_fid != fid:
                counters["missing_facts"] += 1
            statuses.add(f["verification_status"])

        if c["verification_status"] != _status_of(statuses):
            counters["status_violations"] += 1

        if not c["evidence_ids"]:
            if c["verification_status"] == "VERIFIED":
                counters["verified_without_evidence"] += 1
            continue

        known_files = set(c["source_files"])
        for eid in c["evidence_ids"]:
            ev = store.get_evidence(eid)
            if ev is None:
                counters["missing_evidence"] += 1
                continue
            entry = store.find_file_by_path(ev["source_file"])
            if entry is None or not (1 <= ev["line_start"] <= ev["line_end"] <= entry["line_count"]):
                counters["invalid_ranges"] += 1
            if c["verification_status"] == "VERIFIED" and ev["source_file"] not in known_files:
                counters["fabricated"] += 1

    return counters


def main():
    store = SourceStore.load()
    errs = store.validate(deep=True)
    if errs:
        print("SOURCE_LAYER_ERRORS:", len(errs))
        print("SOURCE_INTEGRITY: FAIL")
        sys.exit(1)

    facts_doc = load_json(FACTS_PATH)
    if facts_doc["fact_count"] != len(facts_doc["items"]):
        print("FACT_INTEGRITY: FAIL")
        sys.exit(1)

    items = build_concepts(store, facts_doc)
    doc = {
        "schema": "concepts",
        "version": 1,
        "root": store.index_doc["root"],
        "concept_count": len(items),
        "items": items,
    }
    save_json(CONCEPTS_PATH, doc)
    print("CONCEPTS:", len(items))

    c = validate_concepts(items, store, facts_doc)

    type_counts = {}
    status_counts = {}
    for it in items:
        type_counts[it["concept_type"]] = type_counts.get(it["concept_type"], 0) + 1
        status_counts[it["verification_status"]] = status_counts.get(it["verification_status"], 0) + 1

    print("MODULES:", type_counts.get("MODULE", 0))
    print("TYPES:", ", ".join(f"{k}={v}" for k, v in sorted(type_counts.items())))
    print("STATUSES:", ", ".join(f"{k}={v}" for k, v in sorted(status_counts.items())))
    print("MISSING_SYMBOLS:", c["missing_symbols"])
    print("MISSING_FACTS:", c["missing_facts"])
    print("MISSING_EVIDENCE:", c["missing_evidence"])
    print("INVALID_IDS:", c["invalid_ids"])
    print("INVALID_RANGES:", c["invalid_ranges"])
    print("FABRICATED_CONCEPTS:", c["fabricated"])
    print("VERIFIED_WITHOUT_EVIDENCE:", c["verified_without_evidence"])
    print("STATUS_VIOLATIONS:", c["status_violations"])
    print("DETERMINISTIC_IDS:", "PASS" if c["invalid_ids"] == 0 else "FAIL")
    print("SOURCE_INTEGRITY: PASS")
    print("FACT_INTEGRITY:",
          "PASS" if c["missing_facts"] == 0 and facts_doc["fact_count"] == len(facts_doc["items"]) else "FAIL")
    print("EVIDENCE_INTEGRITY:",
          "PASS" if c["missing_evidence"] == 0 and c["invalid_ranges"] == 0 else "FAIL")

    ok = all([
        c["missing_symbols"] == 0,
        c["missing_facts"] == 0,
        c["missing_evidence"] == 0,
        c["invalid_ids"] == 0,
        c["invalid_ranges"] == 0,
        c["fabricated"] == 0,
        c["verified_without_evidence"] == 0,
        c["status_violations"] == 0,
    ])
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
