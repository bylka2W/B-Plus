import sys

from common import FACTS_PATH, save_json, short_id
from source_store import SourceStore

FACT_TYPES_FROM_RELATIONS = {
    "IMPORTS",
    "CALLS",
    "USES",
    "REFERENCES",
    "HAS_FIELD",
    "FIELD_TYPE",
    "PARAMETER_TYPE",
    "RETURNS",
}


def fact_id_for(fact_type, subject_id, object_id, object_value, evidence_id, line):
    return short_id(
        "FACT", fact_type, subject_id, object_id, object_value, evidence_id, line
    )


def fact_from_relation(rel):
    fact_type = rel["relation_type"]
    if fact_type not in FACT_TYPES_FROM_RELATIONS:
        return None
    object_value = rel.get("target_file", "") or rel.get("target_name", "")
    return {
        "fact_id": fact_id_for(
            fact_type,
            rel["source_symbol_id"],
            rel["target_symbol_id"],
            object_value,
            rel["evidence_id"],
            rel["line_start"],
        ),
        "fact_type": fact_type,
        "predicate": fact_type,
        "subject_id": rel["source_symbol_id"],
        "object_id": rel["target_symbol_id"],
        **({"object_value": object_value} if object_value else {}),
        "evidence_id": rel["evidence_id"],
        "source_file": rel["source_file"],
        "line_start": rel["line_start"],
        "line_end": rel["line_end"],
        "verification_status": rel["verification_status"],
    }


def fact_defines(symbol):
    return {
        "fact_id": fact_id_for(
            "DEFINES", symbol["file_id"], symbol["symbol_id"], "",
            symbol["evidence_id"], symbol["line_start"],
        ),
        "fact_type": "DEFINES",
        "predicate": "DEFINES",
        "subject_id": symbol["file_id"],
        "object_id": symbol["symbol_id"],
        "evidence_id": symbol["evidence_id"],
        "source_file": symbol["source_file"],
        "line_start": symbol["line_start"],
        "line_end": symbol["line_end"],
        "verification_status": "VERIFIED",
    }


def build_facts(store):
    items = []
    for sym in store.symbols_doc["items"]:
        items.append(fact_defines(sym))
    for rel in store.relations_doc["items"]:
        f = fact_from_relation(rel)
        if f is not None:
            items.append(f)
    items.sort(key=lambda x: x["fact_id"])
    return items


def validate_facts(items, store):
    counters = {
        "missing_subjects": 0,
        "missing_objects": 0,
        "missing_evidence": 0,
        "invalid_ranges": 0,
        "fabricated": 0,
        "verified_without_evidence": 0,
        "bad_ids": 0,
    }
    seen = set()
    for it in items:
        expected = fact_id_for(
            it["fact_type"], it["subject_id"], it["object_id"],
            it.get("object_value", ""), it["evidence_id"], it["line_start"],
        )
        if expected != it["fact_id"] or it["fact_id"] in seen:
            counters["bad_ids"] += 1
        seen.add(it["fact_id"])

        subject_ok = it["subject_id"] in store.symbols_by_id or it["subject_id"] in store.files_by_id
        if not subject_ok:
            counters["missing_subjects"] += 1
        if it["verification_status"] == "VERIFIED":
            if it["fact_type"] != "IMPORTS":
                if not it["object_id"] or it["object_id"] not in store.symbols_by_id:
                    counters["missing_objects"] += 1
            elif not it.get("object_value"):
                counters["missing_objects"] += 1
        elif it["object_id"] and it["object_id"] not in store.symbols_by_id:
            counters["missing_objects"] += 1

        ev = store.get_evidence(it["evidence_id"])
        if ev is None:
            counters["missing_evidence"] += 1
            if it["verification_status"] == "VERIFIED":
                counters["verified_without_evidence"] += 1
            continue
        if ev["source_file"] != it["source_file"]:
            counters["fabricated"] += 1
            continue
        entry = store.find_file_by_path(it["source_file"])
        total = entry["line_count"] if entry else 0
        if not (1 <= it["line_start"] <= it["line_end"] <= max(total, 1)):
            counters["invalid_ranges"] += 1
            continue
        text = ev["text"]
        if it["fact_type"] == "DEFINES":
            obj = store.get_symbol(it["object_id"])
            probe = obj is not None and obj["name"] in text
        elif it["fact_type"] == "IMPORTS":
            val = it.get("object_value", "")
            import os.path as op
            probe = ("@import(" in text) and (op.basename(val) in text if val else True)
        else:
            obj = store.get_symbol(it["object_id"])
            probe = obj is not None and obj["name"] in text
        if it["verification_status"] == "VERIFIED" and not probe:
            counters["fabricated"] += 1

    return counters


def main():
    store = SourceStore.load()
    errs = store.validate(deep=True)
    if errs:
        print("SOURCE_LAYER_ERRORS:", len(errs))
        for e in errs[:10]:
            print("  ", e)
        print("SOURCE_INTEGRITY: FAIL")
        sys.exit(1)

    items = build_facts(store)
    doc = {
        "schema": "facts",
        "version": 1,
        "root": store.index_doc["root"],
        "fact_count": len(items),
        "items": items,
    }
    save_json(FACTS_PATH, doc)
    print("FACTS:", len(items))

    c = validate_facts(items, store)
    type_counts = {}
    status_counts = {}
    for it in items:
        type_counts[it["fact_type"]] = type_counts.get(it["fact_type"], 0) + 1
        status_counts[it["verification_status"]] = status_counts.get(it["verification_status"], 0) + 1

    print("SOURCE SYMBOLS:", store.symbol_count())
    print("SOURCE RELATIONS:", store.relation_count())
    print("TYPES:", ", ".join(f"{k}={v}" for k, v in sorted(type_counts.items())))
    print("STATUSES:", ", ".join(f"{k}={v}" for k, v in sorted(status_counts.items())))
    print("MISSING SUBJECTS:", c["missing_subjects"])
    print("MISSING OBJECTS:", c["missing_objects"])
    print("MISSING EVIDENCE:", c["missing_evidence"])
    print("INVALID RANGES:", c["invalid_ranges"])
    print("FABRICATED FACTS:", c["fabricated"])
    print("VERIFIED_WITHOUT_EVIDENCE:", c["verified_without_evidence"])
    print("DETERMINISTIC_IDS:", "PASS" if c["bad_ids"] == 0 else "FAIL")
    print("SOURCE_INTEGRITY: PASS")
    print("EVIDENCE_INTEGRITY:",
          "PASS" if c["fabricated"] == 0 and c["missing_evidence"] == 0 else "FAIL")

    ok = all([
        c["missing_subjects"] == 0,
        c["missing_objects"] == 0,
        c["missing_evidence"] == 0,
        c["invalid_ranges"] == 0,
        c["fabricated"] == 0,
        c["verified_without_evidence"] == 0,
        c["bad_ids"] == 0,
    ])
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
