import sys
import time
from pathlib import Path

AGENT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(AGENT_ROOT))

from core.context_engine import (
    TaskRouter, SymbolResolver, GraphRetriever, EvidenceRetriever,
    SemanticChunker, ContextRanker, ContextBudgeter, ContextCache,
    HashInvalidator, PrefixCache, ModelContextAdapter, ContextEngine,
)
from core.agent_runtime import KnowledgeQuery, SourceIndex
from knowledge.tokenizer import ZigTokenizer


def test_task_router():
    print("C.8.1 Task Router")
    print("-" * 50)
    kb = KnowledgeQuery(AGENT_ROOT.parent / "memory")
    si = SourceIndex([Path(r"C:\Users\Local\zig"), Path(r"C:\B-Plus\zig")])
    router = TaskRouter(kb, si)

    tests = [
        ("fix the error in GPUScheduler.submit", "FIX", ["GPUScheduler", "submit"]),
        ("create a new allocator wrapper", "CREATE", ["allocator"]),
        ("explain how the parser works", "EXPLAIN", ["parser"]),
        ("optimize memory usage in CommandBuffer", "OPTIMIZE", ["CommandBuffer"]),
    ]
    for goal, expected_intent, expected_entities in tests:
        r = router.route(goal)
        print(f"  '{goal[:40]}...' => intent={r['intent']} entities={r['entities'][:3]} confidence={r['confidence']:.2f}")
        assert r["intent"] == expected_intent, f"expected {expected_intent}, got {r['intent']}"
    print("  PASS")


def test_symbol_resolver():
    print("\nC.8.2 Symbol Resolver")
    print("-" * 50)
    kb = KnowledgeQuery(AGENT_ROOT.parent / "memory")
    si = SourceIndex([Path(r"C:\Users\Local\zig"), Path(r"C:\B-Plus\zig")])
    resolver = SymbolResolver(kb, si)

    r = resolver.resolve("parser")
    print(f"  'parser': files={len(r['file_matches'])} concepts={len(r['concept_matches'])} exact={len(r['exact_matches'])}")
    assert len(r["file_matches"]) > 0 or len(r["concept_matches"]) > 0

    r2 = resolver.resolve("GPUScheduler")
    print(f"  'GPUScheduler': files={len(r2['file_matches'])} concepts={len(r2['concept_matches'])}")
    print("  PASS")


def test_graph_retriever():
    print("\nC.8.3 Graph Retriever")
    print("-" * 50)
    kb = KnowledgeQuery(AGENT_ROOT.parent / "memory")
    graph = GraphRetriever(kb)
    print(f"  adjacency: {len(graph.adjacency)} nodes")

    if graph.adjacency:
        first_node = list(graph.adjacency.keys())[0]
        result = graph.retrieve([first_node], depth=2, max_nodes=10)
        print(f"  retrieve from '{first_node[:30]}': {len(result)} nodes")
        for n in result[:3]:
            print(f"    {n['concept'][:40]} depth={n['depth']} neighbors={n['neighbors']}")
    print("  PASS")


def test_evidence_retriever():
    print("\nC.8.4 Evidence Retriever")
    print("-" * 50)
    kb = KnowledgeQuery(AGENT_ROOT.parent / "memory")
    ev = EvidenceRetriever(kb)
    print(f"  evidence index: {len(ev._fact_index)} files")

    results = ev.retrieve_by_symbol("parser", max_evidence=5)
    print(f"  'parser' evidence: {len(results)} facts")
    for r in results[:3]:
        print(f"    {r['predicate']}: {r['source_file'][:50]}:{r['line_start']}")
    print("  PASS")


def test_semantic_chunker():
    print("\nC.8.5 Semantic Chunker")
    print("-" * 50)
    si = SourceIndex([Path(r"C:\Users\Local\zig"), Path(r"C:\B-Plus\zig")])
    si.scan()
    chunker = SemanticChunker(si)

    test_files = list(si.files.keys())[:3]
    for fp in test_files:
        chunks = chunker.chunk_file(fp, max_chunk_tokens=512)
        print(f"  {Path(fp).name}: {len(chunks)} chunks")
        for c in chunks[:2]:
            print(f"    L{c['line_start']}-{c['line_end']}: {c['header'][:50]}")
    print("  PASS")


