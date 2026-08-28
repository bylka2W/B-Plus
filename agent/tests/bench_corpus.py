import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "engine"))

from protocol import QueryProtocol

SIMPLE_QUESTIONS = [
    ("Who calls foldConstantOp?", "CALLERS", "foldConstantOp"),
    ("Where is foldConstantOp defined?", "DEFINITION", "foldConstantOp"),
    ("What does foldConstantOp call?", "CALLEES", "foldConstantOp"),
    ("Who calls getConstValue?", "CALLERS", "getConstValue"),
    ("Where is getConstValue defined?", "DEFINITION", "getConstValue"),
    ("What does getConstValue call?", "CALLEES", "getConstValue"),
    ("Who calls rebuildUses?", "CALLERS", "rebuildUses"),
    ("Where is rebuildUses defined?", "DEFINITION", "rebuildUses"),
    ("What does rebuildUses call?", "CALLEES", "rebuildUses"),
    ("Who calls getValueInfo?", "CALLERS", "getValueInfo"),
    ("Where is getValueInfo defined?", "DEFINITION", "getValueInfo"),
    ("What does getValueInfo call?", "CALLEES", "getValueInfo"),
    ("Who calls runConstantFolding?", "CALLERS", "runConstantFolding"),
    ("Where is runConstantFolding defined?", "DEFINITION", "runConstantFolding"),
    ("What does runConstantFolding call?", "CALLEES", "runConstantFolding"),
    ("Who calls getConstValue?", "CALLERS", "getConstValue"),
    ("Where is NO_VALUE defined?", "DEFINITION", "NO_VALUE"),
    ("Who calls emitToBuffer?", "CALLERS", "emitToBuffer"),
    ("Where is emitToBuffer defined?", "DEFINITION", "emitToBuffer"),
    ("What does emitToBuffer call?", "CALLEES", "emitToBuffer"),
]

NORMAL_QUESTIONS = [
    ("Who depends on x64gen.zig?", "DEPENDENTS", "x64gen.zig"),
    ("What does x64gen.zig depend on?", "DEPENDENCIES", "x64gen.zig"),
    ("Who references foldConstantOp?", "REFERENCES", "foldConstantOp"),
    ("Who references getConstValue?", "REFERENCES", "getConstValue"),
    ("Where is foldConstantOp used?", "REFERENCES", "foldConstantOp"),
    ("Where is getConstValue used?", "REFERENCES", "getConstValue"),
    ("What does x64gen.zig contain?", "CONTAINS", "x64gen.zig"),
    ("What does x64gen.zig contain?", "CONTAINS", "x64gen.zig"),
    ("Who references rebuildUses?", "REFERENCES", "rebuildUses"),
    ("Who references getValueInfo?", "REFERENCES", "getValueInfo"),
    ("Who depends on ast.zig?", "DEPENDENTS", "ast.zig"),
    ("What does ast.zig depend on?", "DEPENDENCIES", "ast.zig"),
    ("Who depends on sema.zig?", "DEPENDENTS", "sema.zig"),
    ("What does sema.zig depend on?", "DEPENDENCIES", "sema.zig"),
    ("Who references runConstantFolding?", "REFERENCES", "runConstantFolding"),
    ("Who references emitToBuffer?", "REFERENCES", "emitToBuffer"),
    ("Where is runConstantFolding used?", "REFERENCES", "runConstantFolding"),
    ("Where is emitToBuffer used?", "REFERENCES", "emitToBuffer"),
    ("Who depends on builder.zig?", "DEPENDENTS", "builder.zig"),
    ("What does builder.zig depend on?", "DEPENDENCIES", "builder.zig"),
]

COMPLEX_QUESTIONS = [
    ("What depends on x64gen.zig?", "DEPENDENTS", "x64gen.zig"),
    ("What does builder.zig depend on?", "DEPENDENCIES", "builder.zig"),
    ("Who references codebuffer.zig?", "REFERENCES", "codebuffer.zig"),
    ("Who depends on codebuffer.zig?", "DEPENDENTS", "codebuffer.zig"),
    ("What does codebuffer.zig depend on?", "DEPENDENCIES", "codebuffer.zig"),
    ("Where is x64gen.zig used?", "REFERENCES", "x64gen.zig"),
    ("Who references x64gen.zig?", "REFERENCES", "x64gen.zig"),
    ("What does sema.zig contain?", "CONTAINS", "sema.zig"),
    ("Who depends on builder.zig?", "DEPENDENTS", "builder.zig"),
    ("What does x64gen.zig contain?", "CONTAINS", "x64gen.zig"),
]

HARD_QUESTIONS = [
    ("Who depends on typeInfo?", "DEPENDENTS", "typeInfo"),
    ("What does typeInfo depend on?", "DEPENDENCIES", "typeInfo"),
    ("Where is createValue used?", "REFERENCES", "createValue"),
    ("What types does createValue use?", "USES_TYPE", "createValue"),
    ("Who references builder.zig?", "REFERENCES", "builder.zig"),
]

ALL_QUESTIONS = {
    "simple": SIMPLE_QUESTIONS,
    "normal": NORMAL_QUESTIONS,
    "complex": COMPLEX_QUESTIONS,
    "hard": HARD_QUESTIONS,
}


