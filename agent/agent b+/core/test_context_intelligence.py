import sys
import time
from pathlib import Path

AGENT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(AGENT_ROOT))

from core.context_intelligence import (
    PersistentContextState, ConfidenceDrivenBudgeter, HierarchicalCache,
    KVPrefixCache, IncrementalRetry, ContextIntelligence,
)
from core.context_engine import ContextEngine, TaskRouter
from core.agent_runtime import KnowledgeQuery, SourceIndex
from knowledge.tokenizer import ZigTokenizer


def test_persistent_state():
    print("C.9.3 Persistent Context State")
    print("-" * 50)
    state = PersistentContextState()

    state.update_from_generation(symbols=["GPUScheduler", "submit"], files=["gpu.zig"])
    print(f"  after gen 1: {state.active.summary()}")
    assert state.active.generation_count == 1
    assert len(state.active.symbols) == 2

    state.update_from_generation(symbols=["submit", "Queue"], files=["gpu.zig", "queue.zig"])
    print(f"  after gen 2: {state.active.summary()}")
    assert state.active.generation_count == 2
    assert len(state.active.symbols) == 3
    assert len(state.active.files) == 2

    state.update_from_failure("syntax error at line 10")
    print(f"  after failure: errors={len(state.active.error_history)}")
    assert len(state.active.error_history) == 1

    prev = state.get_previous_errors(last_n=2)
    print(f"  previous errors: {len(prev)}")
    assert len(prev) == 1

    snap = state.snapshot()
    print(f"  snapshot: {snap}")
    print("  PASS")


def test_confidence_budgeter():
    print("\nC.9.2 Confidence-Driven Budgeter")
    print("-" * 50)
    budgeter = ConfidenceDrivenBudgeter(max_tokens=262144)

    tests = [
        (0.95, 1024),
        (0.8, 2048),
        (0.6, 4096),
        (0.4, 8192),
        (0.2, 16384),
        (0.1, 32768),
        (0.01, 65536),
    ]
    for conf, expected_max in tests:
        budget = budgeter.get_budget(conf)
        print(f"  confidence={conf:.2f} => budget={budget}")
        assert budget <= expected_max * 2

    expanded = budgeter.expand_on_failure(4096, "build_error")
    print(f"  expand build_error: 4096 -> {expanded}")
    assert expanded > 4096

    alloc = budgeter.allocate(8192)
    print(f"  allocation: {alloc}")
    assert sum(alloc.values()) <= 8192
    print("  PASS")


def test_hierarchical_cache():
    print("\nC.9.1 Hierarchical Cache L0-L3")
    print("-" * 50)
    cache = HierarchicalCache(l0_max=5, l1_max=10)

    cache.set_hot("symbol1", {"chunks": [1]})
    assert cache.get_hot("symbol1") is not None
    assert cache.get_hot("symbol2") is None
    print(f"  L0 hot: {cache.stats()['L0_hot']}")

    cache.set_semantic("symbol2", {"chunks": [2]})
    assert cache.get_semantic("symbol2") is not None
    print(f"  L1 semantic: {cache.stats()['L1_semantic']}")

    cache.promote_to_hot("symbol2", {"chunks": [2]})
    assert cache.get_hot("symbol2") is not None
    assert cache.get_semantic("symbol2") is None
    print(f"  after promote: L0={cache.stats()['L0_hot']} L1={cache.stats()['L1_semantic']}")

    cache.set_knowledge("fact1", {"data": "test"})
    assert cache.get_knowledge("fact1") is not None
    print(f"  L2 knowledge: {cache.stats()['L2_knowledge']}")

    cache.set_source("file.zig", "hash1", [{"text": "code", "file": "file.zig"}])
    assert cache.get_source("file.zig", "hash1") is not None
    assert cache.get_source("file.zig", "hash2") is None
    print(f"  L3 source: {cache.stats()['L3_source']}")

    cache.invalidate_file("file.zig")
    assert cache.get_source("file.zig", "hash1") is None
    print(f"  after invalidate: L3={cache.stats()['L3_source']}")

    stats = cache.stats()
    print(f"  stats: {stats}")
    print("  PASS")


