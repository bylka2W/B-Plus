import json
import pathlib
import hashlib
import re
import sys
from datetime import datetime, timezone


BASE = pathlib.Path(r"C:\B-Plus\agent")
MEMORY = BASE / "memory"

STRUCTURED = MEMORY / "structured.json"
LEARNED = MEMORY / "learned_knowledge.json"


# ============================================================
# TIME
# ============================================================

def now():
    return datetime.now(timezone.utc).isoformat()


# ============================================================
# JSON
# ============================================================

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


# ============================================================
# IDS
# ============================================================

def make_id(prefix, text):
    digest = hashlib.sha256(
        text.encode("utf-8")
    ).hexdigest()[:16]

    return f"{prefix}-{digest}"


# ============================================================
# SCHEMA
# ============================================================

def ensure_schema(learned):

    learned.setdefault("version", 3)

    learned.setdefault("candidates", {})
    learned.setdefault("verified", {})
    learned.setdefault("rejected", {})
    learned.setdefault("needs_review", {})

    learned.setdefault("concepts", {})
    learned.setdefault("relations", {})

    learned.setdefault("research_sessions", {})

    return learned


# ============================================================
# TEXT NORMALIZATION
# ============================================================

def normalize_text(text):

    text = str(text).lower()

    text = text.replace(
        "→",
        " to "
    )

    text = re.sub(
        r"[^a-z0-9+#.\- ]+",
        " ",
        text
    )

    text = re.sub(
        r"\s+",
        " ",
        text
    )

    return text.strip()


def tokens(text):

    result = []

    for word in normalize_text(text).split():

        if len(word) >= 3:
            result.append(word)

    return set(result)


# ============================================================
# EVIDENCE
# ============================================================

def search_evidence(structured, subject):

    subject_lower = normalize_text(subject)

    results = []

    for evidence_id, evidence in structured.get(
        "evidence",
        {}
    ).items():

        text = str(
            evidence.get("text", "")
        )

        if subject_lower in normalize_text(text):

            results.append({
                "evidence_id": evidence_id,
                "file": evidence.get("file"),
                "line_start": evidence.get("line_start"),
                "line_end": evidence.get("line_end"),
                "text": text
            })

    return results


# ============================================================
# EVIDENCE CLASSIFICATION
# ============================================================

def classify_evidence(evidence, claim):

    text_tokens = tokens(
        evidence["text"]
    )

    claim_tokens = tokens(
        claim
    )

    if not claim_tokens:
        return "weak"

    matched = len(
        text_tokens.intersection(
            claim_tokens
        )
    )

    ratio = matched / len(claim_tokens)

    if ratio >= 0.35:
        return "direct"

    return "weak"


# ============================================================
# CONTRADICTION DETECTION
# ============================================================

NEGATION_PATTERNS = [
    r"\bdoes not\b",
    r"\bdoesn't\b",
    r"\bdo not\b",
    r"\bdoesn't use\b",
    r"\bnot use\b",
    r"\bwithout\b",
    r"\bnever\b",
    r"\bno\b"
]


def has_negation(text):

    normalized = normalize_text(text)

    for pattern in NEGATION_PATTERNS:

        if re.search(
            pattern,
            normalized
        ):
            return True

    return False


def semantic_keywords(text):

    words = tokens(text)

    ignored = {
        "source",
        "processed",
        "through",
        "produce",
        "produces",
        "object",
        "executable",
        "does",
        "not",
        "use",
        "uses",
        "and",
        "the",
        "from",
        "into",
        "with"
    }

    return {
        word
        for word in words
        if word not in ignored
    }


def claims_contradict(
    existing_claim,
    new_claim
):

    existing_negated = has_negation(
        existing_claim
    )

    new_negated = has_negation(
        new_claim
    )

    existing_keywords = semantic_keywords(
        existing_claim
    )

    new_keywords = semantic_keywords(
        new_claim
    )

    overlap = existing_keywords.intersection(
        new_keywords
    )

    if len(overlap) < 2:
        return False

    if existing_negated != new_negated:
        return True

    return False


# ============================================================
# FIND CONTRADICTIONS
# ============================================================

def find_contradictions(
    learned,
    candidate
):

    contradictions = []

    for fact_id, fact in learned.get(
        "verified",
        {}
    ).items():

        if fact_id == candidate["id"]:
            continue

        if fact.get("subject") != candidate["subject"]:
            continue

        if claims_contradict(
            fact.get("claim", ""),
            candidate.get("claim", "")
        ):

            contradictions.append({
                "fact_id": fact_id,
                "claim": fact.get("claim"),
                "confidence": fact.get(
                    "confidence",
                    0.0
                )
            })

    return contradictions


# ============================================================
# VERIFICATION
# ============================================================

