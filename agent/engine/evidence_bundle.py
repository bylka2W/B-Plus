import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ANSWER_READY = "ANSWER_READY"
NEEDS_DEEP_SEARCH = "NEEDS_DEEP_SEARCH"
UNKNOWN = "UNKNOWN"
PARTIAL = "PARTIAL"


class EvidenceBundle:
    def __init__(self, status, intent, entity, question, direct_answer,
                 answer_type, confidence, evidence, claims, relations,
                 entities, unresolved, limitations, provenance,
                 completeness, plan, routing_ms, query_ms, answer_ms,
                 total_ms):
        self.status = status
        self.intent = intent
        self.entity = entity
        self.question = question
        self.direct_answer = direct_answer
        self.answer_type = answer_type
        self.confidence = confidence
        self.evidence = evidence
        self.claims = claims
        self.relations = relations
        self.entities = entities
        self.unresolved = unresolved
        self.limitations = limitations
        self.provenance = provenance
        self.completeness = completeness
        self.plan = plan
        self.routing_ms = routing_ms
        self.query_ms = query_ms
        self.answer_ms = answer_ms
        self.total_ms = total_ms

    def to_dict(self):
        return {
            "schema": "evidence_bundle",
            "version": 1,
            "status": self.status,
            "intent": self.intent,
            "entity": self.entity,
            "question": self.question,
            "direct_answer": self.direct_answer,
            "answer_type": self.answer_type,
            "confidence": self.confidence,
            "completeness": self.completeness,
            "evidence": self.evidence,
            "claims": self.claims,
            "relations": self.relations,
            "entities": self.entities,
            "unresolved": self.unresolved,
            "limitations": self.limitations,
            "provenance": self.provenance,
            "plan": self.plan,
            "telemetry": {
                "routing_ms": round(self.routing_ms, 1),
                "query_ms": round(self.query_ms, 1),
                "answer_ms": round(self.answer_ms, 1),
                "total_ms": round(self.total_ms, 1),
            },
        }


SIMPLE_INTENTS = {
    "DEFINITION", "MODULE", "FILE",
}

DIRECT_INTENTS = {
    "CALLERS", "CALLEES", "REFERENCES", "USES_TYPE", "TYPE_USERS",
    "CONTAINS", "DEPENDENCIES", "DEPENDENTS",
}

CONTEXT_LIMITS = {
    "simple": {"max_evidence": 3, "max_claims": 5, "max_relations": 3,
               "max_items": 5, "max_tokens_estimate": 1500,
               "max_output_tokens": 300},
    "normal": {"max_evidence": 6, "max_claims": 10, "max_relations": 8,
               "max_items": 10, "max_tokens_estimate": 4000,
               "max_output_tokens": 800},
    "complex": {"max_evidence": 12, "max_claims": 20, "max_relations": 20,
                "max_items": 20, "max_tokens_estimate": 12000,
                "max_output_tokens": 2000},
    "hard": {"max_evidence": 20, "max_claims": 40, "max_relations": 40,
             "max_items": 40, "max_tokens_estimate": 25000,
             "max_output_tokens": 4000},
}

SIMPLE_ROUTING_MS = 50
NORMAL_ROUTING_MS = 200


def classify_complexity(intent, result_count, has_evidence):
    if intent in SIMPLE_INTENTS and result_count <= 3 and has_evidence:
        return "simple"
    if intent in DIRECT_INTENTS and result_count <= 10 and has_evidence:
        return "simple"
    if result_count > 20 or not has_evidence:
        return "complex"
    return "normal"


