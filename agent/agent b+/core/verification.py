import re
import json
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


@dataclass
class VerificationResult:
    claim: str
    verified: bool
    evidence_found: bool = False
    evidence_source: str = ""
    confidence: float = 0.0
    reason: str = ""


@dataclass
class VerificationReport:
    claims: List[VerificationResult] = field(default_factory=list)
    overall_verified: bool = False
    overall_confidence: float = 0.0
    verified_count: int = 0
    total_count: int = 0
    qualified_count: int = 0
    rejected_count: int = 0


class VerificationLayer:
    CLAIM_PATTERNS = [
        re.compile(r"([A-Z][a-zA-Z0-9_]+)\s+(?:is|находится|located|defined|implemented)\s+(.+?)(?:\.|$)"),
        re.compile(r"(?:file|файл)\s+(\w+\.\w+)\s+(?:contains|содержит|has)\s+(.+?)(?:\.|$)"),
        re.compile(r"(?:function|fn|функция)\s+(\w+)\s+(.+?)(?:\.|$)"),
        re.compile(r"([A-Z][a-zA-Z0-9_]+)\s+(.+?)(?:\.|$)"),
    ]

    def __init__(self):
        pass

    def verify(self, answer: str, query_result: Any) -> VerificationReport:
        report = VerificationReport()

        if self._is_random_output(answer):
            report.overall_verified = False
            report.overall_confidence = 0.0
            report.claims = [VerificationResult(
                claim="Model output", verified=False, evidence_found=False,
                confidence=0.0, reason="Output appears to be random/untrained model tokens",
            )]
            report.total_count = 1
            report.rejected_count = 1
            return report

        claims = self._extract_claims(answer)
        if not claims:
            report.overall_verified = True
            report.overall_confidence = 0.5
            return report

        evidence_index = self._build_evidence_index(query_result)

        for claim in claims:
            vr = self._verify_claim(claim, evidence_index, query_result)
            report.claims.append(vr)
            report.total_count += 1
            if vr.verified:
                report.verified_count += 1
            elif vr.evidence_found:
                report.qualified_count += 1
            else:
                report.rejected_count += 1

        if report.total_count > 0:
            report.overall_confidence = report.verified_count / report.total_count
            report.overall_verified = report.verified_count >= report.total_count * 0.5

        return report

    def _extract_claims(self, answer: str) -> List[str]:
        sentences = re.split(r"[.!?\n]", answer)
        claims = []
        for s in sentences:
            s = s.strip()
            if len(s) > 10 and any(kw in s.lower() for kw in [
                "is", "located", "defined", "found", "implements", "contains",
                "находится", "содержит", "реализует", "определяет",
            ]):
                claims.append(s)
        return claims[:10]

    def _build_evidence_index(self, query_result: Any) -> Dict[str, List]:
        index = {"facts": [], "evidence": [], "source_files": []}

        if hasattr(query_result, "facts"):
            index["facts"] = query_result.facts
        if hasattr(query_result, "evidence"):
            index["evidence"] = query_result.evidence
        if hasattr(query_result, "source_files"):
            index["source_files"] = query_result.source_files

        return index

    def _verify_claim(self, claim: str, evidence_index: Dict, query_result: Any) -> VerificationResult:
        claim_lower = claim.lower()

        for fact in evidence_index["facts"]:
            fact_str = json.dumps(fact, ensure_ascii=False).lower()
            overlap = self._text_overlap(claim_lower, fact_str)
            if overlap > 0.3:
                sf = fact.get("source_file", "")
                return VerificationResult(
                    claim=claim, verified=True, evidence_found=True,
                    evidence_source=sf, confidence=overlap,
                    reason=f"Supported by fact: {fact.get('predicate','')}",
                )

        for ev in evidence_index["evidence"]:
            ev_text = ev.get("text", "").lower()
            overlap = self._text_overlap(claim_lower, ev_text)
            if overlap > 0.3:
                sf = ev.get("source_file", "")
                ls = ev.get("line_start", 0)
                le = ev.get("line_end", 0)
                return VerificationResult(
                    claim=claim, verified=True, evidence_found=True,
                    evidence_source=f"{sf}:{ls}-{le}", confidence=overlap,
                    reason=f"Supported by source evidence at {sf}:{ls}-{le}",
                )

        for src in evidence_index["source_files"]:
            content = src.get("content", "").lower()
            if content and self._text_overlap(claim_lower, content) > 0.4:
                return VerificationResult(
                    claim=claim, verified=True, evidence_found=True,
                    evidence_source=src.get("path", ""),
                    confidence=0.5, reason="Found in source file content",
                )

        if any(kw in claim_lower for kw in ["is defined", "is located", "находится", "содержит"]):
            return VerificationResult(
                claim=claim, verified=False, evidence_found=False,
                confidence=0.0, reason="No supporting evidence found",
            )

        return VerificationResult(
            claim=claim, verified=False, evidence_found=False,
            confidence=0.2, reason="Could not verify against available evidence",
        )

    def _text_overlap(self, text1: str, text2: str) -> float:
        words1 = set(text1.split())
        words2 = set(text2.split())
        if not words1 or not words2:
            return 0.0
        intersection = words1 & words2
        return len(intersection) / min(len(words1), len(words2))

    def _is_random_output(self, answer: str) -> bool:
        if len(answer) < 10:
            return True

        alpha_ratio = sum(1 for c in answer if c.isalpha()) / max(len(answer), 1)
        if alpha_ratio < 0.3:
            return True

        words = answer.split()
        if len(words) < 3:
            return True

        repeat_ratio = 1.0 - len(set(words)) / max(len(words), 1)
        if repeat_ratio > 0.5:
            return True

        code_tokens = sum(1 for w in words if w in [
            "fn", "pub", "const", "var", "struct", "enum", "if", "else",
            "return", "void", "import", "test", "try", "catch",
        ])
        if code_tokens > len(words) * 0.3:
            return True

        return False

    def format_report(self, report: VerificationReport) -> str:
        lines = []
        lines.append(f"VERIFICATION: {report.verified_count}/{report.total_count} verified, "
                     f"{report.qualified_count} qualified, {report.rejected_count} rejected")
        lines.append(f"Confidence: {report.overall_confidence:.1%}")
        lines.append(f"Overall: {'VERIFIED' if report.overall_verified else 'QUALIFIED/REJECTED'}")

        for vr in report.claims:
            status = "VERIFIED" if vr.verified else ("QUALIFIED" if vr.evidence_found else "REJECTED")
            lines.append(f"  [{status}] {vr.claim[:80]}...")
            if vr.evidence_source:
                lines.append(f"    Source: {vr.evidence_source}")
            lines.append(f"    Reason: {vr.reason}")

        return "\n".join(lines)
