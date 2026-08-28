import json
import os
import sys
import time
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(os.path.dirname(HERE), "engine")
sys.path.insert(0, ENGINE)

from common import ZIG_ROOT, MEMORY_DIR, save_json, load_json
from source_snapshot import SourceSnapshot, SNAPSHOT_PATH

BASELINE_PATH = MEMORY_DIR / "incremental_baseline.json"


def bench_snapshot_build(n=3):
    times = []
    for _ in range(n):
        t0 = time.time()
        SourceSnapshot.build(str(ZIG_ROOT))
        times.append(time.time() - t0)
    times.sort()
    return {
        "p50": round(times[len(times) // 2] * 1000),
        "min": round(times[0] * 1000),
        "max": round(times[-1] * 1000),
        "n": n,
    }


def bench_snapshot_compare(n=10):
    s1 = SourceSnapshot.build(str(ZIG_ROOT))
    times = []
    for _ in range(n):
        t0 = time.time()
        s2 = SourceSnapshot.build(str(ZIG_ROOT))
        s1.compare(s2)
        times.append(time.time() - t0)
    times.sort()
    return {
        "p50": round(times[len(times) // 2] * 1000),
        "min": round(times[0] * 1000),
        "max": round(times[-1] * 1000),
        "n": n,
    }


def bench_verify_sha_cache(n=5):
    from verify import VerifyEngine
    from context import ContextBuilder
    cb = ContextBuilder.load()
    ve = VerifyEngine(cb, root=str(ZIG_ROOT))
    files = list(ZIG_ROOT.rglob("*.zig"))[:20]
    norms = [os.path.normpath(str(f)) for f in files]

    cold_times = []
    warm_times = []
    for _ in range(n):
        ve.invalidate_cache()
        t0 = time.time()
        for norm in norms:
            ve._get_source(norm)
        cold_times.append(time.time() - t0)

        t0 = time.time()
        for norm in norms:
            ve._get_source(norm)
        warm_times.append(time.time() - t0)

    cold_times.sort()
    warm_times.sort()
    mid = len(cold_times) // 2
    return {
        "cold_p50_ms": round(cold_times[mid] * 1000),
        "warm_p50_ms": round(warm_times[mid] * 1000),
        "speedup": round(cold_times[mid] / max(warm_times[mid], 0.0001), 1),
        "files_tested": len(norms),
        "n": n,
    }


def bench_knowledge_shared_cb(n=3):
    from knowledge import Knowledge
    times = []
    for _ in range(n):
        t0 = time.time()
        k = Knowledge.load()
        times.append(time.time() - t0)
    times.sort()
    return {
        "p50_ms": round(times[len(times) // 2] * 1000),
        "min_ms": round(times[0] * 1000),
        "max_ms": round(times[-1] * 1000),
        "n": n,
    }


def main():
    print("Benchmarking snapshot build...")
    snap_build = bench_snapshot_build()
    print(f"  snapshot build: {snap_build['p50']}ms")

    print("Benchmarking snapshot compare...")
    snap_cmp = bench_snapshot_compare()
    print(f"  snapshot compare: {snap_cmp['p50']}ms")

    print("Benchmarking verify SHA cache...")
    sha_cache = bench_verify_sha_cache()
    print(f"  verify SHA cold: {sha_cache['cold_p50_ms']}ms, "
          f"warm: {sha_cache['warm_p50_ms']}ms, "
          f"speedup: {sha_cache['speedup']}x")

    print("Benchmarking shared CB...")
    shared_cb = bench_knowledge_shared_cb()
    print(f"  shared CB load: {shared_cb['p50_ms']}ms")

    result = {
        "schema": "incremental_baseline",
        "version": 1,
        "snapshot_build": snap_build,
        "snapshot_compare": snap_cmp,
        "verify_sha_cache": sha_cache,
        "shared_context_builder": shared_cb,
    }
    save_json(BASELINE_PATH, result)
    print(f"\nBaseline saved: {BASELINE_PATH}")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
