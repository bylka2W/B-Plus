import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import CONCEPTS_PATH, FACTS_PATH, SEMANTIC_RELATIONS_PATH, load_json
from graph import KnowledgeGraph
from query import QueryEngine
from relations import relation_id_for
from source_store import SourceStore

INTENT_RELATION = {
    "CALLERS": ("CALLS", "in"),
    "CALLEES": ("CALLS", "out"),
    "REFERENCES": ("REFERENCES", "out"),
    "USES_TYPE": ("USES_TYPE", "out"),
    "TYPE_USERS": ("USES_TYPE", "in"),
    "CONTAINS": ("CONTAINS", "out"),
    "DEPENDENCIES": ("DEPENDS_ON", "out"),
    "DEPENDENTS": ("DEPENDS_ON", "in"),
}


class ContextBuilder:
    def __init__(self, query_engine, facts_doc, relations_doc, store):
        self.qe = query_engine
        self.store = store
        self.facts = {f["fact_id"]: f for f in facts_doc["items"]}
        self.relations = {
            r["relation_id"]: r for r in relations_doc["items"]
        }
        self._file_names = {
            e["id"]: p.replace("\\", "/").rsplit("/", 1)[-1]
            for p, e in store.files_by_path.items()
        }
        self.knowledge = {
            "concepts": len(query_engine.search.concepts),
            "relations": len(self.relations),
            "facts": len(self.facts),
        }

    @classmethod
    def load(cls):
        qe = QueryEngine.load()
        facts_doc = load_json(FACTS_PATH)
        relations_doc = load_json(SEMANTIC_RELATIONS_PATH)
        store = SourceStore.load()
        return cls(qe, facts_doc, relations_doc, store)

    def _confidence(self, claims):
        if not claims:
            return "UNSUPPORTED"
        statuses = {c["status"] for c in claims}
        if statuses == {"VERIFIED"}:
            return "VERIFIED"
        if "VERIFIED" in statuses:
            return "PARTIAL"
        return "UNSUPPORTED"

    def _claims_for(self, cid, max_claims):
        c = self.qe.search.concepts.get(cid)
        if not c:
            return []
        out = []
        for fid in sorted(c["fact_ids"]):
            if len(out) >= max_claims:
                break
            f = self.facts.get(fid)
            if not f:
                continue
            subj = self.store.get_symbol(f["subject_id"])
            if subj is not None:
                subj_name = subj["name"]
            else:
                subj_name = self._file_names.get(
                    f["subject_id"], f["subject_id"]
                )
            obj = (
                self.store.get_symbol(f["object_id"])
                if f.get("object_id")
                else None
            )
            ev = self.store.evidence_by_id[f["evidence_id"]]
            out.append({
                "claim": (
                    f"{subj_name} {f['fact_type']} "
                    f"{obj['name'] if obj else f.get('object_value', '?')}"
                ),
                "fact_type": f["fact_type"],
                "fact_id": fid,
                "subject": subj_name,
                "object": obj["name"] if obj else f.get("object_value"),
                "status": f["verification_status"],
                "evidence_id": f["evidence_id"],
                "file": f["source_file"],
                "line_start": f["line_start"],
                "line_end": f["line_end"],
            })
        return out

    def _relation_ids(self, intent, target_cid, items, limit=20):
        spec = INTENT_RELATION.get(intent)
        if not spec:
            return []
        rel_type, direction = spec
        out = []
        for it in items:
            if len(out) >= limit:
                break
            other = it.get("concept_id")
            if not other:
                continue
            a, b = (
                (other, target_cid) if direction == "in"
                else (target_cid, other)
            )
            rid = relation_id_for(rel_type, a, b)
            if rid in self.relations:
                out.append({
                    "relation_id": rid,
                    "relation_type": rel_type,
                    "from_concept": a,
                    "to_concept": b,
                    "verification_status": self.relations[rid][
                        "verification_status"
                    ],
                })
        return out

    def _evidence_block(self, eids, max_evidence):
        seen = set()
        ordered = []
        for e in eids:
            if e not in seen:
                seen.add(e)
                ordered.append(e)
        out = []
        for eid in ordered[:max_evidence]:
            ev = self.store.evidence_by_id.get(eid)
            if not ev:
                continue
            out.append({
                "evidence_id": eid,
                "file": ev["source_file"],
                "line_start": ev["line_start"],
                "line_end": ev["line_end"],
                "sha256": ev["sha256"],
                "text": ev["text"],
            })
        return out

    def build(self, query_result, max_claims=20, max_evidence=8):
        targets = query_result.get("targets", [])
        target_cid = targets[0]["concept_id"] if targets else None
        anchor_eids = []
        if target_cid:
            anchor_eids = self.qe.search.kg.idx[
                "concept_evidence"
            ].get(target_cid, [])
        item_eids = []
        for it in query_result.get("items", []):
            icid = it.get("concept_id")
            if icid:
                item_eids.extend(
                    self.qe.search.kg.idx["concept_evidence"].get(icid, [])[:1]
                )
        claims = self._claims_for(target_cid, max_claims) if target_cid else []
        evidence_ids = anchor_eids + item_eids
        evidence = self._evidence_block(evidence_ids, max_evidence)
        relation_ids = (
            self._relation_ids(
                query_result["intent"], target_cid, query_result["items"]
            )
            if target_cid
            else []
        )
        return {
            "schema": "context_pack",
            "version": 1,
            "intent": query_result["intent"],
            "entity": query_result["entity"],
            "status": query_result["status"],
            "knowledge": self.knowledge,
            "target": targets[0] if targets else None,
            "count_items": query_result.get("count", 0),
            "items_head": query_result.get("items", [])[:10],
            "claims": claims,
            "relation_ids": relation_ids,
            "confidence": self._confidence(claims),
            "evidence": evidence,
        }


def main():
    cb = ContextBuilder.load()
    qr = cb.qe.query("DEFINITION", "foldConstantOp")
    pack = cb.build(qr)
    print("CONTEXT PACK READY")
    print(f"INTENT: {pack['intent']} STATUS: {pack['status']}")
    print(f"CLAIMS: {len(pack['claims'])} CONFIDENCE: {pack['confidence']}")
    print(f"EVIDENCE CHUNKS: {len(pack['evidence'])}")
    sys.exit(0)


if __name__ == "__main__":
    main()
