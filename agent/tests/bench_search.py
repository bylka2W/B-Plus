import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from search import Search

TARGETS = {"p50": 1.0, "p95": 5.0, "p99": 20.0}


def pct(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    k = max(0, min(len(sorted_vals) - 1, int(round(p / 100.0 * (len(sorted_vals) - 1)))))
    return sorted_vals[k]


def timed(fn, *args):
    t = time.perf_counter()
    fn(*args)
    return (time.perf_counter() - t) * 1000.0


def main():
    t0 = time.perf_counter()
    s = Search.load()
    load_ms = (time.perf_counter() - t0) * 1000.0

    all_cids = list(s.concepts.keys())
    rng = random.Random(1337)
    sample = rng.sample(all_cids, min(400, len(all_cids)))
    names = [
        c["name"]
        for c in (s._summaries[cid] for cid in rng.sample(all_cids, 150))
    ]
    mod_names = [s.concepts[m]["canonical_name"] for m in s._modules[:60]]
    paths = list(s.file_paths)[:40]
    prefixes = ["e", "em", "get", "set", "hir", "bir", "mir", "type", "x"]

    ops = []
    for n in names:
        ops.append(timed(s.find_symbol, n))
    for p in prefixes:
        ops.append(timed(s.find_symbols, p))
    for m in mod_names:
        ops.append(timed(s.find_module, m))
        ops.append(timed(s.find_dependencies, m))
        ops.append(timed(s.find_dependents, m))
    for pth in paths:
        ops.append(timed(s.find_file, pth))
    for cid in sample:
        ops.append(timed(s.find_callers, cid))
        ops.append(timed(s.find_callees, cid))
        ops.append(timed(s.find_references, cid))
        ops.append(timed(s.find_referenced_by, cid))
        ops.append(timed(s.find_types_used, cid))
        ops.append(timed(s.find_type_users, cid))
        ops.append(timed(s.find_contains, cid))

    ops.sort()
    n = len(ops)
    p50 = pct(ops, 50)
    p95 = pct(ops, 95)
    p99 = pct(ops, 99)

    print(f"LOAD_MS: {load_ms:.1f} (one-time)")
    print(f"OPS: {n}")
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
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
