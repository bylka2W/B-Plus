import sys
import os
import time
import json

sys.path.insert(0, os.path.dirname(__file__))

from global_resource_cache import (
    CacheKey, CacheTier, GlobalCacheStore, GlobalResourceCache,
    ResourceMeter, _content_hash,
)


def test_cache_key():
    print("\nC.12.1 CacheKey (operation+inputs+version)")
    print("-" * 50)

    k1 = CacheKey.make("parse", "gpu.zig")
    k2 = CacheKey.make("parse", "gpu.zig")
    k3 = CacheKey.make("parse", "queue.zig")
    k4 = CacheKey.make("parse", "gpu.zig", version="2.0")

    assert str(k1) == str(k2), "same inputs must produce same key"
    assert str(k1) != str(k3), "different inputs must produce different key"
    assert str(k1) != str(k4), "different version must produce different key"

    print(f"  parse(gpu.zig) v1: {k1}")
    print(f"  parse(gpu.zig) v1: {k2} (same)")
    print(f"  parse(queue.zig) v1: {k3} (diff)")
    print(f"  parse(gpu.zig) v2: {k4} (diff)")
    print("  PASS")


def test_global_store():
    print("\nC.12.2 GlobalCacheStore (unified hierarchy)")
    print("-" * 50)

    store = GlobalCacheStore(vram_limit=4096, ram_limit=16384, nvme_limit=65536)

    k1 = CacheKey.make("parse", "main.zig")
    r1 = store.put(k1, b"ast_main", CacheTier.VRAM, recompute_cost_ms=50)
    assert r1["status"] == "stored"
    assert r1["tier"] == "VRAM"
    print(f"  put parse(main.zig) -> VRAM: {r1}")

    k2 = CacheKey.make("parse", "main.zig")
    r2 = store.put(k2, b"ast_main", CacheTier.RAM)
    assert r2["status"] == "dedup"
    print(f"  put parse(main.zig) again -> dedup: {r2}")

    k3 = CacheKey.make("compile", "main.zig")
    r3 = store.put(k3, b"compiled_main", CacheTier.VRAM, recompute_cost_ms=200)
    print(f"  put compile(main.zig) -> VRAM: {r3}")

    v = store.get(k1)
    assert v == b"ast_main"
    print(f"  get parse(main.zig): HIT")

    miss = store.get(CacheKey.make("missing", "x"))
    assert miss is None
    print(f"  get missing: MISS")

    assert store.hit_ratio() == 0.5
    print(f"  hit_ratio: {store.hit_ratio()}")

    stats = store.stats()
    assert stats["dedup_saves"] == 1
    assert stats["entries"] == 2
    print(f"  entries: {stats['entries']} dedup_saves: {stats['dedup_saves']}")
    print(f"  vram: {stats['vram_used']} ram: {stats['ram_used']} nvme: {stats['nvme_used']}")
    print(f"  tiers: {stats['tiers']}")
    print("  PASS")


def test_tier_pressure():
    print("\nC.12.3 Tier Pressure (VRAM->RAM->NVMe fallback)")
    print("-" * 50)

    store = GlobalCacheStore(vram_limit=200, ram_limit=600, nvme_limit=2000)

    for i in range(5):
        k = CacheKey.make("tensor", f"layer_{i}")
        r = store.put(k, bytes([i] * 100), CacheTier.VRAM, recompute_cost_ms=10)
        print(f"  tensor layer_{i} -> {r['tier']}")

    assert store.vram_used <= 200
    print(f"  VRAM used: {store.vram_used} (limit: 200)")

    tier_stats = store.tier_stats()
    vram_count = tier_stats["VRAM"]["count"]
    ram_count = tier_stats["RAM"]["count"]
    nvme_count = tier_stats["NVME_HOT"]["count"]
    print(f"  VRAM: {vram_count} RAM: {ram_count} NVME: {nvme_count}")

    assert vram_count + ram_count + nvme_count == 5
    print("  PASS")