def test_kv_prefix_cache():
    print("\nC.9.4 KV Prefix Cache")
    print("-" * 50)
    kv = KVPrefixCache()

    h1 = kv.register_prefix("system prompt v1", kv_data="cached_kv")
    print(f"  register: {h1}")

    hit = kv.get_prefix("system prompt v1")
    print(f"  hit: {hit is not None}")
    assert hit is not None

    miss = kv.get_prefix("different prompt")
    print(f"  miss: {miss is None}")
    assert miss is None

    stats = kv.get_reuse_stats()
    print(f"  stats: {stats}")
    print("  PASS")


def test_incremental_retry():
    print("\nC.9.5 Incremental Retry")
    print("-" * 50)
    retry = IncrementalRetry()

    assert retry.should_retry()

    err_type, strategy = retry.get_expansion_strategy("SyntaxError: expected '}'")
    print(f"  syntax error: type={err_type} strategy={strategy}")
    assert err_type == "syntax_error"
    assert strategy == "add_neighboring_chunks"

    err_type2, strategy2 = retry.get_expansion_strategy("BuildError: undefined symbol 'foo'")
    print(f"  build error: type={err_type2} strategy={strategy2}")
    assert err_type2 == "undefined_symbol"
    assert strategy2 == "add_symbol_definition"

    err_type3, strategy3 = retry.get_expansion_strategy("TestFailure: expected 5 got 4")
    print(f"  test failure: type={err_type3} strategy={strategy3}")
    assert err_type3 == "test_failure"

    for i in range(4):
        retry.record_attempt(f"error {i}", "expand")
    print(f"  after 4 attempts: should_retry={retry.should_retry()}")
    assert not retry.should_retry()

    retry.reset()
    assert retry.should_retry()
    print(f"  after reset: should_retry={retry.should_retry()}")
    print("  PASS")


def test_context_intelligence():
    print("\nC.9.6 Full Context Intelligence")
    print("-" * 50)

    tokenizer = ZigTokenizer.load(AGENT_ROOT / "knowledge" / "corpus" / "zig_tokenizer.json")
    kb = KnowledgeQuery(AGENT_ROOT.parent / "memory")
    si = SourceIndex([Path(r"C:\Users\Local\zig"), Path(r"C:\B-Plus\zig")])
    print("  scanning source...")
    si.scan()

    ctx_engine = ContextEngine(tokenizer, kb, si, max_tokens=4096)
    intel = ContextIntelligence(tokenizer, kb, si, ctx_engine, max_tokens=262144)

    goals = [
        "fix the error in parser.zig",
        "create a new struct for GPU command buffer",
    ]

    for goal in goals:
        t0 = time.monotonic()
        result = intel.prepare_generation(goal)
        dur = (time.monotonic() - t0) * 1000
        print(f"\n  goal: '{goal}'")
        print(f"    tokens_used: {result['tokens_used']}")
        print(f"    tokens_budget: {result['tokens_budget']}")
        print(f"    confidence: {result['confidence']:.2f}")
        print(f"    attempt: {result['attempt']}")
        print(f"    chunks: {result['chunks_count']}")
        print(f"    evidence: {result['evidence_count']}")
        print(f"    graph_nodes: {result['graph_nodes_count']}")
        print(f"    active: {result['active_context']}")
        print(f"    cache: {result['cache_stats']}")
        print(f"    duration: {dur:.0f}ms")

    failure_result = intel.handle_failure("BuildError: undefined symbol 'submit'")
    print(f"\n  after failure:")
    print(f"    error_type: {failure_result['error_type']}")
    print(f"    strategy: {failure_result['strategy']}")
    print(f"    new_budget: {failure_result['new_budget']}")
    print(f"    should_retry: {failure_result['should_retry']}")

    intel.handle_success()
    stats = intel.full_stats()
    print(f"\n  full stats: {stats}")

    print("\n  PASS")


def main():
    print("C.9 CONTEXT-DRIVEN INTELLIGENCE VERIFICATION")
    print("=" * 60)

    tests = [
        test_persistent_state,
        test_confidence_budgeter,
        test_hierarchical_cache,
        test_kv_prefix_cache,
        test_incremental_retry,
        test_context_intelligence,
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
        print("C.9 CONTEXT INTELLIGENCE: VERIFIED")
    else:
        print("C.9 CONTEXT INTELLIGENCE: FAILURES DETECTED")
    print("=" * 60)


if __name__ == "__main__":
    main()
