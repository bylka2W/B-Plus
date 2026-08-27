import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import (
    CONCEPTS_PATH,
    FACTS_PATH,
    SEMANTIC_RELATIONS_PATH,
    load_json,
    save_json,
    short_id,
)
from source_store import SourceStore

EDGE_INPUT_TYPES = {
    "CALLS": "CALLS",
    "REFERENCES": "REFERENCES",
    "USES": "REFERENCES",
    "PARAMETER_TYPE": "USES_TYPE",
    "RETURNS": "USES_TYPE",
    "FIELD_TYPE": "USES_TYPE",
}

DEPENDS_ON_SOURCES = {"CALLS", "REFERENCES", "USES_TYPE"}

STATUS_ORDER = ["AMBIGUOUS", "UNRESOLVED", "VERIFIED"]


def _worst(statuses):
    for s in STATUS_ORDER:
        if s in statuses:
            return s
    return "UNRESOLVED"


def relation_id_for(relation_type, from_concept, to_concept):
    return short_id("SR", relation_type, from_concept, to_concept)


def _build_maps(concepts_doc):
    sym2cid = {}
    fid2mod = {}
    for c in concepts_doc["items"]:
        if c["concept_type"] == "MODULE":
            fid2mod[c["file_id"]] = c["concept_id"]
            continue
        for sid in c["source_symbol_ids"]:
            sym2cid[sid] = c["concept_id"]
    return sym2cid, fid2mod


def build_relations(store, facts_doc, concepts_doc):
    sym2cid, fid2mod = _build_maps(concepts_doc)
    agg = {}
    skipped_unresolved = 0
    skipped_imports = 0

    def add(etype, frm, to, fact_id, status):
        key = (etype, frm, to)
        entry = agg.setdefault(key, [set(), set()])
        entry[0].add(fact_id)
        entry[1].add(status)

    for f in facts_doc["items"]:
        ft = f["fact_type"]
        st = f["verification_status"]
        subj = f["subject_id"]
        obj = f.get("object_id")

        if ft == "DEFINES":
            mod = fid2mod.get(subj)
            cid = sym2cid.get(obj)
            if mod is None or cid is None:
                continue
            add("DEFINES", mod, cid, f["fact_id"], st)
            add("BELONGS_TO", cid, mod, f["fact_id"], st)
            continue

        if ft == "HAS_FIELD":
            a = sym2cid.get(subj)
            b = sym2cid.get(obj)
            if a is None or b is None:
                continue
            add("CONTAINS", a, b, f["fact_id"], st)
            continue

        if ft == "IMPORTS":
            src_sym = store.symbols_by_id.get(subj)
            target_path = f.get("object_id") or f.get("object_value")
            entry = store.files_by_path.get(target_path) if target_path else None
            if src_sym is None or entry is None:
                skipped_imports += 1
                continue
            a = fid2mod.get(src_sym["file_id"])
            b = fid2mod.get(entry["id"])
            if a is None or b is None or a == b:
                continue
            add("IMPORTS", a, b, f["fact_id"], st)
            continue

        etype = EDGE_INPUT_TYPES.get(ft)
        if etype is None:
            continue
        if obj is None or obj not in sym2cid or subj not in sym2cid:
            skipped_unresolved += 1
            continue
        add(etype, sym2cid[subj], sym2cid[obj], f["fact_id"], st)

    items = []
    cid_file = {}
    for c in concepts_doc["items"]:
        cid_file[c["concept_id"]] = c["file_id"]

    for (etype, frm, to), entry in agg.items():
        fact_ids, statuses = entry
        items.append({
            "relation_id": relation_id_for(etype, frm, to),
            "relation_type": etype,
            "from_concept": frm,
            "to_concept": to,
            "evidence_fact_ids": sorted(fact_ids),
            "verification_status": _worst(statuses),
        })

    dep = {}
    for r in items:
        if r["relation_type"] not in DEPENDS_ON_SOURCES:
            continue
        fm = fid2mod.get(cid_file.get(r["from_concept"]))
        tm = fid2mod.get(cid_file.get(r["to_concept"]))
        if fm is None or tm is None or fm == tm:
            continue
        key = ("DEPENDS_ON", fm, tm)
        e = dep.setdefault(key, [set(), set()])
        e[0].update(r["evidence_fact_ids"])
    for (etype, frm, to), entry in dep.items():
        fact_ids, _ = entry
        items.append({
            "relation_id": relation_id_for(etype, frm, to),
            "relation_type": etype,
            "from_concept": frm,
            "to_concept": to,
            "evidence_fact_ids": sorted(fact_ids),
            "verification_status": _worst({"VERIFIED"}),
        })

    items.sort(key=lambda r: r["relation_id"])
    meta = {
        "skipped_unresolved_facts": skipped_unresolved,
        "skipped_imports": skipped_imports,
    }
    return items, meta


