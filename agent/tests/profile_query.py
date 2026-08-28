"""
Profile a single cold Knowledge Engine query — stage-by-stage breakdown.
Instruments the actual pipeline: route → query → context → phrase → evidence → terminal.
"""
import sys, os, time, json, statistics

sys.path.insert(0, r"C:\B-Plus\agent\engine")

from knowledge import Knowledge
from context import ContextBuilder
from query import QueryEngine
from answer import AnswerEngine
from router import Router
from evidence_bundle import build_evidence_bundle
from protocol import is_terminal, QueryProtocol


def p50(vals):
    s = sorted(vals)
    return s[len(s) // 2]


def main():
    print("=" * 70)
    print("COLD QUERY PROFILER — stage breakdown")
    print("=" * 70)

    t0 = time.perf_counter()
    k = Knowledge.load()
    load_ms = (time.perf_counter() - t0) * 1000
    print(f"Knowledge load: {load_ms:.1f} ms")

    cb = k.cb
    qe = cb.qe
    router = k.router

    # Build question pool from real index
    funcs = [c["canonical_name"].rsplit("/", 1)[-1]
             for c in cb.qe.search.concepts.values()
             if c["concept_type"] == "FUNCTION"
             and c.get("verification_status") == "VERIFIED"][:30]

    questions = []
    for fn in funcs[:6]:
        questions.append(("Who calls %s?" % fn, "CALLERS", fn))
    for fn in funcs[6:12]:
        questions.append(("What does %s call?" % fn, "CALLEES", fn))
    for fn in funcs[12:18]:
        questions.append(("Where is %s defined?" % fn, "DEFINITION", fn))

    N = 20
    times = {k: [] for k in [
        "parse_and_route",
        "query_engine",
        "context_build",
        "phrase",
        "evidence_bundle",
        "terminal_check",
    ]}

    print(f"\nProfiling {len(questions)} questions x {N} runs...\n")

    # Warmup
    for q_text, _, _ in questions[:3]:
        for _ in range(5):
            k.route(q_text)
            k.ask(q_text)

    for q_text, intent_hint, entity in questions:
        for _ in range(N):
            # Stage 1: parse + route
            t1 = time.perf_counter()
            route = k.route(q_text)
            intent = route.get("intent", "")
            entity_r = route.get("entity", "")
            status = route.get("status", "")
            t_route = (time.perf_counter() - t1) * 1000

            # Stage 2: QueryEngine.query (entity resolution + search)
            t2 = time.perf_counter()
            qr = qe.query(intent, entity_r)
            t_query = (time.perf_counter() - t2) * 1000

            # Stage 3: ContextBuilder.build (evidence + claims assembly)
            t3 = time.perf_counter()
            if qr["status"] not in ("UNKNOWN_INTENT", "NOT_FOUND", "AMBIGUOUS"):
                pack = cb.build(qr)
            else:
                pack = {"evidence": [], "claims": [], "relation_ids": [],
                        "target": None, "confidence": "UNSUPPORTED"}
            t_context = (time.perf_counter() - t3) * 1000

            # Stage 4: Phrase (text generation)
            t4 = time.perf_counter()
            if qr["status"] not in ("UNKNOWN_INTENT", "NOT_FOUND", "AMBIGUOUS"):
                target_name = pack["target"]["name"] if pack["target"] else entity_r
                direct, limitations = k.ae._phrase(intent, target_name, pack, qr)
            else:
                direct = None
                limitations = []
            t_phrase = (time.perf_counter() - t4) * 1000

            # Stage 5: Evidence bundle (for protocol)
            t5 = time.perf_counter()
            bundle = build_evidence_bundle(k, q_text, time.monotonic())
            bd = bundle.to_dict()
            t_evidence = (time.perf_counter() - t5) * 1000

            # Stage 6: Terminal check
            t6 = time.perf_counter()
            term = is_terminal(bd)
            t_terminal = (time.perf_counter() - t6) * 1000

            times["parse_and_route"].append(t_route)
            times["query_engine"].append(t_query)
            times["context_build"].append(t_context)
            times["phrase"].append(t_phrase)
            times["evidence_bundle"].append(t_evidence)
            times["terminal_check"].append(t_terminal)

    print("=" * 70)
    print(f"STAGE BREAKDOWN (p50 of {N} runs x {len(questions)} questions)")
    print("=" * 70)

    total = 0
    for stage in ["parse_and_route", "query_engine", "context_build",
                   "phrase", "evidence_bundle", "terminal_check"]:
        v = times[stage]
        p = p50(v)
        avg = statistics.mean(v)
        p95 = sorted(v)[int(len(v) * 0.95)]
        total += p
        bar = "#" * max(1, int(p / 2))
        print(f"  {stage:22s}  p50={p:7.2f}ms  avg={avg:7.2f}ms  p95={p95:7.2f}ms  {bar}")

    print(f"  {'':22s}  {'':13s}  --------")
    print(f"  {'SUM p50':22s}  {total:7.2f}ms")

    # Full pipeline comparison
    full_times = []
    for q_text, _, _ in questions:
        for _ in range(N):
            t0 = time.perf_counter()
            k.ask(q_text)
            full_times.append((time.perf_counter() - t0) * 1000)

    print(f"\n  Full k.ask() p50:     {p50(full_times):7.2f}ms")

    # Protocol pipeline
    proto_times = []
    qp = QueryProtocol(k)
    for q_text, _, _ in questions:
        for _ in range(N):
            t0 = time.perf_counter()
            qp.ask(q_text, "simple")
            proto_times.append((time.perf_counter() - t0) * 1000)

    print(f"  Protocol.ask() p50:   {p50(proto_times):7.2f}ms")

    # Save
    profile = {}
    for stage in times:
        v = times[stage]
        profile[stage] = {
            "p50": round(p50(v), 2),
            "avg": round(statistics.mean(v), 2),
            "p95": round(sorted(v)[int(len(v) * 0.95)], 2),
        }
    profile["sum_p50"] = round(total, 2)
    profile["full_ask_p50"] = round(p50(full_times), 2)
    profile["protocol_ask_p50"] = round(p50(proto_times), 2)
    profile["questions"] = len(questions)
    profile["runs_per_question"] = N

    with open(r"C:\B-Plus\agent\memory\cold_query_profile.json", "w") as f:
        json.dump(profile, f, indent=2)
    print(f"\nSaved: memory/cold_query_profile.json")


if __name__ == "__main__":
    main()
