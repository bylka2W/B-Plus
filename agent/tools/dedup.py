import json
import pathlib
import shutil
from datetime import datetime, timezone


BASE = pathlib.Path(r"C:\B-Plus\agent")
MEMORY = BASE / "memory"

LEARNED = MEMORY / "learned_knowledge.json"


def now():
    return datetime.now(timezone.utc).isoformat()


def normalize_claim(claim):
    if not claim:
        return ""

    return " ".join(
        str(claim)
        .strip()
        .lower()
        .split()
    )


def load():
    with LEARNED.open(
        "r",
        encoding="utf-8"
    ) as f:
        return json.load(f)


def save(data):
    tmp = LEARNED.with_suffix(
        ".json.tmp"
    )

    with tmp.open(
        "w",
        encoding="utf-8"
    ) as f:
        json.dump(
            data,
            f,
            ensure_ascii=False,
            indent=2
        )

    tmp.replace(LEARNED)


def choose_keeper(items):
    """
    Choose the best VERIFIED fact.

    Priority:
    1. Higher confidence
    2. DIRECT_PROJECT_EVIDENCE
    3. Older fact
    """

    def score(item):
        fact_id, fact = item

        confidence = float(
            fact.get(
                "confidence",
                0.0
            )
        )

        method = str(
            fact.get(
                "verification_method",
                ""
            )
        ).upper()

        direct = (
            1
            if method == "DIRECT_PROJECT_EVIDENCE"
            else 0
        )

        created = str(
            fact.get(
                "created_at",
                ""
            )
        )

        return (
            confidence,
            direct,
            created
        )

    return max(
        items,
        key=score
    )


