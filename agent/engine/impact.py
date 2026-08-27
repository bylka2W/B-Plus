import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import MEMORY_DIR, load_json, save_json

IMPACT_PATH = MEMORY_DIR / "impact_graph.json"


class ImpactGraph:
    def __init__(self, file_to_symbols=None, symbol_to_relations=None,
                 relation_to_facts=None, fact_to_concepts=None,
                 snapshot_id=None):
        self.file_to_symbols = file_to_symbols or {}
        self.symbol_to_relations = symbol_to_relations or {}
        self.relation_to_facts = relation_to_facts or {}
        self.fact_to_concepts = fact_to_concepts or {}
        self.snapshot_id = snapshot_id

    @classmethod
    def load(cls, path=None):
        path = Path(path or IMPACT_PATH)
        if not path.exists():
            return cls()
        doc = load_json(path)
        return cls(
            file_to_symbols=doc.get("file_to_symbols", {}),
            symbol_to_relations=doc.get("symbol_to_relations", {}),
            relation_to_facts=doc.get("relation_to_facts", {}),
            fact_to_concepts=doc.get("fact_to_concepts", {}),
            snapshot_id=doc.get("snapshot_id"),
        )

    def save(self, path=None):
        path = Path(path or IMPACT_PATH)
        doc = {
            "schema": "impact_graph",
            "version": 1,
            "snapshot_id": self.snapshot_id,
            "file_count": len(self.file_to_symbols),
            "symbol_count": len(self.symbol_to_relations),
            "relation_count": len(self.relation_to_facts),
            "fact_count": len(self.fact_to_concepts),
            "file_to_symbols": self.file_to_symbols,
            "symbol_to_relations": self.symbol_to_relations,
            "relation_to_facts": self.relation_to_facts,
            "fact_to_concepts": self.fact_to_concepts,
        }
        save_json(path, doc)

    def build_from_artifacts(self, snapshot_id=None):
        self.snapshot_id = snapshot_id
        self.file_to_symbols.clear()
        self.symbol_to_relations.clear()
        self.relation_to_facts.clear()
        self.fact_to_concepts.clear()

        symbols_doc = load_json(MEMORY_DIR / "source_symbols.json")
        relations_doc = load_json(MEMORY_DIR / "source_relations.json")
        facts_doc = load_json(MEMORY_DIR / "facts.json")
        concepts_doc = load_json(MEMORY_DIR / "concepts.json")

        for sym in symbols_doc.get("items", []):
            fp = sym["source_file"]
            self.file_to_symbols.setdefault(fp, []).append(sym["symbol_id"])

        for rel in relations_doc.get("items", []):
            sid = rel["source_symbol_id"]
            self.symbol_to_relations.setdefault(sid, []).append(rel["relation_id"])

        for fact in facts_doc.get("items", []):
            rid = fact.get("evidence_id", "")
            for rkey, rlist in self.symbol_to_relations.items():
                if fact.get("subject_id") == rkey or fact.get("object_id") == rkey:
                    for r in rlist:
                        self.relation_to_facts.setdefault(r, []).append(fact["fact_id"])
                    break

        for concept in concepts_doc.get("items", []):
            for fid in concept.get("source_fact_ids", []):
                self.fact_to_concepts.setdefault(fid, []).append(concept["concept_id"])

    def impact_for_file(self, file_path):
        symbols = self.file_to_symbols.get(file_path, [])
        relations = []
        for sid in symbols:
            relations.extend(self.symbol_to_relations.get(sid, []))
        facts = []
        for rid in relations:
            facts.extend(self.relation_to_facts.get(rid, []))
        concepts = []
        for fid in facts:
            concepts.extend(self.fact_to_concepts.get(fid, []))

        affected_symbols = set()
        for sid in symbols:
            affected_symbols.add(sid)
        affected_relations = set()
        for rid in relations:
            affected_relations.add(rid)
        affected_facts = set()
        for fid in facts:
            affected_facts.add(fid)
        affected_concepts = set()
        for cid in concepts:
            affected_concepts.add(cid)

        return {
            "file": file_path,
            "symbols": sorted(affected_symbols),
            "relations": sorted(affected_relations),
            "facts": sorted(affected_facts),
            "concepts": sorted(affected_concepts),
            "cascade_depth": self._cascade_depth(file_path),
            "total_affected": (len(affected_symbols) + len(affected_relations)
                               + len(affected_facts) + len(affected_concepts)),
        }

    def impact_for_files(self, file_paths):
        all_symbols = set()
        all_relations = set()
        all_facts = set()
        all_concepts = set()
        for fp in file_paths:
            imp = self.impact_for_file(fp)
            all_symbols.update(imp["symbols"])
            all_relations.update(imp["relations"])
            all_facts.update(imp["facts"])
            all_concepts.update(imp["concepts"])
        return {
            "files": sorted(file_paths),
            "symbols": sorted(all_symbols),
            "relations": sorted(all_relations),
            "facts": sorted(all_facts),
            "concepts": sorted(all_concepts),
            "total_affected": (len(all_symbols) + len(all_relations)
                               + len(all_facts) + len(all_concepts)),
        }

    def _cascade_depth(self, file_path):
        symbols = self.file_to_symbols.get(file_path, [])
        if not symbols:
            return 0
        relations = []
        for sid in symbols:
            relations.extend(self.symbol_to_relations.get(sid, []))
        if not relations:
            return 1
        facts = []
        for rid in relations:
            facts.extend(self.relation_to_facts.get(rid, []))
        if not facts:
            return 2
        concepts = []
        for fid in facts:
            concepts.extend(self.fact_to_concepts.get(fid, []))
        return 3 if concepts else 2

    def stats(self):
        return {
            "files": len(self.file_to_symbols),
            "symbols": len(self.symbol_to_relations),
            "relations": len(self.relation_to_facts),
            "facts": len(self.fact_to_concepts),
            "snapshot_id": self.snapshot_id,
        }


def main():
    graph = ImpactGraph.load()
    if not graph.file_to_symbols:
        graph.build_from_artifacts()
        graph.save()
    print("IMPACT GRAPH:", graph.stats())
    sys.exit(0)


if __name__ == "__main__":
    main()
