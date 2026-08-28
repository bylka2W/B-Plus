"""
STAGE 2 RELEASE GATE — FULL INTEGRITY AUDIT
Proves every ID in the knowledge base resolves. Zero orphans, zero dangling refs.
"""
import os
import sys
import json
import hashlib
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "engine"))

from common import MEMORY_DIR, load_json


def load_all():
    concepts = load_json(MEMORY_DIR / "concepts.json")
    facts = load_json(MEMORY_DIR / "facts.json")
    relations = load_json(MEMORY_DIR / "semantic_relations.json")
    evidence = load_json(MEMORY_DIR / "source_evidence.json")
    symbols = load_json(MEMORY_DIR / "source_symbols.json")
    index = load_json(MEMORY_DIR / "source_index.json")
    return concepts, facts, relations, evidence, symbols, index


def check_unique(items, id_field, label):
    ids = [item[id_field] for item in items]
    dupes = [x for x in ids if ids.count(x) > 1]
    unique_dupes = list(set(dupes))
    return {
        "check": f"{label} IDs unique",
        "total": len(ids),
        "unique": len(set(ids)),
        "dupes": len(unique_dupes),
        "status": "PASS" if len(unique_dupes) == 0 else "FAIL",
        "details": unique_dupes[:5] if unique_dupes else [],
    }


def check_ref(label, source_ids, target_set, allow_empty=False):
    missing = []
    for sid in source_ids:
        if not sid and allow_empty:
            continue
        if sid and sid not in target_set:
            missing.append(sid)
    return {
        "check": label,
        "checked": len(source_ids),
        "missing": len(missing),
        "status": "PASS" if len(missing) == 0 else "FAIL",
        "details": missing[:5] if missing else [],
    }


def check_file_exists(paths, label):
    missing = []
    for p in paths:
        if p and not os.path.exists(p):
            missing.append(p)
    return {
        "check": label,
        "checked": len(paths),
        "missing": len(missing),
        "status": "PASS" if len(missing) == 0 else "FAIL",
        "details": missing[:5] if missing else [],
    }


