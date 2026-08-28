import io
import json
import os
import sys
import time
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import source_coverage as sc

MEMORY = r"C:\B-Plus\agent\memory"
TRUTH_ROOT = r"C:\Users\Local\zig"
OUT_DIR = os.path.join(MEMORY, "full_zig")
LIMIT = int(sys.argv[1]) if len(sys.argv) > 1 else 0  # 0 = all


def save_json(path, data):
    tmp = path + ".tmp"
    with io.open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def main():
    t0 = time.time()
    files = sc.iter_zig_files(TRUTH_ROOT)
    if LIMIT:
        files = files[:LIMIT]
    print(f"scanning {len(files)} files under {TRUTH_ROOT}")

    symbol_items = []
    evidence_items = []
    fact_items = []
    concept_items = []
    relation_items = []
    index_files = []

    digest_by_file = {}
    units_by_file = {}

    file_seq = 0
    for path in files:
        digest = sc.sha256_file(path)
        digest_by_file[path] = digest
        units, total = sc.extract_file(path, digest)
        units_by_file[path] = units
        file_seq += 1
        fid = sc.short_id("FI", path, digest)
        index_files.append({
            "id": fid,
            "path": path,
            "sha256": digest,
            "root": sc.find_root(path),
            "tier": sc.evidence_tier(sc.find_root(path)),
            "line_count": total,
            "symbol_count": len(units),
        })

        file_concept_id = sc.short_id("CN", path, digest)
        concept_items.append({
            "concept_id": file_concept_id,
            "name": os.path.basename(path),
            "kind": "file",
            "source_file": path,
            "root": sc.find_root(path),
            "tier": "truth",
            "line_start": 1,
            "line_end": total,
            "evidence_id": None,
            "verification_status": "VERIFIED",
        })

        # facts / symbols / evidence
        for u in units:
            symbol_items.append({
                "symbol_id": u["symbol_id"],
                "name": u["name"],
                "kind": u["kind"],
                "source_file": u["source_file"],
                "root": u["root"],
                "file_id": u["file_id"],
                "line_start": u["line_start"],
                "line_end": u["line_end"],
                "evidence_id": u["evidence_id"],
                "signature": u["signature"],
                "tier": "truth",
                "verification_status": "VERIFIED",
            })
            # FACT: FILE DECLARES SYMBOL
            fact_items.append({
                "fact_id": sc.short_id("FACT", u["symbol_id"], "DECLARES"),
                "fact_type": u["kind"],
                "predicate": "DECLARES",
                "subject_id": file_concept_id,
                "object_id": u["symbol_id"],
                "evidence_id": u["evidence_id"],
                "source_file": u["source_file"],
                "root": u["root"],
                "tier": "truth",
                "line_start": u["line_start"],
                "line_end": u["line_end"],
                "verification_status": "VERIFIED",
            })
            # concept for the symbol
            concept_items.append({
                "concept_id": u["symbol_id"],
                "name": u["name"],
                "kind": u["kind"],
                "source_file": u["source_file"],
                "root": u["root"],
                "tier": "truth",
                "line_start": u["line_start"],
                "line_end": u["line_end"],
                "evidence_id": u["evidence_id"],
                "verification_status": "VERIFIED",
            })
            # relation FILE CONTAINS SYMBOL
            relation_items.append({
                "relation_id": sc.short_id("SR", file_concept_id, u["symbol_id"], "CONTAINS"),
                "relation_type": "CONTAINS",
                "from_concept": file_concept_id,
                "to_concept": u["symbol_id"],
                "evidence_fact_ids": [sc.short_id("FACT", u["symbol_id"], "DECLARES")],
                "verification_status": "VERIFIED",
            })
            # doc comment concept + relation
            if u["doc"]:
                doc_cid = sc.short_id("CN", u["symbol_id"], "doc")
                concept_items.append({
                    "concept_id": doc_cid,
                    "name": u["name"] + "::doc",
                    "kind": "doc_comment",
                    "source_file": u["source_file"],
                    "root": u["root"],
                    "tier": "truth",
                    "line_start": u["doc"].get("start") if isinstance(u["doc"], dict) else 1,
                    "line_end": u["doc"].get("end") if isinstance(u["doc"], dict) else 1,
                    "evidence_id": u["evidence_id"],
                    "verification_status": "VERIFIED",
                })
                relation_items.append({
                    "relation_id": sc.short_id("SR", u["symbol_id"], doc_cid, "DOCUMENTED_BY"),
                    "relation_type": "DOCUMENTED_BY",
                    "from_concept": u["symbol_id"],
                    "to_concept": doc_cid,
                    "evidence_fact_ids": [sc.short_id("FACT", u["symbol_id"], "DECLARES")],
                    "verification_status": "VERIFIED",
                })
            # imports relation target_file
            if u["kind"] == "import":
                relation_items.append({
                    "relation_id": sc.short_id("SR", file_concept_id, u["symbol_id"], "IMPORTS"),
                    "relation_type": "IMPORTS",
                    "from_concept": file_concept_id,
                    "to_concept": u["symbol_id"],
                    "target_file": None,
                    "evidence_fact_ids": [sc.short_id("FACT", u["symbol_id"], "DECLARES")],
                    "verification_status": "VERIFIED",
                })

    evidence_items = sc.build_evidence(units_by_file, digest_by_file)

    os.makedirs(OUT_DIR, exist_ok=True)
    save_json(os.path.join(OUT_DIR, "source_index.json"), {
        "schema": "source_index", "version": 1, "root": TRUTH_ROOT,
        "tier": "truth", "file_count": len(index_files), "files": index_files})
    save_json(os.path.join(OUT_DIR, "source_symbols.json"), {
        "schema": "source_symbols", "version": 1, "root": TRUTH_ROOT,
        "tier": "truth", "symbol_count": len(symbol_items), "items": symbol_items})
    save_json(os.path.join(OUT_DIR, "source_evidence.json"), {
        "schema": "source_evidence", "version": 1, "root": TRUTH_ROOT,
        "tier": "truth", "evidence_count": len(evidence_items), "items": evidence_items})
    save_json(os.path.join(OUT_DIR, "facts.json"), {
        "schema": "facts", "version": 1, "root": TRUTH_ROOT,
        "tier": "truth", "fact_count": len(fact_items), "items": fact_items})
    save_json(os.path.join(OUT_DIR, "concepts.json"), {
        "schema": "concepts", "version": 1, "root": TRUTH_ROOT,
        "tier": "truth", "concept_count": len(concept_items), "items": concept_items})
    save_json(os.path.join(OUT_DIR, "semantic_relations.json"), {
        "schema": "semantic_relations", "version": 1, "root": TRUTH_ROOT,
        "tier": "truth", "relation_count": len(relation_items), "items": relation_items})
    save_json(os.path.join(OUT_DIR, "graph.json"), {
        "schema": "graph", "version": 1, "root": TRUTH_ROOT, "tier": "truth",
        "nodes": len(concept_items), "edges": len(relation_items)})

    print(f"DONE in {time.time()-t0:.1f}s")
    print(f"  files={len(index_files)} symbols={len(symbol_items)} "
          f"evidence={len(evidence_items)} facts={len(fact_items)} "
          f"concepts={len(concept_items)} relations={len(relation_items)}")
    for f in sorted(os.listdir(OUT_DIR)):
        print(f"  {f:22s} {round(os.path.getsize(os.path.join(OUT_DIR,f))/1e6,2)}MB")


if __name__ == "__main__":
    main()
