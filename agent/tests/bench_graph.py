import random
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from graph import KnowledgeGraph

TARGETS = {"p50": 100.0, "p95": 500.0, "p99": 1000.0}


def pct(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    k = max(0, min(len(sorted_vals) - 1, int(round(p / 100.0 * (len(sorted_vals) - 1)))))
    return sorted_vals[k]


def main():
    t0 = time.perf_counter()
    kg = KnowledgeGraph.load()
    load_ms = (time.perf_counter() - t0) * 1000.0

    all_cids = list(kg.concepts.keys())
    rng = random.Random(42)
    sample = rng.sample(all_cids, min(600, len(all_cids)))
    names = [
        c["canonical_name"]
        for c in (kg.get_concept(cid) for cid in rng.sample(all_cids, 200))
        if c
    ]

    ops = []
    for cid in sample:
        t = time.perf_counter()
        kg.callers(cid)
        ops.append((time.perf_counter() - t) * 1000.0)
        t = time.perf_counter()
        kg.callees(cid)
        ops.append((time.perf_counter() - t) * 1000.0)
        t = time.perf_counter()
        mid = kg.get_module(cid)
        if mid:
            kg.module_concepts(mid)
        ops.append((time.perf_counter() - t) * 1000.0)

    for name in names[:100]:
        t = time.perf_counter()
        kg.find_symbol(name)
        ops.append((time.perf_counter() - t) * 1000.0)

    for cid in sample[:150]:
        t = time.perf_counter()
        for dep in kg.dependencies(cid)[:20]:
            kg.dependents(dep)
        ops.append((time.perf_counter() - t) * 1000.0)

    ops.sort()
    n = len(ops)
    total_ms = sum(ops)
    p50 = pct(ops, 50)
    p95 = pct(ops, 95)
    p99 = pct(ops, 99)

    print(f"LOAD_MS: {load_ms:.1f} (one-time, not part of query budget)")
    print(f"OPS: {n}")
    print(f"TOTAL_QUERY_MS: {total_ms:.3f}")
    print(f"P50_MS: {p50:.4f}")
    print(f"P95_MS: {p95:.4f}")
    print(f"P99_MS: {p99:.4f}")
    print(f"MAX_MS: {ops[-1]:.4f}")

    ok = True
    for name, limit in TARGETS.items():
        val = {"p50": p50, "p95": p95, "p99": p99}[name]
        status = "PASS" if val < limit else "FAIL"
        if status == "FAIL":
            ok = False
        print(f"TARGET_{name.upper()}: {val:.4f} < {limit} ms -> {status}")

    fast_budget_ms = 1000.0
    est_fast = load_ms * 0 + (total_ms / max(n, 1)) * 50
    print(f"EST_50OP_ANSWER_MS: {est_fast:.3f} (budget {fast_budget_ms}) -> "
          f"{'PASS' if est_fast < fast_budget_ms else 'FAIL'}")

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
