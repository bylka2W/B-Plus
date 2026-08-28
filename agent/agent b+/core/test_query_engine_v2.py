import os
import sys
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
AGENT_BPLUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, AGENT_BPLUS)
AGENT_DIR = os.path.dirname(AGENT_BPLUS)

from pathlib import Path
from core.tool_registry import ToolExecutionEngine, RiskLevel
from core.system_tools import register_all_tools
from core.query_engine import QueryEngine
from core.agent_runtime import KnowledgeQuery, SourceIndex


def setup():
    roots = [str(Path(r)) for r in [r"C:\B-Plus\zig"] if Path(r).exists()]
    source_index = SourceIndex(roots)
    source_index.scan()

    kb_dir = Path(AGENT_DIR) / "memory"
    knowledge = KnowledgeQuery(str(kb_dir))

    engine = ToolExecutionEngine(allowed_risk=[RiskLevel.READ, RiskLevel.ANALYSIS, RiskLevel.EXECUTION])
    register_all_tools(engine, knowledge, source_index, None)
    qe = QueryEngine(engine)
    return qe, engine


def check(exercise, result, min_facts=0, min_evidence=0, min_sources=0, min_relations=0):
    ok = True
    issues = []
    if len(result.facts) < min_facts:
        ok = False
        issues.append(f"facts {len(result.facts)} < {min_facts}")
    if len(result.evidence) < min_evidence:
        ok = False
        issues.append(f"evidence {len(result.evidence)} < {min_evidence}")
    if len(result.source_files) < min_sources:
        ok = False
        issues.append(f"source_files {len(result.source_files)} < {min_sources}")
    if len(result.relations) < min_relations:
        ok = False
        issues.append(f"relations {len(result.relations)} < {min_relations}")
    status = "PASS" if ok else "FAIL"
    extras = "; ".join(issues) if issues else ""
    print(f"  [{status}] {exercise} -> route={result.route} facts={len(result.facts)} "
          f"evidence={len(result.evidence)} src={len(result.source_files)} rel={len(result.relations)} {extras}")
    return ok


def run():
    qe, engine = setup()
    results = []

    print("\n=== QUERY ENGINE v2 ROUTE TESTS ===")

    r = qe.query("Где определён GPUScheduler?")
    results.append(check("LOCATE", r, min_sources=1, min_evidence=1))

    r = qe.query("Кто использует GPUScheduler?")
    results.append(check("REFERENCES", r, min_sources=1, min_evidence=1))

    r = qe.query("Как работает GPUScheduler?")
    results.append(check("HOW", r, min_evidence=1))

    r = qe.query("Почему GPUScheduler важен?")
    results.append(check("WHY", r, min_evidence=1))

    r = qe.query("Что такое Scheduler?")
    results.append(check("EXPLAIN", r, min_facts=1, min_evidence=1))

    r = qe.query("Сравни GPUScheduler и GlobalSchedulerState")
    results.append(check("COMPARE", r, min_evidence=1))

    r = qe.query("Проследи вызов GPUScheduler.submit")
    results.append(check("TRACE", r, min_sources=1, min_evidence=1))

    r = qe.query("Почему не работает GPUScheduler?")
    results.append(check("FIX", r, min_evidence=1))

    r = qe.query("Создай функцию для GPUScheduler")
    results.append(check("CREATE", r))

    r = qe.query("Проверь тест для GPUScheduler")
    results.append(check("TEST", r))

    r = qe.query("Привет")
    results.append(check("GREET", r))

    print("\n=== INTENT ANALYSIS ===")
    for q in ["Что такое GPUScheduler?", "Кто использует GPUScheduler?",
              "Как работает Scheduler?", "Сравни A и B", "Где GPUScheduler?"]:
        intent = qe.analyze_intent(q)
        print(f"  [{q}] -> {intent.intent_type} confidence={intent.confidence} symbols={intent.symbols}")

    print("\n=== EXECUTION LOG (tools actually called) ===")
    stats = engine.get_stats()
    tools = sorted({e.tool for e in engine.get_execution_log()})
    print(f"  total={stats['total_executions']} success={stats['success']} errors={stats['errors']}")
    print(f"  tools used: {tools}")

    pass_count = sum(1 for x in results if x)
    total = len(results)
    print(f"\n  RESULT: {pass_count}/{total} PASS")

    return 0 if pass_count == total else 1


if __name__ == "__main__":
    sys.exit(run())
