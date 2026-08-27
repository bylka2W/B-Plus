import json
import pathlib
import hashlib
from datetime import datetime, timezone

BASE = pathlib.Path(r"C:\B-Plus\agent")
MEMORY = BASE / "memory"
LEARNED = MEMORY / "learned_knowledge.json"


def now():
    return datetime.now(timezone.utc).isoformat()


def load_json(path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path, data):
    tmp = path.with_suffix(".tmp")

    with tmp.open("w", encoding="utf-8") as f:
        json.dump(
            data,
            f,
            ensure_ascii=False,
            indent=2
        )

    tmp.replace(path)


def make_id(text):
    digest = hashlib.sha256(
        text.encode("utf-8")
    ).hexdigest()[:16]

    return "RS-" + digest


def ensure_schema(data):
    data.setdefault("version", 2)
    data.setdefault("candidates", {})
    data.setdefault("verified", {})
    data.setdefault("rejected", {})
    data.setdefault("needs_review", {})
    data.setdefault("concepts", {})
    data.setdefault("relations", {})
    data.setdefault("research_sessions", {})

    return data


def create_session(data, subject):
    session_id = make_id(
        subject + "\n" + now()
    )

    session = {
        "id": session_id,
        "subject": subject,
        "status": "ACTIVE",
        "started_at": now(),
        "completed_at": None,

        "candidates": [],
        "verified_facts": [],
        "rejected_facts": [],
        "needs_review": [],

        "evidence_used": [],
        "contradictions": [],

        "concepts_created": [],
        "relations_created": [],

        "decisions": []
    }

    data["research_sessions"][session_id] = session

    return session_id


def attach_verified_facts(data, session_id):
    session = data["research_sessions"][session_id]

    subject = session["subject"]

    for fact_id, fact in data["verified"].items():

        if fact.get("subject", "").lower() != subject.lower():
            continue

        if fact_id not in session["verified_facts"]:
            session["verified_facts"].append(fact_id)

        for evidence in fact.get(
            "supporting_evidence",
            []
        ):

            evidence_id = evidence.get(
                "evidence_id"
            )

            if evidence_id and evidence_id not in session[
                "evidence_used"
            ]:
                session["evidence_used"].append(
                    evidence_id
                )

        session["decisions"].append({
            "fact_id": fact_id,
            "decision": "VERIFIED",
            "confidence": fact.get(
                "confidence",
                0.0
            ),
            "method": fact.get(
                "verification_method"
            )
        })


def attach_review_facts(data, session_id):
    session = data["research_sessions"][session_id]

    subject = session["subject"]

    for fact_id, fact in data["needs_review"].items():

        if fact.get("subject", "").lower() != subject.lower():
            continue

        if fact_id not in session["needs_review"]:
            session["needs_review"].append(
                fact_id
            )

        session["decisions"].append({
            "fact_id": fact_id,
            "decision": "NEEDS_REVIEW",
            "confidence": fact.get(
                "confidence",
                0.0
            )
        })


def attach_concepts(data, session_id):
    session = data["research_sessions"][session_id]

    subject = session["subject"]

    for concept_id, concept in data["concepts"].items():

        if concept.get(
            "subject",
            ""
        ).lower() == subject.lower():

            if concept_id not in session[
                "concepts_created"
            ]:
                session["concepts_created"].append(
                    concept_id
                )


def attach_relations(data, session_id):
    session = data["research_sessions"][session_id]

    subject = session["subject"]

    for relation_id, relation in data[
        "relations"
    ].items():

        text = json.dumps(
            relation,
            ensure_ascii=False
        ).lower()

        if subject.lower() in text:

            if relation_id not in session[
                "relations_created"
            ]:
                session["relations_created"].append(
                    relation_id
                )


def finish_session(data, session_id):
    session = data["research_sessions"][session_id]

    session["status"] = "COMPLETED"
    session["completed_at"] = now()


def print_session(data, session_id):
    session = data[
        "research_sessions"
    ][session_id]

    print("=" * 70)
    print("RESEARCH SESSION")
    print("=" * 70)

    print("ID:", session["id"])
    print("SUBJECT:", session["subject"])
    print("STATUS:", session["status"])

    print()
    print("VERIFIED:", len(
        session["verified_facts"]
    ))

    print("NEEDS REVIEW:", len(
        session["needs_review"]
    ))

    print("EVIDENCE:", len(
        session["evidence_used"]
    ))

    print("CONCEPTS:", len(
        session["concepts_created"]
    ))

    print("RELATIONS:", len(
        session["relations_created"]
    ))

    print("DECISIONS:", len(
        session["decisions"]
    ))


def main():

    data = ensure_schema(
        load_json(LEARNED)
    )

    if len(__import__("sys").argv) < 2:

        print(
            "Usage:"
        )

        print(
            "  --start \"SUBJECT\""
        )

        print(
            "  --info"
        )

        return

    command = __import__(
        "sys"
    ).argv[1]

    if command == "--start":

        if len(__import__("sys").argv) < 3:
            print(
                'Usage: --start "SUBJECT"'
            )
            return

        subject = __import__(
            "sys"
        ).argv[2]

        session_id = create_session(
            data,
            subject
        )

        attach_verified_facts(
            data,
            session_id
        )

        attach_review_facts(
            data,
            session_id
        )

        attach_concepts(
            data,
            session_id
        )

        attach_relations(
            data,
            session_id
        )

        finish_session(
            data,
            session_id
        )

        save_json(
            LEARNED,
            data
        )

        print_session(
            data,
            session_id
        )

        return

    if command == "--info":

        print(
            "RESEARCH SESSIONS:",
            len(data["research_sessions"])
        )

        for session_id in data[
            "research_sessions"
        ]:

            print(
                "-",
                session_id,
                data["research_sessions"][
                    session_id
                ]["subject"]
            )

        return


if __name__ == "__main__":
    main()