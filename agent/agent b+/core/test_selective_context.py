import sys
import time
from pathlib import Path

AGENT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(AGENT_ROOT))

from core.selective_context import (
    ContextAddressSpace, ContextPageTable, ContextController,
    ContextSelector, ContextDelta, KVSegmentCache,
    WorkingSetManager, SelectiveContextRuntime, PageID,
)


def test_address_space():
    print("C.10.1 ContextAddressSpace")
    print("-" * 50)
    asp = ContextAddressSpace()

    pid1 = asp.register("symbol", "GPUScheduler", {"name": "GPUScheduler", "file": "gpu.zig"}, token_estimate=50)
    pid2 = asp.register("symbol", "submit", {"name": "submit"}, token_estimate=20, dependencies=[str(pid1)])
    pid3 = asp.register("file", "gpu.zig", {"path": "gpu.zig"}, token_estimate=30)

    print(f"  pages: {asp.stats()['total_pages']}")
    print(f"  by_kind: {asp.stats()['by_kind']}")
    print(f"  total_tokens: {asp.stats()['total_tokens']}")

    page = asp.get(pid1)
    assert page is not None
    assert page.token_estimate == 50
    page.touch()
    assert page.use_count == 1

    print(f"  resident: {asp.stats()['resident']}")
    assert asp.stats()['resident'] == 1

    asp.invalidate(pid3)
    print(f"  after invalidate: {asp.stats()['total_pages']}")
    assert asp.stats()['total_pages'] == 2
    print("  PASS")


def test_page_table():
    print("\nC.10.2 ContextPageTable")
    print("-" * 50)
    asp = ContextAddressSpace()
    pt = ContextPageTable(asp)

    pid = pt.register_symbol("GPUScheduler", definition="pub const GPUScheduler = struct {}", dependencies=["Queue", "CommandBuffer"], callers=["main", "init"], file_path="gpu.zig")
    print(f"  GPUScheduler page: {pid}")

    pid2 = pt.register_symbol("Queue", dependencies=["Device"])
    pid3 = pt.register_symbol("CommandBuffer")
    pid4 = pt.register_symbol("Device")

    expanded = pt.expand_symbol("GPUScheduler", depth=2)
    print(f"  expanded GPUScheduler: {len(expanded)} nodes")
    for n in expanded:
        print(f"    {n['name']} depth={n['depth']}")

    assert len(expanded) >= 1
    print("  PASS")


def test_controller():
    print("\nC.10.3 ContextController")
    print("-" * 50)
    asp = ContextAddressSpace()
    ctrl = ContextController(asp, max_active_pages=5, max_tokens=1000)

    pid_a = asp.register("symbol", "A", {"name": "A"}, token_estimate=100)
    pid_b = asp.register("symbol", "B", {"name": "B"}, token_estimate=200)
    pid_c = asp.register("symbol", "C", {"name": "C"}, token_estimate=300)
    pid_d = asp.register("symbol", "D", {"name": "D"}, token_estimate=50)
    pid_e = asp.register("symbol", "E", {"name": "E"}, token_estimate=10)

    action_load = ctrl.decide(pid_a, 0.9, 0)
    print(f"  LOAD  A (new, rel=0.9): {action_load}")
    assert action_load == "LOAD"
    ctrl.execute(action_load, pid_a)

    action_keep = ctrl.decide(pid_a, 0.7, 100)
    print(f"  KEEP  A (active, rel=0.7): {action_keep}")
    assert action_keep == "KEEP"

    action_evict = ctrl.decide(pid_a, 0.1, 100)
    print(f"  EVICT A (active, rel=0.1): {action_evict}")
    assert action_evict == "EVICT"
    ctrl.execute(action_evict, pid_a)

    ctrl.execute("LOAD", pid_b)
    ctrl.execute("LOAD", pid_c)
    ctrl.execute("LOAD", pid_d)

    action_promote = ctrl.decide(pid_b, 0.9, 600)
    print(f"  PROMOTE B (active, rel=0.9, near limit): {action_promote}")
    ctrl.execute("PROMOTE", pid_b)

    action_expand = ctrl.decide(pid_e, 0.6, 600)
    print(f"  EXPAND E (new, rel=0.6, within budget): {action_expand}")

    print(f"  active: {len(ctrl.get_active_pages())}")
    print(f"  tokens: {ctrl.active_tokens()}")
    print(f"  stats: {ctrl.stats()}")
    print("  PASS")