def main():
    print("=" * 70)
    print("STAGE 2 RELEASE GATE — FULL INTEGRITY AUDIT")
    print("=" * 70)

    t0 = time.perf_counter()
    concepts_doc, facts_doc, relations_doc, evidence_doc, symbols_doc, index_doc = load_all()
    load_ms = (time.perf_counter() - t0) * 1000

    concepts = concepts_doc["items"]
    facts = facts_doc["items"]
    relations = relations_doc["items"]
    evidence = evidence_doc["items"]
    symbols = symbols_doc["items"]
    files = index_doc["files"]

    print(f"\nLoad: {load_ms:.0f} ms")
    print(f"  concepts:     {len(concepts)}")
    print(f"  facts:        {len(facts)}")
    print(f"  relations:    {len(relations)}")
    print(f"  evidence:     {len(evidence)}")
    print(f"  symbols:      {len(symbols)}")
    print(f"  files:        {len(files)}")

    results = []
    all_pass = True

    def run(check):
        results.append(check)
        status = check["status"]
        mark = "PASS" if status == "PASS" else "FAIL"
        if status == "FAIL":
            global all_pass
            all_pass = False
        details = check.get("details", [])
        detail_str = f" {details}" if details else ""
        print(f"  [{mark}] {check['check']}{detail_str}")

    print("\n--- UNIQUE IDS ---")
    run(check_unique(concepts, "concept_id", "concept"))
    run(check_unique(facts, "fact_id", "fact"))
    run(check_unique(relations, "relation_id", "relation"))
    run(check_unique(evidence, "id", "evidence"))
    run(check_unique(symbols, "symbol_id", "symbol"))
    run(check_unique(files, "id", "file"))

    file_ids = {f["id"] for f in files}
    concept_ids = {c["concept_id"] for c in concepts}
    fact_ids = {f["fact_id"] for f in facts}
    evidence_ids = {e["id"] for e in evidence}
    symbol_ids = {s["symbol_id"] for s in symbols}

    print("\n--- CONCEPT REFS ---")
    run(check_ref("concept.file_id -> files",
                  [c.get("file_id") for c in concepts], file_ids))
    run(check_ref("concept.evidence_ids -> evidence",
                  [eid for c in concepts for eid in c.get("evidence_ids", [])],
                  evidence_ids))
    run(check_ref("concept.fact_ids -> facts",
                  [fid for c in concepts for fid in c.get("fact_ids", [])],
                  fact_ids))
    run(check_ref("concept.source_symbol_ids -> symbols",
                  [sid for c in concepts for sid in c.get("source_symbol_ids", [])],
                  symbol_ids))

    print("\n--- FACT REFS ---")
    run(check_ref("fact.evidence_id -> evidence",
                  [f.get("evidence_id") for f in facts], evidence_ids))
    run(check_ref("fact.subject_id -> symbols|files",
                  [f.get("subject_id") for f in facts],
                  symbol_ids | file_ids, allow_empty=True))
    run(check_ref("fact.object_id -> symbols|files",
                  [f.get("object_id") for f in facts if f.get("object_id")],
                  symbol_ids | file_ids, allow_empty=True))

    print("\n--- RELATION REFS ---")
    run(check_ref("relation.from_concept -> concepts",
                  [r.get("from_concept") for r in relations], concept_ids))
    run(check_ref("relation.to_concept -> concepts",
                  [r.get("to_concept") for r in relations], concept_ids))
    run(check_ref("relation.evidence_fact_ids -> facts",
                  [fid for r in relations for fid in r.get("evidence_fact_ids", [])],
                  fact_ids))

    print("\n--- SYMBOL REFS ---")
    run(check_ref("symbol.file_id -> files",
                  [s.get("file_id") for s in symbols], file_ids))
    run(check_ref("symbol.evidence_id -> evidence",
                  [s.get("evidence_id") for s in symbols if s.get("evidence_id")],
                  evidence_ids))

    print("\n--- EVIDENCE REFS ---")
    run(check_ref("evidence.file_id -> files",
                  [e.get("file_id") for e in evidence], file_ids))

    print("\n--- SOURCE FILES EXIST ---")
    concept_files = list({c.get("source_files", [""])[0]
                         for c in concepts if c.get("source_files")})
    fact_files = list({f.get("source_file", "") for f in facts if f.get("source_file")})
    evidence_files = list({e.get("source_file", "") for e in evidence
                          if e.get("source_file")})
    all_files = list(set(concept_files + fact_files + evidence_files))
    run(check_file_exists(all_files, "source files on disk"))

    print("\n--- ORPHAN AUDIT ---")
    symbols_by_file = set(s.get("file_id", "") for s in symbols)
    orphan_symbols = [s["symbol_id"] for s in symbols
                      if s.get("file_id") and s["file_id"] not in file_ids]
    run({"check": "orphan symbols (file_id not in files)",
         "total": len(symbols), "orphan": len(orphan_symbols),
         "status": "PASS" if len(orphan_symbols) == 0 else "FAIL",
         "details": orphan_symbols[:5]})

    facts_by_symbol = set()
    for f in facts:
        if f.get("subject_id"):
            facts_by_symbol.add(f["subject_id"])
        if f.get("object_id"):
            facts_by_symbol.add(f["object_id"])
    orphan_facts = [f["fact_id"] for f in facts
                    if f.get("subject_id")
                    and f["subject_id"] not in symbol_ids
                    and f["subject_id"] not in file_ids]
    run({"check": "orphan facts (subject_id not in symbols)",
         "total": len(facts), "orphan": len(orphan_facts),
         "status": "PASS" if len(orphan_facts) == 0 else "FAIL",
         "details": orphan_facts[:5]})

    print("\n" + "=" * 70)
    passed = sum(1 for r in results if r["status"] == "PASS")
    failed = sum(1 for r in results if r["status"] == "FAIL")
    print(f"RESULT: {passed}/{len(results)} PASS, {failed} FAIL")
    print(f"STATUS: {'ALL PASS' if all_pass else 'GATE FAILED'}")
    print("=" * 70)

    with open(MEMORY_DIR / "integrity_audit.json", "w") as f:
        json.dump({
            "timestamp": time.time(),
            "results": results,
            "passed": passed,
            "failed": failed,
            "all_pass": all_pass,
        }, f, indent=2)
    print(f"Saved: memory/integrity_audit.json")

    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
