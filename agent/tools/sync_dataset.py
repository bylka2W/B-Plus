import json
import pathlib
import sys


BASE = pathlib.Path(r"C:\B-Plus\agent")
MEMORY = BASE / "memory"

SOURCE = MEMORY / "learned_knowledge.json"
DATASET = MEMORY / "training_dataset.jsonl"


# ============================================================
# JSON
# ============================================================

def load_json(path, default):
    if not path.exists():
        return default

    with path.open(
        "r",
        encoding="utf-8"
    ) as f:
        return json.load(f)


# ============================================================
# LOAD VERIFIED FACTS
# ============================================================

def load_verified_facts():

    learned = load_json(
        SOURCE,
        {}
    )

    verified = learned.get(
        "verified",
        {}
    )

    facts = []

    for fact_id, fact in verified.items():

        if not isinstance(
            fact,
            dict
        ):
            continue

        claim = str(
            fact.get(
                "claim",
                ""
            )
        ).strip()

        if not claim:
            continue

        facts.append({
            "id": fact_id,
            "subject": fact.get(
                "subject",
                ""
            ),
            "claim": claim,
            "type": fact.get(
                "type",
                ""
            ),
            "status": "VERIFIED",
            "confidence": fact.get(
                "confidence",
                0.0
            ),
            "supporting_evidence":
                fact.get(
                    "supporting_evidence",
                    []
                ),
            "weak_evidence":
                fact.get(
                    "weak_evidence",
                    []
                ),
            "verification_method":
                fact.get(
                    "verification_method",
                    ""
                )
        })

    return facts


# ============================================================
# DEDUPLICATE
# ============================================================

def deduplicate_facts(facts):

    unique = []
    seen_claims = set()

    for fact in facts:

        claim_key = (
            str(
                fact.get(
                    "subject",
                    ""
                )
            ).strip().lower()
            + "\n"
            + str(
                fact.get(
                    "claim",
                    ""
                )
            ).strip().lower()
        )

        if claim_key in seen_claims:
            continue

        seen_claims.add(
            claim_key
        )

        unique.append(
            fact
        )

    return unique


# ============================================================
# BUILD DATASET RECORD
# ============================================================

def build_record(fact):

    claim = fact["claim"]

    evidence_lines = []

    for evidence in fact.get(
        "supporting_evidence",
        []
    ):

        if not isinstance(
            evidence,
            dict
        ):
            continue

        text = evidence.get(
            "text",
            ""
        )

        if text:
            evidence_lines.append(
                text
            )

    assistant_content = (
        "Verified fact about "
        + str(
            fact.get(
                "subject",
                "B+"
            )
        )
        + ": "
        + claim
    )

    if evidence_lines:

        assistant_content += (
            "\n\nProject evidence:\n"
        )

        for evidence in evidence_lines:

            assistant_content += (
                "- "
                + evidence
                + "\n"
            )

    return {
        "messages": [
            {
                "role": "user",
                "content": (
                    "What is known about "
                    + str(
                        fact.get(
                            "subject",
                            "B+"
                        )
                    )
                    + "?"
                )
            },
            {
                "role": "assistant",
                "content": assistant_content
            }
        ],
        "metadata": {
            "fact_id": fact["id"],
            "subject": fact.get(
                "subject",
                ""
            ),
            "status": "VERIFIED",
            "claim": claim,
            "confidence": fact.get(
                "confidence",
                0.0
            ),
            "type": fact.get(
                "type",
                ""
            ),
            "verification_method":
                fact.get(
                    "verification_method",
                    ""
                )
        }
    }


# ============================================================
# WRITE DATASET
# ============================================================

def write_dataset(facts):

    records = []

    for fact in facts:

        record = build_record(
            fact
        )

        records.append(
            record
        )

    with DATASET.open(
        "w",
        encoding="utf-8",
        newline="\n"
    ) as f:

        for record in records:

            f.write(
                json.dumps(
                    record,
                    ensure_ascii=False
                )
                + "\n"
            )

    return len(records)


# ============================================================
# PRINT
# ============================================================

def print_result(
    original_facts,
    unique_facts,
    record_count
):

    print("=" * 70)
    print("B+ DATASET SYNC")
    print("=" * 70)

    print()

    print(
        "SOURCE:",
        SOURCE
    )

    print(
        "DATASET:",
        DATASET
    )

    print()

    print(
        "VERIFIED FACTS:",
        len(original_facts)
    )

    print(
        "UNIQUE VERIFIED FACTS:",
        len(unique_facts)
    )

    print()

    for index, fact in enumerate(
        unique_facts,
        start=1
    ):

        print(
            f"{index}. {fact['id']}"
        )

        print(
            "    OK:",
            fact["claim"]
        )

    duplicates = (
        len(original_facts)
        - len(unique_facts)
    )

    print()

    print(
        "DUPLICATES REMOVED:",
        duplicates
    )

    print(
        "DONE"
    )

    print()

    print(
        "DATASET RECORDS:",
        record_count
    )

    print()

    print(
        "MEMORY:",
        SOURCE
    )

    print(
        "DATASET:",
        DATASET
    )


# ============================================================
# MAIN
# ============================================================

def main():

    try:

        facts = load_verified_facts()

        unique_facts = deduplicate_facts(
            facts
        )

        record_count = write_dataset(
            unique_facts
        )

        print_result(
            facts,
            unique_facts,
            record_count
        )

    except Exception as exc:

        print(
            "ERROR:",
            str(exc)
        )

        sys.exit(1)


# ============================================================
# ENTRY POINT
# ============================================================

if __name__ == "__main__":
    main()