STRUCTURAL_TYPES = {"DEFINES", "BELONGS_TO", "CONTAINS", "IMPORTS", "DEPENDS_ON"}
CALLABLE_CONCEPTS = {"FUNCTION", "CONST", "VAR"}


def validate_relations(items, store, facts_doc, concepts_doc):
    concepts = {c["concept_id"]: c for c in concepts_doc["items"]}
    facts = {f["fact_id"]: f for f in facts_doc["items"]}
    counters = {
        "missing_from": 0,
        "missing_to": 0,
        "missing_facts": 0,
        "invalid_ids": 0,
        "fabricated": 0,
        "status_violations": 0,
        "self_loops": 0,
        "type_violations": 0,
    }
    seen = set()
    for c in items:
        rid = relation_id_for(
            c["relation_type"], c["from_concept"], c["to_concept"]
        )
        if rid != c["relation_id"] or rid in seen:
            counters["invalid_ids"] += 1
        seen.add(rid)
        if c["from_concept"] not in concepts:
            counters["missing_from"] += 1
        if c["to_concept"] not in concepts:
            counters["missing_to"] += 1
        if not c["evidence_fact_ids"]:
            counters["fabricated"] += 1
        statuses = set()
        for fid in c["evidence_fact_ids"]:
            f = facts.get(fid)
            if f is None:
                counters["missing_facts"] += 1
                continue
            statuses.add(f["verification_status"])
        t = c["relation_type"]
        if c["from_concept"] == c["to_concept"] and t in STRUCTURAL_TYPES:
            counters["self_loops"] += 1
        if c["evidence_fact_ids"] and statuses:
            if c["verification_status"] != _worst(statuses):
                counters["status_violations"] += 1
        fc = concepts.get(c["from_concept"], {})
        tc = concepts.get(c["to_concept"], {})
        ft = fc.get("concept_type")
        tt = tc.get("concept_type")
        bad = False
        if t == "DEFINES":
            bad = ft != "MODULE" or tt == "MODULE"
        elif t == "BELONGS_TO":
            bad = tt != "MODULE" or ft == "MODULE"
        elif t == "CONTAINS":
            bad = ft not in {"STRUCT", "UNION", "ENUM", "ERROR_SET"} or tt != "FIELD"
        elif t == "CALLS":
            bad = ft not in CALLABLE_CONCEPTS or tt not in CALLABLE_CONCEPTS
        elif t == "USES_TYPE":
            bad = tt == "MODULE"
        elif t == "REFERENCES":
            bad = ft == "MODULE" or tt == "MODULE"
        elif t in {"IMPORTS", "DEPENDS_ON"}:
            bad = ft != "MODULE" or tt != "MODULE"
        else:
            bad = True
        if bad:
            counters["type_violations"] += 1
    gates = {
        "DETERMINISTIC_IDS": counters["invalid_ids"] == 0,
        "FACT_INTEGRITY": counters["missing_facts"] == 0 and len(facts_doc["items"]) > 0,
        "CONCEPT_INTEGRITY": len(concepts) == concepts_doc["concept_count"],
        "EVIDENCE_INTEGRITY": all(
            f.get("evidence_id") in store.evidence_by_id for f in facts_doc["items"]
        ),
    }
    return counters, gates


def main():
    store = SourceStore.load()
    errs = store.validate(deep=True)
    if errs:
        print("STORE ERRORS:", len(errs))
        sys.exit(2)
    facts_doc = load_json(FACTS_PATH)
    concepts_doc = load_json(CONCEPTS_PATH)
    items, meta = build_relations(store, facts_doc, concepts_doc)
    counters, gates = validate_relations(items, store, facts_doc, concepts_doc)

    types = {}
    statuses = {}
    for r in items:
        types[r["relation_type"]] = types.get(r["relation_type"], 0) + 1
        s = r["verification_status"]
        statuses[s] = statuses.get(s, 0) + 1

    doc = {
        "schema": "semantic_relations",
        "version": 1,
        "root": concepts_doc.get("root", ""),
        "relation_count": len(items),
        "concept_count": concepts_doc["concept_count"],
        "fact_count": facts_doc["fact_count"],
        "items": items,
    }
    save_json(SEMANTIC_RELATIONS_PATH, doc)

    print(f"RELATIONS: {len(items)}")
    print("TYPES: " + ", ".join(
        f"{k}={types[k]}" for k in sorted(types)
    ))
    print("STATUSES: " + ", ".join(
        f"{k}={statuses[k]}" for k in sorted(statuses)
    ))
    for k in sorted(counters):
        print(f"{k.upper()}: {counters[k]}")
    print(f"SKIPPED_UNRESOLVED_FACTS: {meta['skipped_unresolved_facts']}")
    print(f"SKIPPED_IMPORTS: {meta['skipped_imports']}")
    for k in sorted(gates):
        print(f"{k}: {'PASS' if gates[k] else 'FAIL'}")
    ok = all(v == 0 for v in counters.values()) and all(gates.values())
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
