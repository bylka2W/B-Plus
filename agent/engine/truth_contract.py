import os
import sys
import time
import re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

STATUS_VERIFIED = "VERIFIED"
STATUS_STALE = "STALE"
STATUS_MISSING = "MISSING"
STATUS_INVALID = "INVALID"
STATUS_NOT_FOUND = "NOT_FOUND"
STATUS_PARTIAL = "PARTIAL"
STATUS_UNKNOWN = "UNKNOWN"
STATUS_UNSUPPORTED = "UNSUPPORTED"
STATUS_CONTRADICTION = "CONTRADICTION"

ALL_CLAIM_STATUSES = {
    STATUS_VERIFIED, STATUS_STALE, STATUS_MISSING, STATUS_INVALID,
    STATUS_NOT_FOUND, STATUS_PARTIAL, STATUS_UNKNOWN, STATUS_UNSUPPORTED,
    STATUS_CONTRADICTION,
}

STATUS_PASS = "PASS"
STATUS_FAIL = "FAIL"
STATUS_PARTIAL_PASS = "PARTIAL"

CN_RE = re.compile(r"\b(CN-[0-9a-f]{16})\b")
FI_RE = re.compile(r"\b(FI-[0-9a-f]{16})\b")
EV_RE = re.compile(r"\b(EV-[0-9a-f]{16})\b")
FACT_RE = re.compile(r"\b(FACT-[0-9a-f]{16})\b")
SR_RE = re.compile(r"\b(SR-[0-9a-f]{16})\b")

IDENTITY_RE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]{2,})\b")
ARROW_RE = re.compile(r"(\w[\w.]*)\s*(?:--|->|→|calls?|uses?|depends\s+on|contains?|references?)\s*(\w[\w.]*)", re.I)
FILE_LINE_RE = re.compile(r"([\w/\\.\-]+\.zig):(\d+)(?:-(\d+))?")


class Claim:
    __slots__ = (
        "text", "subject", "predicate", "object",
        "evidence_ids", "concept_ids", "fact_ids",
        "source_files", "status", "confidence", "detail",
    )

    def __init__(self):
        self.text = ""
        self.subject = ""
        self.predicate = ""
        self.object = ""
        self.evidence_ids = []
        self.concept_ids = []
        self.fact_ids = []
        self.source_files = []
        self.status = STATUS_UNKNOWN
        self.confidence = 0.0
        self.detail = ""

    def to_dict(self):
        return {
            "text": self.text,
            "subject": self.subject,
            "predicate": self.predicate,
            "object": self.object,
            "evidence_ids": self.evidence_ids,
            "concept_ids": self.concept_ids,
            "fact_ids": self.fact_ids,
            "source_files": self.source_files,
            "status": self.status,
            "confidence": round(self.confidence, 4),
            "detail": self.detail,
        }


class AnswerVerification:
    __slots__ = (
        "claims", "total_claims", "verified_claims", "stale_claims",
        "unsupported_claims", "contradiction_claims", "unknown_claims",
        "overall_status", "evidence_confidence", "source_confidence",
        "graph_confidence", "verification_confidence", "overall_confidence",
        "hallucination_rate", "elapsed_ms",
    )

    def __init__(self):
        self.claims = []
        self.total_claims = 0
        self.verified_claims = 0
        self.stale_claims = 0
        self.unsupported_claims = 0
        self.contradiction_claims = 0
        self.unknown_claims = 0
        self.overall_status = STATUS_PASS
        self.evidence_confidence = 0.0
        self.source_confidence = 0.0
        self.graph_confidence = 0.0
        self.verification_confidence = 0.0
        self.overall_confidence = 0.0
        self.hallucination_rate = 0.0
        self.elapsed_ms = 0.0

    def to_dict(self):
        return {
            "total_claims": self.total_claims,
            "verified_claims": self.verified_claims,
            "stale_claims": self.stale_claims,
            "unsupported_claims": self.unsupported_claims,
            "contradiction_claims": self.contradiction_claims,
            "unknown_claims": self.unknown_claims,
            "overall_status": self.overall_status,
            "evidence_confidence": round(self.evidence_confidence, 4),
            "source_confidence": round(self.source_confidence, 4),
            "graph_confidence": round(self.graph_confidence, 4),
            "verification_confidence": round(self.verification_confidence, 4),
            "overall_confidence": round(self.overall_confidence, 4),
            "hallucination_rate": round(self.hallucination_rate, 4),
            "elapsed_ms": self.elapsed_ms,
            "claims": [c.to_dict() for c in self.claims],
        }


