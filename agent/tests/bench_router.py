import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from knowledge import Knowledge

ROUTE_GATE = {"p50": 1.0, "p95": 5.0, "p99": 20.0}
ASK_GATE = {"p50": 10.0, "p95": 100.0, "p99": 500.0}


def pct(vals, p):
    if not vals:
        return 0.0
    k = max(0, min(len(vals) - 1, int(round(p / 100.0 * (len(vals) - 1)))))
    return vals[k]


def main():
    t0 = time.perf_counter()
    k = Knowledge.load()
    load_ms = (time.perf_counter() - t0) * 1000.0

    rng = random.Random(20260824)
    concepts = k.router.search.concepts
    names = [concepts[c]["name"]
             for c in rng.sample(list(concepts.keys()), 150)]

    templates = [
        "Кто вызывает {n}?",
        "Что вызывает {n}?",
        "Где определён {n}?",
    ]

    route_ops = []
    for n in names:
        for tpl in templates:
            q = tpl.format(n=n)
            s = time.perf_counter()
            d = k.route(q)
            route_ops.append((time.perf_counter() - s) * 1000.0)
            assert d["intent"] in (
                "CALLERS", "CALLEES", "DEFINITION"), (q, d["status"])

    ask_ops = []
    for n in names:
        s = time.perf_counter()
        a = k.ask(f"Кто вызывает {n}?")
        ask_ops.append((time.perf_counter() - s) * 1000.0)
        assert a["status"] in ("RESOLVED", "AMBIGUOUS", "NOT_FOUND")
        s = time.perf_counter()
        a = k.ask(f"Где определён {n}?")
        ask_ops.append((time.perf_counter() - s) * 1000.0)

    def report(tag, ops, gate):
        ops = sorted(ops)
        p50, p95, p99 = pct(ops, 50), pct(ops, 95), pct(ops, 99)
        print(f"{tag}: OPS={len(ops)} "
              f"P50={p50:.4f} P95={p95:.4f} P99={p99:.4f} "
              f"MAX={ops[-1]:.4f}")
        ok = True
        for name, limit in gate.items():
            val = {"p50": p50, "p95": p95, "p99": p99}[name]
            st = "PASS" if val < limit else "FAIL"
            if st == "FAIL":
                ok = False
            print(f"  TARGET_{name.upper()}: {val:.4f} < {limit} -> {st}")
        return ok

    print(f"LOAD_MS: {load_ms:.1f} (one-time)")
    ok_r = report("ROUTE_MS", route_ops, ROUTE_GATE)
    ok_a = report("ASK_MS", ask_ops, ASK_GATE)
    sys.exit(0 if (ok_r and ok_a) else 1)


if __name__ == "__main__":
    main()
