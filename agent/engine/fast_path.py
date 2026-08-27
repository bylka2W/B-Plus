import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from budget import BudgetTracker, BudgetExceeded, format_budget
from evidence_bundle import (
    build_evidence_bundle, format_compact, ANSWER_READY,
    NEEDS_DEEP_SEARCH, UNKNOWN, PARTIAL,
)
from query_cache import QueryCache, format_cache_stats
from source_snapshot import SourceSnapshot
from telemetry import Telemetry, format_telemetry_stats

DIRECT_ANSWER_INTENTS = {
    "DEFINITION", "CALLERS", "CALLEES", "REFERENCES", "USES_TYPE",
    "TYPE_USERS", "CONTAINS", "DEPENDENCIES", "DEPENDENTS", "MODULE", "FILE",
}

FORBIDDEN_GREP_INTENTS = {"DEFINITION", "MODULE", "FILE", "CALLEES"}

MAX_CACHE_HINT_MS = 100


class FastPath:
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

    def ask(self, question, complexity_override=None):
        t0 = time.monotonic()
        d = self.knowledge.route(question)
        intent = d.get("intent")
        entity = d.get("entity")

        budget = BudgetTracker(
            complexity=complexity_override or "normal", start_time=t0
        )

        cached = self.cache.get(intent, entity, self.tree_sha)
        if cached is not None:
            cached["cache_hit"] = True
            cached["telemetry"]["total_ms"] = round(
                (time.monotonic() - t0) * 1000, 1
            )
            self.telemetry.record_question(question, cached, budget)
            return cached

        bundle = build_evidence_bundle(self.knowledge, question, t0)
        bundle_dict = bundle.to_dict()
        bundle_dict["cache_hit"] = False

        self._enforce_direct_path(bundle_dict, budget)

        if bundle.status == ANSWER_READY:
            self.cache.put(
                intent or "", entity or "", bundle_dict, self.tree_sha
            )

        self.telemetry.record_question(question, bundle_dict, budget)
        return bundle_dict

    def _enforce_direct_path(self, bundle_dict, budget):
        status = bundle_dict.get("status")
        if status == ANSWER_READY:
            return
        intent = bundle_dict.get("intent")
        if intent in FORBIDDEN_GREP_INTENTS:
            for lim in bundle_dict.get("limitations", []):
                if "global grep" in lim.lower():
                    bundle_dict["limitations"] = [
                        "global grep forbidden for this intent type"
                    ]
                    break

    def ask_with_budget(self, question, complexity="normal"):
        t0 = time.monotonic()
        budget = BudgetTracker(complexity, t0)
        try:
            result = self.ask(question, complexity_override=complexity)
            return result, budget
        except BudgetExceeded as exc:
            elapsed = (time.monotonic() - t0) * 1000
            return {
                "schema": "evidence_bundle",
                "version": 1,
                "status": "BUDGET_EXCEEDED",
                "intent": None,
                "entity": None,
                "question": question,
                "direct_answer": None,
                "answer_type": "EMPTY",
                "confidence": "UNSUPPORTED",
                "completeness": "BUDGET_EXCEEDED",
                "evidence": [],
                "claims": [],
                "relations": [],
                "entities": [],
                "unresolved": [],
                "limitations": [
                    f"budget exceeded: {exc.budget_type} "
                    f"{exc.current}/{exc.limit}"
                ],
                "provenance": {"engine": "bplus-knowledge-engine",
                               "read_only": True},
                "plan": None,
                "cache_hit": False,
                "telemetry": {
                    "routing_ms": 0,
                    "query_ms": 0,
                    "answer_ms": 0,
                    "total_ms": round(elapsed, 1),
                    "budget_exceeded": True,
                    "budget_error": str(exc),
                },
            }, budget

    def stats(self):
        return {
            "tree_sha": self.tree_sha[:16] + "...",
            "cache": self.cache.stats(),
            "telemetry": self.telemetry.stats(),
            "gates": self.telemetry.check_gates(),
        }


def format_fast_path(fp):
    s = fp.stats()
    lines = [
        f"FAST PATH: tree={s['tree_sha']}",
        format_cache_stats(fp.cache),
        format_telemetry_stats(s["telemetry"]),
    ]
    gates = s["gates"]
    if gates["passed"]:
        lines.append("GATES: PASS")
    else:
        for v in gates["violations"]:
            lines.append(
                f"GATE VIOLATION: {v['complexity']} {v['metric']} "
                f"actual={v['actual']} gate={v['gate']}"
            )
    return "\n".join(lines)


def main():
    fp = FastPath.load()
    questions = [
        "Кто вызывает foldConstantOp?",
        "Где определён foldConstantOp?",
        "Кто вызывает foldConstantOp?",
    ]
    for q in questions:
        t0 = time.monotonic()
        result, budget = fp.ask_with_budget(q, "simple")
        elapsed = (time.monotonic() - t0) * 1000
        cache_hit = result.get("cache_hit", False)
        status = result.get("status")
        direct = result.get("direct_answer", "")
        print(f"Q: {q}")
        print(f"  status={status} cache={cache_hit} "
              f"time={elapsed:.0f}ms")
        print(f"  answer: {direct[:80] if direct else 'N/A'}")
        print(f"  {format_budget(budget)}")
        print()
    print(format_fast_path(fp))
    print("FAST PATH MODULE READY")
    sys.exit(0)


if __name__ == "__main__":
    main()
