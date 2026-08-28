import sys
import os
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from engine.answer_verifier import (
    AnswerVerifier, AnswerCheck, VerifiedAnswer, get_answer_verifier,
    STATUS_PASS_A, STATUS_FAIL_A, STATUS_PARTIAL_A,
    STATUS_INSUFFICIENT, STATUS_NO_CLAIMS,
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


def test_load():
    av = AnswerVerifier.load()
    check("AV loads", av is not None)
    check("AV has idx", hasattr(av, "idx"))
    check("AV has truth", hasattr(av, "truth"))


def test_singleton():
    a1 = get_answer_verifier()
    a2 = get_answer_verifier()
    check("Singleton", a1 is a2)


def test_check_slots():
    c = AnswerCheck()
    c.claim_text = "test"
    c.claim_status = "VERIFIED"
    d = c.to_dict()
    check("check.to_dict", d["claim_text"] == "test")


def test_verified_answer_slots():
    v = VerifiedAnswer()
    v.overall_status = "PASS"
    d = v.to_dict()
    check("VA.to_dict status", d["overall_status"] == "PASS")
    check("VA.to_dict has checks", isinstance(d["checks"], list))


def test_verify_explicit_ids():
    av = AnswerVerifier.load()
    result = av.verify(
        "foldConstantOp (CN-00673ad4ff190413) calls "
        "getConstValue (CN-f31091417b8ee7dd)."
    )
    check("explicit PASS", result.overall_status == STATUS_PASS_A)
    check("explicit has verified", result.verified_count >= 1)
    check("explicit hallucination=0", result.hallucination_rate == 0.0)
    check("explicit confidence>0", result.confidence > 0)


def test_verify_plain_text():
    av = AnswerVerifier.load()
    result = av.verify("foldConstantOp is called by runConstantFolding.")
    check("plain has claims", result.total_claims >= 1)
    check("plain has status", result.overall_status != "")


def test_verify_fake():
    av = AnswerVerifier.load()
    result = av.verify(
        "nonexistentFakeXYZ (CN-0000000000000000) does something."
    )
    check("fake has claims", result.total_claims >= 1)
    check("fake not PASS", result.overall_status != STATUS_PASS_A)


def test_verify_vague():
    av = AnswerVerifier.load()
    result = av.verify("I think it probably does something maybe.")
    check("vague has claims", result.total_claims >= 1)
    check("vague not PASS", result.overall_status != STATUS_PASS_A)


def test_verify_empty():
    av = AnswerVerifier.load()
    result = av.verify("")
    check("empty NO_CLAIMS", result.overall_status == STATUS_NO_CLAIMS)
    check("empty 0 claims", result.total_claims == 0)


def test_verify_none_like():
    av = AnswerVerifier.load()
    result = av.verify("   ")
    check("whitespace NO_CLAIMS", result.overall_status == STATUS_NO_CLAIMS)


def test_evidence_chain():
    av = AnswerVerifier.load()
    result = av.verify(
        "foldConstantOp (CN-00673ad4ff190413) calls "
        "getConstValue (CN-f31091417b8ee7dd)."
    )
    has_chain = any(c.evidence_chain for c in result.checks)
    check("evidence chain present", has_chain)


def test_render():
    av = AnswerVerifier.load()
    result = av.verify(
        "foldConstantOp (CN-00673ad4ff190413) calls "
        "getConstValue (CN-f31091417b8ee7dd)."
    )
    rendered = result.render()
    check("render has STATUS", "STATUS:" in rendered)
    check("render has CLAIMS", "CLAIMS:" in rendered)
    check("render has HALLUCINATION", "HALLUCINATION_RATE:" in rendered)
    check("render has CONFIDENCE", "CONFIDENCE:" in rendered)


def test_multi_claim():
    av = AnswerVerifier.load()
    result = av.verify(
        "foldConstantOp (CN-00673ad4ff190413) is defined in manager.zig. "
        "It calls getConstValue (CN-f31091417b8ee7dd)."
    )
    check("multi has 2+ claims", result.total_claims >= 2)


def test_to_dict_full():
    av = AnswerVerifier.load()
    result = av.verify(
        "foldConstantOp (CN-00673ad4ff190413) calls "
        "getConstValue (CN-f31091417b8ee7dd)."
    )
    d = result.to_dict()
    check("to_dict has overall_status", "overall_status" in d)
    check("to_dict has hallucination_rate", "hallucination_rate" in d)
    check("to_dict has confidence", "confidence" in d)
    check("to_dict has checks", isinstance(d["checks"], list))


def test_relation_verification():
    av = AnswerVerifier.load()
    result = av.verify(
        "runConstantFolding calls foldConstantOp."
    )
    check("relation answer has claims", result.total_claims >= 1)
    check("relation has status", result.overall_status != "")


def test_latency():
    av = AnswerVerifier.load()
    answer = "foldConstantOp (CN-00673ad4ff190413) calls getConstValue (CN-f31091417b8ee7dd)."
    times = []
    for _ in range(50):
        t0 = time.monotonic()
        av.verify(answer)
        times.append((time.monotonic() - t0) * 1000)
    times.sort()
    p50 = times[len(times) // 2]
    p99 = times[int(len(times) * 0.99)]
    check(f"verify p50={p50:.1f}ms < 50ms", p50 < 50)
    check(f"verify p99={p99:.1f}ms < 200ms", p99 < 200)


if __name__ == "__main__":
    test_load()
    test_singleton()
    test_check_slots()
    test_verified_answer_slots()
    test_verify_explicit_ids()
    test_verify_plain_text()
    test_verify_fake()
    test_verify_vague()
    test_verify_empty()
    test_verify_none_like()
    test_evidence_chain()
    test_render()
    test_multi_claim()
    test_to_dict_full()
    test_relation_verification()
    test_latency()
    print()
    print(f"ANSWER VERIFIER: {PASS} PASS / {FAIL} FAIL")
    sys.exit(0 if FAIL == 0 else 1)
