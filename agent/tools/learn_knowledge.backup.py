import json
import pathlib
import hashlib
import sys
from datetime import datetime, timezone


BASE = pathlib.Path(r"C:\B-Plus\agent")
MEMORY = BASE / "memory"

STRUCTURED = MEMORY / "structured.json"
LEARNED = MEMORY / "learned_knowledge.json"


def load_json(path, default):
    if not path.exists():
        return default

    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path, data):
    tmp = path.with_suffix(path.suffix + ".tmp")

    with tmp.open("w", encoding="utf-8") as f:
        json.dump(
            data,
            f,
            ensure_ascii=False,
            indent=2
        )

    tmp.replace(path)


def now():
    return datetime.now(timezone.utc).isoformat()


def make_id(prefix, text):
    digest = hashlib.sha256(
        text.encode("utf-8")
    ).hexdigest()[:16]

    return f"{prefix}-{digest}"


def ensure_schema(learned):
    learned.setdefault("version", 2)
    learned.setdefault("candidates", {})
    learned.setdefault("verified", {})
    learned.setdefault("rejected", {})
    learned.setdefault("needs_review", {})
    learned.setdefault("concepts", {})
    learned.setdefault("relations", {})
    learned.setdefault("research_sessions", {})

    return learned


def search_evidence(structured, subject):
    """
    Conservative evidence search.

    Only evidence already present in structured.json
    is allowed to participate in verification.
    """

    subject_lower = subject.lower()

    results = []

    for evidence_id, evidence in structured.get(
        "evidence",
        {}
    ).items():

        text = str(
            evidence.get("text", "")
        )

        if subject_lower in text.lower():

            results.append({
                "evidence_id": evidence_id,
                "file": evidence.get("file"),
                "line_start": evidence.get(
                    "line_start"
                ),
                "line_end": evidence.get(
                    "line_end"
                ),
                "text": text
            })

    return results


def classify_evidence(evidence, claim):
    """
    First conservative deterministic classifier.

    It does NOT claim semantic understanding.

    direct:
        evidence text contains meaningful pieces
        of the claim.

    weak:
        only the subject is present.
    """

    text = evidence["text"].lower()
    claim_lower = claim.lower()

    words = [
        w.strip(".,:;()[]{}<>\"'")
        for w in claim_lower.split()
    ]

    words = [
        w for w in words
        if len(w) >= 4
    ]

    if not words:
        return "weak"

    matched = sum(
        1
        for word in words
        if word in text
    )

    ratio = matched / len(words)

    if ratio >= 0.35:
        return "direct"

    return "weak"


def verify_candidate(structured, candidate):
    """
    Deterministic verification layer.

    IMPORTANT:
    This function may only verify against project evidence.
    """

    subject = candidate["subject"]
    claim = candidate["claim"]

    evidence = search_evidence(
        structured,
        subject
    )

    if not evidence:

        return {
            "status": "REJECTED",
            "reason": "NO_EVIDENCE",
            "confidence": 0.0,
            "supporting_evidence": [],
            "weak_evidence": [],
            "contradicting_evidence": []
        }

    supporting = []
    weak = []

    for ev in evidence:

        classification = classify_evidence(
            ev,
            claim
        )

        if classification == "direct":
            supporting.append(ev)
        else:
            weak.append(ev)

    if supporting:

        confidence = min(
            0.99,
            0.70 + 0.05 * len(supporting)
        )

        return {
            "status": "VERIFIED",
            "reason": "DIRECT_PROJECT_EVIDENCE",
            "confidence": round(
                confidence,
                2
            ),
            "supporting_evidence": supporting,
            "weak_evidence": weak,
            "contradicting_evidence": []
        }

    return {
        "status": "NEEDS_REVIEW",
        "reason": "ONLY_WEAK_EVIDENCE",
        "confidence": 0.25,
        "supporting_evidence": [],
        "weak_evidence": weak,
        "contradicting_evidence": []
    }