def test_eviction_score():
    print("\nC.12.4 Cost-Aware Eviction")
    print("-" * 50)

    store = GlobalCacheStore(vram_limit=500, ram_limit=500, nvme_limit=5000)

    for i in range(10):
        k = CacheKey.make("obj", f"item_{i}")
        store.put(k, bytes([i + 10] * 80), CacheTier.RAM, recompute_cost_ms=1.0)

    k_cheap = CacheKey.make("obj", "cheap")
    store.put(k_cheap, bytes([20] * 80), CacheTier.RAM, recompute_cost_ms=0.1)

    k_exp = CacheKey.make("obj", "expensive")
    store.put(k_exp, bytes([30] * 80), CacheTier.RAM, recompute_cost_ms=1000.0)
    store.get(k_exp)
    store.get(k_exp)
    store.get(k_exp)

    print(f"  12 objects: 10 generic, 1 cheap(0.1ms), 1 expensive(1000ms, 3x accessed)")
    print(f"  RAM used: {store.ram_used}")

    evicted_before = store._evictions
    k_fill = CacheKey.make("fill", "big")
    store.put(k_fill, bytes([40] * 300), CacheTier.RAM, recompute_cost_ms=5.0)
    evicted_now = store._evictions

    print(f"  evictions after overflow: {evicted_now - evicted_before}")

    assert store.has(k_exp), "expensive must survive eviction"
    print(f"  expensive object: SURVIVED")
    print(f"  cheap object evicted: {not store.has(k_cheap)}")
    print("  PASS")


def test_compute():
    print("\nC.12.5 Compute (operation+inputs+version)")
    print("-" * 50)

    cache = GlobalResourceCache(vram_limit=8 * 1024**3, ram_limit=16 * 1024**3)

    call_count = [0]

    def expensive_parse(filename):
        call_count[0] += 1
        time.sleep(0.001)
        return {"ast": f"parsed_{filename}"}

    r1, hit1 = cache.compute("parse", expensive_parse, "main.zig")
    assert not hit1
    assert r1 == {"ast": "parsed_main.zig"}
    print(f"  parse(main.zig): MISS, calls={call_count[0]}")

    r2, hit2 = cache.compute("parse", expensive_parse, "main.zig")
    assert hit2
    assert r2 == {"ast": "parsed_main.zig"}
    assert call_count[0] == 1
    print(f"  parse(main.zig): HIT, calls={call_count[0]} (no recompute)")

    r3, hit3 = cache.compute("parse", expensive_parse, "utils.zig")
    assert not hit3
    print(f"  parse(utils.zig): MISS")

    r4, hit4 = cache.compute("parse", expensive_parse, "main.zig")
    assert hit4
    print(f"  parse(main.zig): HIT again")

    cache_stats = cache.store.stats()
    assert cache_stats["hits"] == 2
    assert cache_stats["misses"] == 2
    print(f"  hits: {cache_stats['hits']} misses: {cache_stats['misses']}")
    print(f"  hit_ratio: {cache_stats['hit_ratio']}")
    print("  PASS")


def test_compress_cold():
    print("\nC.12.6 Compress Cold Objects")
    print("-" * 50)

    store = GlobalCacheStore(vram_limit=1024 * 1024, ram_limit=4 * 1024 * 1024)

    for i in range(20):
        k = CacheKey.make("source", f"file_{i}.zig")
        data = f"fn main() void {{ var x: i32 = {i}; return x; }}" * 50
        store.put(k, data.encode(), CacheTier.NVME_HOT, recompute_cost_ms=5.0)

    total_before = sum(e.size_bytes for e in store._entries.values())
    print(f"  20 source files: total_bytes={total_before}")

    compressed = store.compress_cold(threshold_access=1)
    total_after = sum(e.size_bytes for e in store._entries.values())

    print(f"  compressed: {compressed} objects")
    print(f"  total after: {total_after} bytes")
    print(f"  saved: {total_before - total_after} bytes")

    assert total_after <= total_before
    print("  PASS")


