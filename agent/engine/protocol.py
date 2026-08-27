import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from budget import BudgetTracker, BudgetExceeded
from evidence_bundle import (
    ANSWER_READY, NEEDS_DEEP_SEARCH, UNKNOWN, PARTIAL,
    build_evidence_bundle, CONTEXT_LIMITS,
)
from query_cache import QueryCache
from source_snapshot import SourceSnapshot
from telemetry import Telemetry

TERMINAL = "TERMINAL"
NON_TERMINAL = "NON_TERMINAL"

SIMPLE_INTENTS = {"DEFINITION", "MODULE", "FILE", "CALLERS", "CALLEES",
                  "REFERENCES", "USES_TYPE", "TYPE_USERS", "CONTAINS",
                  "DEPENDENCIES", "DEPENDENTS"}

TERMINAL_CONFIDENCE = {"VERIFIED"}

CONTEXT_PACK_TEMPLATES = {
    "simple": {
        "max_context_lines": 20,
        "max_source_chars": 2000,
        "include_full_source": False,
        "include_graph": False,
        "include_all_claims": False,
    },
    "normal": {
        "max_context_lines": 60,
        "max_source_chars": 8000,
        "include_full_source": False,
        "include_graph": False,
        "include_all_claims": True,
    },
    "complex": {
        "max_context_lines": 200,
        "max_source_chars": 30000,
        "include_full_source": True,
        "include_graph": True,
        "include_all_claims": True,
    },
    "hard": {
        "max_context_lines": 500,
        "max_source_chars": 60000,
        "include_full_source": True,
        "include_graph": True,
        "include_all_claims": True,
    },
}


def is_terminal(bundle_dict):
    status = bundle_dict.get("status")
    confidence = bundle_dict.get("confidence")
    completeness = bundle_dict.get("completeness")
    evidence = bundle_dict.get("evidence", [])
    unresolved = bundle_dict.get("unresolved", [])
    if not evidence:
        return False
    if unresolved:
        return False
    if status == ANSWER_READY and confidence in TERMINAL_CONFIDENCE:
        return True
    if status == ANSWER_READY and completeness == ANSWER_READY:
        return True
    return False


def terminal_reason(bundle_dict):
    if not is_terminal(bundle_dict):
        return None
    return {
        "reason": "verified_answer_available",
        "status": bundle_dict.get("status"),
        "confidence": bundle_dict.get("confidence"),
        "completeness": bundle_dict.get("completeness"),
        "evidence_count": len(bundle_dict.get("evidence", [])),
        "unresolved_count": len(bundle_dict.get("unresolved", [])),
    }


class QueryResult:
    def __init__(self, bundle_dict, terminal, terminal_info,
                 budget, compact_context, elapsed_ms):
        self.bundle = bundle_dict
        self.terminal = terminal
        self.terminal_info = terminal_info
        self.budget = budget
        self.compact_context = compact_context
        self.elapsed_ms = elapsed_ms

    def to_dict(self):
        d = dict(self.bundle)
        d["terminal"] = self.terminal
        d["terminal_info"] = self.terminal_info
        d["compact_context"] = self.compact_context
        d["budget_summary"] = self.budget.budget_summary()
        return d


