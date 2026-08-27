import os
import sys
import time
import hashlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import ZIG_ROOT

STATUS_VERIFIED = "VERIFIED"
STATUS_STALE = "STALE"
STATUS_MISSING = "MISSING"
STATUS_INVALID = "INVALID"
STATUS_NOT_FOUND = "NOT_FOUND"
STATUS_PARTIAL = "PARTIAL"

ALL_STATUSES = {
    STATUS_VERIFIED, STATUS_STALE, STATUS_MISSING,
    STATUS_INVALID, STATUS_NOT_FOUND, STATUS_PARTIAL,
}

_hashes_cache = {}


def _read_file_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.readlines()
    except (OSError, IOError):
        return None


def _hash_lines(lines, start, end):
    segment = "".join(lines[start - 1:end])
    return hashlib.sha256(segment.encode("utf-8")).hexdigest()


def _hash_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class VerificationResult:
    __slots__ = (
        "evidence_id", "status", "file_exists", "lines_exist",
        "hash_match", "text_match", "symbol_exists", "fact_exists",
        "relation_exists", "source_file", "line_start", "line_end",
        "stored_hash", "actual_hash", "elapsed_ms", "detail",
    )

    def __init__(self):
        self.evidence_id = ""
        self.status = STATUS_NOT_FOUND
        self.file_exists = False
        self.lines_exist = False
        self.hash_match = False
        self.text_match = False
        self.symbol_exists = False
        self.fact_exists = False
        self.relation_exists = False
        self.source_file = ""
        self.line_start = 0
        self.line_end = 0
        self.stored_hash = ""
        self.actual_hash = ""
        self.elapsed_ms = 0.0
        self.detail = ""

    def to_dict(self):
        return {
            "evidence_id": self.evidence_id,
            "status": self.status,
            "file_exists": self.file_exists,
            "lines_exist": self.lines_exist,
            "hash_match": self.hash_match,
            "text_match": self.text_match,
            "symbol_exists": self.symbol_exists,
            "fact_exists": self.fact_exists,
            "relation_exists": self.relation_exists,
            "source_file": self.source_file,
            "line_start": self.line_start,
            "line_end": self.line_end,
            "stored_hash": self.stored_hash,
            "actual_hash": self.actual_hash,
            "elapsed_ms": self.elapsed_ms,
            "detail": self.detail,
        }


class EvidenceVerifier:
    def __init__(self, idx=None):
        from indexes import get_fast_index
        self.idx = idx or get_fast_index()

    @classmethod
    def load(cls):
        return cls()

    def verify_evidence(self, evidence_id):
        t0 = time.monotonic()
        result = VerificationResult()
        result.evidence_id = evidence_id

        ev = self.idx.evidence_by_id.get(evidence_id)
        if not ev:
            result.status = STATUS_NOT_FOUND
            result.detail = "evidence not in index"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result

        result.source_file = ev.get("source_file", "")
        result.line_start = ev.get("line_start", 0)
        result.line_end = ev.get("line_end", 0)
        result.stored_hash = ev.get("sha256", "")
        stored_text = ev.get("text", "")

        result.file_exists = os.path.exists(result.source_file)
        if not result.file_exists:
            result.status = STATUS_MISSING
            result.detail = f"file not found: {result.source_file}"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result

        lines = _read_file_lines(result.source_file)
        if lines is None:
            result.status = STATUS_MISSING
            result.detail = "cannot read file"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result

        total_lines = len(lines)
        if result.line_start < 1 or result.line_start > total_lines:
            result.status = STATUS_INVALID
            result.detail = f"line_start {result.line_start} out of range (file has {total_lines} lines)"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result

        effective_end = min(result.line_end, total_lines)
        result.lines_exist = result.line_start <= effective_end

        actual_segment = "".join(lines[result.line_start - 1:effective_end])
        result.actual_hash = _hash_lines(lines, result.line_start, effective_end)

        if result.stored_hash:
            result.hash_match = result.actual_hash == result.stored_hash

        if stored_text.strip():
            result.text_match = actual_segment.strip() == stored_text.strip()

        if result.hash_match and result.text_match:
            result.status = STATUS_VERIFIED
        elif result.hash_match and not result.text_match:
            result.status = STATUS_INVALID
            result.detail = "hash matches but text differs (encoding issue)"
        elif result.text_match and not result.hash_match:
            result.status = STATUS_STALE
            result.detail = "text content matches but hash differs (whitespace/encoding drift)"
        elif not result.text_match and not result.hash_match:
            result.status = STATUS_STALE
            result.detail = "both hash and text differ (file changed since evidence creation)"

        result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return result

    def verify_fact(self, fact_id):
        t0 = time.monotonic()
        result = VerificationResult()
        result.fact_exists = True

        fact = self.idx.fact_by_id.get(fact_id)
        if not fact:
            result.status = STATUS_NOT_FOUND
            result.detail = "fact not in index"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result

        subject_id = fact.get("subject_id", "")
        object_id = fact.get("object_id", "")
        result.symbol_exists = subject_id in self.idx.symbol_by_id
        if object_id:
            result.relation_exists = object_id in self.idx.symbol_by_id
        else:
            result.relation_exists = True

        ev_id = fact.get("evidence_id", "")
        if ev_id:
            ev_result = self.verify_evidence(ev_id)
            result.source_file = ev_result.source_file
            result.line_start = ev_result.line_start
            result.line_end = ev_result.line_end
            result.stored_hash = ev_result.stored_hash
            result.actual_hash = ev_result.actual_hash
            result.file_exists = ev_result.file_exists
            result.lines_exist = ev_result.lines_exist
            result.hash_match = ev_result.hash_match
            result.text_match = ev_result.text_match
            result.status = ev_result.status
            result.detail = ev_result.detail
        else:
            if result.symbol_exists:
                result.status = STATUS_PARTIAL
                result.detail = "symbol exists but no evidence"
            else:
                result.status = STATUS_INVALID
                result.detail = "no evidence and subject symbol missing"

        result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return result

    def verify_relation(self, relation_id):
        t0 = time.monotonic()
        result = VerificationResult()
        result.relation_exists = True

        rel = self.idx.relation_by_id.get(relation_id)
        if not rel:
            result.status = STATUS_NOT_FOUND
            result.detail = "relation not in index"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result

        from_id = rel.get("from_concept", "")
        to_id = rel.get("to_concept", "")
        result.symbol_exists = from_id in self.idx.concept_by_id
        result.fact_exists = to_id in self.idx.concept_by_id

        fact_ids = rel.get("evidence_fact_ids", [])
        if not fact_ids:
            result.status = STATUS_PARTIAL
            result.detail = "relation exists but no evidence facts"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result

        statuses = []
        for fid in fact_ids[:5]:
            fr = self.verify_fact(fid)
            statuses.append(fr.status)

        if all(s == STATUS_VERIFIED for s in statuses):
            result.status = STATUS_VERIFIED
            result.detail = f"{len(statuses)}/{len(fact_ids)} facts verified"
        elif any(s == STATUS_VERIFIED for s in statuses):
            result.status = STATUS_PARTIAL
            result.detail = f"{sum(1 for s in statuses if s == STATUS_VERIFIED)}/{len(statuses)} facts verified"
        elif any(s == STATUS_STALE for s in statuses):
            result.status = STATUS_STALE
            result.detail = f"all evidence stale"
        else:
            result.status = STATUS_INVALID
            result.detail = f"statuses: {statuses}"

        result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return result

    def verify_concept(self, concept_id):
        t0 = time.monotonic()
        result = VerificationResult()

        c = self.idx.concept_by_id.get(concept_id)
        if not c:
            result.status = STATUS_NOT_FOUND
            result.detail = "concept not in index"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result

        file_id = c.get("file_id", "")
        file_entry = self.idx.file_by_id.get(file_id)
        if file_entry:
            result.source_file = file_entry.get("path", "")
            result.file_exists = os.path.exists(result.source_file)

        ev_ids = c.get("evidence_ids", [])
        if not ev_ids:
            fact_ids = c.get("fact_ids", [])
            if fact_ids:
                fr = self.verify_fact(fact_ids[0])
                result.status = fr.status
                result.source_file = fr.source_file
                result.line_start = fr.line_start
                result.line_end = fr.line_end
                result.hash_match = fr.hash_match
                result.text_match = fr.text_match
                result.detail = fr.detail
            else:
                result.status = STATUS_PARTIAL
                result.detail = "concept exists but no evidence or facts"
        else:
            ev_result = self.verify_evidence(ev_ids[0])
            result.status = ev_result.status
            result.source_file = ev_result.source_file
            result.line_start = ev_result.line_start
            result.line_end = ev_result.line_end
            result.hash_match = ev_result.hash_match
            result.text_match = ev_result.text_match
            result.stored_hash = ev_result.stored_hash
            result.actual_hash = ev_result.actual_hash
            result.detail = ev_result.detail

        result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return result

    def bulk_verify(self, evidence_ids=None, limit=100):
        t0 = time.monotonic()
        if evidence_ids is None:
            evidence_ids = list(self.idx.evidence_by_id.keys())[:limit]

        results = []
        stats = {STATUS_VERIFIED: 0, STATUS_STALE: 0, STATUS_MISSING: 0,
                 STATUS_INVALID: 0, STATUS_NOT_FOUND: 0, STATUS_PARTIAL: 0}
        for eid in evidence_ids:
            r = self.verify_evidence(eid)
            results.append(r)
            stats[r.status] = stats.get(r.status, 0) + 1

        elapsed = round((time.monotonic() - t0) * 1000, 2)
        avg_ms = round(elapsed / max(len(results), 1), 3)
        return {
            "total": len(results),
            "stats": stats,
            "elapsed_ms": elapsed,
            "avg_ms": avg_ms,
            "results": results,
        }


_instance = None


def get_evidence_verifier():
    global _instance
    if _instance is None:
        _instance = EvidenceVerifier.load()
    return _instance


def main():
    v = EvidenceVerifier.load()
    print("EVIDENCE VERIFIER READY")

    ev = v.verify_evidence("EV-a57cb8a7fdeac64d")
    print(f"\nEV-a57cb8a7fdeac64d: {ev.status}")
    print(f"  file_exists={ev.file_exists} hash_match={ev.hash_match} text_match={ev.text_match}")
    print(f"  detail={ev.detail}")

    bulk = v.bulk_verify(limit=50)
    print(f"\nBulk verify {bulk['total']}:")
    for s, c in bulk["stats"].items():
        if c > 0:
            print(f"  {s}: {c}")
    print(f"  elapsed: {bulk['elapsed_ms']}ms avg: {bulk['avg_ms']}ms")

    sys.exit(0)


if __name__ == "__main__":
    main()