def test_baseline_vs_cached():
    print("\nC.12.7 Baseline vs Cached Benchmark (REAL MEASUREMENT)")
    print("-" * 50)

    cache = GlobalResourceCache(vram_limit=8 * 1024**3, ram_limit=16 * 1024**3)

    def parse_file(name):
        data = b""
        for _ in range(100):
            data += f"symbol_{name}".encode() * 10
        return {"symbols": len(data)}

    def extract_symbols(ast):
        return [f"sym_{i}" for i in range(50)]

    def build_relations(syms):
        return [(syms[i], "CALLS", syms[i + 1]) for i in range(len(syms) - 1)]

    operations = [
        ("parse", parse_file, ("main.zig",), {}),
        ("parse", parse_file, ("utils.zig",), {}),
        ("parse", parse_file, ("gpu.zig",), {}),
        ("extract_symbols", extract_symbols, ({"n": 100},), {}),
        ("extract_symbols", extract_symbols, ({"n": 200},), {}),
        ("build_relations", build_relations, (["a", "b", "c", "d"],), {}),
    ]

    print("  Running BASELINE (no cache, 5 iterations)...")
    baseline = cache.baseline_benchmark(operations, iterations=5)
    print(f"    time: {baseline['elapsed_ms']}ms")
    print(f"    recomputes: {baseline['total_recomputes']}")

    print("  Running CACHED (5 iterations, same operations)...")
    cached = cache.cached_benchmark(operations, iterations=5)
    print(f"    time: {cached['elapsed_ms']}ms")
    print(f"    recomputes: {cached['total_recomputes']}")
    print(f"    hits: {cached['total_hits']}")
    print(f"    hit_ratio: {cached['hit_ratio']}")

    report = cache.savings_report(baseline, cached)
    print(f"\n  SAVINGS REPORT:")
    print(f"    time: {report['time_baseline_ms']}ms -> {report['time_cached_ms']}ms")
    print(f"    time saved: {report['time_saved_ms']}ms ({report['time_reduction_pct']}%)")
    print(f"    recomputes: {report['recomputes_baseline']} -> {report['recomputes_cached']}")
    print(f"    compute saved: {report['recomputes_saved']} ({report['compute_reduction_pct']}%)")
    print(f"    hit_ratio: {report['hit_ratio']}")
    print(f"    dedup_saves: {report['dedup_saves']}")

    assert report["recomputes_cached"] < report["recomputes_baseline"]
    assert report["hit_ratio"] > 0
    print("  PASS")


def test_real_resources():
    print("\nC.12.8 Real Resource Measurement")
    print("-" * 50)

    meter = ResourceMeter()
    snap1 = meter.snapshot()
    print(f"  RAM: {snap1['ram_bytes'] / 1024 / 1024:.1f} MB")
    print(f"  VRAM: {snap1['vram_bytes'] / 1024 / 1024:.1f} MB")

    data = []
    for i in range(1000):
        data.append(b"x" * 10000)
    snap2 = meter.snapshot()

    print(f"  After 10MB allocation:")
    print(f"  RAM: {snap2['ram_bytes'] / 1024 / 1024:.1f} MB")
    ram_delta = snap2["ram_bytes"] - snap1["ram_bytes"]
    print(f"  RAM delta: {ram_delta / 1024 / 1024:.1f} MB")
    assert snap2["ram_bytes"] >= snap1["ram_bytes"]

    del data
    snap3 = meter.snapshot()
    print(f"  After dealloc:")
    print(f"  RAM: {snap3['ram_bytes'] / 1024 / 1024:.1f} MB")

    print(f"  CPU time: {snap3['cpu_time_ms']:.1f}ms")

    cache = GlobalResourceCache()
    heavy_result, _ = cache.compute("heavy", lambda: sum(range(100000)))
    heavy_result2, hit = cache.compute("heavy", lambda: sum(range(100000)))
    assert hit

    cache_stats = cache.store.stats()
    print(f"  Cache entries: {cache_stats['entries']}")
    print(f"  Hit ratio: {cache_stats['hit_ratio']}")
    print(f"  Dedup saves: {cache_stats['dedup_saves']}")

    final_snap = cache.snapshot()
    print(f"  Resource: {final_snap['resource']}")
    print("  PASS")


def main():
    print("C.12 GLOBAL RESOURCE CACHE VERIFICATION")
    print("=" * 60)

    tests = [
        test_cache_key,
        test_global_store,
        test_tier_pressure,
        test_eviction_score,
        test_compute,
        test_compress_cold,
        test_baseline_vs_cached,
        test_real_resources,
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
        print("C.12 GLOBAL RESOURCE CACHE: VERIFIED")
    else:
        print(f"RESULTS: {passed}/{passed + failed} PASS, {failed} FAIL")
        print("C.12: NOT VERIFIED")
    print("=" * 60)


if __name__ == "__main__":
    main()