def run_benchmark(qp, complexity, questions):
    for _, _, entity in questions:
        for intent in ("CALLERS", "DEFINITION", "CALLEES", "REFERENCES",
                       "DEPENDENCIES", "DEPENDENTS", "CONTAINS", "USES_TYPE",
                       "TYPE_USERS"):
            qp.cache.invalidate_entity(intent, entity)

    results = []
    for question, expected_intent, entity in questions:
        times = []
        terminal_count = 0
        cache_hits = 0
        last_qr = None
        for _ in range(3):
            t0 = time.monotonic()
            qr = qp.ask(question, complexity)
            elapsed = (time.monotonic() - t0) * 1000
            times.append(elapsed)
            if qr.terminal:
                terminal_count += 1
            if qr.bundle.get("cache_hit"):
                cache_hits += 1
            last_qr = qr

        avg_ms = sum(times) / len(times)
        intent_match = last_qr.bundle.get("intent") == expected_intent
        evidence_count = len(last_qr.bundle.get("evidence", []))
        ctx_chars = last_qr.compact_context.get("chars", 0) if last_qr.compact_context else 0

        results.append({
            "question": question,
            "complexity": complexity,
            "expected_intent": expected_intent,
            "intent_match": intent_match,
            "status": last_qr.bundle.get("status"),
            "confidence": last_qr.bundle.get("confidence"),
            "terminal": last_qr.terminal,
            "terminal_rate": terminal_count / 3.0,
            "cache_hit_rate": cache_hits / 3.0,
            "evidence_count": evidence_count,
            "context_chars": ctx_chars,
            "avg_ms": round(avg_ms, 1),
        })
    return results


def compute_summary(all_results):
    summary = {}
    for comp in ("simple", "normal", "complex", "hard"):
        items = [r for r in all_results if r["complexity"] == comp]
        if not items:
            continue
        times = [r["avg_ms"] for r in items]
        terminals = [r["terminal_rate"] for r in items]
        intents = [r["intent_match"] for r in items]
        sorted_times = sorted(times)
        summary[comp] = {
            "count": len(items),
            "avg_ms": round(sum(times) / len(times), 1),
            "p50_ms": round(sorted_times[len(sorted_times) // 2], 1),
            "p95_ms": round(sorted_times[int(len(sorted_times) * 0.95)], 1),
            "max_ms": round(max(times), 1),
            "terminal_rate": round(sum(terminals) / len(terminals), 2),
            "intent_accuracy": round(sum(intents) / len(intents), 2),
            "avg_evidence": round(
                sum(r["evidence_count"] for r in items) / len(items), 1
            ),
            "avg_context_chars": round(
                sum(r["context_chars"] for r in items) / len(items), 0
            ),
        }
    return summary


def main():
    qp = QueryProtocol.load()
    all_results = []
    for comp, questions in ALL_QUESTIONS.items():
        print("Running %s (%d questions)..." % (comp, len(questions)))
        results = run_benchmark(qp, comp, questions)
        all_results.extend(results)

    summary = compute_summary(all_results)

    print()
    print("=== BENCHMARK RESULTS ===")
    for comp in ("simple", "normal", "complex", "hard"):
        if comp not in summary:
            continue
        s = summary[comp]
        print("%8s: %d questions | avg=%6.0fms p50=%6.0fms p95=%6.0fms max=%6.0fms | terminal=%.0f%% intent=%.0f%% evidence=%.1f ctx=%.0f" % (
            comp, s["count"], s["avg_ms"], s["p50_ms"], s["p95_ms"], s["max_ms"],
            s["terminal_rate"] * 100, s["intent_accuracy"] * 100,
            s["avg_evidence"], s["avg_context_chars"],
        ))

    gates = {
        "simple": {"p50_ms": 100, "p95_ms": 500, "max_ms": 1000, "intent_accuracy": 0.9},
        "normal": {"p50_ms": 500, "p95_ms": 2000, "max_ms": 5000, "intent_accuracy": 0.8},
        "complex": {"p50_ms": 2000, "p95_ms": 10000, "max_ms": 30000, "intent_accuracy": 0.7},
        "hard": {"p50_ms": 5000, "p95_ms": 20000, "max_ms": 60000, "intent_accuracy": 0.6},
    }
    gate_check = True
    print()
    print("=== GATE CHECK ===")
    for comp in ("simple", "normal", "complex", "hard"):
        if comp not in summary:
            continue
        s = summary[comp]
        g = gates[comp]
        passed = True
        reasons = []
        if s["p50_ms"] > g["p50_ms"]:
            passed = False
            reasons.append("p50=%dms > %dms" % (s["p50_ms"], g["p50_ms"]))
        if s["p95_ms"] > g["p95_ms"]:
            passed = False
            reasons.append("p95=%dms > %dms" % (s["p95_ms"], g["p95_ms"]))
        if s["max_ms"] > g["max_ms"]:
            passed = False
            reasons.append("max=%dms > %dms" % (s["max_ms"], g["max_ms"]))
        if s["intent_accuracy"] < g["intent_accuracy"]:
            passed = False
            reasons.append("intent=%.0f%% < %.0f%%" % (
                s["intent_accuracy"] * 100, g["intent_accuracy"] * 100
            ))
        status = "PASS" if passed else "FAIL"
        if not passed:
            gate_check = False
        print("  %8s: %s %s" % (comp, status, " ".join(reasons)))

    doc = {
        "schema": "benchmark_corpus",
        "version": 1,
        "total_questions": len(all_results),
        "summary": summary,
        "gates": gates,
        "gates_passed": gate_check,
        "results": all_results,
    }
    path = os.path.join(os.path.dirname(__file__), "..", "memory", "benchmark_corpus.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
    print()
    print("Saved: %s" % path)
    print("GATES: %s" % ("PASS" if gate_check else "FAIL"))


if __name__ == "__main__":
    main()
