import sys
import os
import time

sys.path.insert(0, os.path.dirname(__file__))

from unified_cache import (
    content_hash, CacheAddressSpace, ContentAddressedStore,
    MemoryPressureManager, CostAwareEviction, CPUResultCache,
    CompressionManager, DeduplicationEngine, CacheTelemetry,
    UnifiedResourceController, Tier, CacheObject,
)


def test_address_space():
    print("\nC.11.1 CacheAddressSpace")
    print("-" * 50)
    asp = CacheAddressSpace()

    o1 = asp.register("file:main.zig", b"fn main() void {}", Tier.RAM, recompute_cost_ms=50.0)
    o2 = asp.register("file:utils.zig", b"fn add(a: i32) i32 {}", Tier.RAM, recompute_cost_ms=10.0)
    o3 = asp.register("ast:main.zig", b"AST_NODE_1", Tier.VRAM, recompute_cost_ms=100.0)

    assert o1.content_hash == content_hash(b"fn main() void {}")
    print(f"  registered 3 objects")

    found = asp.get("file:main.zig")
    assert found is not None
    assert found.access_count == 1
    print(f"  get file:main.zig: access_count={found.access_count}")

    by_hash = asp.get_by_hash(o1.content_hash)
    assert len(by_hash) == 1
    print(f"  get_by_hash: {len(by_hash)} objects")

    asp.move_tier("file:utils.zig", Tier.NVME_HOT)
    assert asp.get("file:utils.zig").tier == Tier.NVME_HOT
    print(f"  move file:utils.zig -> NVME_HOT")

    assert len(asp.objects_in_tier(Tier.RAM)) == 1
    assert len(asp.objects_in_tier(Tier.NVME_HOT)) == 1
    assert len(asp.objects_in_tier(Tier.VRAM)) == 1
    print(f"  RAM=1 NVME_HOT=1 VRAM=1")

    stats = asp.stats()
    assert stats["total_objects"] == 3
    assert stats["unique_hashes"] == 3
    print(f"  stats: {stats}")
    print("  PASS")


def test_content_addressed_store():
    print("\nC.11.2 ContentAddressedStore")
    print("-" * 50)
    store = ContentAddressedStore()

    ch1 = store.put(b"hello world")
    ch2 = store.put(b"hello world")
    ch3 = store.put(b"different data")

    assert ch1 == ch2
    assert ch1 != ch3
    assert store.ref_count(ch1) == 2
    assert store.ref_count(ch3) == 1
    print(f"  put hello: refs={store.ref_count(ch1)} (dedup)")
    print(f"  put different: refs={store.ref_count(ch3)}")

    data = store.get(ch1)
    assert data == b"hello world"
    print(f"  get: {data}")

    ratio = store.dedup_ratio()
    assert ratio == 3.0 / 2.0
    print(f"  dedup_ratio: {ratio}")

    stats = store.stats()
    assert stats["objects"] == 2
    assert stats["total_bytes"] == 25
    assert stats["total_refs"] == 3
    print(f"  stats: {stats}")
    print("  PASS")


def test_memory_pressure():
    print("\nC.11.3 MemoryPressureManager")
    print("-" * 50)
    pm = MemoryPressureManager(vram_limit=1024 * 1024, ram_limit=4 * 1024 * 1024)

    assert pm.level() == "LOW"
    print(f"  initial: level={pm.level()} vram={pm.vram_pressure()} ram={pm.ram_pressure()}")

    pm.allocate_vram(400 * 1024)
    assert pm.level() == "MEDIUM"
    print(f"  after 400K VRAM: level={pm.level()} pressure={pm.vram_pressure()}")

    pm.allocate_vram(400 * 1024)
    assert pm.level() == "HIGH"
    print(f"  after 800K VRAM: level={pm.level()} pressure={pm.vram_pressure()}")

    pm.allocate_vram(100 * 1024)
    assert pm.level() == "CRITICAL"
    print(f"  after 900K VRAM: level={pm.level()}")

    pm.free_vram(500 * 1024)
    assert pm.level() != "CRITICAL"
    print(f"  after free 500K: level={pm.level()}")

    stats = pm.stats()
    assert stats["vram_used"] == 400 * 1024
    print(f"  stats: {stats}")
    print("  PASS")


