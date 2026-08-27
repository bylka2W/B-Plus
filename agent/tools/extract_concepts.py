import json
import pathlib
import hashlib
import re
import sys
from datetime import datetime, timezone


BASE = pathlib.Path(r"C:\B-Plus\agent")
MEMORY = BASE / "memory"

LEARNED = MEMORY / "learned_knowledge.json"


def now():
    return datetime.now(timezone.utc).isoformat()


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


def make_id(prefix, text):
    digest = hashlib.sha256(
        text.encode("utf-8")
    ).hexdigest()[:16]

    return f"{prefix}-{digest}"


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


def extract_pipeline_concepts(text):
    """
    Extract concepts only from explicit pipeline notation.

    Example:

        B+ source → BIR → MIR → x64 COFF object

    becomes:

        B+
        BIR
        MIR
        x64 COFF

    No external knowledge is introduced.
    """

    if not text:
        return []

    parts = re.split(
        r"\s*[→➜⟶]\s*",
        text
    )

    if len(parts) < 2:
        return []

    concepts = []

    for part in parts:

        value = part.strip()

        if not value:
            continue

        # Normalize the source description.
        if re.fullmatch(
            r"B\+\s+source",
            value,
            flags=re.IGNORECASE
        ):
            value = "B+"

        # Normalize final object description.
        value = re.sub(
            r"\s+object$",
            "",
            value,
            flags=re.IGNORECASE
        )

        value = value.strip(
            " .,:;()[]{}\"'"
        )

        if value and value not in concepts:
            concepts.append(value)

    return concepts


def add_concept(
    learned,
    name,
    source_fact_id,
    evidence_ids
):
    concept_id = make_id(
        "CON",
        name.lower()
    )

    existing = learned["concepts"].get(
        concept_id
    )

    if existing:

        existing.setdefault(
            "source_facts",
            []
        )

        if source_fact_id not in existing[
            "source_facts"
        ]:
            existing["source_facts"].append(
                source_fact_id
            )

        existing.setdefault(
            "supporting_evidence",
            []
        )

        for evidence_id in evidence_ids:

            if evidence_id not in existing[
                "supporting_evidence"
            ]:
                existing[
                    "supporting_evidence"
                ].append(
                    evidence_id
                )

        existing["updated_at"] = now()

        return concept_id

    learned["concepts"][concept_id] = {
        "id": concept_id,
        "name": name,
        "status": "DERIVED",
        "source_facts": [
            source_fact_id
        ],
        "supporting_evidence": evidence_ids,
        "created_at": now(),
        "updated_at": now()
    }

    return concept_id


def add_relation(
    learned,
    source_concept_id,
    relation_type,
    target_concept_id,
    source_fact_id,
    evidence_ids
):
    relation_key = (
        source_concept_id
        + "\n"
        + relation_type
        + "\n"
        + target_concept_id
    )

    relation_id = make_id(
        "REL",
        relation_key
    )

    existing = learned["relations"].get(
        relation_id
    )

    if existing:

        existing.setdefault(
            "source_facts",
            []
        )

        if source_fact_id not in existing[
            "source_facts"
        ]:
            existing[
                "source_facts"
            ].append(
                source_fact_id
            )

        existing.setdefault(
            "supporting_evidence",
            []
        )

        for evidence_id in evidence_ids:

            if evidence_id not in existing[
                "supporting_evidence"
            ]:
                existing[
                    "supporting_evidence"
                ].append(
                    evidence_id
                )

        return relation_id

    learned["relations"][relation_id] = {
        "id": relation_id,
        "source": source_concept_id,
        "relation": relation_type,
        "target": target_concept_id,
        "status": "DERIVED",
        "source_facts": [
            source_fact_id
        ],
        "supporting_evidence": evidence_ids,
        "created_at": now()
    }

    return relation_id


def extract_from_verified_fact(
    learned,
    fact_id,
    fact
):
    """
    Extract concepts from VERIFIED evidence.

    The claim describes the fact.

    The supporting evidence is authoritative
    for structural extraction.

    We do not invent concepts from the claim
    when the evidence does not explicitly contain
    the required structure.
    """

    supporting = fact.get(
        "supporting_evidence",
        []
    )

    evidence_ids = [
        e.get("evidence_id")
        for e in supporting
        if e.get("evidence_id")
    ]

    evidence_texts = [
        e.get("text", "")
        for e in supporting
        if e.get("text")
    ]

    all_concepts = []

    for evidence_text in evidence_texts:

        concepts = extract_pipeline_concepts(
            evidence_text
        )

        for concept in concepts:

            if concept not in all_concepts:
                all_concepts.append(
                    concept
                )

    if len(all_concepts) < 2:

        return {
            "concepts": 0,
            "relations": 0
        }

    concept_ids = []

    for name in all_concepts:

        concept_id = add_concept(
            learned,
            name,
            fact_id,
            evidence_ids
        )

        concept_ids.append(
            concept_id
        )

    relation_count = 0

    for index in range(
        len(concept_ids) - 1
    ):

        add_relation(
            learned,
            concept_ids[index],
            "PIPELINE_TO",
            concept_ids[index + 1],
            fact_id,
            evidence_ids
        )

        relation_count += 1

    return {
        "concepts": len(concept_ids),
        "relations": relation_count
    }


def extract_all_verified(learned):

    total_concepts = 0
    total_relations = 0

    for fact_id, fact in learned[
        "verified"
    ].items():

        result = extract_from_verified_fact(
            learned,
            fact_id,
            fact
        )

        total_concepts += result[
            "concepts"
        ]

        total_relations += result[
            "relations"
        ]

    return (
        total_concepts,
        total_relations
    )


def print_info(learned):

    print("=" * 70)
    print("B+ CONCEPT EXTRACTION")
    print("=" * 70)

    print()
    print("VERIFIED FACTS:")
    print(
        " ",
        len(learned["verified"])
    )

    print()
    print("CONCEPTS:")
    print(
        " ",
        len(learned["concepts"])
    )

    print()
    print("RELATIONS:")
    print(
        " ",
        len(learned["relations"])
    )

    print()
    print("STATUS: READY")


def main():

    learned = ensure_schema(
        load_json(
            LEARNED,
            {}
        )
    )

    if len(sys.argv) >= 2:

        command = sys.argv[1]

        if command == "--extract":

            concepts, relations = (
                extract_all_verified(
                    learned
                )
            )

            save_json(
                LEARNED,
                learned
            )

            print("=" * 70)
            print("CONCEPT EXTRACTION COMPLETE")
            print("=" * 70)

            print(
                "CONCEPTS EXTRACTED:",
                concepts
            )

            print(
                "RELATIONS EXTRACTED:",
                relations
            )

            print(
                "TOTAL CONCEPTS:",
                len(
                    learned["concepts"]
                )
            )

            print(
                "TOTAL RELATIONS:",
                len(
                    learned["relations"]
                )
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