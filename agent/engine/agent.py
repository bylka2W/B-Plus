import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from knowledge import Knowledge
from protocol import QueryProtocol, is_terminal, CONTEXT_PACK_TEMPLATES
from query_cache import QueryCache
from source_snapshot import SourceSnapshot
from telemetry import Telemetry
from indexes import get_fast_index

TERMINAL_CONFIDENCE = {"VERIFIED"}

MODE_FACT = "FACT"
MODE_DEFINITION = "DEFINITION"
MODE_RELATION = "RELATION"
MODE_TRACE = "TRACE"
MODE_SOURCE = "SOURCE"
MODE_EXPLAIN = "EXPLAIN"
MODE_DEEP = "DEEP"

SUPPORTED_MODES = {
    MODE_FACT, MODE_DEFINITION, MODE_RELATION,
    MODE_TRACE, MODE_SOURCE, MODE_EXPLAIN, MODE_DEEP,
}

FAST_INTENTS = {
    "DEFINITION", "CALLERS", "CALLEES", "REFERENCES",
    "CONTAINS", "DEPENDENCIES", "DEPENDENTS", "MODULE", "FILE",
    "USES_TYPE", "TYPE_USERS",
}


def _compact_evidence(evidence, max_items=3, max_text_chars=200):
    out = []
    for ev in evidence[:max_items]:
        f = ev.get("file", "").replace("\\", "/").rsplit("/", 1)[-1]
        ls = ev.get("line_start", "?")
        le = ev.get("line_end", "?")
        text = ev.get("text", "")[:max_text_chars]
        out.append({
            "file": f,
            "line_start": ls,
            "line_end": le,
            "text": text,
            "sha256": ev.get("sha256", ""),
        })
    return out


def _compact_relations(relations, max_items=10):
    out = []
    for r in relations[:max_items]:
        out.append({
            "type": r.get("relation_type", "?"),
            "from": r.get("from_concept", "?"),
            "to": r.get("to_concept", "?"),
            "status": r.get("verification_status", "?"),
        })
    return out


def _compact_entities(entities, max_items=5):
    out = []
    for e in entities[:max_items]:
        out.append({
            "name": e.get("name", "?"),
            "type": e.get("concept_type", "?"),
            "file": e.get("file", "").replace("\\", "/").rsplit("/", 1)[-1],
            "line_start": e.get("line_start"),
            "line_end": e.get("line_end"),
        })
    return out


class AnswerPacket:
    __slots__ = (
        "status", "confidence", "terminal", "entity", "intent",
        "answer_type", "direct_answer", "evidence", "relations",
        "entities", "limitations", "elapsed_ms", "cache_hit",
        "query_signature", "fast_path",
    )

    def __init__(self):
        self.status = "UNKNOWN"
        self.confidence = "UNSUPPORTED"
        self.terminal = False
        self.entity = ""
        self.intent = ""
        self.answer_type = ""
        self.direct_answer = None
        self.evidence = []
        self.relations = []
        self.entities = []
        self.limitations = []
        self.elapsed_ms = 0.0
        self.cache_hit = False
        self.query_signature = ""
        self.fast_path = False

    def to_dict(self):
        return {
            "status": self.status,
            "confidence": self.confidence,
            "terminal": self.terminal,
            "entity": self.entity,
            "intent": self.intent,
            "answer_type": self.answer_type,
            "direct_answer": self.direct_answer,
            "evidence": self.evidence,
            "relations": self.relations,
            "entities": self.entities,
            "limitations": self.limitations,
            "elapsed_ms": self.elapsed_ms,
            "cache_hit": self.cache_hit,
            "query_signature": self.query_signature,
            "fast_path": self.fast_path,
        }

    def to_context(self):
        lines = []
        lines.append("STATUS: %s" % self.status)
        lines.append("CONFIDENCE: %s" % self.confidence)
        lines.append("ENTITY: %s" % self.entity)
        lines.append("INTENT: %s" % self.intent)
        if self.direct_answer:
            lines.append("ANSWER: %s" % self.direct_answer)
        if self.evidence:
            lines.append("EVIDENCE:")
            for ev in self.evidence[:3]:
                lines.append("  %s:%s-%s" % (
                    ev["file"], ev["line_start"], ev["line_end"]))
        if self.relations:
            lines.append("RELATIONS:")
            for r in self.relations[:5]:
                lines.append("  %s (%s)" % (r["type"], r["status"]))
        if self.limitations:
            lines.append("LIMITATIONS:")
            for lim in self.limitations[:3]:
                lines.append("  %s" % lim)
        return "\n".join(lines)