def test_selector():
    print("\nC.10.4 ContextSelector")
    print("-" * 50)
    asp = ContextAddressSpace()
    pt = ContextPageTable(asp)
    ctrl = ContextController(asp, max_active_pages=10, max_tokens=5000)
    sel = ContextSelector(asp, pt, ctrl)

    pt.register_symbol("GPUScheduler", dependencies=["Queue", "CommandBuffer"], file_path="gpu.zig")
    pt.register_symbol("Queue", dependencies=["Device"])
    pt.register_symbol("CommandBuffer")
    pt.register_symbol("Device")
    pt.register_symbol("Parser", file_path="parser.zig")

    result = sel.select(["GPUScheduler", "Queue", "CommandBuffer"], "FIX", 5000)
    print(f"  selected: {len(result['selected'])}")
    print(f"  tokens: {result['total_tokens']}")
    print(f"  utilization: {result['utilization']:.2%}")
    for s in result["selected"]:
        print(f"    {s['entity']}: relevance={s['relevance']:.2f} action={s['action']}")
    print("  PASS")


def test_delta():
    print("\nC.10.5 ContextDelta")
    print("-" * 50)
    delta = ContextDelta()

    gen1 = {"s1", "s2", "s3"}
    gen2 = {"s2", "s3", "s4"}

    result = delta.compute(gen1, gen2)
    print(f"  gen1={gen1} gen2={gen2}")
    print(f"  added: {result['added']}")
    print(f"  removed: {result['removed']}")
    print(f"  unchanged: {result['unchanged']}")
    print(f"  reuse_ratio: {result['reuse_ratio']:.2%}")

    assert "s4" in result["added"]
    assert "s1" in result["removed"]
    assert "s2" in result["unchanged"]
    assert result["reuse_ratio"] == 2 / 3

    print(f"  needs_prefill: {delta.needs_prefill()}")
    print("  PASS")


def test_kv_segment_cache():
    print("\nC.10.6 KVSegmentCache")
    print("-" * 50)
    kv = KVSegmentCache(max_segments=5)

    kv.register("page:GPUScheduler", "hash1", 0, 100, kv_data="kv_data_1")
    kv.register("page:submit", "hash2", 100, 150, kv_data="kv_data_2")

    seg = kv.get_segment("page:GPUScheduler", "hash1")
    print(f"  get GPUScheduler: {seg is not None}")
    assert seg is not None

    miss = kv.get_segment("page:GPUScheduler", "hash_wrong")
    print(f"  miss: {miss is None}")
    assert miss is None

    assert kv.can_reuse("page:GPUScheduler", "hash1")
    assert not kv.can_reuse("page:GPUScheduler", "hash2")

    asp = ContextAddressSpace()
    pid1 = asp.register("symbol", "GPUScheduler", {}, token_estimate=100)
    pid2 = asp.register("symbol", "submit", {}, token_estimate=50)
    kv.register(str(pid1), asp.content_hash(pid1), 0, 100)
    kv.register(str(pid2), asp.content_hash(pid2), 100, 150)

    reusable = kv.compute_reusable_tokens([pid1, pid2], asp)
    print(f"  reusable tokens: {reusable}")
    print(f"  stats: {kv.stats()}")
    print("  PASS")


