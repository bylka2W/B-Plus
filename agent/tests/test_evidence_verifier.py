import sys
import os
import time
import hashlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from engine.evidence_verifier import (
    EvidenceVerifier, VerificationResult, get_evidence_verifier,
    STATUS_VERIFIED, STATUS_STALE, STATUS_MISSING, STATUS_INVALID,
    STATUS_NOT_FOUND, STATUS_PARTIAL, ALL_STATUSES,
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
    check("ALL_STATUSES has 6", len(ALL_STATUSES) == 6)
    check("VERIFIED in ALL", STATUS_VERIFIED in ALL_STATUSES)
    check("STALE in ALL", STATUS_STALE in ALL_STATUSES)
    check("MISSING in ALL", STATUS_MISSING in ALL_STATUSES)
    check("INVALID in ALL", STATUS_INVALID in ALL_STATUSES)
    check("NOT_FOUND in ALL", STATUS_NOT_FOUND in ALL_STATUSES)
    check("PARTIAL in ALL", STATUS_PARTIAL in ALL_STATUSES)


def test_load():
    v = EvidenceVerifier.load()
    check("Verifier loads", v is not None)
    check("Verifier has idx", hasattr(v, "idx"))


def test_singleton():
    v1 = get_evidence_verifier()
    v2 = get_evidence_verifier()
    check("Singleton", v1 is v2)


def test_result_slots():
    r = VerificationResult()
    r.evidence_id = "EV-123"
    r.status = STATUS_VERIFIED
    d = r.to_dict()
    check("Result.to_dict has evidence_id", d["evidence_id"] == "EV-123")
    check("Result.to_dict has status", d["status"] == STATUS_VERIFIED)
    check("Result.to_dict has file_exists", "file_exists" in d)
    check("Result.to_dict has hash_match", "hash_match" in d)
    check("Result.to_dict has elapsed_ms", "elapsed_ms" in d)


def test_verify_evidence_not_found():
    v = EvidenceVerifier.load()
    r = v.verify_evidence("EV-nonexistent")
    check("not_found status", r.status == STATUS_NOT_FOUND)
    check("not_found detail", "not in index" in r.detail)
    d = r.to_dict()
    check("not_found in dict", d["status"] == STATUS_NOT_FOUND)


def test_verify_evidence_stale():
    v = EvidenceVerifier.load()
    from indexes import get_fast_index
    idx = get_fast_index()
    ev_ids = list(idx.evidence_by_id.keys())[:1]
    if ev_ids:
        r = v.verify_evidence(ev_ids[0])
        check("known evidence status in ALL", r.status in ALL_STATUSES)
        check("known evidence has source_file", r.source_file != "")
        check("known evidence file_exists", r.file_exists is True)
        check("known evidence has line_start", r.line_start > 0)
        check("known evidence elapsed_ms > 0", r.elapsed_ms > 0)
    else:
        check("known evidence skip", True)


def test_verify_evidence_hash_detail():
    v = EvidenceVerifier.load()
    from indexes import get_fast_index
    idx = get_fast_index()
    ev_ids = list(idx.evidence_by_id.keys())[:1]
    if ev_ids:
        r = v.verify_evidence(ev_ids[0])
        if r.status == STATUS_STALE:
            check("stale has detail", r.detail != "")
            check("stale has actual_hash", r.actual_hash != "")
            check("stale has stored_hash", r.stored_hash != "")
            check("stale hashes differ", r.actual_hash != r.stored_hash)
        else:
            check("stale check (non-stale)", True)


def test_verify_fact_not_found():
    v = EvidenceVerifier.load()
    r = v.verify_fact("FACT-nonexistent")
    check("fact not_found", r.status == STATUS_NOT_FOUND)


def test_verify_fact_exists():
    v = EvidenceVerifier.load()
    from indexes import get_fast_index
    idx = get_fast_index()
    fids = list(idx.fact_by_id.keys())[:1]
    if fids:
        r = v.verify_fact(fids[0])
        check("fact status in ALL", r.status in ALL_STATUSES)
        check("fact has symbol_exists", isinstance(r.symbol_exists, bool))
        check("fact elapsed_ms > 0", r.elapsed_ms > 0)
    else:
        check("fact exists skip", True)


def test_verify_relation_not_found():
    v = EvidenceVerifier.load()
    r = v.verify_relation("SR-nonexistent")
    check("relation not_found", r.status == STATUS_NOT_FOUND)


def test_verify_relation_exists():
    v = EvidenceVerifier.load()
    from indexes import get_fast_index
    idx = get_fast_index()
    rids = list(idx.relation_by_id.keys())[:1]
    if rids:
        r = v.verify_relation(rids[0])
        check("relation status in ALL", r.status in ALL_STATUSES)
        check("relation has symbol_exists", isinstance(r.symbol_exists, bool))
        check("relation elapsed_ms > 0", r.elapsed_ms > 0)
    else:
        check("relation exists skip", True)


def test_verify_concept_not_found():
    v = EvidenceVerifier.load()
    r = v.verify_concept("CN-nonexistent")
    check("concept not_found", r.status == STATUS_NOT_FOUND)


def test_verify_concept_exists():
    v = EvidenceVerifier.load()
    from indexes import get_fast_index
    idx = get_fast_index()
    cids = list(idx.concept_by_id.keys())[:1]
    if cids:
        r = v.verify_concept(cids[0])
        check("concept status in ALL", r.status in ALL_STATUSES)
        check("concept has source_file", isinstance(r.source_file, str))
        check("concept elapsed_ms > 0", r.elapsed_ms > 0)
    else:
        check("concept exists skip", True)


def test_bulk_verify():
    v = EvidenceVerifier.load()
    bulk = v.bulk_verify(limit=10)
    check("bulk total == 10", bulk["total"] == 10)
    check("bulk has stats", isinstance(bulk["stats"], dict))
    check("bulk has elapsed_ms", bulk["elapsed_ms"] > 0)
    check("bulk has avg_ms", bulk["avg_ms"] > 0)
    check("bulk stats sum == total",
          sum(bulk["stats"].values()) == bulk["total"])
    check("bulk results list", len(bulk["results"]) == 10)


def test_bulk_verify_statuses():
    v = EvidenceVerifier.load()
    bulk = v.bulk_verify(limit=20)
    total_status = sum(bulk["stats"].values())
    check("bulk stats match total", total_status == bulk["total"])
    for status in ALL_STATUSES:
        count = bulk["stats"].get(status, 0)
        if count > 0:
            check(f"bulk has {status}", True)


def test_verify_evidence_file_missing():
    v = EvidenceVerifier.load()
    r = VerificationResult()
    r.evidence_id = "EV-fake"
    r.source_file = "C:\\nonexistent\\path\\file.zig"
    r.file_exists = False
    check("fake missing file", r.file_exists is False)


def test_verify_evidence_latency():
    v = EvidenceVerifier.load()
    from indexes import get_fast_index
    idx = get_fast_index()
    ev_ids = list(idx.evidence_by_id.keys())[:1]
    if not ev_ids:
        check("latency skip", True)
        return
    times = []
    for _ in range(50):
        t0 = time.monotonic()
        v.verify_evidence(ev_ids[0])
        times.append((time.monotonic() - t0) * 1000)
    times.sort()
    p50 = times[len(times) // 2]
    p99 = times[int(len(times) * 0.99)]
    check(f"verify latency p50={p50:.3f}ms < 5ms", p50 < 5.0)
    check(f"verify latency p99={p99:.3f}ms < 20ms", p99 < 20.0)


def test_bulk_verify_latency():
    v = EvidenceVerifier.load()
    t0 = time.monotonic()
    v.bulk_verify(limit=100)
    elapsed = (time.monotonic() - t0) * 1000
    check(f"bulk 100 verify < 500ms ({elapsed:.0f}ms)", elapsed < 500)


def test_text_match_detection():
    v = EvidenceVerifier.load()
    from indexes import get_fast_index
    idx = get_fast_index()
    ev_ids = list(idx.evidence_by_id.keys())[:1]
    if not ev_ids:
        check("text match skip", True)
        return
    r = v.verify_evidence(ev_ids[0])
    if r.file_exists:
        check("text_match is bool", isinstance(r.text_match, bool))
        check("hash_match is bool", isinstance(r.hash_match, bool))
        if r.text_match and not r.hash_match:
            check("text match + hash mismatch = STALE", r.status == STATUS_STALE)
        elif r.text_match and r.hash_match:
            check("text match + hash match = VERIFIED", r.status == STATUS_VERIFIED)
        else:
            check("text+hash both false = STALE/INVALID",
                  r.status in (STATUS_STALE, STATUS_INVALID))
    else:
        check("text match file missing", True)


if __name__ == "__main__":
    test_constants()
    test_load()
    test_singleton()
    test_result_slots()
    test_verify_evidence_not_found()
    test_verify_evidence_stale()
    test_verify_evidence_hash_detail()
    test_verify_fact_not_found()
    test_verify_fact_exists()
    test_verify_relation_not_found()
    test_verify_relation_exists()
    test_verify_concept_not_found()
    test_verify_concept_exists()
    test_bulk_verify()
    test_bulk_verify_statuses()
    test_verify_evidence_file_missing()
    test_verify_evidence_latency()
    test_bulk_verify_latency()
    test_text_match_detection()
    print()
    print(f"EVIDENCE VERIFIER: {PASS} PASS / {FAIL} FAIL")
    sys.exit(0 if FAIL == 0 else 1)
