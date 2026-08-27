import json
import pathlib
import random
import sys


BASE = pathlib.Path(r"C:\B-Plus\agent")
MEMORY = BASE / "memory"

LEARNED = MEMORY / "learned_knowledge.json"
DATASET = MEMORY / "training_dataset.jsonl"


def load_json(path, default):
    if not path.exists():
        return default

    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def normalize_fact(fact):
    subject = str(
        fact.get("subject", "")
    ).strip()

    claim = str(
        fact.get("claim", "")
    ).strip()

    return subject, claim


def make_verified_examples(learned):

    examples = []

    for fact_id, fact in learned.get(
        "verified",
        {}
    ).items():

        subject, claim = normalize_fact(fact)

        if not subject or not claim:
            continue

        examples.append({
            "messages": [
                {
                    "role": "user",
                    "content": (
                        "What is known about "
                        + subject
                        + "?"
                    )
                },
                {
                    "role": "assistant",
                    "content": claim
                }
            ],
            "metadata": {
                "fact_id": fact_id,
                "status": "VERIFIED",
                "confidence": fact.get(
                    "confidence",
                    0.0
                )
            }
        })

    return examples


def make_rejection_examples(learned):

    examples = []

    for fact_id, fact in learned.get(
        "rejected",
        {}
    ).items():

        subject, claim = normalize_fact(fact)

        if not subject or not claim:
            continue

        reason = str(
            fact.get(
                "reason",
                "REJECTED"
            )
        )

        examples.append({
            "messages": [
                {
                    "role": "user",
                    "content": (
                        "Evaluate this claim about "
                        + subject
                        + ": "
                        + claim
                    )
                },
                {
                    "role": "assistant",
                    "content": (
                        "REJECTED: "
                        + reason
                    )
                }
            ],
            "metadata": {
                "fact_id": fact_id,
                "status": "REJECTED"
            }
        })

    return examples


def make_review_examples(learned):

    examples = []

    for fact_id, fact in learned.get(
        "needs_review",
        {}
    ).items():

        subject, claim = normalize_fact(fact)

        if not subject or not claim:
            continue

        examples.append({
            "messages": [
                {
                    "role": "user",
                    "content": (
                        "Evaluate this claim about "
                        + subject
                        + ": "
                        + claim
                    )
                },
                {
                    "role": "assistant",
                    "content": (
                        "NEEDS_REVIEW: "
                        "available evidence is insufficient."
                    )
                }
            ],
            "metadata": {
                "fact_id": fact_id,
                "status": "NEEDS_REVIEW"
            }
        })

    return examples


def save_jsonl(path, examples):

    with path.open(
        "w",
        encoding="utf-8"
    ) as f:

        for example in examples:

            f.write(
                json.dumps(
                    example,
                    ensure_ascii=False
                )
                + "\n"
            )


def main():

    learned = load_json(
        LEARNED,
        {}
    )

    verified = make_verified_examples(
        learned
    )

    rejected = make_rejection_examples(
        learned
    )

    review = make_review_examples(
        learned
    )

    examples = (
        verified
        + rejected
        + review
    )

    random.shuffle(examples)

    save_jsonl(
        DATASET,
        examples
    )

    print("=" * 70)
    print("B+ DATASET BUILDER")
    print("=" * 70)

    print()
    print("VERIFIED:", len(verified))
    print("REJECTED:", len(rejected))
    print("NEEDS REVIEW:", len(review))
    print("TOTAL:", len(examples))

    print()
    print("OUTPUT:")
    print(DATASET)

    print()
    print("STATUS: READY")


if __name__ == "__main__":
    main()