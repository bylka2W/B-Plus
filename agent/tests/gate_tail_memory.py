"""
STAGE 2 RELEASE GATE — TAIL LATENCY + MEMORY PROFILE
Explains p99/max latency. Measures memory footprint.
"""
import os
import sys
import json
import time
import tracemalloc

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "engine"))


def main():
    print("=" * 70)
    print("STAGE 2 RELEASE GATE — TAIL LATENCY + MEMORY PROFILE")
    print("=" * 70)

    # Memory: before load
    tracemalloc.start()
    mem_before = tracemalloc.get_traced_memory()

    from knowledge import Knowledge
    k = Knowledge.load()

    mem_after = tracemalloc.get_traced_memory()
    load_heap = mem_after[0] - mem_before[0]
    load_peak = mem_after[1] - mem_before[1]

    print(f"\n--- MEMORY ---")
    print(f"  Heap after load:    {load_heap / 1024 / 1024:.1f} MB")
    print(f"  Peak after load:    {load_peak / 1024 / 1024:.1f} MB")

    # Component sizes
    from common import MEMORY_DIR, load_json
    sizes = {}
    for fname in ["concepts.json", "facts.json", "semantic_relations.json",
                   "source_evidence.json", "source_symbols.json", "source_index.json"]:
        path = MEMORY_DIR / fname
        sizes[fname] = path.stat().st_size
        print(f"  {fname:30s} {sizes[fname] / 1024:.0f} KB")
    total = sum(sizes.values())
    print(f"  {'TOTAL':30s} {total / 1024:.0f} KB")

    # Tail latency: profile cold queries
    print(f"\n--- TAIL LATENCY ---")
    from evidence_bundle import build_evidence_bundle
    from source_store import SourceStore

    store = SourceStore.load()
    funcs = [c["canonical_name"].rsplit("/", 1)[-1]
             for c in k.cb.qe.search.concepts.values()
             if c["concept_type"] == "FUNCTION"
             and c.get("verification_status") == "VERIFIED"][:100]

    questions = [("Who calls %s?" % fn) for fn in funcs[:50]]
    questions += [("What does %s call?" % fn) for fn in funcs[:50]]

    # Cold: invalidate cache before each
    times = []
    for q in questions:
        k.route(q)
        t0 = time.perf_counter()
        bd = build_evidence_bundle(k, q, None).to_dict()
        elapsed = (time.perf_counter() - t0) * 1000
        times.append(elapsed)

    times_sorted = sorted(times)
    n = len(times_sorted)
    p50 = times_sorted[n // 2]
    p95 = times_sorted[int(n * 0.95)]
    p99 = times_sorted[int(n * 0.99)]
    mx = times_sorted[-1]
    avg = sum(times) / n

    print(f"  n={n}")
    print(f"  avg:  {avg:.2f} ms")
    print(f"  p50:  {p50:.2f} ms")
    print(f"  p95:  {p95:.2f} ms")
    print(f"  p99:  {p99:.2f} ms")
    print(f"  max:  {mx:.2f} ms")

    # Explain the slowest queries
    slowest = sorted(zip(questions, times), key=lambda x: -x[1])[:5]
    print(f"\n  Slowest 5:")
    for q, t in slowest:
        print(f"    {t:7.2f} ms  {q[:60]}")

    # Check: are slow queries the first ones (cold start)?
    first5_avg = sum(times[:5]) / 5
    last5_avg = sum(times[-5:]) / 5
    print(f"\n  First 5 avg: {first5_avg:.2f} ms")
    print(f"  Last 5 avg:  {last5_avg:.2f} ms")
    if first5_avg > last5_avg * 2:
        print(f"  NOTE: Cold start effect detected (first >> last)")
    else:
        print(f"  NOTE: No significant cold start effect")

    # Memory after queries
    mem_final = tracemalloc.get_traced_memory()
    print(f"\n--- MEMORY AFTER QUERIES ---")
    print(f"  Heap: {mem_final[0] / 1024 / 1024:.1f} MB")
    print(f"  Peak: {mem_final[1] / 1024 / 1024:.1f} MB")

    tracemalloc.stop()

    result = {
        "memory": {
            "heap_mb": round(load_heap / 1024 / 1024, 1),
            "peak_mb": round(load_peak / 1024 / 1024, 1),
            "file_sizes": {k: round(v / 1024, 0) for k, v in sizes.items()},
            "total_kb": round(total / 1024, 0),
        },
        "tail_latency": {
            "n": n,
            "avg_ms": round(avg, 2),
            "p50_ms": round(p50, 2),
            "p95_ms": round(p95, 2),
            "p99_ms": round(p99, 2),
            "max_ms": round(mx, 2),
            "first5_avg_ms": round(first5_avg, 2),
            "last5_avg_ms": round(last5_avg, 2),
        },
    }
    with open(MEMORY_DIR / "tail_memory_audit.json", "w") as f:
        json.dump(result, f, indent=2)
    print(f"\nSaved: memory/tail_memory_audit.json")


if __name__ == "__main__":
    main()
