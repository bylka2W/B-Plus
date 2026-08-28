import sys
import os
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from engine.truth_contract import (
    TruthContract, Claim, AnswerVerification, get_truth_contract,
    STATUS_VERIFIED, STATUS_STALE, STATUS_MISSING, STATUS_INVALID,
    STATUS_NOT_FOUND, STATUS_PARTIAL, STATUS_UNKNOWN, STATUS_UNSUPPORTED,
    STATUS_CONTRADICTION, STATUS_PASS, STATUS_FAIL, STATUS_PARTIAL_PASS,
    ALL_CLAIM_STATUSES,
)

PASS = 0
FAIL = 0


def check(name, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print("PASS:", name)
    else:
        FAIL += 1
        print("FAIL:", name, "-", detail)


def test_constants():
    check("ALL_CLAIM_STATUSES has 9", len(ALL_CLAIM_STATUSES) == 9)
    check("VERIFIED in ALL", STATUS_VERIFIED in ALL_CLAIM_STATUSES)
    check("UNSUPPORTED in ALL", STATUS_UNSUPPORTED in ALL_CLAIM_STATUSES)
    check("CONTRADICTION in ALL", STATUS_CONTRADICTION in ALL_CLAIM_STATUSES)


def test_claim():
    c = Claim()
    c.text = "test"
    c.subject = "foo"
    c.predicate = "CALLS"
    c.object = "bar"
    c.status = STATUS_VERIFIED
    c.confidence = 1.0
    d = c.to_dict()
    check("Claim.to_dict text", d["text"] == "test")
    check("Claim.to_dict subject", d["subject"] == "foo")
    check("Claim.to_dict status", d["status"] == STATUS_VERIFIED)


def test_answer_verification():
    r = AnswerVerification()
    r.total_claims = 5
    r.verified_claims = 3
    r.overall_status = STATUS_PASS
    d = r.to_dict()
    check("AV.to_dict total", d["total_claims"] == 5)
    check("AV.to_dict has claims list", isinstance(d["claims"], list))


def test_load():
    tc = TruthContract.load()
    check("TC loads", tc is not None)
    check("TC has idx", hasattr(tc, "idx"))
    check("TC has verifier", hasattr(tc, "verifier"))


def test_singleton():
    t1 = get_truth_contract()
    t2 = get_truth_contract()
    check("Singleton", t1 is t2)


def test_extract_claims_explicit_id():
    tc = TruthContract.load()
    answer = "foldConstantOp (CN-00673ad4ff190413) calls getConstValue (CN-f31091417b8ee7dd)."
    claims = tc.extract_claims(answer)
    check("explicit id extracts claims", len(claims) >= 1)
    has_cn = any("CN-00673ad4ff190413" in c.concept_ids for c in claims)
    check("explicit id finds CN", has_cn)


def test_extract_claims_ev_id():
    tc = TruthContract.load()
    answer = "Evidence: EV-a57cb8a7fdeac64d shows the function."
    claims = tc.extract_claims(answer)
    has_ev = any("EV-a57cb8a7fdeac64d" in c.evidence_ids for c in claims)
    check("extracts EV id", has_ev)


def test_extract_claims_arrow():
    tc = TruthContract.load()
    answer = "runConstantFolding calls foldConstantOp."
    claims = tc.extract_claims(answer)
    check("arrow extracts claims", len(claims) >= 1)
    if claims:
        has_predicate = claims[0].predicate == "CALLS"
        check("arrow detects CALLS", has_predicate)


def test_extract_claims_entity_resolution():
    tc = TruthContract.load()
    answer = "foldConstantOp is a function."
    claims = tc.extract_claims(answer)
    check("entity resolution finds foldConstantOp",
          any("foldConstantOp" in c.subject or
              any("CN-" in cid for cid in c.concept_ids)
              for c in claims))


def test_verify_explicit_verified():
    tc = TruthContract.load()
    answer = "foldConstantOp (CN-00673ad4ff190413) is called by runConstantFolding (CN-8fc457aae7477e79)."
    result = tc.verify_answer(answer)
    check("explicit verified has claims", result.total_claims >= 1)
    check("explicit verified overall_status in statuses",
          result.overall_status in (STATUS_PASS, STATUS_PARTIAL_PASS, STATUS_FAIL))


def test_verify_with_evidence():
    tc = TruthContract.load()
    answer = ("foldConstantOp (CN-00673ad4ff190413) calls getConstValue. "
              "Evidence: EV-a57cb8a7fdeac64d.")
    result = tc.verify_answer(answer)
    check("evidence answer has claims", result.total_claims >= 1)
    verified = [c for c in result.claims if c.status == STATUS_VERIFIED]
    partial = [c for c in result.claims if c.status == STATUS_PARTIAL]
    check("evidence answer has verified or partial",
          len(verified) > 0 or len(partial) > 0)


def test_verify_fake_entity():
    tc = TruthContract.load()
    answer = "nonexistentFakeXYZ (CN-0000000000000000) does something."
    result = tc.verify_answer(answer)
    check("fake entity has claims", result.total_claims >= 1)
    not_found = [c for c in result.claims if c.status == STATUS_NOT_FOUND]
    check("fake entity has NOT_FOUND", len(not_found) > 0)


def test_verify_plain_text():
    tc = TruthContract.load()
    answer = "foldConstantOp is called by runConstantFolding."
    result = tc.verify_answer(answer)
    check("plain text has claims", result.total_claims >= 1)
    check("plain text has overall_status", result.overall_status != "")


def test_verify_empty():
    tc = TruthContract.load()
    result = tc.verify_answer("")
    check("empty has 0 claims", result.total_claims == 0)
    check("empty PASS", result.overall_status == STATUS_PASS)
    check("empty hallucination=0", result.hallucination_rate == 0.0)


def test_hallucination_rate():
    tc = TruthContract.load()
    result = tc.verify_answer("I think it probably does something vague.")
    check("vague text hallucination=0 or has claims",
          result.hallucination_rate >= 0.0)


def test_confidence_scores():
    tc = TruthContract.load()
    answer = "foldConstantOp (CN-00673ad4ff190413) calls getConstValue (CN-f31091417b8ee7dd)."
    result = tc.verify_answer(answer)
    check("confidence has evidence_confidence",
          isinstance(result.evidence_confidence, float))
    check("confidence has source_confidence",
          isinstance(result.source_confidence, float))
    check("confidence has graph_confidence",
          isinstance(result.graph_confidence, float))
    check("confidence has overall_confidence",
          isinstance(result.overall_confidence, float))
    check("confidence 0-1 range",
          0.0 <= result.overall_confidence <= 1.0)


def test_to_dict_full():
    tc = TruthContract.load()
    answer = "foldConstantOp (CN-00673ad4ff190413) calls getConstValue (CN-f31091417b8ee7dd)."
    result = tc.verify_answer(answer)
    d = result.to_dict()
    check("to_dict has total_claims", "total_claims" in d)
    check("to_dict has verified_claims", "verified_claims" in d)
    check("to_dict has hallucination_rate", "hallucination_rate" in d)
    check("to_dict has overall_confidence", "overall_confidence" in d)
    check("to_dict has claims list", isinstance(d["claims"], list))


def test_claim_split_sentences():
    tc = TruthContract.load()
    answer = ("foldConstantOp is defined in manager.zig. "
              "It calls getConstValue. "
              "runConstantFolding calls it.")
    claims = tc.extract_claims(answer)
    check("split sentences has claims", len(claims) >= 2)


def test_predicate_detection():
    tc = TruthContract.load()
    cases = [
        ("X calls Y", "CALLS"),
        ("X uses Y", "USES"),
        ("X depends on Y", "DEPENDS_ON"),
        ("X contains Y", "CONTAINS"),
        ("X references Y", "REFERENCES"),
    ]
    for text, expected in cases:
        claims = tc.extract_claims(text)
        if claims:
            check(f"predicate {expected}", claims[0].predicate == expected)
        else:
            check(f"predicate {expected} (no claims)", False)


def test_latency():
    tc = TruthContract.load()
    answer = "foldConstantOp (CN-00673ad4ff190413) calls getConstValue (CN-f31091417b8ee7dd)."
    times = []
    for _ in range(50):
        t0 = time.monotonic()
        tc.verify_answer(answer)
        times.append((time.monotonic() - t0) * 1000)
    times.sort()
    p50 = times[len(times) // 2]
    p99 = times[int(len(times) * 0.99)]
    check(f"verify latency p50={p50:.1f}ms < 50ms", p50 < 50)
    check(f"verify latency p99={p99:.1f}ms < 200ms", p99 < 200)


def test_long_answer():
    tc = TruthContract.load()
    lines = []
    for i in range(20):
        lines.append(f"Statement {i}: foldConstantOp (CN-00673ad4ff190413) "
                     f"calls something.")
    answer = " ".join(lines)
    result = tc.verify_answer(answer)
    check("long answer has claims", result.total_claims >= 10)


if __name__ == "__main__":
    test_constants()
    test_claim()
    test_answer_verification()
    test_load()
    test_singleton()
    test_extract_claims_explicit_id()
    test_extract_claims_ev_id()
    test_extract_claims_arrow()
    test_extract_claims_entity_resolution()
    test_verify_explicit_verified()
    test_verify_with_evidence()
    test_verify_fake_entity()
    test_verify_plain_text()
    test_verify_empty()
    test_hallucination_rate()
    test_confidence_scores()
    test_to_dict_full()
    test_claim_split_sentences()
    test_predicate_detection()
    test_latency()
    test_long_answer()
    print()
    print(f"TRUTH CONTRACT: {PASS} PASS / {FAIL} FAIL")
    sys.exit(0 if FAIL == 0 else 1)
