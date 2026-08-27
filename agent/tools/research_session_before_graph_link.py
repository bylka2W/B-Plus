import json
import pathlib
import hashlib
import sys
from datetime import datetime, timezone


BASE = pathlib.Path(r"C:\B-Plus\agent")
MEMORY = BASE / "memory"

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
# FIND FACTS FOR SUBJECT
# ============================================================

def facts_for_subject(learned, subject):

    subject_lower = str(subject).lower()

    verified = []
    rejected = []
    needs_review = []

    for fact_id, fact in learned.get(
        "verified",
        {}
    ).items():

        if str(
            fact.get("subject", "")
        ).lower() == subject_lower:

            verified.append(fact)

    for fact_id, fact in learned.get(
        "rejected",
        {}
    ).items():

        if str(
            fact.get("subject", "")
        ).lower() == subject_lower:

            rejected.append(fact)

    for fact_id, fact in learned.get(
        "needs_review",
        {}
    ).items():

        if str(
            fact.get("subject", "")
        ).lower() == subject_lower:

            needs_review.append(fact)

    return (
        verified,
        rejected,
        needs_review
    )


# ============================================================
# EVIDENCE
# ============================================================

def collect_evidence_ids(
    verified,
    rejected,
    needs_review
):

    evidence_ids = []

    for fact in verified:

        for evidence in fact.get(
            "supporting_evidence",
            []
        ):

            evidence_id = evidence.get(
                "evidence_id"
            )

            if evidence_id:
                evidence_ids.append(
                    evidence_id
                )

    for fact in rejected:

        for evidence in fact.get(
            "weak_evidence",
            []
        ):

            evidence_id = evidence.get(
                "evidence_id"
            )

            if evidence_id:
                evidence_ids.append(
                    evidence_id
                )

    for fact in needs_review:

        for evidence in fact.get(
            "weak_evidence",
            []
        ):

            evidence_id = evidence.get(
                "evidence_id"
            )

            if evidence_id:
                evidence_ids.append(
                    evidence_id
                )

    return sorted(
        set(evidence_ids)
    )


# ============================================================
# DECISIONS
# ============================================================

def build_decisions(
    verified,
    rejected,
    needs_review
):

    decisions = []

    for fact in verified:

        decisions.append({
            "fact_id": fact["id"],
            "decision": "VERIFIED",
            "confidence": fact.get(
                "confidence",
                0.0
            ),
            "method": fact.get(
                "verification_method",
                "UNKNOWN"
            )
        })

    for fact in rejected:

        decisions.append({
            "fact_id": fact["id"],
            "decision": "REJECTED",
            "confidence": fact.get(
                "confidence",
                0.0
            ),
            "method": fact.get(
                "reason",
                "UNKNOWN"
            ),
            "contradicting_facts": [
                item.get("fact_id")
                for item in fact.get(
                    "contradicting_evidence",
                    []
                )
                if item.get("fact_id")
            ]
        })

    for fact in needs_review:

        decisions.append({
            "fact_id": fact["id"],
            "decision": "NEEDS_REVIEW",
            "confidence": fact.get(
                "confidence",
                0.0
            )
        })

    return decisions


# ============================================================
# CREATE SESSION
# ============================================================

def start_session(
    learned,
    subject
):

    verified, rejected, needs_review = (
        facts_for_subject(
            learned,
            subject
        )
    )

    evidence_ids = collect_evidence_ids(
        verified,
        rejected,
        needs_review
    )

    decisions = build_decisions(
        verified,
        rejected,
        needs_review
    )

    session_id = make_id(
        "RS",
        subject + "\n" + now()
    )

    session = {

        "id": session_id,

        "subject": subject,

        "status": "COMPLETED",

        "started_at": now(),

        "completed_at": now(),

        "candidates": [],

        "verified_facts": [
            fact["id"]
            for fact in verified
        ],

        "rejected_facts": [
            fact["id"]
            for fact in rejected
        ],

        "needs_review": [
            fact["id"]
            for fact in needs_review
        ],

        "evidence_used":
            evidence_ids,

        "contradictions": [],

        "concepts_created": [],

        "relations_created": [],

        "decisions":
            decisions
    }

    learned[
        "research_sessions"
    ][session_id] = session

    print("=" * 70)
    print("RESEARCH SESSION")
    print("=" * 70)

    print(
        "ID:",
        session_id
    )

    print(
        "SUBJECT:",
        subject
    )

    print(
        "STATUS:",
        session["status"]
    )

    print()

    print(
        "VERIFIED:",
        len(verified)
    )

    print(
        "REJECTED:",
        len(rejected)
    )

    print(
        "NEEDS REVIEW:",
        len(needs_review)
    )

    print(
        "EVIDENCE:",
        len(evidence_ids)
    )

    print(
        "CONCEPTS:",
        len(
            session[
                "concepts_created"
            ]
        )
    )

    print(
        "RELATIONS:",
        len(
            session[
                "relations_created"
            ]
        )
    )

    print(
        "DECISIONS:",
        len(decisions)
    )

    return session


# ============================================================
# INFO
# ============================================================

def print_info(learned):

    sessions = learned.get(
        "research_sessions",
        {}
    )

    print(
        "RESEARCH SESSIONS:",
        len(sessions)
    )

    for session_id, session in sessions.items():

        print(
            "-",
            session_id,
            session.get(
                "subject",
                ""
            )
        )

        print(
            "  VERIFIED:",
            len(
                session.get(
                    "verified_facts",
                    []
                )
            )
        )

        print(
            "  REJECTED:",
            len(
                session.get(
                    "rejected_facts",
                    []
                )
            )
        )

        print(
            "  NEEDS_REVIEW:",
            len(
                session.get(
                    "needs_review",
                    []
                )
            )
        )

        print(
            "  DECISIONS:",
            len(
                session.get(
                    "decisions",
                    []
                )
            )
        )


# ============================================================
# MAIN
# ============================================================

def main():

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

        if command == "--start":

            if len(sys.argv) < 3:

                print(
                    'Usage: py research_session.py --start "SUBJECT"'
                )

                sys.exit(1)

            subject = sys.argv[2]

            start_session(
                learned,
                subject
            )

            save_json(
                LEARNED,
                learned
            )

            return

        if command == "--info":

            print_info(
                learned
            )

            return

    print_info(
        learned
    )


if __name__ == "__main__":
    main()