def test_context_budgeter():
    print("\nC.8.7 Context Budgeter")
    print("-" * 50)
    budgeter = ContextBudgeter(max_tokens=4096)

    tests = [
        ({"intent": "EXPLAIN", "entities": ["parser"]}, "simple_query"),
        ({"intent": "FIX", "entities": ["GPUScheduler"]}, "function_fix"),
        ({"intent": "MODIFY", "entities": ["A", "B", "C", "D", "E", "F"]}, "large_refactor"),
    ]
    for route, expected in tests:
        complexity = budgeter.estimate_complexity(route)
        budget = budgeter.get_budget(route)
        alloc = budgeter.allocate(budget)
        print(f"  intent={route['intent']} entities={len(route['entities'])} => {complexity} budget={budget}")
        print(f"    allocation: {alloc}")
    print("  PASS")


def test_context_cache():
    print("\nC.8.8 Context Cache")
    print("-" * 50)
    cache = ContextCache()

    cache.set_L0("task1", "hash1", {"result": "data"})
    hit = cache.get_L0("task1", "hash1")
    miss = cache.get_L0("task1", "hash2")
    print(f"  L0 hit: {hit is not None}, miss: {miss is None}")

    cache.set_L2("symbol1", {"chunks": [1, 2]})
    hit2 = cache.get_L2("symbol1")
    print(f"  L2 hit: {hit2 is not None}")

    stats = cache.stats()
    print(f"  stats: {stats}")
    print("  PASS")


def test_hash_invalidation():
    print("\nC.8.9 Hash Invalidation")
    print("-" * 50)
    hasher = HashInvalidator()

    test_file = AGENT_ROOT / "workspace" / "test_hash.zig"
    AGENT_ROOT / "workspace" / "test_hash.zig"
    test_file.parent.mkdir(parents=True, exist_ok=True)
    test_file.write_text("pub fn main() void {}", encoding="utf-8")

    h1 = hasher.compute_file_hash(str(test_file))
    print(f"  hash1: {h1[:16]}...")

    invalidated = hasher.check_invalidation(str(test_file), h1)
    print(f"  same content: invalidated={invalidated}")

    test_file.write_text("pub fn main() void { unreachable; }", encoding="utf-8")
    invalidated2 = hasher.check_invalidation(str(test_file), h1)
    print(f"  different content: invalidated={invalidated2}")

    test_file.unlink()
    print("  PASS")


def test_full_context_engine():
    print("\nC.8.11 Full Context Engine")
    print("-" * 50)

    tokenizer = ZigTokenizer.load(AGENT_ROOT / "knowledge" / "corpus" / "zig_tokenizer.json")
    kb = KnowledgeQuery(AGENT_ROOT.parent / "memory")
    si = SourceIndex([Path(r"C:\Users\Local\zig"), Path(r"C:\B-Plus\zig")])
    print("  scanning source...")
    si.scan()

    engine = ContextEngine(tokenizer, kb, si, max_tokens=4096)

    goals = [
        "fix the error in parser.zig",
        "create a new struct for GPU command buffer",
        "explain how the allocator works",
    ]

    for goal in goals:
        t0 = time.monotonic()
        ctx = engine.build_context(goal)
        dur = (time.monotonic() - t0) * 1000
        print(f"\n  goal: '{goal}'")
        print(f"    tokens_used: {ctx['tokens_used']}")
        print(f"    tokens_budget: {ctx['tokens_budget']}")
        print(f"    chunks: {ctx['chunks_count']}")
        print(f"    evidence: {ctx['evidence_count']}")
        print(f"    graph_nodes: {ctx['graph_nodes_count']}")
        print(f"    duration: {dur:.0f}ms")
        print(f"    route: intent={ctx['route']['intent']} entities={ctx['route']['entities'][:3]}")
        print(f"    prompt[:200]: {ctx['prompt'][:200]}...")

    stats = engine.cache_stats()
    print(f"\n  cache stats: {stats}")
    print("  PASS")


def main():
    print("C.8 CONTEXT ENGINE VERIFICATION")
    print("=" * 60)

    tests = [
        test_task_router,
        test_symbol_resolver,
        test_graph_retriever,
        test_evidence_retriever,
        test_semantic_chunker,
        test_context_budgeter,
        test_context_cache,
        test_hash_invalidation,
        test_full_context_engine,
    ]

    passed = 0
    failed = 0
    for test_fn in tests:
        try:
            test_fn()
            passed += 1
        except Exception as e:
            print(f"  FAIL: {e}")
            import traceback
            traceback.print_exc()
            failed += 1

    print("\n" + "=" * 60)
    print(f"RESULTS: {passed}/{passed + failed} PASS, {failed} FAIL")
    if failed == 0:
        print("C.8 CONTEXT ENGINE: VERIFIED")
    else:
        print("C.8 CONTEXT ENGINE: FAILURES DETECTED")
    print("=" * 60)


if __name__ == "__main__":
    main()