class TruthContract:
    def __init__(self, idx=None, verifier=None):
        from indexes import get_fast_index
        from evidence_verifier import get_evidence_verifier
        self.idx = idx or get_fast_index()
        self.verifier = verifier or get_evidence_verifier()

    @classmethod
    def load(cls):
        return cls()

    def extract_claims(self, answer_text):
        claims = []
        sentences = self._split_sentences(answer_text)
        for sent in sentences:
            sent = sent.strip()
            if not sent or len(sent) < 5:
                continue
            claim = Claim()
            claim.text = sent
            self._extract_references(claim, sent)
            if claim.subject or claim.concept_ids or claim.evidence_ids:
                claims.append(claim)
        if not claims and answer_text.strip():
            claim = Claim()
            claim.text = answer_text.strip()
            self._extract_references(claim, answer_text)
            claims.append(claim)
        return claims

    def verify_answer(self, answer_text, context=None):
        t0 = time.monotonic()
        result = AnswerVerification()
        claims = self.extract_claims(answer_text)
        for claim in claims:
            self._verify_claim(claim)
            result.claims.append(claim)

        result.total_claims = len(claims)
        for c in claims:
            if c.status == STATUS_VERIFIED:
                result.verified_claims += 1
            elif c.status == STATUS_STALE:
                result.stale_claims += 1
            elif c.status == STATUS_UNSUPPORTED:
                result.unsupported_claims += 1
            elif c.status == STATUS_CONTRADICTION:
                result.contradiction_claims += 1
            elif c.status in (STATUS_UNKNOWN, STATUS_NOT_FOUND):
                result.unknown_claims += 1

        if result.total_claims > 0:
            result.evidence_confidence = result.verified_claims / result.total_claims
            result.source_confidence = result.verified_claims / result.total_claims
            result.graph_confidence = (result.verified_claims + result.stale_claims) / result.total_claims
            result.verification_confidence = result.verified_claims / result.total_claims
            result.hallucination_rate = (result.unsupported_claims + result.contradiction_claims) / result.total_claims
        else:
            result.evidence_confidence = 1.0
            result.source_confidence = 1.0
            result.graph_confidence = 1.0
            result.verification_confidence = 1.0
            result.hallucination_rate = 0.0

        result.overall_confidence = (
            result.evidence_confidence * 0.35 +
            result.source_confidence * 0.25 +
            result.graph_confidence * 0.15 +
            result.verification_confidence * 0.25
        )

        if result.hallucination_rate > 0:
            result.overall_status = STATUS_FAIL
        elif result.stale_claims > 0:
            result.overall_status = STATUS_PARTIAL_PASS
        else:
            result.overall_status = STATUS_PASS

        result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return result

    def _verify_claim(self, claim):
        if claim.concept_ids:
            verified_concepts = 0
            for cid in claim.concept_ids:
                c = self.idx.concept_by_id.get(cid)
                if c:
                    verified_concepts += 1
            if verified_concepts == len(claim.concept_ids):
                if claim.evidence_ids:
                    ev_ok = 0
                    for eid in claim.evidence_ids:
                        ev = self.idx.evidence_by_id.get(eid)
                        if ev:
                            vr = self.verifier.verify_evidence(eid)
                            if vr.status in (STATUS_VERIFIED, STATUS_STALE):
                                ev_ok += 1
                    if ev_ok == len(claim.evidence_ids):
                        claim.status = STATUS_VERIFIED
                        claim.confidence = 1.0
                    elif ev_ok > 0:
                        claim.status = STATUS_PARTIAL
                        claim.confidence = ev_ok / len(claim.evidence_ids)
                    else:
                        claim.status = STATUS_UNSUPPORTED
                        claim.confidence = 0.0
                else:
                    claim.status = STATUS_PARTIAL
                    claim.confidence = 0.5
            else:
                claim.status = STATUS_NOT_FOUND
                claim.confidence = 0.0
        elif claim.fact_ids:
            verified_facts = 0
            for fid in claim.fact_ids:
                f = self.idx.fact_by_id.get(fid)
                if f:
                    verified_facts += 1
            if verified_facts == len(claim.fact_ids):
                claim.status = STATUS_VERIFIED
                claim.confidence = 0.9
            else:
                claim.status = STATUS_PARTIAL
                claim.confidence = verified_facts / max(len(claim.fact_ids), 1)
        elif claim.source_files:
            file_ok = 0
            for sf in claim.source_files:
                if os.path.exists(sf):
                    file_ok += 1
            if file_ok == len(claim.source_files):
                claim.status = STATUS_PARTIAL
                claim.confidence = 0.5
            else:
                claim.status = STATUS_MISSING
                claim.confidence = 0.0
        else:
            claim.status = STATUS_UNKNOWN
            claim.confidence = 0.0

    def _extract_references(self, claim, text):
        for m in CN_RE.finditer(text):
            claim.concept_ids.append(m.group(1))
        for m in FACT_RE.finditer(text):
            claim.fact_ids.append(m.group(1))
        for m in EV_RE.finditer(text):
            claim.evidence_ids.append(m.group(1))
        for m in FILE_LINE_RE.finditer(text):
            claim.source_files.append(m.group(1))

        arrow_m = ARROW_RE.search(text)
        if arrow_m:
            claim.subject = arrow_m.group(1)
            claim.object = arrow_m.group(2)
            lower = text.lower()
            if "call" in lower:
                claim.predicate = "CALLS"
            elif "use" in lower:
                claim.predicate = "USES"
            elif "depend" in lower:
                claim.predicate = "DEPENDS_ON"
            elif "contain" in lower:
                claim.predicate = "CONTAINS"
            elif "reference" in lower:
                claim.predicate = "REFERENCES"
            else:
                claim.predicate = "RELATES_TO"

        if not claim.subject:
            names = IDENTITY_RE.findall(text)
            known = []
            for name in names:
                cids = self.idx.resolve_concept(name)
                if cids:
                    known.append((name, cids[0]))
            if known:
                claim.subject = known[0][0]
                claim.concept_ids.append(known[0][1])
                if len(known) > 1:
                    claim.object = known[1][0]
                    claim.concept_ids.append(known[1][1])

    def _split_sentences(self, text):
        parts = re.split(r"(?<=[.!?])\s+|\n+", text)
        return [p.strip() for p in parts if p.strip()]


