import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(r"C:\B-Plus\agent\engine")))

from answer import AnswerEngine

TARGETS = {"p50": 10.0, "p95": 100.0, "p99": 500.0}


def pct(vals, p):
    if not vals:
        return 0.0
    k = max(0, min(len(vals) - 1, int(round(p / 100.0 * (len(vals) - 1)))))
    return vals[k]


def main():
    t0 = time.perf_counter()
    ae = AnswerEngine.load()
    load_ms = (time.perf_counter() - t0) * 1000.0

    rng = random.Random(4242)
    concepts = ae.cb.qe.search.concepts
    cids = rng.sample(list(concepts.keys()), min(200, len(concepts)))

    ops = []
    for cid in cids:
        name = ae.cb.qe.search._summaries[cid]["name"]
        s = time.perf_counter()
        m = ae.answer("DEFINITION", name)
        ops.append((time.perf_counter() - s) * 1000.0)
        assert m["status"] in ("RESOLVED", "AMBIGUOUS"), m["status"]
        s = time.perf_counter()
        m = ae.answer("CALLEES", name)
        ops.append((time.perf_counter() - s) * 1000.0)
        s = time.perf_counter()
        m = ae.answer("CALLERS", name)
        ops.append((time.perf_counter() - s) * 1000.0)

    ops.sort()
    p50, p95, p99 = pct(ops, 50), pct(ops, 95), pct(ops, 99)

    print(f"LOAD_MS: {load_ms:.1f} (one-time)")
    print(f"OPS: {len(ops)}")
    print(f"P50_MS: {p50:.4f}   P95_MS: {p95:.4f}   P99_MS: {p99:.4f}")
    print(f"MAX_MS: {ops[-1]:.4f}")

    ok = True
    for name, limit in TARGETS.items():
        val = {"p50": p50, "p95": p95, "p99": p99}[name]
        st = "PASS" if val < limit else "FAIL"
        if st == "FAIL":
            ok = False
        print(f"TARGET_{name.upper()}: {val:.4f} < {limit} ms -> {st}")

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
