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

    learned.setdefault(
        "version",
        3
    )

    learned.setdefault(
        "candidates",
        {}
    )

    learned.setdefault(
        "verified",
        {}
    )

    learned.setdefault(
        "rejected",
        {}
    )

    learned.setdefault(
        "needs_review",
        {}
    )

    learned.setdefault(
        "concepts",
        {}
    )

    learned.setdefault(
        "relations",
        {}
    )

    learned.setdefault(
        "research_sessions",
        {}
    )

    return learned


# ============================================================
# SUBJECT MATCHING
# ============================================================

def subject_matches(item, subject):

    return (
        str(
            item.get(
                "subject",
                ""
            )
        ).strip().lower()
        ==
        str(subject).strip().lower()
    )


# ============================================================
# EVIDENCE COLLECTION
# ============================================================

def collect_evidence_from_fact(
    fact,
    evidence_ids
):

    for evidence in fact.get(
        "supporting_evidence",
        []
    ):

        evidence_id = evidence.get(
            "evidence_id"
        )

        if evidence_id:

            if evidence_id not in evidence_ids:

                evidence_ids.append(
                    evidence_id
                )

    for evidence in fact.get(
        "weak_evidence",
        []
    ):

        evidence_id = evidence.get(
            "evidence_id"
        )

        if evidence_id:

            if evidence_id not in evidence_ids:

                evidence_ids.append(
                    evidence_id
                )

    for evidence in fact.get(
        "contradicting_evidence",
        []
    ):

        if isinstance(evidence, dict):

            evidence_id = evidence.get(
                "evidence_id"
            )

            if evidence_id:

                if evidence_id not in evidence_ids:

                    evidence_ids.append(
                        evidence_id
                    )


# ============================================================
# FIND CONCEPTS CREATED BY FACT
# ============================================================

def find_concepts_for_facts(
    learned,
    fact_ids
):

    concepts_created = []

    fact_ids = set(
        fact_ids
    )

    for concept_id, concept in learned.get(
        "concepts",
        {}
    ).items():

        source_facts = set(
            concept.get(
                "source_facts",
                []
            )
        )

        if source_facts.intersection(
            fact_ids
        ):

            if concept_id not in concepts_created:

                concepts_created.append(
                    concept_id
                )

    return concepts_created


# ============================================================
# FIND RELATIONS CREATED BY FACT
# ============================================================

def find_relations_for_facts(
    learned,
    fact_ids
):

    relations_created = []

    fact_ids = set(
        fact_ids
    )

    for relation_id, relation in learned.get(
        "relations",
        {}
    ).items():

        source_facts = set(
            relation.get(
                "source_facts",
                []
            )
        )

        if source_facts.intersection(
            fact_ids
        ):

            if relation_id not in relations_created:

                relations_created.append(
                    relation_id
                )

    return relations_created


# ============================================================
# COLLECT VERIFIED
# ============================================================

def collect_verified(
    learned,
    subject
):

    verified_facts = []

    evidence_ids = []

    for fact_id, fact in learned.get(
        "verified",
        {}
    ).items():

        if not subject_matches(
            fact,
            subject
        ):
            continue

        verified_facts.append(
            fact_id
        )

        collect_evidence_from_fact(
            fact,
            evidence_ids
        )

    return (
        verified_facts,
        evidence_ids
    )


# ============================================================
# COLLECT REJECTED
# ============================================================

def collect_rejected(
    learned,
    subject
):

    rejected_facts = []

    evidence_ids = []

    for fact_id, fact in learned.get(
        "rejected",
        {}
    ).items():

        if not subject_matches(
            fact,
            subject
        ):
            continue

        rejected_facts.append(
            fact_id
        )

        collect_evidence_from_fact(
            fact,
            evidence_ids
        )

    return (
        rejected_facts,
        evidence_ids
    )


# ============================================================
# COLLECT NEEDS REVIEW
# ============================================================

def collect_needs_review(
    learned,
    subject
):

    needs_review = []

    evidence_ids = []

    for fact_id, fact in learned.get(
        "needs_review",
        {}
    ).items():

        if not subject_matches(
            fact,
            subject
        ):
            continue

        needs_review.append(
            fact_id
        )

        collect_evidence_from_fact(
            fact,
            evidence_ids
        )

    return (
        needs_review,
        evidence_ids
    )


# ============================================================
# BUILD DECISION
# ============================================================

def verified_decision(
    fact_id,
    fact
):

    return {
        "fact_id": fact_id,
        "decision": "VERIFIED",
        "confidence": fact.get(
            "confidence",
            0.0
        ),
        "method": fact.get(
            "verification_method",
            "UNKNOWN"
        )
    }


def rejected_decision(
    fact_id,
    fact
):

    contradiction_ids = []

    for contradiction in fact.get(
        "contradicting_evidence",
        []
    ):

        if not isinstance(
            contradiction,
            dict
        ):
            continue

        contradiction_id = contradiction.get(
            "fact_id"
        )

        if contradiction_id:

            contradiction_ids.append(
                contradiction_id
            )

    return {
        "fact_id": fact_id,
        "decision": "REJECTED",
        "confidence": fact.get(
            "confidence",
            0.0
        ),
        "method": fact.get(
            "reason",
            "UNKNOWN"
        ),
        "contradicting_facts":
            contradiction_ids
    }


def review_decision(
    fact_id,
    fact
):

    return {
        "fact_id": fact_id,
        "decision": "NEEDS_REVIEW",
        "confidence": fact.get(
            "confidence",
            0.0
        )
    }


# ============================================================
# BUILD RESEARCH SESSION
# ============================================================

