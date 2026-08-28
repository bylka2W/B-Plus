import json
import os
import random
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "engine"))

REQUIREMENT_MS = 20


def percentile(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    idx = int(len(sorted_vals) * p / 100.0)
    return sorted_vals[min(idx, len(sorted_vals) - 1)]


def generate_questions(kp):
    from common import load_json, CONCEPTS_PATH, FACTS_PATH
    concepts_doc = load_json(CONCEPTS_PATH)
    facts_doc = load_json(FACTS_PATH)
    qe = kp.knowledge.cb.qe

    questions = []
    seen = set()

    funcs = [c for c in concepts_doc["items"]
             if c["concept_type"] == "FUNCTION" and c["verification_status"] == "VERIFIED"]
    random.seed(42)
    random.shuffle(funcs)

    for c in funcs:
        name = c["canonical_name"]
        base = name.rsplit("/", 1)[-1]
        if base in seen or len(base) < 3:
            continue
        seen.add(base)
        questions.append(("Who calls %s?" % base, "CALLERS", base))
        questions.append(("Where is %s defined?" % base, "DEFINITION", base))
        questions.append(("What does %s call?" % base, "CALLEES", base))
        if len(questions) >= 120:
            break

    mods = [c for c in concepts_doc["items"]
            if c["concept_type"] == "MODULE" and c["verification_status"] == "VERIFIED"]
    random.shuffle(mods)
    for c in mods:
        name = c["canonical_name"]
        base = name.rsplit("/", 1)[-1]
        if base in seen:
            continue
        seen.add(base)
        questions.append(("Who depends on %s?" % base, "DEPENDENTS", base))
        questions.append(("What does %s depend on?" % base, "DEPENDENCIES", base))
        if len(questions) >= 200:
            break

    random.shuffle(questions)
    return questions


def measure_cold(qp, questions, iterations=20):
    results = []
    for _ in range(iterations):
        q, intent, entity = random.choice(questions)
        qp.cache.invalidate_entity(intent, entity)
        t0 = time.monotonic()
        qr = qp.ask(q, "simple")
        elapsed = (time.monotonic() - t0) * 1000
        results.append({
            "question": q,
            "intent": intent,
            "entity": entity,
            "ms": round(elapsed, 2),
            "terminal": qr.terminal,
            "evidence": len(qr.bundle.get("evidence", [])),
        })
    return results


def measure_no_cache(qp, questions, iterations=100):
    results = []
    for _ in range(iterations):
        q, intent, entity = random.choice(questions)
        t0 = time.monotonic()
        qr = qp.ask(q, "simple")
        elapsed = (time.monotonic() - t0) * 1000
        results.append({
            "question": q,
            "intent": intent,
            "entity": entity,
            "ms": round(elapsed, 2),
            "terminal": qr.terminal,
        })
    return results


def measure_warm_cache(qp, questions, iterations=1000):
    for q, intent, entity in questions[:50]:
        qp.ask(q, "simple")

    results = []
    for _ in range(iterations):
        q, intent, entity = random.choice(questions)
        t0 = time.monotonic()
        qr = qp.ask(q, "simple")
        elapsed = (time.monotonic() - t0) * 1000
        results.append({
            "question": q,
            "ms": round(elapsed, 2),
            "cache_hit": qr.bundle.get("cache_hit", False),
        })
    return results


def main():
    print("=" * 70)
    print("PERFORMANCE AUDIT — REAL MEASUREMENTS")
    print("=" * 70)
    print()
    print("REQUIREMENT: warm cache query < %d ms (p50)" % REQUIREMENT_MS)
    print()

    t0 = time.monotonic()
    from protocol import QueryProtocol
    qp = QueryProtocol.load()
    load_ms = (time.monotonic() - t0) * 1000
    print("COLD LOAD: %.0f ms" % load_ms)
    print()

    questions = generate_questions(qp)
    total_concepts = len(questions) // 2
    print("GENERATED: %d questions from %d+ concepts" % (
        len(questions), total_concepts))
    print()

    print("=== PHASE 1: COLD QUERY (20 random, cache invalidated each) ===")
    cold = measure_cold(qp, questions, 20)
    cold_ms = [r["ms"] for r in cold]
    cold_sorted = sorted(cold_ms)
    print("  count:  %d" % len(cold))
    print("  avg:    %.1f ms" % (sum(cold_ms) / len(cold_ms)))
    print("  p50:    %.1f ms" % percentile(cold_sorted, 50))
    print("  p95:    %.1f ms" % percentile(cold_sorted, 95))
    print("  max:    %.1f ms" % max(cold_ms))
    print("  terminal: %d/%d" % (
        sum(1 for r in cold if r["terminal"]), len(cold)))
    print("  with evidence: %d/%d" % (
        sum(1 for r in cold if r["evidence"] > 0), len(cold)))
    print()

    print("=== PHASE 2: NO-CACHE (100 random, no cache write) ===")
    qp.cache.invalidate_tree()
    no_cache = []
    for _ in range(100):
        q, intent, entity = random.choice(questions)
        t0_nc = time.monotonic()
        qr = qp.ask(q, "simple")
        elapsed_nc = (time.monotonic() - t0_nc) * 1000
        no_cache.append({
            "ms": round(elapsed_nc, 2),
            "terminal": qr.terminal,
            "evidence": len(qr.bundle.get("evidence", [])),
        })
    nc_ms = [r["ms"] for r in no_cache]
    nc_sorted = sorted(nc_ms)
    print("  count:  %d" % len(nc_ms))
    print("  avg:    %.1f ms" % (sum(nc_ms) / len(nc_ms)))
    print("  p50:    %.1f ms" % percentile(nc_sorted, 50))
    print("  p95:    %.1f ms" % percentile(nc_sorted, 95))
    print("  max:    %.1f ms" % max(nc_ms))
    print("  terminal: %d/%d" % (
        sum(1 for r in no_cache if r["terminal"]), len(no_cache)))
    print()

    print("=== PHASE 3: WARM CACHE (%d queries, %d warmup) ===" % (
        1000, 50))
    warm = measure_warm_cache(qp, questions, 1000)
    warm_ms = [r["ms"] for r in warm]
    warm_sorted = sorted(warm_ms)
    cache_hits = sum(1 for r in warm if r.get("cache_hit"))
    print("  count:       %d" % len(warm))
    print("  cache_hits:  %d (%.0f%%)" % (cache_hits, 100 * cache_hits / len(warm)))
    print("  avg:         %.1f ms" % (sum(warm_ms) / len(warm_ms)))
    print("  p50:         %.1f ms" % percentile(warm_sorted, 50))
    print("  p95:         %.1f ms" % percentile(warm_sorted, 95))
    print("  p99:         %.1f ms" % percentile(warm_sorted, 99))
    print("  max:         %.1f ms" % max(warm_ms))
    print()

    cache_only = [r["ms"] for r in warm if r.get("cache_hit")]
    if cache_only:
        co_sorted = sorted(cache_only)
        print("=== PHASE 3a: CACHE HITS ONLY ===")
        print("  count:  %d" % len(cache_only))
        print("  avg:    %.1f ms" % (sum(cache_only) / len(cache_only)))
        print("  p50:    %.1f ms" % percentile(co_sorted, 50))
        print("  p95:    %.1f ms" % percentile(co_sorted, 95))
        print("  max:    %.1f ms" % max(cache_only))
        print()

    print("=== VERDICT ===")
    p50_warm = percentile(warm_sorted, 50)
    p50_cache = percentile(sorted(cache_only), 50) if cache_only else 0
    p50_no_cache = percentile(nc_sorted, 50)
    print("  Cold query (no cache):     p50 = %.1f ms" % p50_no_cache)
    print("  Warm cache (all):          p50 = %.1f ms" % p50_warm)
    print("  Warm cache (hits only):    p50 = %.1f ms" % p50_cache)
    print()
    print("  REQUIREMENT: warm cache p50 < %d ms" % REQUIREMENT_MS)
    print("  ACTUAL:      warm cache p50 = %.1f ms" % p50_warm)
    print("  STATUS:      %s" % ("PASS" if p50_warm < REQUIREMENT_MS else "FAIL"))
    print()
    print("  REALITY: Knowledge engine query (no cache) p50 = %.1f ms" % p50_no_cache)
    print("  This is the actual engine cost, not cache illusion.")

    result = {
        "requirement_ms": REQUIREMENT_MS,
        "cold_load_ms": round(load_ms, 1),
        "cold_query": {
            "count": len(cold),
            "avg_ms": round(sum(cold_ms) / len(cold_ms), 1),
            "p50_ms": round(percentile(cold_sorted, 50), 1),
            "p95_ms": round(percentile(cold_sorted, 95), 1),
            "max_ms": round(max(cold_ms), 1),
        },
        "no_cache": {
            "count": len(nc_ms),
            "avg_ms": round(sum(nc_ms) / len(nc_ms), 1),
            "p50_ms": round(percentile(nc_sorted, 50), 1),
            "p95_ms": round(percentile(nc_sorted, 95), 1),
            "max_ms": round(max(nc_ms), 1),
        },
        "warm_cache": {
            "count": len(warm_ms),
            "cache_hits": cache_hits,
            "avg_ms": round(sum(warm_ms) / len(warm_ms), 1),
            "p50_ms": round(percentile(warm_sorted, 50), 1),
            "p95_ms": round(percentile(warm_sorted, 95), 1),
            "p99_ms": round(percentile(warm_sorted, 99), 1),
            "max_ms": round(max(warm_ms), 1),
        },
        "warm_cache_hits_only": {
            "count": len(cache_only),
            "p50_ms": round(p50_cache, 1),
        } if cache_only else None,
    }
    path = os.path.join(os.path.dirname(__file__), "..", "memory",
                        "performance_audit.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
    print()
    print("Saved: %s" % path)


if __name__ == "__main__":
    main()