_instance = None


def get_truth_contract():
    global _instance
    if _instance is None:
        _instance = TruthContract.load()
    return _instance


def main():
    tc = TruthContract.load()
    print("TRUTH CONTRACT READY")

    test_answers = [
        "foldConstantOp is called by runConstantFolding. "
        "It calls getConstValue. "
        "It is defined in manager.zig.",

        "foldConstantOp calls nonexistentFakeFunction. "
        "It is located in fakefile.zig.",

        "The function foldConstantOp (CN-00673ad4ff190413) "
        "calls getConstValue (CN-f31091417b8ee7dd). "
        "Evidence: EV-a57cb8a7fdeac64d.",
    ]

    for answer in test_answers:
        print(f"\n{'='*60}")
        print(f"ANSWER: {answer[:80]}...")
        result = tc.verify_answer(answer)
        print(f"STATUS: {result.overall_status}")
        print(f"CLAIMS: {result.total_claims}")
        print(f"  verified={result.verified_claims} stale={result.stale_claims} "
              f"unsupported={result.unsupported_claims} unknown={result.unknown_claims}")
        print(f"  hallucination_rate={result.hallucination_rate:.2f}")
        print(f"  overall_confidence={result.overall_confidence:.2f}")
        for i, c in enumerate(result.claims):
            print(f"  claim {i+1}: [{c.status}] {c.text[:60]}...")
            if c.concept_ids:
                print(f"    concepts: {c.concept_ids}")

    sys.exit(0)


if __name__ == "__main__":
    main()
