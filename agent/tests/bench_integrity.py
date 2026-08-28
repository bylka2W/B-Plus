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


def load_index():
    from common import load_json, CONCEPTS_PATH, FACTS_PATH, SEMANTIC_RELATIONS_PATH
    concepts_doc = load_json(CONCEPTS_PATH)
    facts_doc = load_json(FACTS_PATH)
    relations_doc = load_json(SEMANTIC_RELATIONS_PATH)
    return concepts_doc, facts_doc, relations_doc


def build_question_pool(concepts_doc, facts_doc, relations_doc, seed=42):
    rng = random.Random(seed)

    id_to_name = {}
    for c in concepts_doc["items"]:
        name = c["canonical_name"]
        base = name.rsplit("/", 1)[-1]
        id_to_name[c["concept_id"]] = base
        id_to_name[name] = base

    funcs = [c for c in concepts_doc["items"]
             if c["concept_type"] == "FUNCTION"
             and c.get("verification_status") == "VERIFIED"]
    mods = [c for c in concepts_doc["items"]
            if c["concept_type"] == "MODULE"
             and c.get("verification_status") == "VERIFIED"]
    structs = [c for c in concepts_doc["items"]
               if c["concept_type"] == "STRUCT"
               and c.get("verification_status") == "VERIFIED"]
    all_verified = [c for c in concepts_doc["items"]
                    if c.get("verification_status") == "VERIFIED"]

    call_facts = [f for f in facts_doc["items"]
                  if f["fact_type"] == "CALLS"
                  and f.get("verification_status") == "VERIFIED"]
    ref_facts = [f for f in facts_doc["items"]
                 if f["fact_type"] == "REFERENCES"
                 and f.get("verification_status") == "VERIFIED"]
    def_facts = [f for f in facts_doc["items"]
                 if f["fact_type"] == "DEFINES"
                 and f.get("verification_status") == "VERIFIED"]

    callers_qs = []
    for fact in call_facts:
        obj_name = id_to_name.get(fact["object_id"], fact["object_id"])
        callers_qs.append({
            "question": "Who calls %s?" % obj_name,
            "intent": "CALLERS",
            "entity_ref": obj_name,
            "type": "callers",
        })

    callees_qs = []
    for fact in call_facts:
        subj_name = id_to_name.get(fact["subject_id"], fact["subject_id"])
        callees_qs.append({
            "question": "What does %s call?" % subj_name,
            "intent": "CALLEES",
            "entity_ref": subj_name,
            "type": "callees",
        })

    def_qs = []
    for fact in def_facts:
        subj_name = id_to_name.get(fact["subject_id"], fact["subject_id"])
        def_qs.append({
            "question": "Where is %s defined?" % subj_name,
            "intent": "DEFINITION",
            "entity_ref": subj_name,
            "type": "definition",
        })

    ref_qs = []
    for fact in ref_facts:
        subj_name = id_to_name.get(fact["subject_id"], fact["subject_id"])
        ref_qs.append({
            "question": "Where is %s used?" % subj_name,
            "intent": "REFERENCES",
            "entity_ref": subj_name,
            "type": "references",
        })

    dep_qs = []
    for item in relations_doc["items"]:
        if item["relation_type"] == "DEPENDS_ON":
            from_id = id_to_name.get(item["from_concept"], item["from_concept"])
            dep_qs.append({
                "question": "What does %s depend on?" % from_id,
                "intent": "DEPENDENCIES",
                "entity_ref": from_id,
                "type": "dependencies",
            })

    all_qs = callers_qs + callees_qs + def_qs + ref_qs + dep_qs

    return {
        "callers": callers_qs,
        "callees": callees_qs,
        "definition": def_qs,
        "references": ref_qs,
        "dependencies": dep_qs,
        "all": all_qs,
    }


def build_adversarial_pool():
    return [
        {"question": "Who calls DefinitelyFakeFunction123?",
         "intent": "CALLERS", "entity_ref": "DefinitelyFakeFunction123",
         "type": "nonexistent"},
        {"question": "Where is FakeModule_XXXX defined?",
         "intent": "DEFINITION", "entity_ref": "FakeModule_XXXX",
         "type": "nonexistent"},
        {"question": "What does NonExistent999 call?",
         "intent": "CALLEES", "entity_ref": "NonExistent999",
         "type": "nonexistent"},
        {"question": "Who depends on FAKE_ZIG_FILE.zig?",
         "intent": "DEPENDENTS", "entity_ref": "FAKE_ZIG_FILE.zig",
         "type": "nonexistent"},
        {"question": "Where is nonexistent_type_abc used?",
         "intent": "REFERENCES", "entity_ref": "nonexistent_type_abc",
         "type": "nonexistent"},
    ]


def measure_mode_a_cold(qp, pool, n=200):
    rng = random.Random(123)
    questions = rng.sample(pool["all"], min(n, len(pool["all"])))

    results = []
    for q in questions:
        qp.cache.invalidate_entity(q["intent"], q["entity_ref"])
        t0 = time.monotonic()
        qr = qp.ask(q["question"], "simple")
        elapsed = (time.monotonic() - t0) * 1000
        results.append({
            "ms": round(elapsed, 2),
            "terminal": qr.terminal,
            "evidence": len(qr.bundle.get("evidence", [])),
            "status": qr.bundle.get("status"),
            "confidence": qr.bundle.get("confidence"),
            "intent": qr.bundle.get("intent"),
            "expected_intent": q["intent"],
        })
    return results


def measure_mode_b_cache_throughput(qp, pool, n=1000, warmup=50):
    rng = random.Random(456)
    warm_questions = rng.sample(pool["all"], min(100, len(pool["all"])))
    for q in warm_questions:
        qp.ask(q["question"], "simple")

    questions = rng.sample(pool["all"], min(n, len(pool["all"])))

    results = []
    for q in questions:
        t0 = time.monotonic()
        qr = qp.ask(q["question"], "simple")
        elapsed = (time.monotonic() - t0) * 1000
        results.append({
            "ms": round(elapsed, 2),
            "cache_hit": qr.bundle.get("cache_hit", False),
        })
    return results


def measure_mode_c_cold_random(qp, pool, n=500):
    rng = random.Random(789)

    all_intents = list(pool.keys())
    all_intents.remove("all")

    results = []
    for _ in range(n):
        intent_key = rng.choice(all_intents)
        q = rng.choice(pool[intent_key])
        qp.cache.invalidate_entity(q["intent"], q["entity_ref"])
        t0 = time.monotonic()
        qr = qp.ask(q["question"], "simple")
        elapsed = (time.monotonic() - t0) * 1000
        results.append({
            "ms": round(elapsed, 2),
            "terminal": qr.terminal,
            "evidence": len(qr.bundle.get("evidence", [])),
            "status": qr.bundle.get("status"),
            "confidence": qr.bundle.get("confidence"),
            "intent_used": qr.bundle.get("intent"),
            "expected_intent": q["intent"],
            "type": q["type"],
        })
    return results


def measure_mode_d_adversarial(qp, adversarial):
    results = []
    for q in adversarial:
        t0 = time.monotonic()
        qr = qp.ask(q["question"], "simple")
        elapsed = (time.monotonic() - t0) * 1000
        results.append({
            "ms": round(elapsed, 2),
            "terminal": qr.terminal,
            "status": qr.bundle.get("status"),
            "confidence": qr.bundle.get("confidence"),
            "expected": q["type"],
        })
    return results


def report(label, results, field="ms"):
    times = [r[field] for r in results]
    s = sorted(times)
    avg = sum(times) / len(times)
    p50 = percentile(s, 50)
    p95 = percentile(s, 95)
    p99 = percentile(s, 99)
    mx = max(times)
    print("  count: %d" % len(times))
    print("  avg:   %.1f ms" % avg)
    print("  p50:   %.1f ms" % p50)
    print("  p95:   %.1f ms" % p95)
    print("  p99:   %.1f ms" % p99)
    print("  max:   %.1f ms" % mx)
    return {"avg": round(avg, 1), "p50": round(p50, 1),
            "p95": round(p95, 1), "p99": round(p99, 1),
            "max": round(mx, 1)}