class QueryProtocol:
    def __init__(self, knowledge, cache=None, telemetry=None):
        self.knowledge = knowledge
        self.snap = SourceSnapshot.load()
        self.tree_sha = self.snap.tree_sha() if self.snap else "none"
        self.cache = cache or QueryCache.load(self.tree_sha)
        self.telemetry = telemetry or Telemetry.load()

    @classmethod
    def load(cls):
        from knowledge import Knowledge
        k = Knowledge.load()
        return cls(k)

    def ask(self, question, complexity="normal"):
        t0 = time.monotonic()
        budget = BudgetTracker(complexity, t0)

        d = self.knowledge.route(question)
        intent = d.get("intent")
        entity = d.get("entity")

        cached = self.cache.get(intent, entity, self.tree_sha)
        if cached is not None:
            cached["cache_hit"] = True
            elapsed = (time.monotonic() - t0) * 1000
            cached["telemetry"]["total_ms"] = round(elapsed, 1)
            term = is_terminal(cached)
            compact = self._build_compact_context(cached, complexity)
            qr = QueryResult(cached, term, terminal_reason(cached),
                             budget, compact, elapsed)
            self.telemetry.record_question(question, cached, budget)
            return qr

        budget.check_tool("search")
        bundle = build_evidence_bundle(self.knowledge, question, t0)
        bundle_dict = bundle.to_dict()
        bundle_dict["cache_hit"] = False

        elapsed = (time.monotonic() - t0) * 1000
        bundle_dict["telemetry"]["total_ms"] = round(elapsed, 1)

        term = is_terminal(bundle_dict)
        self.cache.put(
            intent or "", entity or "", bundle_dict, self.tree_sha
        )

        compact = self._build_compact_context(bundle_dict, complexity)
        qr = QueryResult(bundle_dict, term, terminal_reason(bundle_dict),
                         budget, compact, elapsed)
        self.telemetry.record_question(question, bundle_dict, budget)
        return qr

    def _build_compact_context(self, bundle_dict, complexity):
        tmpl = CONTEXT_PACK_TEMPLATES.get(
            complexity, CONTEXT_PACK_TEMPLATES["normal"]
        )
        max_lines = tmpl["max_context_lines"]
        max_chars = tmpl["max_source_chars"]

        lines = []
        intent = bundle_dict.get("intent", "?")
        entity = bundle_dict.get("entity", "?")
        lines.append("INTENT: %s" % intent)
        lines.append("ENTITY: %s" % entity)
        lines.append("STATUS: %s" % bundle_dict.get("status"))
        lines.append("CONFIDENCE: %s" % bundle_dict.get("confidence"))
        lines.append("COMPLETENESS: %s" % bundle_dict.get("completeness"))
        lines.append("")

        direct = bundle_dict.get("direct_answer")
        if direct:
            lines.append("ANSWER:")
            lines.append(direct)
            lines.append("")

        evidence = bundle_dict.get("evidence", [])
        if evidence:
            lines.append("EVIDENCE:")
            for ev in evidence[:3]:
                fp = ev.get("file", "").replace("\\", "/").rsplit("/", 1)[-1]
                ls = ev.get("line_start", "?")
                le = ev.get("line_end", "?")
                lines.append("  %s:%s-%s" % (fp, ls, le))
                text = ev.get("text", "")
                if text and tmpl["include_full_source"]:
                    for src_line in text.splitlines()[:5]:
                        lines.append("    %s" % src_line)
            lines.append("")

        claims = bundle_dict.get("claims", [])
        if claims:
            limit = len(claims) if tmpl["include_all_claims"] else 3
            lines.append("CLAIMS:")
            for c in claims[:limit]:
                lines.append("  %s [%s]" % (
                    c.get("claim", ""), c.get("status", "?")
                ))
            lines.append("")

        relations = bundle_dict.get("relations", [])
        if relations:
            lines.append("RELATIONS:")
            for r in relations[:5]:
                lines.append("  %s (%s)" % (
                    r.get("relation_type", "?"),
                    r.get("verification_status", "?"),
                ))
            lines.append("")

        unresolved = bundle_dict.get("unresolved", [])
        if unresolved:
            lines.append("UNRESOLVED:")
            for u in unresolved[:5]:
                lines.append("  %s [%s]" % (
                    u.get("fact_type", "?"), u.get("status", "?")
                ))
            lines.append("")

        context_text = "\n".join(lines[:max_lines])
        if len(context_text) > max_chars:
            context_text = context_text[:max_chars] + "\n...[truncated]"

        return {
            "text": context_text,
            "lines": min(len(lines), max_lines),
            "chars": len(context_text),
            "truncated": len(lines) > max_lines or len(context_text) >= max_chars,
            "complexity": complexity,
            "max_context_lines": max_lines,
            "max_source_chars": max_chars,
        }


def format_protocol_result(qr):
    lines = []
    lines.append("TERMINAL: %s" % qr.terminal)
    if qr.terminal_info:
        lines.append("  reason: %s" % qr.terminal_info.get("reason"))
        lines.append("  confidence: %s" % qr.terminal_info.get("confidence"))
        lines.append("  evidence: %s" % qr.terminal_info.get("evidence_count"))
    lines.append("TIME: %.0fms" % qr.elapsed_ms)
    if qr.compact_context:
        ctx = qr.compact_context
        lines.append("CONTEXT: %d lines, %d chars, truncated=%s" % (
            ctx["lines"], ctx["chars"], ctx["truncated"]
        ))
    return "\n".join(lines)


def main():
    qp = QueryProtocol.load()
    questions = [
        ("simple", "Who calls foldConstantOp?"),
        ("simple", "Where is foldConstantOp defined?"),
        ("simple", "What does foldConstantOp call?"),
        ("normal", "What depends on x64gen.zig?"),
        ("complex", "Where is emit used?"),
    ]
    for comp, q in questions:
        qr = qp.ask(q, comp)
        print("Q: %s" % q)
        print(format_protocol_result(qr))
        if qr.compact_context:
            print("--- compact context ---")
            print(qr.compact_context["text"][:500])
        print()

    print("QUERY PROTOCOL MODULE READY")
    sys.exit(0)


if __name__ == "__main__":
    main()