def learn_candidate(
    structured,
    learned,
    subject,
    claim,
    fact_type="unknown"
):

    candidate_id = make_id(
        "CAND",
        subject + "\n" + claim
    )

    candidate = {
        "id": candidate_id,
        "subject": subject,
        "claim": claim,
        "type": fact_type,
        "created_at": now()
    }

    learned["candidates"][candidate_id] = candidate

    verification = verify_candidate(
        structured,
        candidate
    )

    status = verification["status"]

    if status == "VERIFIED":

        fact = {
            "id": candidate_id,
            "subject": subject,
            "claim": claim,
            "type": fact_type,
            "status": "VERIFIED",
            "confidence": verification[
                "confidence"
            ],
            "supporting_evidence":
                verification[
                    "supporting_evidence"
                ],
            "weak_evidence":
                verification[
                    "weak_evidence"
                ],
            "contradicting_evidence":
                verification[
                    "contradicting_evidence"
                ],
            "verification_method":
                verification["reason"],
            "created_at":
                candidate["created_at"],
            "verified_at":
                now()
        }

        learned["verified"][
            candidate_id
        ] = fact

        print()
        print("=" * 70)
        print("VERIFIED")
        print("=" * 70)
        print("ID:", candidate_id)
        print("SUBJECT:", subject)
        print("CLAIM:", claim)
        print(
            "CONFIDENCE:",
            fact["confidence"]
        )
        print(
            "SUPPORTING:",
            len(
                fact["supporting_evidence"]
            )
        )

    elif status == "REJECTED":

        learned["rejected"][
            candidate_id
        ] = {
            **candidate,
            "status": "REJECTED",
            "reason": verification[
                "reason"
            ],
            "rejected_at": now()
        }

        print()
        print("=" * 70)
        print("REJECTED")
        print("=" * 70)
        print("ID:", candidate_id)
        print("REASON:", verification["reason"])

    else:

        learned["needs_review"][
            candidate_id
        ] = {
            **candidate,
            "status": "NEEDS_REVIEW",
            "confidence":
                verification["confidence"],
            "weak_evidence":
                verification["weak_evidence"],
            "created_at":
                candidate["created_at"]
        }

        print()
        print("=" * 70)
        print("NEEDS REVIEW")
        print("=" * 70)
        print("ID:", candidate_id)
        print("CLAIM:", claim)
        print(
            "WEAK EVIDENCE:",
            len(
                verification["weak_evidence"]
            )
        )

    return candidate_id


def print_info(structured, learned):

    print("=" * 70)
    print("B+ KNOWLEDGE LEARNING SYSTEM")
    print("=" * 70)

    print()
    print("SOURCE DATABASE")
    print(
        "  sources:",
        len(structured.get("sources", {}))
    )
    print(
        "  knowledge:",
        len(structured.get("knowledge", {}))
    )
    print(
        "  evidence:",
        len(structured.get("evidence", {}))
    )
    print(
        "  relations:",
        len(structured.get("relations", {}))
    )

    print()
    print("LEARNED DATABASE")
    print(
        "  candidates:",
        len(learned["candidates"])
    )
    print(
        "  verified:",
        len(learned["verified"])
    )
    print(
        "  rejected:",
        len(learned["rejected"])
    )
    print(
        "  needs_review:",
        len(learned["needs_review"])
    )
    print(
        "  concepts:",
        len(learned["concepts"])
    )
    print(
        "  relations:",
        len(learned["relations"])
    )
    print(
        "  research_sessions:",
        len(learned["research_sessions"])
    )

    print()
    print("STATUS: READY")


def main():

    structured = load_json(
        STRUCTURED,
        {}
    )

    learned = load_json(
        LEARNED,
        {
            "version": 2,
            "candidates": {},
            "verified": {},
            "rejected": {},
            "needs_review": {},
            "concepts": {},
            "relations": {},
            "research_sessions": {}
        }
    )

    learned = ensure_schema(
        learned
    )

    if len(sys.argv) >= 2:

        command = sys.argv[1]

        if command == "--info":

            print_info(
                structured,
                learned
            )

            save_json(
                LEARNED,
                learned
            )

            return

        if command == "--learn":

            if len(sys.argv) < 4:

                print(
                    'Usage: py learn_knowledge.py '
                    '--learn "SUBJECT" "CLAIM"'
                )

                sys.exit(1)

            subject = sys.argv[2]
            claim = sys.argv[3]

            fact_type = (
                sys.argv[4]
                if len(sys.argv) >= 5
                else "unknown"
            )

            learn_candidate(
                structured,
                learned,
                subject,
                claim,
                fact_type
            )

            save_json(
                LEARNED,
                learned
            )

            return

    print_info(
        structured,
        learned
    )

    save_json(
        LEARNED,
        learned
    )


if __name__ == "__main__":
    main()