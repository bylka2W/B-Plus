import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import load_json, CONCEPTS_PATH, FACTS_PATH, SEMANTIC_RELATIONS_PATH
from graph import KnowledgeGraph
from search import Search
from source_store import SourceStore


class FastIndex:
    def __init__(self):
        self.concepts = {}
        self.symbols = {}
        self.evidence = {}
        self.facts = {}
        self.relations = {}

        self.concept_by_id = {}
        self.symbol_by_id = {}
        self.evidence_by_id = {}
        self.fact_by_id = {}
        self.relation_by_id = {}

        self.concept_by_name = {}
        self.concept_by_name_lower = {}
        self.symbol_by_name = {}
        self.symbol_by_name_lower = {}
        self.file_by_id = {}
        self.file_by_path = {}
        self.file_by_base = {}

        self.facts_by_subject = {}
        self.facts_by_object = {}
        self.facts_by_type = {}

        self.relations_by_source = {}
        self.relations_by_target = {}
        self.relations_by_type = {}

        self.callers = {}
        self.callees = {}
        self.references = {}
        self.referenced_by = {}
        self.types_used = {}
        self.type_users = {}
        self.dependencies = {}
        self.dependents = {}
        self.contains = {}

        self.concept_evidence = {}
        self.concept_module = {}
        self.module_concepts = {}
        self.file_to_module = {}

        self._loaded = False
        self._load_time_ms = 0.0

    def load(self):
        if self._loaded:
            return self
        t0 = time.monotonic()

        concepts_doc = load_json(CONCEPTS_PATH)
        facts_doc = load_json(FACTS_PATH)
        relations_doc = load_json(SEMANTIC_RELATIONS_PATH)
        store = SourceStore.load()
        kg = KnowledgeGraph.load()

        for c in concepts_doc["items"]:
            cid = c["concept_id"]
            self.concept_by_id[cid] = c
            name = c["canonical_name"]
            self.concept_by_name.setdefault(name, []).append(cid)
            self.concept_by_name_lower.setdefault(name.lower(), []).append(cid)

        for s in store.symbols_doc["items"]:
            sid = s["symbol_id"]
            self.symbol_by_id[sid] = s
            name = s["name"]
            self.symbol_by_name.setdefault(name, []).append(sid)
            self.symbol_by_name_lower.setdefault(name.lower(), []).append(sid)

        for e in store.evidence_doc["items"]:
            eid = e["id"]
            self.evidence_by_id[eid] = e

        for f in facts_doc["items"]:
            fid = f["fact_id"]
            self.fact_by_id[fid] = f
            subj = f.get("subject_id", "")
            obj = f.get("object_id", "")
            ftype = f.get("fact_type", "")
            self.facts_by_subject.setdefault(subj, []).append(fid)
            if obj:
                self.facts_by_object.setdefault(obj, []).append(fid)
            self.facts_by_type.setdefault(ftype, []).append(fid)

        for r in relations_doc["items"]:
            rid = r["relation_id"]
            self.relation_by_id[rid] = r
            src = r.get("from_concept", "")
            tgt = r.get("to_concept", "")
            rtype = r.get("relation_type", "")
            self.relations_by_source.setdefault(src, []).append(rid)
            if tgt:
                self.relations_by_target.setdefault(tgt, []).append(rid)
            self.relations_by_type.setdefault(rtype, []).append(rid)

        idx = kg.idx
        self.callers = idx.get("callers", {})
        self.callees = idx.get("callees", {})
        self.references = idx.get("references", {})
        self.referenced_by = idx.get("referenced_by", {})
        self.types_used = idx.get("types_used", {})
        self.type_users = idx.get("type_users", {})
        self.dependencies = idx.get("dependencies", {})
        self.dependents = idx.get("dependents", {})
        self.contains = idx.get("contains", {})
        self.concept_evidence = idx.get("concept_evidence", {})
        self.concept_module = idx.get("concept_module", {})
        self.module_concepts = idx.get("module_concepts", {})

        for cid, mid in self.concept_module.items():
            c = self.concept_by_id.get(cid)
            if c:
                fid = c.get("file_id", "")
                if fid:
                    self.file_to_module[fid] = mid

        for path, entry in store.files_by_path.items():
            self.file_by_id[entry["id"]] = entry
            self.file_by_path[path] = entry
            base = path.replace("\\", "/").rsplit("/", 1)[-1]
            if base not in self.file_by_base:
                self.file_by_base[base] = entry

        self.concepts = self.concept_by_id
        self.symbols = self.symbol_by_id
        self.evidence = self.evidence_by_id
        self.facts = self.fact_by_id
        self.relations = self.relation_by_id

        self._loaded = True
        self._load_time_ms = round((time.monotonic() - t0) * 1000, 2)
        return self

    def resolve_concept(self, name):
        cids = self.concept_by_name.get(name)
        if cids:
            return cids
        cids = self.concept_by_name_lower.get(name.lower())
        if cids:
            return cids
        return []

    def resolve_symbol(self, name):
        sids = self.symbol_by_name.get(name)
        if sids:
            return sids
        sids = self.symbol_by_name_lower.get(name.lower())
        if sids:
            return sids
        return []

    def get_callers(self, concept_id):
        return self.callers.get(concept_id, [])

    def get_callees(self, concept_id):
        return self.callees.get(concept_id, [])

    def get_references(self, concept_id):
        return self.references.get(concept_id, [])

    def get_referenced_by(self, concept_id):
        return self.referenced_by.get(concept_id, [])

    def get_types_used(self, concept_id):
        return self.types_used.get(concept_id, [])

    def get_type_users(self, type_id):
        return self.type_users.get(type_id, [])

    def get_dependencies(self, module_id):
        return self.dependencies.get(module_id, [])

    def get_dependents(self, module_id):
        return self.dependents.get(module_id, [])

    def get_contains(self, container_id):
        return self.contains.get(container_id, [])

    def get_facts_by_subject(self, subject_id):
        return self.facts_by_subject.get(subject_id, [])

    def get_facts_by_object(self, object_id):
        return self.facts_by_object.get(object_id, [])

    def get_facts_by_type(self, fact_type):
        return self.facts_by_type.get(fact_type, [])

    def get_relations_by_source(self, source_id):
        return self.relations_by_source.get(source_id, [])

    def get_relations_by_target(self, target_id):
        return self.relations_by_target.get(target_id, [])

    def get_relations_by_type(self, relation_type):
        return self.relations_by_type.get(relation_type, [])

    def get_evidence(self, evidence_id):
        return self.evidence_by_id.get(evidence_id)

    def get_concept_evidence(self, concept_id):
        return self.concept_evidence.get(concept_id, [])

    def get_module_of(self, concept_id):
        return self.concept_module.get(concept_id)

    def get_module_concepts(self, module_id):
        return self.module_concepts.get(module_id, [])

    def stats(self):
        return {
            "concepts": len(self.concept_by_id),
            "symbols": len(self.symbol_by_id),
            "evidence": len(self.evidence_by_id),
            "facts": len(self.fact_by_id),
            "relations": len(self.relation_by_id),
            "files": len(self.file_by_id),
            "callers_keys": len(self.callers),
            "callees_keys": len(self.callees),
            "facts_by_subject_keys": len(self.facts_by_subject),
            "relations_by_source_keys": len(self.relations_by_source),
            "load_time_ms": self._load_time_ms,
        }


_instance = None


def get_fast_index():
    global _instance
    if _instance is None:
        _instance = FastIndex()
        _instance.load()
    return _instance


def main():
    idx = get_fast_index()
    print("FAST INDEX READY")
    for k, v in idx.stats().items():
        print(f"  {k}: {v}")

    t0 = time.monotonic()
    for _ in range(1000):
        idx.resolve_concept("foldConstantOp")
    elapsed = (time.monotonic() - t0) * 1000
    print(f"\n1000x resolve_concept: {elapsed:.2f}ms ({elapsed/1000*1000:.3f}us each)")

    cids = idx.resolve_concept("foldConstantOp")
    if cids:
        cid = cids[0]
        callers = idx.get_callers(cid)
        callees = idx.get_callees(cid)
        ev_ids = idx.get_concept_evidence(cid)
        print(f"\nfoldConstantOp:")
        print(f"  callers: {callers}")
        print(f"  callees: {callees}")
        print(f"  evidence: {ev_ids}")
    sys.exit(0)


if __name__ == "__main__":
    main()