def build_evidence_bundle(k, question, start_time=None):
    t0 = start_time or time.monotonic()

    t_route = time.monotonic()
    d = k.route(question)
    routing_ms = (time.monotonic() - t_route) * 1000

    status_raw = d["status"]
    intent = d.get("intent")
    entity = d.get("entity")

    if status_raw == "UNKNOWN_INTENT":
        elapsed = (time.monotonic() - t0) * 1000
        return EvidenceBundle(
            status=UNKNOWN, intent=intent, entity=entity,
            question=question, direct_answer=None,
            answer_type="EMPTY", confidence="UNSUPPORTED",
            evidence=[], claims=[], relations=[], entities=[],
            unresolved=[], limitations=[
                f"unknown intent for question"
            ],
            provenance={"engine": "bplus-knowledge-engine",
                         "read_only": True},
            completeness=UNKNOWN, plan=None,
            routing_ms=routing_ms, query_ms=0, answer_ms=0,
            total_ms=elapsed,
        )

    if status_raw in ("ENTITY_NOT_FOUND", "AMBIGUOUS_ENTITY"):
        if status_raw == "ENTITY_NOT_FOUND":
            from answer import INTENT_TYPE_MAP, _type_mismatch
            expected_types = INTENT_TYPE_MAP.get(intent)
            if expected_types:
                alt = k.router.search.find_symbol(entity)
                if alt["status"] == "RESOLVED" and alt.get("targets"):
                    actual_type = alt["targets"][0].get("concept_type", "")
                    mm = _type_mismatch(intent, actual_type)
                    if mm:
                        elapsed = (time.monotonic() - t0) * 1000
                        return EvidenceBundle(
                            status=NEEDS_DEEP_SEARCH,
                            intent=intent, entity=entity,
                            question=question, direct_answer=None,
                            answer_type="TYPE_MISMATCH",
                            confidence="UNSUPPORTED",
                            evidence=[], claims=[], relations=[],
                            entities=[], unresolved=[],
                            limitations=[mm],
                            provenance={"engine": "bplus-knowledge-engine",
                                         "read_only": True},
                            completeness=NEEDS_DEEP_SEARCH, plan=None,
                            routing_ms=routing_ms, query_ms=0, answer_ms=0,
                            total_ms=elapsed,
                        )
        elapsed = (time.monotonic() - t0) * 1000
        return EvidenceBundle(
            status=NEEDS_DEEP_SEARCH if status_raw == "ENTITY_NOT_FOUND"
            else PARTIAL,
            intent=intent, entity=entity, question=question,
            direct_answer=None,
            answer_type="AMBIGUOUS_ENTITY" if status_raw == "AMBIGUOUS_ENTITY"
            else "EMPTY",
            confidence="UNSUPPORTED",
            evidence=[], claims=[], relations=[],
            entities=d.get("candidates", []),
            unresolved=[],
            limitations=[f"entity resolution: {status_raw}"],
            provenance={"engine": "bplus-knowledge-engine",
                         "read_only": True},
            completeness=NEEDS_DEEP_SEARCH, plan=None,
            routing_ms=routing_ms, query_ms=0, answer_ms=0,
            total_ms=elapsed,
        )

    t_query = time.monotonic()
    qr = k.cb.qe.query(intent, entity)
    query_ms = (time.monotonic() - t_query) * 1000

    if qr["status"] == "NOT_FOUND":
        elapsed = (time.monotonic() - t0) * 1000
        return EvidenceBundle(
            status=NEEDS_DEEP_SEARCH, intent=intent, entity=entity,
            question=question, direct_answer=None,
            answer_type="EMPTY", confidence="UNSUPPORTED",
            evidence=[], claims=[], relations=[], entities=[],
            unresolved=[],
            limitations=[f"entity '{entity}' not found in knowledge base"],
            provenance={"engine": "bplus-knowledge-engine",
                         "read_only": True},
            completeness=NEEDS_DEEP_SEARCH, plan=None,
            routing_ms=routing_ms, query_ms=query_ms, answer_ms=0,
            total_ms=elapsed,
        )

    t_answer = time.monotonic()
    m = k.ae.answer(intent, entity, question=question)
    answer_ms = (time.monotonic() - t_answer) * 1000

    has_evidence = bool(m.get("evidence"))
    result_count = len(m.get("entities", []))
    if result_count == 0:
        result_count = m.get("routing", {}).get("count", 0)
    complexity = classify_complexity(intent, result_count, has_evidence)
    limits = CONTEXT_LIMITS[complexity]

    total_ms = (time.monotonic() - t0) * 1000

    verification = m.get("confidence", "UNSUPPORTED")
    unresolved = m.get("unresolved", [])
    completeness = _assess_completeness(
        m.get("status"), verification, unresolved, has_evidence
    )

    plan = None
    if completeness == NEEDS_DEEP_SEARCH:
        plan = _suggest_plan(intent, entity, m)

    direct_answer = m.get("direct_answer")

    return EvidenceBundle(
        status=_bundle_status(completeness, verification),
        intent=intent, entity=entity, question=question,
        direct_answer=direct_answer,
        answer_type=m.get("answer_type", "EMPTY"),
        confidence=verification,
        evidence=m.get("evidence", [])[:limits["max_evidence"]],
        claims=m.get("facts", [])[:limits["max_claims"]],
        relations=m.get("relations", [])[:limits["max_relations"]],
        entities=m.get("entities", [])[:limits["max_items"]],
        unresolved=unresolved,
        limitations=m.get("limitations", []),
        provenance=m.get("provenance", {}),
        completeness=completeness, plan=plan,
        routing_ms=routing_ms, query_ms=query_ms,
        answer_ms=answer_ms, total_ms=total_ms,
    )