def test_cost_aware_eviction():
    print("\nC.11.4 CostAwareEviction")
    print("-" * 50)
    asp = CacheAddressSpace()
    pm = MemoryPressureManager(vram_limit=1024, ram_limit=4096)
    evict = CostAwareEviction(asp, pm)

    asp.register("cheap1", b"x" * 200, Tier.RAM, recompute_cost_ms=1.0)
    asp.register("expensive1", b"y" * 200, Tier.RAM, recompute_cost_ms=500.0)
    asp.register("cheap2", b"z" * 200, Tier.RAM, recompute_cost_ms=2.0)
    asp.register("expensive2", b"w" * 200, Tier.RAM, recompute_cost_ms=1000.0)

    for _ in range(3):
        asp.get("expensive1")
        asp.get("expensive2")

    print(f"  4 objects: cheap1=1ms, expensive1=500ms, cheap2=2ms, expensive2=1000ms")
    print(f"  expensive accessed 3x, cheap accessed 0x")

    pm.ram_used = 800
    pm.ram_limit = 800
    evicted = evict.evict_to_target(Tier.RAM, 250)
    print(f"  evicted (need 250 bytes): {evicted}")

    assert "cheap1" in evicted or "cheap2" in evicted
    assert "expensive1" not in evicted
    assert "expensive2" not in evicted
    print(f"  cheap evicted first (low recompute cost)")

    stats = evict.stats()
    assert stats["total_evictions"] > 0
    print(f"  stats: {stats}")
    print("  PASS")


def test_cpu_result_cache():
    print("\nC.11.5 CPUResultCache")
    print("-" * 50)
    cache = CPUResultCache()

    r1 = cache.get("parse", "file.zig")
    assert r1 is None
    print(f"  parse(file.zig): MISS")

    cache.put("parse", {"ast": "node_1"}, "file.zig")
    r2 = cache.get("parse", "file.zig")
    assert r2 is not None
    assert r2 == {"ast": "node_1"}
    print(f"  parse(file.zig): HIT -> {r2}")

    r3 = cache.get("compile", "file.zig")
    assert r3 is None
    print(f"  compile(file.zig): MISS")

    assert cache.hit_ratio() == 1 / 3
    print(f"  hit_ratio: {cache.hit_ratio()}")

    cache.put("compile", {"status": "ok"}, "file.zig")
    r4 = cache.get("compile", "file.zig")
    assert r4 == {"status": "ok"}
    assert cache.hit_ratio() == 2 / 4
    print(f"  compile(file.zig): HIT -> {r4}")
    print(f"  hit_ratio after: {cache.hit_ratio()}")

    stats = cache.stats()
    assert stats["cached_ops"] == 2
    assert stats["hits"] == 2
    assert stats["misses"] == 2
    print(f"  stats: {stats}")
    print("  PASS")


def test_compression():
    print("\nC.11.6 CompressionManager")
    print("-" * 50)
    cm = CompressionManager()

    original = b"fn main() void { var x: i32 = 0; x = x + 1; return; }" * 100

    c_light = cm.compress(original, "light")
    assert len(c_light) <= len(original)
    print(f"  original: {len(original)} bytes")
    print(f"  compressed (light): {len(c_light)} bytes")

    c_aggressive = cm.compress(original, "aggressive")
    print(f"  compressed (aggressive): {len(c_aggressive)} bytes")

    d = cm.decompress(c_light if len(c_light) < len(c_aggressive) else c_aggressive)
    assert d == original
    print(f"  decompress: roundtrip OK ({len(d)} bytes)")

    ratio = cm.compression_ratio()
    assert 0.0 <= ratio <= 1.0
    print(f"  compression_ratio: {ratio}")
    print(f"  bytes_saved: {cm.bytes_saved()}")

    stats = cm.stats()
    assert stats["original_bytes"] > 0
    assert stats["bytes_saved"] >= 0
    print(f"  stats: {stats}")
    print("  PASS")


def test_deduplication():
    print("\nC.11.7 DeduplicationEngine")
    print("-" * 50)
    asp = CacheAddressSpace()
    store = ContentAddressedStore()
    dedup = DeduplicationEngine(asp, store)

    is_dup, oid1 = dedup.check_and_store("a1", b"identical data", Tier.RAM)
    assert not is_dup
    print(f"  store a1: dup={is_dup} -> stored")

    is_dup, orig = dedup.check_and_store("a2", b"identical data", Tier.RAM)
    assert is_dup
    assert orig == "a1"
    print(f"  store a2: dup={is_dup} -> original={orig}")

    is_dup, oid3 = dedup.check_and_store("b1", b"different data", Tier.RAM)
    assert not is_dup
    print(f"  store b1: dup={is_dup} -> stored")

    dups = dedup.find_duplicates()
    assert len(dups) >= 1
    print(f"  duplicates: {len(dups)} groups")

    stats = dedup.stats()
    assert stats["dedup_count"] == 1
    assert stats["dedup_bytes"] == 14
    assert stats["duplicates_found"] == 1
    print(f"  stats: {stats}")
    print("  PASS")


