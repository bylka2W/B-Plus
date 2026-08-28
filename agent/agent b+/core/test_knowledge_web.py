import os
import sys
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
AGENT_BPLUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, AGENT_BPLUS)
AGENT_DIR = os.path.dirname(AGENT_BPLUS)

from pathlib import Path
from core.agent_runtime import KnowledgeQuery, SourceIndex
from core.symbol_graph import SymbolGraph
from core.knowledge_web import KnowledgeWebEngine


def setup():
    roots = [str(Path(r)) for r in [r"C:\B-Plus\zig", r"C:\Users\Local\zig"] if Path(r).exists()]
    source_index = SourceIndex(roots)
    source_index.scan()
    knowledge = KnowledgeQuery(str(Path(AGENT_DIR) / "memory"))
    symbol_graph = SymbolGraph(source_index, knowledge)
    symbol_graph.build()
    return source_index, knowledge, symbol_graph


def run():
    source_index, knowledge, symbol_graph = setup()
    web = KnowledgeWebEngine(source_index, symbol_graph, knowledge)
    web.build()

    print("\n=== KNOWLEDGE WEB BUILD ===")
    stats = web.get_stats()
    print(f"  nodes={stats['nodes']} edges={stats['edges']} built={stats['built']}")

    print("\n=== LOOKUP GPUScheduler ===")
    nodes = web.lookup("GPUScheduler")
    for n in nodes:
        print(f"  {n.name} kind={n.kind} level={n.knowledge_level} "
              f"file={os.path.basename(n.file_path) if n.file_path else '-'} "
              f"evidence={len(n.evidence_ids)} facts={len(n.facts)}")

    print("\n=== NEIGHBORS GPUScheduler (score>=0.85) ===")
    nbrs = web.neighbors("GPUScheduler", min_score=0.85)
    for x in nbrs[:10]:
        print(f"  {x['relation']:12s} -> {x['target']} [{x['kind']}] score={x['score']} ev={bool(x['evidence_id'])}")

    print("\n=== EXPAND scheduler (depth=2, min_score=0.85) ===")
    exp = web.expand("Scheduler", depth=2, min_score=0.85)
    print(f"  root={exp['root']} nodes={len(exp['nodes'])} edges={len(exp['edges'])}")
    for d, names in exp["levels"].items():
        print(f"    depth {d}: {names[:8]}")

    print("\n=== COVERAGE REPORT (all nodes) ===")
    rep = web.coverage_report()
    print(f"  total_nodes={rep['total_nodes']} edges={rep['total_edges']}")
    print(f"  KCS={rep['kcs']}%")
    print("  coverage:")
    for k, v in rep["coverage"].items():
        print(f"    {k:12s} {v}%")
    print("  levels (>= level):")
    for lv, v in rep["levels"].items():
        print(f"    L{lv:>2} {v}%")
    print("  quality:")
    for k, v in rep["quality"].items():
        print(f"    {k:22s} {v}")

    print("\n=== SYMBOL KNOWLEDGE DENSITY (top-level) ===")
    sym = web.symbol_coverage_report()
    print(f"  total top-level={sym['total']}")
    print(f"  KNOWLEDGE DENSITY={sym['knowledge_density']}%  orphan={sym['orphan_rate']}%")
    print("  coverage:")
    for k, v in sym["coverage"].items():
        print(f"    {k:16s} {v}%")
    print("  levels:")
    for lv, v in sym["levels"].items():
        print(f"    L{lv:>2} {v}%")

    print("\n=== KNOWLEDGE INTEGRITY ===")
    integ = web.integrity_report()
    print(f"  dangling_relations={integ.get('dangling_relations')} "
          f"concepts={integ.get('dangling_concepts')}")
    for rt, n in integ.get("dangling_by_type", {}).items():
        print(f"    {rt:15s} {n}")

    print("\n=== SHORTEST PATH GPUScheduler -> CommandQueue ===")
    path = web.shortest_path("GPUScheduler", "CommandQueue")
    for p in path:
        print(f"  {p['from']} --{p['relation']}[{p['score']}]--> {p['to']}")

    print("\n=== RESULT ===")
    ok = True
    if stats["nodes"] < 5000:
        ok = False
        print("  FAIL: too few nodes")
    if stats["edges"] < 5000:
        ok = False
        print("  FAIL: too few edges")
    if sym["knowledge_density"] <= 0:
        ok = False
        print("  FAIL: knowledge density zero")

    k10 = sym["levels"].get("10", 0)
    k7 = sym["levels"].get("7", 0)
    print(f"  Top-level: Level>=7: {k7}%  Level 10 (fully VERIFIED): {k10}%  "
          f"Density={sym['knowledge_density']}%")
    print(f"\n  {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(run())