def _assess_completeness(status, verification, unresolved, has_evidence):
    if status == "UNKNOWN_INTENT":
        return UNKNOWN
    if status == "AMBIGUOUS":
        return PARTIAL
    if status == "TYPE_MISMATCH":
        return NEEDS_DEEP_SEARCH
    if status == "INVALID_EVIDENCE":
        return NEEDS_DEEP_SEARCH
    if not has_evidence:
        return NEEDS_DEEP_SEARCH
    if verification == "VERIFIED" and not unresolved:
        return ANSWER_READY
    if verification == "PARTIAL" and unresolved:
        return PARTIAL
    if verification == "VERIFIED":
        return ANSWER_READY
    return PARTIAL


def _bundle_status(completeness, verification):
    if completeness == ANSWER_READY:
        return ANSWER_READY
    if completeness == NEEDS_DEEP_SEARCH:
        return NEEDS_DEEP_SEARCH
    if completeness == UNKNOWN:
        return UNKNOWN
    return PARTIAL


def _suggest_plan(intent, entity, model):
    steps = []
    if not model.get("evidence"):
        steps.append("verify source evidence exists for entity")
    if model.get("unresolved"):
        steps.append("resolve unresolved facts")
    if model.get("confidence") != "VERIFIED":
        steps.append("re-verify with fresh source read")
    if not steps:
        return None
    return {
        "intent": intent,
        "entity": entity,
        "steps": steps,
        "tool_budget": {"max_search": 4, "max_source_read": 8,
                        "max_grep": 1},
    }


def format_compact(bundle):
    lines = [f"STATUS: {bundle.status}"]
    lines.append(f"INTENT: {bundle.intent} ENTITY: {bundle.entity}")
    lines.append(f"CONFIDENCE: {bundle.confidence}")
    lines.append(f"COMPLETENESS: {bundle.completeness}")
    if bundle.direct_answer:
        lines.append(f"ANSWER: {bundle.direct_answer}")
    if bundle.evidence:
        for ev in bundle.evidence[:3]:
            fp = ev.get("file", "").replace("\\", "/").rsplit("/", 1)[-1]
            lines.append(f"EVIDENCE: {fp}:{ev.get('line_start')}-{ev.get('line_end')}")
    if bundle.claims:
        for c in bundle.claims[:3]:
            lines.append(f"CLAIM: {c.get('claim', '')}")
    t = bundle.total_ms
    lines.append(f"TIME: {t:.0f}ms")
    return "\n".join(lines)


def main():
    from knowledge import Knowledge
    k = Knowledge.load()
    questions = [
        "Кто вызывает foldConstantOp?",
        "Где определён foldConstantOp?",
        "От чего зависит x64gen.zig?",
    ]
    for q in questions:
        t0 = time.monotonic()
        b = build_evidence_bundle(k, q, t0)
        print(format_compact(b))
        print("---")
    print("EVIDENCE BUNDLE MODULE READY")
    sys.exit(0)


if __name__ == "__main__":
    main()