def main():

    if not LEARNED.exists():

        print(
            "ERROR: memory file not found:"
        )

        print(
            LEARNED
        )

        return 1

    # --------------------------------------------------------
    # BACKUP
    # --------------------------------------------------------

    timestamp = datetime.now().strftime(
        "%Y%m%d_%H%M%S"
    )

    backup = MEMORY / (
        "learned_knowledge_before_dedup_"
        + timestamp
        + ".json"
    )

    shutil.copy2(
        LEARNED,
        backup
    )

    print("=" * 70)
    print("B+ KNOWLEDGE DEDUP")
    print("=" * 70)
    print()

    print(
        "BACKUP:",
        backup
    )

    print()

    data = load()

    verified = data.setdefault(
        "verified",
        {}
    )

    duplicates = data.setdefault(
        "duplicates",
        {}
    )

    # --------------------------------------------------------
    # GROUP VERIFIED FACTS BY NORMALIZED CLAIM
    # --------------------------------------------------------

    groups = {}

    for fact_id, fact in verified.items():

        claim = normalize_claim(
            fact.get(
                "claim",
                ""
            )
        )

        if not claim:
            continue

        groups.setdefault(
            claim,
            []
        ).append(
            (
                fact_id,
                fact
            )
        )

    # --------------------------------------------------------
    # FIND DUPLICATES
    # --------------------------------------------------------

    removed = []

    for claim, items in groups.items():

        if len(items) <= 1:
            continue

        keeper_id, keeper = choose_keeper(
            items
        )

        print(
            "DUPLICATE GROUP:"
        )

        print(
            "KEEP:",
            keeper_id
        )

        print(
            "CLAIM:",
            keeper.get(
                "claim",
                ""
            )
        )

        print()

        keeper_evidence = keeper.setdefault(
            "supporting_evidence",
            []
        )

        keeper_evidence_ids = set()

        for evidence in keeper_evidence:

            if isinstance(
                evidence,
                dict
            ):

                evidence_id = evidence.get(
                    "evidence_id"
                )

                if evidence_id:
                    keeper_evidence_ids.add(
                        evidence_id
                    )

        for fact_id, fact in items:

            if fact_id == keeper_id:
                continue

            print(
                "REMOVE:",
                fact_id
            )

            # ------------------------------------------------
            # MERGE SUPPORTING EVIDENCE
            # ------------------------------------------------

            for evidence in fact.get(
                "supporting_evidence",
                []
            ):

                if not isinstance(
                    evidence,
                    dict
                ):
                    continue

                evidence_id = evidence.get(
                    "evidence_id"
                )

                if (
                    evidence_id
                    and evidence_id
                    not in keeper_evidence_ids
                ):

                    keeper_evidence.append(
                        evidence
                    )

                    keeper_evidence_ids.add(
                        evidence_id
                    )

            # ------------------------------------------------
            # SAVE DUPLICATE RECORD
            # ------------------------------------------------

            duplicate_record = dict(
                fact
            )

            duplicate_record[
                "status"
            ] = "DUPLICATE"

            duplicate_record[
                "duplicate_of"
            ] = keeper_id

            duplicate_record[
                "deduplicated_at"
            ] = now()

            duplicates[
                fact_id
            ] = duplicate_record

            removed.append(
                (
                    fact_id,
                    keeper_id
                )
            )

    # --------------------------------------------------------
    # REMOVE DUPLICATES FROM VERIFIED
    # --------------------------------------------------------

    for duplicate_id, keeper_id in removed:

        verified.pop(
            duplicate_id,
            None
        )

    # --------------------------------------------------------
    # UPDATE GRAPH REFERENCES
    # --------------------------------------------------------

    for concept_id, concept in data.get(
        "concepts",
        {}
    ).items():

        source_facts = concept.get(
            "source_facts",
            []
        )

        changed = False

        new_source_facts = []

        for fact_id in source_facts:

            replacement = fact_id

            for duplicate_id, keeper_id in removed:

                if fact_id == duplicate_id:

                    replacement = keeper_id
                    changed = True

            if replacement not in new_source_facts:

                new_source_facts.append(
                    replacement
                )

        if changed:

            concept[
                "source_facts"
            ] = new_source_facts

            concept[
                "updated_at"
            ] = now()

    # --------------------------------------------------------
    # UPDATE RELATION REFERENCES
    # --------------------------------------------------------

    for relation_id, relation in data.get(
        "relations",
        {}
    ).items():

        source_facts = relation.get(
            "source_facts",
            []
        )

        changed = False

        new_source_facts = []

        for fact_id in source_facts:

            replacement = fact_id

            for duplicate_id, keeper_id in removed:

                if fact_id == duplicate_id:

                    replacement = keeper_id
                    changed = True

            if replacement not in new_source_facts:

                new_source_facts.append(
                    replacement
                )

        if changed:

            relation[
                "source_facts"
            ] = new_source_facts

    # --------------------------------------------------------
    # UPDATE RESEARCH SESSIONS
    # --------------------------------------------------------

    for session_id, session in data.get(
        "research_sessions",
        {}
    ).items():

        verified_ids = session.get(
            "verified_facts",
            []
        )

        changed = False

        new_verified_ids = []

        for fact_id in verified_ids:

            replacement = fact_id

            for duplicate_id, keeper_id in removed:

                if fact_id == duplicate_id:

                    replacement = keeper_id
                    changed = True

            if replacement not in new_verified_ids:

                new_verified_ids.append(
                    replacement
                )

        if changed:

            session[
                "verified_facts"
            ] = new_verified_ids

    # --------------------------------------------------------
    # SAVE
    # --------------------------------------------------------

    save(data)

    print()
    print("=" * 70)
    print("RESULT")
    print("=" * 70)

    print(
        "VERIFIED:",
        len(data.get("verified", {}))
    )

    print(
        "DUPLICATES REMOVED:",
        len(removed)
    )

    print(
        "DUPLICATES ARCHIVED:",
        len(data.get("duplicates", {}))
    )

    print(
        "CONCEPTS:",
        len(data.get("concepts", {}))
    )

    print(
        "RELATIONS:",
        len(data.get("relations", {}))
    )

    print()
    print(
        "MEMORY:",
        LEARNED
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )