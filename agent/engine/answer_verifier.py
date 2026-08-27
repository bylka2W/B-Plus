import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from truth_contract import (
    TruthContract, Claim, AnswerVerification,
    STATUS_VERIFIED, STATUS_STALE, STATUS_MISSING, STATUS_INVALID,
    STATUS_NOT_FOUND, STATUS_PARTIAL, STATUS_UNKNOWN, STATUS_UNSUPPORTED,
    STATUS_CONTRADICTION, STATUS_PASS, STATUS_FAIL, STATUS_PARTIAL_PASS,
)

STATUS_PASS_A = "PASS"
STATUS_FAIL_A = "FAIL"
STATUS_PARTIAL_A = "PARTIAL"
STATUS_INSUFFICIENT = "INSUFFICIENT_CONTEXT"
STATUS_NO_CLAIMS = "NO_CLAIMS"


class AnswerCheck:
    __slots__ = (
        "claim_text", "claim_status", "evidence_chain",
        "concept_verified", "source_exists", "source_match",
        "relation_verified", "detail",
    )

    def __init__(self):
        self.claim_text = ""
        self.claim_status = STATUS_UNKNOWN
        self.evidence_chain = []
        self.concept_verified = False
        self.source_exists = False
        self.source_match = False
        self.relation_verified = False
        self.detail = ""

    def to_dict(self):
        return {
            "claim_text": self.claim_text,
            "claim_status": self.claim_status,
            "evidence_chain": self.evidence_chain,
            "concept_verified": self.concept_verified,
            "source_exists": self.source_exists,
            "source_match": self.source_match,
            "relation_verified": self.relation_verified,
            "detail": self.detail,
        }


class VerifiedAnswer:
    __slots__ = (
        "original_answer", "checks", "total_claims", "verified_count",
        "stale_count", "unsupported_count", "unknown_count",
        "overall_status", "hallucination_rate", "confidence",
        "evidence_chain_complete", "all_sources_exist",
        "elapsed_ms",
    )

    def __init__(self):
        self.original_answer = ""
        self.checks = []
        self.total_claims = 0
        self.verified_count = 0
        self.stale_count = 0
        self.unsupported_count = 0
        self.unknown_count = 0
        self.overall_status = STATUS_PASS_A
        self.hallucination_rate = 0.0
        self.confidence = 0.0
        self.evidence_chain_complete = False
        self.all_sources_exist = False
        self.elapsed_ms = 0.0

    def to_dict(self):
        return {
            "original_answer": self.original_answer,
            "total_claims": self.total_claims,
            "verified_count": self.verified_count,
            "stale_count": self.stale_count,
            "unsupported_count": self.unsupported_count,
            "unknown_count": self.unknown_count,
            "overall_status": self.overall_status,
            "hallucination_rate": round(self.hallucination_rate, 4),
            "confidence": round(self.confidence, 4),
            "evidence_chain_complete": self.evidence_chain_complete,
            "all_sources_exist": self.all_sources_exist,
            "elapsed_ms": self.elapsed_ms,
            "checks": [c.to_dict() for c in self.checks],
        }

    def render(self):
        lines = []
        lines.append(f"STATUS: {self.overall_status}")
        lines.append(f"CLAIMS: {self.total_claims} "
                     f"(verified={self.verified_count} stale={self.stale_count} "
                     f"unsupported={self.unsupported_count})")
        lines.append(f"HALLUCINATION_RATE: {self.hallucination_rate:.2%}")
        lines.append(f"CONFIDENCE: {self.confidence:.2%}")
        lines.append(f"EVIDENCE_CHAIN: {'COMPLETE' if self.evidence_chain_complete else 'INCOMPLETE'}")
        lines.append(f"SOURCES: {'ALL_EXIST' if self.all_sources_exist else 'MISSING'}")
        lines.append("")
        for i, c in enumerate(self.checks):
            tag = "OK" if c.claim_status == STATUS_VERIFIED else c.claim_status
            lines.append(f"  [{tag}] {c.claim_text[:80]}")
            if c.evidence_chain:
                for ev in c.evidence_chain[:3]:
                    lines.append(f"       -> {ev}")
            if c.detail:
                lines.append(f"       {c.detail}")
        return "\n".join(lines)


class AnswerVerifier:
    def __init__(self, idx=None, truth=None):
        from indexes import get_fast_index
        self.idx = idx or get_fast_index()
        self.truth = truth or TruthContract.load()

    @classmethod
    def load(cls):
        return cls()

    def verify(self, answer, question="", context=None):
        t0 = time.monotonic()
        result = VerifiedAnswer()
        result.original_answer = answer

        if not answer or not answer.strip():
            result.overall_status = STATUS_NO_CLAIMS
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result

        claims = self.truth.extract_claims(answer)
        if not claims:
            result.overall_status = STATUS_NO_CLAIMS
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result

        result.total_claims = len(claims)
        all_evidence_chains = []
        all_sources_exist = True

        for claim in claims:
            check = AnswerCheck()
            check.claim_text = claim.text

            evidence_chain = self._build_evidence_chain(claim)
            check.evidence_chain = evidence_chain

            if claim.concept_ids:
                for cid in claim.concept_ids:
                    c = self.idx.concept_by_id.get(cid)
                    if c:
                        check.concept_verified = True
                        file_id = c.get("file_id", "")
                        fe = self.idx.file_by_id.get(file_id)
                        if fe:
                            path = fe.get("path", "")
                            check.source_exists = os.path.exists(path)
                            if not check.source_exists:
                                all_sources_exist = False
                        break

            if claim.subject and claim.object and claim.predicate:
                check.relation_verified = self._verify_relation(
                    claim.subject, claim.object, claim.predicate
                )

            if evidence_chain:
                all_evidence_chains.append(evidence_chain)

            if check.concept_verified and (check.relation_verified or evidence_chain):
                check.claim_status = STATUS_VERIFIED
                result.verified_count += 1
            elif check.concept_verified:
                check.claim_status = STATUS_STALE
                result.stale_count += 1
            elif claim.concept_ids:
                check.claim_status = STATUS_NOT_FOUND
                result.unsupported_count += 1
            elif evidence_chain:
                check.claim_status = STATUS_PARTIAL
                result.stale_count += 1
            else:
                check.claim_status = STATUS_UNSUPPORTED
                result.unsupported_count += 1

            result.checks.append(check)

        result.evidence_chain_complete = len(all_evidence_chains) == result.total_claims
        result.all_sources_exist = all_sources_exist

        if result.total_claims > 0:
            result.hallucination_rate = result.unsupported_count / result.total_claims
            result.confidence = result.verified_count / result.total_claims

        if result.hallucination_rate > 0:
            result.overall_status = STATUS_FAIL_A
        elif result.stale_count > 0:
            result.overall_status = STATUS_PARTIAL_A
        else:
            result.overall_status = STATUS_PASS_A

        result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return result

    def _build_evidence_chain(self, claim):
        chain = []
        for cid in claim.concept_ids:
            c = self.idx.concept_by_id.get(cid)
            if not c:
                continue
            name = c.get("canonical_name", "")
            file_id = c.get("file_id", "")
            fe = self.idx.file_by_id.get(file_id)
            file_path = fe.get("path", "") if fe else ""
            ls = c.get("line_start", 0)
            le = c.get("line_end", 0)
            ev_ids = c.get("evidence_ids", [])
            for eid in ev_ids[:3]:
                ev = self.idx.evidence_by_id.get(eid)
                if ev:
                    chain.append(f"{name} -> {os.path.basename(file_path)}:{ls}-{le} [{eid}]")
                    break
            else:
                if file_path:
                    chain.append(f"{name} -> {os.path.basename(file_path)}:{ls}-{le}")
        return chain

    def _verify_relation(self, subject_name, object_name, predicate):
        sids = self.idx.resolve_concept(subject_name)
        oids = self.idx.resolve_concept(object_name)
        if not sids or not oids:
            return False
        sid = sids[0]
        oid = oids[0]
        for rid in self.idx.get_relations_by_source(sid):
            r = self.idx.relation_by_id.get(rid)
            if r and r.get("to_concept") == oid:
                rtype = r.get("relation_type", "")
                if predicate == "CALLS" and rtype == "CALLS":
                    return True
                if predicate == "USES" and rtype in ("USES_TYPE", "REFERENCES"):
                    return True
                if predicate == "DEPENDS_ON" and rtype == "DEPENDS_ON":
                    return True
                if predicate == "CONTAINS" and rtype == "CONTAINS":
                    return True
                if predicate == "REFERENCES" and rtype == "REFERENCES":
                    return True
                return True
        return False


_instance = None


def get_answer_verifier():
    global _instance
    if _instance is None:
        _instance = AnswerVerifier.load()
    return _instance


def main():
    av = AnswerVerifier.load()
    print("ANSWER VERIFIER READY")

    tests = [
        ("foldConstantOp (CN-00673ad4ff190413) calls getConstValue (CN-f31091417b8ee7dd).",
         "Who calls what?"),

        ("runConstantFolding calls foldConstantOp. "
         "foldConstantOp calls getConstValue.",
         "Trace foldConstantOp"),

        ("I think maybe it does something unclear.",
         "What does it do?"),

        ("", "empty"),
    ]

    for answer, question in tests:
        print(f"\n{'='*60}")
        print(f"Q: {question}")
        print(f"A: {answer[:70]}...")
        result = av.verify(answer, question)
        print(result.render())

    sys.exit(0)


if __name__ == "__main__":
    main()
