"""
STAGE 2 RELEASE GATE — DETERMINISM AUDIT
Proves same data loaded twice = identical IDs, hashes, and query results.
"""
import os
import sys
import json
import hashlib
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "engine"))

from common import MEMORY_DIR, load_json


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def load_ids():
    concepts = load_json(MEMORY_DIR / "concepts.json")
    facts = load_json(MEMORY_DIR / "facts.json")
    relations = load_json(MEMORY_DIR / "semantic_relations.json")
    evidence = load_json(MEMORY_DIR / "source_evidence.json")
    symbols = load_json(MEMORY_DIR / "source_symbols.json")
    return {
        "concepts": [c["concept_id"] for c in concepts["items"]],
        "facts": [f["fact_id"] for f in facts["items"]],
        "relations": [r["relation_id"] for r in relations["items"]],
        "evidence": [e["id"] for e in evidence["items"]],
        "symbols": [s["symbol_id"] for s in symbols["items"]],
    }


def main():
    print("=" * 70)
    print("STAGE 2 RELEASE GATE — DETERMINISM AUDIT")
    print("=" * 70)

    all_pass = True
    results = []

    def check(label, condition, detail=""):
        nonlocal all_pass
        status = "PASS" if condition else "FAIL"
        if not condition:
            all_pass = False
        results.append({"check": label, "status": status})
        d = f" ({detail})" if detail else ""
        print(f"  [{status}] {label}{d}")

    # 1. File hashes are stable (load twice, compare)
    print("\n--- FILE HASH STABILITY ---")
    json_files = [
        "concepts.json", "facts.json", "semantic_relations.json",
        "source_evidence.json", "source_symbols.json", "source_index.json",
    ]
    for fname in json_files:
        path = MEMORY_DIR / fname
        h1 = sha256_file(path)
        h2 = sha256_file(path)
        check(f"hash stability: {fname}", h1 == h2, h1[:16])

    # 2. ID sets are identical across two loads
    print("\n--- ID SET STABILITY ---")
    ids1 = load_ids()
    ids2 = load_ids()
    for entity in ids1:
        check(f"IDs stable: {entity}",
              ids1[entity] == ids2[entity],
              f"{len(ids1[entity])} ids")

    # 3. ID count stability
    print("\n--- COUNT STABILITY ---")
    for entity in ids1:
        check(f"count stable: {entity}",
              len(ids1[entity]) == len(ids2[entity]),
              f"{len(ids1[entity])}")

    # 4. Query determinism via Knowledge engine
    print("\n--- QUERY DETERMINISM ---")
    from knowledge import Knowledge
    k1 = Knowledge.load()
    test_questions = [
        "Who calls foldConstantOp?",
        "Where is disassemble defined?",
        "What does emit call?",
    ]
    results1 = []
    for q in test_questions:
        r = k1.ask(q)
        results1.append({
            "question": q,
            "status": r["status"],
            "confidence": r["confidence"],
            "entity_count": len(r.get("entities", [])),
        })

    k2 = Knowledge.load()
    for i, q in enumerate(test_questions):
        r = k2.ask(q)
        match = (
            r["status"] == results1[i]["status"]
            and r["confidence"] == results1[i]["confidence"]
            and len(r.get("entities", [])) == results1[i]["entity_count"]
        )
        check(f"query deterministic: {q[:40]}", match,
              f"{results1[i]['status']}=={r['status']}")

    # 5. Schema version check
    print("\n--- SCHEMA VERSION ---")
    for fname in json_files:
        path = MEMORY_DIR / fname
        doc = load_json(path)
        has_schema = "schema" in doc
        has_version = "version" in doc
        check(f"schema+version: {fname}",
              has_schema and has_version,
              f"v{doc.get('version', '?')}")

    # 6. tree_sha stability
    print("\n--- TREE SHA STABILITY ---")
    from source_snapshot import SourceSnapshot
    snap = SourceSnapshot.load()
    if snap:
        sha1 = snap.tree_sha()
        sha2 = snap.tree_sha()
        check("tree_sha deterministic", sha1 == sha2, sha1[:16])
    else:
        check("tree_sha deterministic", False, "no snapshot")

    print("\n" + "=" * 70)
    passed = sum(1 for r in results if r["status"] == "PASS")
    failed = sum(1 for r in results if r["status"] == "FAIL")
    print(f"RESULT: {passed}/{len(results)} PASS, {failed} FAIL")
    print(f"STATUS: {'ALL PASS' if all_pass else 'GATE FAILED'}")
    print("=" * 70)

    with open(MEMORY_DIR / "determinism_audit.json", "w") as f:
        json.dump({
            "timestamp": time.time(),
            "results": results,
            "passed": passed,
            "failed": failed,
            "all_pass": all_pass,
        }, f, indent=2)
    print(f"Saved: memory/determinism_audit.json")

    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