def test_working_set():
    print("\nC.10.7 WorkingSetManager")
    print("-" * 50)
    runtime = SelectiveContextRuntime(max_active_pages=10, max_tokens=8000)

    runtime.register_symbol("GPUScheduler", dependencies=["Queue", "CommandBuffer"], file_path="gpu.zig")
    runtime.register_symbol("Queue", dependencies=["Device"])
    runtime.register_symbol("CommandBuffer")
    runtime.register_symbol("Device")
    runtime.register_symbol("Parser", file_path="parser.zig")
    runtime.register_fact("F1", "DEFINES", "gpu.zig", 10, 20)
    runtime.register_fact("F2", "CALLS", "gpu.zig", 30, 35)

    print(f"  address_space: {runtime.stats()['address_space']}")
    print(f"  page_table: {runtime.stats()['page_table']}")

    gen1 = runtime.select_context(["GPUScheduler", "Queue"], "FIX", 8000)
    rr1 = gen1['kv_reuse']['reuse_ratio']
    assert 0.0 <= rr1 <= 1.0, f"gen1 reuse_ratio={rr1}"
    print(f"\n  gen1: tokens={gen1['working_set']['tokens']} pages={gen1['working_set']['pages']}")
    print(f"    delta: added={gen1['delta']['added_count']} unchanged={gen1['delta']['unchanged_count']}")
    print(f"    kv_reuse: {gen1['kv_reuse']['reusable_tokens']} tokens ({rr1:.0%})")

    gen2 = runtime.select_context(["GPUScheduler", "Queue", "CommandBuffer"], "FIX", 8000, previous_error="undefined symbol")
    rr2 = gen2['kv_reuse']['reuse_ratio']
    assert 0.0 <= rr2 <= 1.0, f"gen2 reuse_ratio={rr2}"
    assert gen2['kv_reuse']['reusable_tokens'] <= gen2['working_set']['tokens'], "gen2 reusable > total"
    print(f"\n  gen2: tokens={gen2['working_set']['tokens']} pages={gen2['working_set']['pages']}")
    print(f"    delta: added={gen2['delta']['added_count']} unchanged={gen2['delta']['unchanged_count']} reuse={gen2['delta']['reuse_ratio']:.0%}")
    print(f"    kv_reuse: {gen2['kv_reuse']['reusable_tokens']} tokens ({rr2:.0%})")

    gen3 = runtime.select_context(["Parser"], "EXPLAIN", 8000)
    rr3 = gen3['kv_reuse']['reuse_ratio']
    assert 0.0 <= rr3 <= 1.0, f"gen3 reuse_ratio={rr3}"
    assert gen3['kv_reuse']['reusable_tokens'] <= gen3['working_set']['tokens'], "gen3 reusable > total"
    print(f"\n  gen3: tokens={gen3['working_set']['tokens']} pages={gen3['working_set']['pages']}")
    print(f"    delta: added={gen3['delta']['added_count']} removed={gen3['delta']['removed_count']} unchanged={gen3['delta']['unchanged_count']}")

    evicted = runtime.evict_stale()
    print(f"\n  evicted: {len(evicted)}")
    promoted = runtime.promote_hot()
    print(f"  promoted: {len(promoted)}")

    print(f"\n  final stats: {runtime.stats()}")
    print("  PASS")


def test_full_runtime():
    print("\nC.10.8 Full Selective Context Runtime")
    print("-" * 50)

    runtime = SelectiveContextRuntime(max_active_pages=20, max_tokens=16000)

    symbols = [
        ("GPUScheduler", ["Queue", "CommandBuffer", "Device"], "gpu_scheduler.zig"),
        ("Queue", ["Device"], "queue.zig"),
        ("CommandBuffer", [], "command_buffer.zig"),
        ("Device", [], "device.zig"),
        ("Parser", ["AST", "Token"], "parser.zig"),
        ("AST", [], "ast.zig"),
        ("Token", [], "token.zig"),
        ("Allocator", [], "allocator.zig"),
    ]
    for name, deps, fp in symbols:
        runtime.register_symbol(name, dependencies=deps, file_path=fp)

    tasks = [
        (["GPUScheduler", "submit"], "FIX", "undefined symbol 'submit'"),
        (["GPUScheduler", "Queue"], "MODIFY", None),
        (["Parser", "AST"], "EXPLAIN", None),
    ]

    for entities, task_type, error in tasks:
        t0 = time.monotonic()
        result = runtime.select_context(entities, task_type, 16000, previous_error=error)
        dur = (time.monotonic() - t0) * 1000
        rr = result['kv_reuse']['reuse_ratio']
        rt = result['kv_reuse']['reusable_tokens']
        wt = result['working_set']['tokens']
        assert 0.0 <= rr <= 1.0, f"reuse_ratio={rr} out of [0,1]"
        assert rt <= wt, f"reusable_tokens={rt} > working_set_tokens={wt}"
        print(f"\n  task={task_type} entities={entities}")
        print(f"    tokens: {wt}")
        print(f"    pages: {result['working_set']['pages']}")
        print(f"    kv_reuse: {rt} ({rr:.0%})")
        print(f"    delta: +{result['delta']['added_count']} -{result['delta']['removed_count']} ={result['delta']['unchanged_count']}")
        print(f"    duration: {dur:.1f}ms")

    final = runtime.stats()
    print(f"\n  final: {final}")
    print("  PASS")


def main():
    print("C.10 SELECTIVE CONTEXT RUNTIME VERIFICATION")
    print("=" * 60)

    tests = [
        test_address_space,
        test_page_table,
        test_controller,
        test_selector,
        test_delta,
        test_kv_segment_cache,
        test_working_set,
        test_full_runtime,
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
        print("C.10 SELECTIVE CONTEXT: VERIFIED")
    else:
        print("C.10 SELECTIVE CONTEXT: FAILURES DETECTED")
    print("=" * 60)


if __name__ == "__main__":
    main()