def verify_candidate(
    structured,
    learned,
    candidate
):

    subject = candidate["subject"]
    claim = candidate["claim"]

    # --------------------------------------------------------
    # First check existing verified knowledge.
    # --------------------------------------------------------

    contradictions = find_contradictions(
        learned,
        candidate
    )

    # --------------------------------------------------------
    # Then inspect project evidence.
    # --------------------------------------------------------

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
            "contradicting_evidence": contradictions
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

    # --------------------------------------------------------
    # Contradiction wins over weak evidence.
    # --------------------------------------------------------

    if contradictions:

        return {
            "status": "REJECTED",
            "reason": "CONTRADICTED_BY_VERIFIED_KNOWLEDGE",
            "confidence": 0.0,
            "supporting_evidence": supporting,
            "weak_evidence": weak,
            "contradicting_evidence": contradictions
        }

    # --------------------------------------------------------
    # Direct evidence.
    # --------------------------------------------------------

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

    # --------------------------------------------------------
    # Weak evidence.
    # --------------------------------------------------------

    return {
        "status": "NEEDS_REVIEW",
        "reason": "ONLY_WEAK_EVIDENCE",
        "confidence": 0.25,
        "supporting_evidence": [],
        "weak_evidence": weak,
        "contradicting_evidence": []
    }


# ============================================================
# LEARNING
# ============================================================

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

    learned["candidates"][
        candidate_id
    ] = candidate

    verification = verify_candidate(
        structured,
        learned,
        candidate
    )

    status = verification["status"]

    # ========================================================
    # VERIFIED
    # ========================================================

    if status == "VERIFIED":

        fact = {
            "id": candidate_id,
            "subject": subject,
            "claim": claim,
            "type": fact_type,
            "status": "VERIFIED",

            "confidence":
                verification["confidence"],

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

        # If it was previously under review,
        # remove stale copy.

        learned["needs_review"].pop(
            candidate_id,
            None
        )

        learned["rejected"].pop(
            candidate_id,
            None
        )

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
                fact[
                    "supporting_evidence"
                ]
            )
        )

        return candidate_id

    # ========================================================
    # REJECTED
    # ========================================================

    if status == "REJECTED":

        rejected = {
            **candidate,

            "status": "REJECTED",

            "reason":
                verification["reason"],

            "confidence":
                verification["confidence"],

            "weak_evidence":
                verification[
                    "weak_evidence"
                ],

            "contradicting_evidence":
                verification[
                    "contradicting_evidence"
                ],

            "rejected_at":
                now()
        }

        learned["rejected"][
            candidate_id
        ] = rejected

        learned["needs_review"].pop(
            candidate_id,
            None
        )

        print()
        print("=" * 70)
        print("REJECTED")
        print("=" * 70)

        print("ID:", candidate_id)
        print("SUBJECT:", subject)
        print("CLAIM:", claim)
        print(
            "REASON:",
            verification["reason"]
        )

        print(
            "CONTRADICTIONS:",
            len(
                verification[
                    "contradicting_evidence"
                ]
            )
        )

        return candidate_id

    # ========================================================
    # NEEDS REVIEW
    # ========================================================

    learned["needs_review"][
        candidate_id
    ] = {
        **candidate,

        "status": "NEEDS_REVIEW",

        "confidence":
            verification["confidence"],

        "weak_evidence":
            verification["weak_evidence"],

        "contradicting_evidence":
            verification[
                "contradicting_evidence"
            ]
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
            verification[
                "weak_evidence"
            ]
        )
    )

    return candidate_id


# ============================================================
# INFO
# ============================================================

def print_info(
    structured,
    learned
):

    print("=" * 70)
    print("B+ KNOWLEDGE LEARNING SYSTEM")
    print("=" * 70)

    print()
    print("SOURCE DATABASE")

    print(
        "  sources:",
        len(
            structured.get(
                "sources",
                {}
            )
        )
    )

    print(
        "  knowledge:",
        len(
            structured.get(
                "knowledge",
                {}
            )
        )
    )

    print(
        "  evidence:",
        len(
            structured.get(
                "evidence",
                {}
            )
        )
    )

    print(
        "  relations:",
        len(
            structured.get(
                "relations",
                {}
            )
        )
    )

    print()
    print("LEARNED DATABASE")

    print(
        "  candidates:",
        len(
            learned["candidates"]
        )
    )

    print(
        "  verified:",
        len(
            learned["verified"]
        )
    )

    print(
        "  rejected:",
        len(
            learned["rejected"]
        )
    )

    print(
        "  needs_review:",
        len(
            learned["needs_review"]
        )
    )

    print(
        "  concepts:",
        len(
            learned["concepts"]
        )
    )

    print(
        "  relations:",
        len(
            learned["relations"]
        )
    )

    print(
        "  research_sessions:",
        len(
            learned[
                "research_sessions"
            ]
        )
    )

    print()
    print("STATUS: READY")


# ============================================================
# MAIN
# ============================================================

def main():

    structured = load_json(
        STRUCTURED,
        {}
    )

    learned = load_json(
        LEARNED,
        {
            "version": 3,
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
                    '--learn "SUBJECT" "CLAIM" [TYPE]'
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