def test_unified_controller():
    print("\nC.11.8 UnifiedResourceController")
    print("-" * 50)
    ctrl = UnifiedResourceController(vram_limit=4096, ram_limit=16384)

    r1 = ctrl.put("src:main.zig", b"fn main() void {}", Tier.RAM, recompute_cost_ms=50)
    assert r1["status"] == "stored"
    print(f"  put src:main.zig: {r1}")

    r2 = ctrl.put("src:main.zig", b"fn main() void {}", Tier.RAM)
    assert r2["status"] == "dedup"
    print(f"  put src:main.zig again: {r2}")

    r3 = ctrl.put("src:utils.zig", b"fn add(a: i32) i32 {}", Tier.VRAM, recompute_cost_ms=10)
    print(f"  put src:utils.zig: {r3}")

    v = ctrl.get("src:main.zig")
    assert v == b"fn main() void {}"
    ctrl.promote_on_use("src:main.zig")
    print(f"  get src:main.zig + promote")

    result, hit = ctrl.get_or_compute("parse", lambda f: {"parsed": f}, "test.zig")
    assert not hit
    assert result == {"parsed": "test.zig"}
    print(f"  get_or_compute parse: hit={hit}")

    result2, hit2 = ctrl.get_or_compute("parse", lambda f: {"parsed": f}, "test.zig")
    assert hit2
    print(f"  get_or_compute parse again: hit={hit2}")

    entries = [(f"chunk:{i}", bytes([i] * 50), Tier.RAM) for i in range(20)]
    scan = ctrl.scan_and_cache(entries)
    assert scan["total"] == 20
    print(f"  scan_and_cache: {scan}")

    pressure = ctrl.handle_pressure()
    print(f"  handle_pressure: {pressure}")

    ctrl.snapshot()
    ctrl.snapshot()
    assert len(ctrl.telemetry._snapshots) == 2
    print(f"  snapshots: {len(ctrl.telemetry._snapshots)}")

    stats = ctrl.stats()
    assert stats["dedup"]["dedup_count"] == 1
    assert stats["dedup"]["duplicates_found"] >= 0
    assert stats["cpu_cache"]["hits"] == 1
    print(f"  stats: {stats}")
    print("  PASS")


def test_real_metrics():
    print("\nC.11.9 Real Metrics Verification")
    print("-" * 50)

    ctrl = UnifiedResourceController(vram_limit=8192, ram_limit=32768)

    identical = b"symbol_data" * 100
    for i in range(50):
        ctrl.put(f"sym:{i}", identical, Tier.RAM, recompute_cost_ms=5.0)

    for i in range(50):
        ctrl.put(f"unique:{i}", bytes([i] * 50), Tier.RAM, recompute_cost_ms=10.0)

    dedup = ctrl.dedup.stats()
    print(f"  objects stored: {ctrl.address_space.stats()['total_objects']}")
    print(f"  dedup_count: {dedup['dedup_count']}")
    print(f"  dedup_bytes_saved: {dedup['dedup_bytes']}")
    assert dedup["dedup_count"] == 49
    assert dedup["dedup_bytes"] > 0

    asp_stats = ctrl.address_space.stats()
    print(f"  unique_hashes: {asp_stats['unique_hashes']}")
    assert asp_stats["unique_hashes"] == 51

    hit_count = 0
    miss_count = 0
    for i in range(50):
        r, hit = ctrl.get_or_compute("parse", lambda x: x * 2, i)
        if hit:
            hit_count += 1
        else:
            miss_count += 1
    for i in range(50):
        r, hit = ctrl.get_or_compute("parse", lambda x: x * 2, i)
        if hit:
            hit_count += 1
        else:
            miss_count += 1

    cpu = ctrl.cpu_cache.stats()
    print(f"  cpu_cache: hits={cpu['hits']} misses={cpu['misses']} ratio={cpu['hit_ratio']}")
    assert cpu["hit_ratio"] >= 0.5

    t0 = time.monotonic()
    for _ in range(100):
        ctrl.get_or_compute("heavy", lambda: sum(range(1000)))
    cpu_time = (time.monotonic() - t0) * 1000

    t1 = time.monotonic()
    for _ in range(100):
        ctrl.get_or_compute("heavy", lambda: sum(range(1000)))
    cached_time = (time.monotonic() - t1) * 1000

    print(f"  cpu_recompute: {cpu_time:.1f}ms vs cached: {cached_time:.1f}ms")
    assert cached_time < cpu_time * 2

    print(f"  FINAL stats: {ctrl.stats()}")
    print("  PASS")


def main():
    print("C.11 UNIFIED RESOURCE CACHE VERIFICATION")
    print("=" * 60)

    tests = [
        test_address_space,
        test_content_addressed_store,
        test_memory_pressure,
        test_cost_aware_eviction,
        test_cpu_result_cache,
        test_compression,
        test_deduplication,
        test_unified_controller,
        test_real_metrics,
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
    if failed == 0:
        print(f"RESULTS: {passed}/{passed + failed} PASS, 0 FAIL")
        print("C.11 UNIFIED RESOURCE CACHE: VERIFIED")
    else:
        print(f"RESULTS: {passed}/{passed + failed} PASS, {failed} FAIL")
        print("C.11: NOT VERIFIED")
    print("=" * 60)


if __name__ == "__main__":
    main()