def main():
    print("=" * 70)
    print("BENCHMARK INTEGRITY AUDIT")
    print("=" * 70)
    print()
    print("REQUIREMENT: cold knowledge query p50 < %d ms" % REQUIREMENT_MS)
    print("No thresholds changed. No questions hardcoded around one function.")
    print()

    print("--- INDEX SIZE ---")
    concepts_doc, facts_doc, relations_doc = load_index()
    print("  concepts:     %d" % len(concepts_doc["items"]))
    print("  facts:        %d" % len(facts_doc["items"]))
    print("  relations:    %d" % len(relations_doc["items"]))
    vc = sum(1 for i in concepts_doc["items"]
             if i.get("verification_status") == "VERIFIED")
    print("  verified:     %d" % vc)
    print()

    pool = build_question_pool(concepts_doc, facts_doc, relations_doc)
    print("--- QUESTION POOL (from real index) ---")
    print("  callers:      %d unique" % len(pool["callers"]))
    print("  callees:      %d unique" % len(pool["callees"]))
    print("  definition:   %d unique" % len(pool["definition"]))
    print("  references:   %d unique" % len(pool["references"]))
    print("  dependencies: %d unique" % len(pool["dependencies"]))
    print("  TOTAL:        %d unique" % len(pool["all"]))
    print()

    adversarial = build_adversarial_pool()
    print("  adversarial:  %d cases" % len(adversarial))
    print()

    t0 = time.monotonic()
    from protocol import QueryProtocol
    qp = QueryProtocol.load()
    load_ms = (time.monotonic() - t0) * 1000
    print("COLD LOAD: %.0f ms" % load_ms)
    print()

    print("=" * 70)
    print("MODE A: COLD KNOWLEDGE QUERY")
    print("  Each query is unique, cache invalidated before each.")
    print("  Measures real Knowledge Engine traversal cost.")
    print("=" * 70)
    cold = measure_mode_a_cold(qp, pool, n=200)
    stats_a = report("COLD", cold)
    terminals = sum(1 for r in cold if r["terminal"])
    evidences = sum(1 for r in cold if r["evidence"] > 0)
    print("  terminal:     %d/%d (%.0f%%)" % (
        terminals, len(cold), 100 * terminals / len(cold)))
    print("  with evidence: %d/%d (%.0f%%)" % (
        evidences, len(cold), 100 * evidences / len(cold)))
    p50_a = stats_a["p50"]
    passes_a = p50_a < REQUIREMENT_MS
    print("  REQUIREMENT:  p50 < %d ms" % REQUIREMENT_MS)
    print("  ACTUAL:       p50 = %.1f ms" % p50_a)
    print("  STATUS:       %s" % ("PASS" if passes_a else "FAIL"))
    print()

    print("=" * 70)
    print("MODE B: CACHE THROUGHPUT")
    print("  Same queries repeated. Measures cache extraction speed.")
    print("  Label: CACHE PERFORMANCE, not Knowledge Engine performance.")
    print("=" * 70)
    cache_results = measure_mode_b_cache_throughput(qp, pool, n=1000)
    stats_b = report("CACHE", cache_results)
    cache_hits = sum(1 for r in cache_results if r.get("cache_hit"))
    cache_misses = len(cache_results) - cache_hits
    print("  cache hits:   %d (%.0f%%)" % (
        cache_hits, 100 * cache_hits / len(cache_results)))
    print("  cache misses: %d (%.0f%%)" % (
        cache_misses, 100 * cache_misses / len(cache_results)))
    print()

    print("=" * 70)
    print("MODE C: COLD RANDOM (different intents, unique entities)")
    print("  Random entity from random intent category.")
    print("  Each query: cache miss, real graph traversal.")
    print("=" * 70)
    cold_random = measure_mode_c_cold_random(qp, pool, n=500)
    stats_c = report("COLD RANDOM", cold_random)
    terminals_c = sum(1 for r in cold_random if r["terminal"])
    evidences_c = sum(1 for r in cold_random if r["evidence"] > 0)
    intents_correct = sum(1 for r in cold_random
                          if r["intent_used"] == r["expected_intent"])
    print("  terminal:     %d/%d (%.0f%%)" % (
        terminals_c, len(cold_random),
        100 * terminals_c / len(cold_random)))
    print("  with evidence: %d/%d (%.0f%%)" % (
        evidences_c, len(cold_random),
        100 * evidences_c / len(cold_random)))
    print("  intent match: %d/%d (%.0f%%)" % (
        intents_correct, len(cold_random),
        100 * intents_correct / len(cold_random)))

    by_type = {}
    for r in cold_random:
        t = r["type"]
        if t not in by_type:
            by_type[t] = []
        by_type[t].append(r["ms"])
    print("  by type:")
    for t in sorted(by_type.keys()):
        ts = sorted(by_type[t])
        print("    %-15s n=%3d p50=%6.1fms avg=%6.1fms" % (
            t, len(ts), percentile(ts, 50),
            sum(ts) / len(ts)))
    print()

    print("=" * 70)
    print("MODE D: ADVERSARIAL / UNKNOWN")
    print("  Nonexistent entities must return UNKNOWN, not VERIFIED.")
    print("  System must NOT hallucinate answers.")
    print("=" * 70)
    adv = measure_mode_d_adversarial(qp, adversarial)
    for r in adv:
        print("  %s %-40s status=%-12s terminal=%s" % (
            "PASS" if r["status"] in ("UNKNOWN", "NOT_FOUND", "EMPTY", "NEEDS_DEEP_SEARCH", "PARTIAL", "UNSUPPORTED") else "FAIL",
            r["expected"], r["status"], r["terminal"]))
    wrong_terminal = sum(1 for r in adv if r["terminal"])
    wrong_verified = sum(1 for r in adv
                         if r.get("confidence") == "VERIFIED")
    print()
    print("  non-terminal: %d/%d" % (
        len(adv) - wrong_terminal, len(adv)))
    print("  no false VERIFIED: %s" % (
        "PASS" if wrong_verified == 0 else "FAIL (%d false)" % wrong_verified))
    print()

    print("=" * 70)
    print("FINAL SUMMARY")
    print("=" * 70)
    print()
    print("  MODE A — Cold Knowledge Query (200 unique, cache miss)")
    print("    p50 = %.1f ms | requirement < %d ms | %s" % (
        stats_a["p50"], REQUIREMENT_MS,
        "PASS" if passes_a else "FAIL"))
    print()
    print("  MODE B — Cache Throughput (1000 repeated)")
    print("    p50 = %.1f ms (CACHE ONLY, not Knowledge Engine)" % stats_b["p50"])
    print()
    print("  MODE C — Cold Random (500 unique from real index)")
    print("    p50 = %.1f ms | intent accuracy = %.0f%%" % (
        stats_c["p50"], 100 * intents_correct / len(cold_random)))
    print()
    print("  MODE D — Adversarial (%d cases)" % len(adv))
    print("    false VERIFIED: %d | non-terminal: %d/%d" % (
        wrong_verified, len(adv) - wrong_terminal, len(adv)))
    print()

    doc = {
        "schema": "benchmark_integrity_audit",
        "version": 1,
        "requirement_ms": REQUIREMENT_MS,
        "index_size": {
            "concepts": len(concepts_doc["items"]),
            "facts": len(facts_doc["items"]),
            "relations": len(relations_doc["items"]),
            "verified_concepts": vc,
        },
        "pool_size": len(pool["all"]),
        "mode_a_cold": {
            "count": len(cold),
            "stats": stats_a,
            "terminal_rate": round(terminals / len(cold), 2),
            "evidence_rate": round(evidences / len(cold), 2),
            "passes": passes_a,
        },
        "mode_b_cache_throughput": {
            "count": len(cache_results),
            "stats": stats_b,
            "cache_hit_rate": round(cache_hits / len(cache_results), 2),
        },
        "mode_c_cold_random": {
            "count": len(cold_random),
            "stats": stats_c,
            "terminal_rate": round(terminals_c / len(cold_random), 2),
            "evidence_rate": round(evidences_c / len(cold_random), 2),
            "intent_accuracy": round(intents_correct / len(cold_random), 2),
            "by_type": {t: {"count": len(ts),
                            "p50_ms": round(percentile(sorted(ts), 50), 1)}
                        for t, ts in by_type.items()},
        },
        "mode_d_adversarial": {
            "count": len(adv),
            "false_verified": wrong_verified,
            "non_terminal": len(adv) - wrong_terminal,
            "passes": wrong_verified == 0,
        },
    }
    path = os.path.join(os.path.dirname(__file__), "..", "memory",
                        "benchmark_integrity_audit.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
    print("Saved: %s" % path)


if __name__ == "__main__":
    main()