def create_research_session(
    learned,
    subject
):

    started_at = now()

    # --------------------------------------------------------
    # VERIFIED
    # --------------------------------------------------------

    (
        verified_facts,
        verified_evidence
    ) = collect_verified(
        learned,
        subject
    )

    # --------------------------------------------------------
    # REJECTED
    # --------------------------------------------------------

    (
        rejected_facts,
        rejected_evidence
    ) = collect_rejected(
        learned,
        subject
    )

    # --------------------------------------------------------
    # NEEDS REVIEW
    # --------------------------------------------------------

    (
        needs_review,
        review_evidence
    ) = collect_needs_review(
        learned,
        subject
    )

    # --------------------------------------------------------
    # Evidence
    # --------------------------------------------------------

    evidence_used = []

    for evidence_id in (
        verified_evidence
        + rejected_evidence
        + review_evidence
    ):

        if evidence_id not in evidence_used:

            evidence_used.append(
                evidence_id
            )

    # --------------------------------------------------------
    # All facts participating in graph extraction
    #
    # Only VERIFIED facts can create concepts/relations.
    # --------------------------------------------------------

    graph_fact_ids = list(
        verified_facts
    )

    # --------------------------------------------------------
    # Concepts
    # --------------------------------------------------------

    concepts_created = find_concepts_for_facts(
        learned,
        graph_fact_ids
    )

    # --------------------------------------------------------
    # Relations
    # --------------------------------------------------------

    relations_created = find_relations_for_facts(
        learned,
        graph_fact_ids
    )

    # --------------------------------------------------------
    # Decisions
    # --------------------------------------------------------

    decisions = []

    for fact_id in verified_facts:

        fact = learned[
            "verified"
        ].get(
            fact_id
        )

        if fact:

            decisions.append(
                verified_decision(
                    fact_id,
                    fact
                )
            )

    for fact_id in rejected_facts:

        fact = learned[
            "rejected"
        ].get(
            fact_id
        )

        if fact:

            decisions.append(
                rejected_decision(
                    fact_id,
                    fact
                )
            )

    for fact_id in needs_review:

        fact = learned[
            "needs_review"
        ].get(
            fact_id
        )

        if fact:

            decisions.append(
                review_decision(
                    fact_id,
                    fact
                )
            )

    # --------------------------------------------------------
    # Contradictions
    #
    # Collect rejected facts that explicitly reference
    # verified facts.
    # --------------------------------------------------------

    contradictions = []

    verified_set = set(
        verified_facts
    )

    for fact_id in rejected_facts:

        fact = learned[
            "rejected"
        ].get(
            fact_id
        )

        if not fact:
            continue

        for contradiction in fact.get(
            "contradicting_evidence",
            []
        ):

            if not isinstance(
                contradiction,
                dict
            ):
                continue

            other_fact_id = contradiction.get(
                "fact_id"
            )

            if (
                other_fact_id
                and other_fact_id in verified_set
            ):

                contradictions.append({
                    "rejected_fact":
                        fact_id,

                    "verified_fact":
                        other_fact_id
                })

    # --------------------------------------------------------
    # Session ID
    # --------------------------------------------------------

    session_seed = (
        subject
        + "\n"
        + started_at
    )

    session_id = make_id(
        "RS",
        session_seed
    )

    # --------------------------------------------------------
    # Session object
    # --------------------------------------------------------

    session = {
        "id": session_id,
        "subject": subject,
        "status": "COMPLETED",

        "started_at":
            started_at,

        "completed_at":
            now(),

        "candidates": [],

        "verified_facts":
            verified_facts,

        "rejected_facts":
            rejected_facts,

        "needs_review":
            needs_review,

        "evidence_used":
            evidence_used,

        "contradictions":
            contradictions,

        "concepts_created":
            concepts_created,

        "relations_created":
            relations_created,

        "decisions":
            decisions
    }

    learned[
        "research_sessions"
    ][session_id] = session

    return session


# ============================================================
# PRINT SESSION
# ============================================================

def print_session(
    session
):

    print("=" * 70)
    print("RESEARCH SESSION")
    print("=" * 70)

    print(
        "ID:",
        session["id"]
    )

    print(
        "SUBJECT:",
        session["subject"]
    )

    print(
        "STATUS:",
        session["status"]
    )

    print()

    print(
        "VERIFIED:",
        len(
            session[
                "verified_facts"
            ]
        )
    )

    print(
        "REJECTED:",
        len(
            session[
                "rejected_facts"
            ]
        )
    )

    print(
        "NEEDS REVIEW:",
        len(
            session[
                "needs_review"
            ]
        )
    )

    print(
        "EVIDENCE:",
        len(
            session[
                "evidence_used"
            ]
        )
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
        len(
            session[
                "decisions"
            ]
        )
    )


# ============================================================
# INFO
# ============================================================

def print_info(
    learned
):

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


# ============================================================
# START
# ============================================================

def start_session(
    learned,
    subject
):

    session = create_research_session(
        learned,
        subject
    )

    save_json(
        LEARNED,
        learned
    )

    print_session(
        session
    )

    return session


# ============================================================
# MAIN
# ============================================================

def main():

    learned = load_json(
        LEARNED,
        {}
    )

    learned = ensure_schema(
        learned
    )

    if len(sys.argv) >= 2:

        command = sys.argv[1]

        # ----------------------------------------------------
        # --start
        # ----------------------------------------------------

        if command == "--start":

            if len(sys.argv) < 3:

                print(
                    'Usage: py research_session.py '
                    '--start "SUBJECT"'
                )

                sys.exit(1)

            subject = sys.argv[2]

            start_session(
                learned,
                subject
            )

            return

        # ----------------------------------------------------
        # --info
        # ----------------------------------------------------

        if command == "--info":

            print_info(
                learned
            )

            return

    print_info(
        learned
    )


# ============================================================
# ENTRY POINT
# ============================================================

if __name__ == "__main__":
    main()