class KnowledgeAgent:
    def __init__(self, knowledge=None, protocol=None):
        self.knowledge = knowledge or Knowledge.load()
        self.protocol = protocol or QueryProtocol(self.knowledge)
        self.snap = SourceSnapshot.load()
        self.tree_sha = self.snap.tree_sha() if self.snap else "none"
        self.fast = get_fast_index()

    @classmethod
    def load(cls):
        return cls()

    def ask(self, question, mode="auto"):
        t0 = time.monotonic()
        packet = AnswerPacket()
        packet.entity = ""
        packet.intent = ""

        routing = self.knowledge.route(question)
        intent = routing.get("intent", "")
        entity = routing.get("entity", "")
        packet.entity = entity
        packet.intent = intent
        packet.query_signature = "%s|%s|%s" % (intent, entity, self.tree_sha[:16])

        effective_mode = mode if mode != "auto" else self._classify_mode(intent, routing)

        if effective_mode in (MODE_FACT, MODE_DEFINITION, MODE_RELATION):
            fast_result = self._fast_lookup(intent, entity)
            if fast_result is not None:
                packet.status = fast_result["status"]
                packet.confidence = fast_result["confidence"]
                packet.terminal = fast_result["terminal"]
                packet.direct_answer = fast_result["direct_answer"]
                packet.evidence = fast_result["evidence"]
                packet.relations = fast_result["relations"]
                packet.entities = fast_result["entities"]
                packet.fast_path = True
                elapsed = (time.monotonic() - t0) * 1000
                packet.elapsed_ms = round(elapsed, 2)
                return packet

        qr = self.protocol.ask(question, "simple" if effective_mode in (MODE_FACT, MODE_DEFINITION, MODE_RELATION) else "normal" if effective_mode in (MODE_TRACE, MODE_SOURCE) else "complex")

        bundle = qr.bundle
        packet.status = bundle.get("status", "UNKNOWN")
        packet.confidence = bundle.get("confidence", "UNSUPPORTED")
        packet.terminal = qr.terminal
        packet.direct_answer = bundle.get("direct_answer")
        packet.cache_hit = bundle.get("cache_hit", False)
        packet.evidence = _compact_evidence(bundle.get("evidence", []))
        packet.relations = _compact_relations(bundle.get("relations", []))
        packet.entities = _compact_entities(bundle.get("entities", []))
        packet.limitations = bundle.get("limitations", [])[:5]

        elapsed = (time.monotonic() - t0) * 1000
        packet.elapsed_ms = round(elapsed, 2)
        return packet

    def _fast_lookup(self, intent, entity):
        idx = self.fast
        if intent == "DEFINITION":
            cids = idx.resolve_concept(entity)
            if not cids:
                return None
            cid = cids[0]
            c = idx.concept_by_id.get(cid)
            if not c:
                return None
            evidence_ids = idx.get_concept_evidence(cid)
            evidence = []
            for eid in evidence_ids[:3]:
                ev = idx.get_evidence(eid)
                if ev:
                    evidence.append({
                        "file": ev.get("source_file", ""),
                        "line_start": ev.get("line_start"),
                        "line_end": ev.get("line_end"),
                        "text": ev.get("text", "")[:200],
                        "sha256": ev.get("sha256", ""),
                    })
            file_entry = idx.file_by_id.get(c.get("file_id", ""))
            file_path = file_entry.get("path", "") if file_entry else ""
            file_base = file_path.replace("\\", "/").rsplit("/", 1)[-1] if file_path else ""
            module_id = idx.get_module_of(cid)
            module_name = ""
            if module_id:
                mc = idx.concept_by_id.get(module_id)
                if mc:
                    module_name = mc["canonical_name"].rsplit("/", 1)[-1]
            direct = "%s is defined at %s:%s-%s" % (
                c["canonical_name"].rsplit("/", 1)[-1],
                file_base,
                evidence[0]["line_start"] if evidence else "?",
                evidence[0]["line_end"] if evidence else "?",
            ) if evidence else "%s: definition available" % c["canonical_name"].rsplit("/", 1)[-1]
            return {
                "status": "ANSWER_READY",
                "confidence": "VERIFIED",
                "terminal": True,
                "direct_answer": direct,
                "evidence": evidence,
                "relations": [],
                "entities": [{
                    "name": c["canonical_name"].rsplit("/", 1)[-1],
                    "type": c["concept_type"],
                    "file": file_base,
                    "line_start": evidence[0]["line_start"] if evidence else None,
                    "line_end": evidence[0]["line_end"] if evidence else None,
                }],
            }

        if intent == "CALLERS":
            cids = idx.resolve_concept(entity)
            if not cids:
                return None
            cid = cids[0]
            caller_cids = idx.get_callers(cid)
            if not caller_cids:
                return {
                    "status": "ANSWER_READY",
                    "confidence": "VERIFIED",
                    "terminal": True,
                    "direct_answer": "%s is called by nothing in the knowledge base" % entity,
                    "evidence": [],
                    "relations": [],
                    "entities": [],
                }
            items = []
            for caller_cid in caller_cids:
                cc = idx.concept_by_id.get(caller_cid)
                if cc:
                    items.append({
                        "name": cc["canonical_name"].rsplit("/", 1)[-1],
                        "type": cc["concept_type"],
                        "file": "",
                        "line_start": None,
                        "line_end": None,
                    })
            names = [i["name"] for i in items[:5]]
            extra = len(items) - len(names)
            tail = " (+%d more)" % extra if extra > 0 else ""
            return {
                "status": "ANSWER_READY",
                "confidence": "VERIFIED",
                "terminal": True,
                "direct_answer": "%s is called by %d concept(s): %s%s" % (entity, len(items), ", ".join(names), tail),
                "evidence": [],
                "relations": [],
                "entities": items,
            }

        if intent == "CALLEES":
            cids = idx.resolve_concept(entity)
            if not cids:
                return None
            cid = cids[0]
            callee_cids = idx.get_callees(cid)
            if not callee_cids:
                return {
                    "status": "ANSWER_READY",
                    "confidence": "VERIFIED",
                    "terminal": True,
                    "direct_answer": "%s calls nothing in the knowledge base" % entity,
                    "evidence": [],
                    "relations": [],
                    "entities": [],
                }
            items = []
            for callee_cid in callee_cids:
                cc = idx.concept_by_id.get(callee_cid)
                if cc:
                    items.append({
                        "name": cc["canonical_name"].rsplit("/", 1)[-1],
                        "type": cc["concept_type"],
                        "file": "",
                        "line_start": None,
                        "line_end": None,
                    })
            names = [i["name"] for i in items[:5]]
            extra = len(items) - len(names)
            tail = " (+%d more)" % extra if extra > 0 else ""
            return {
                "status": "ANSWER_READY",
                "confidence": "VERIFIED",
                "terminal": True,
                "direct_answer": "%s calls %d concept(s): %s%s" % (entity, len(items), ", ".join(names), tail),
                "evidence": [],
                "relations": [],
                "entities": items,
            }

        return None

    def _classify_mode(self, intent, routing):
        if intent in FAST_INTENTS:
            return MODE_FACT
        if intent == "DEFINITION":
            return MODE_DEFINITION
        if intent in ("CALLERS", "CALLEES", "REFERENCES"):
            return MODE_RELATION
        return MODE_EXPLAIN

    def stats(self):
        search = self.knowledge.cb.qe.search
        return {
            "tree_sha": self.tree_sha[:16] + "...",
            "concepts": len(search.concepts),
            "facts": len(self.knowledge.cb.facts),
            "relations": len(self.knowledge.cb.relations),
            "fast_index": self.fast.stats(),
        }


def main():
    agent = KnowledgeAgent.load()
    questions = [
        ("simple", "Who calls foldConstantOp?"),
        ("simple", "Where is foldConstantOp defined?"),
        ("simple", "What does foldConstantOp call?"),
        ("normal", "What depends on x64gen.zig?"),
        ("complex", "Where is emit used?"),
    ]
    for mode_hint, q in questions:
        packet = agent.ask(q, mode=mode_hint)
        print("Q: %s" % q)
        print("  status=%s conf=%s terminal=%s fast=%s" % (
            packet.status, packet.confidence, packet.terminal, packet.fast_path))
        print("  answer: %s" % (packet.direct_answer or "N/A")[:80])
        print("  evidence: %d  relations: %d  entities: %d" % (
            len(packet.evidence), len(packet.relations), len(packet.entities)))
        print("  time: %.2fms cache=%s" % (packet.elapsed_ms, packet.cache_hit))
        print()

    stats = agent.stats()
    print("AGENT STATS: %s" % stats)
    print("KNOWLEDGE AGENT READY")
    sys.exit(0)


if __name__ == "__main__":
    main()
