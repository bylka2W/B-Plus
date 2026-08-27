import argparse
import json
import pathlib
import re
import sys

BASE_DIR = pathlib.Path(r"C:\B-Plus\zig")
DB_PATH = BASE_DIR.parent / "agent" / "memory" / "structured.json"


def print_json(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=2))


def normalize(text):
    return re.sub(r"\s+", " ", str(text)).strip()


def evidence_text(ev):
    return normalize(ev.get("text", ""))


def direct_evidence_supports(query, ev):
    """
    Conservative evidence check.

    A matching occurrence is NOT automatically proof.
    We only consider evidence directly relevant when the
    query appears in the actual source text and the text
    contains a meaningful statement about the queried subject.
    """
    text = evidence_text(ev).lower()
    q = query.lower().strip()

    if not q or q not in text:
        return False

    # A bare occurrence such as:
    #   <pipeline.b+>
    # is not a definition.
    definition_patterns = [
        r"\b" + re.escape(q) + r"\s+(?:is|are|means|refers to)\b",
        r"\b" + re.escape(q) + r"\s+(?:source|language|compiler|pipeline)\b",
        r"\b" + re.escape(q) + r"\s*[:=]",
        r"\b" + re.escape(q) + r".*(?:->|→)",
        r"(?:source|language|compiler|pipeline).*\b" + re.escape(q) + r"\b",
    ]

    return any(re.search(p, text, re.IGNORECASE) for p in definition_patterns)


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    parser = argparse.ArgumentParser(
        description="Query B+ Knowledge Base"
    )

    parser.add_argument(
        "--query",
        required=True,
        help="Symbol, function, file or concept to search"
    )

    args = parser.parse_args()
    query = args.query.strip()

    if not DB_PATH.exists():
        print("ERROR: Knowledge Base not found:")
        print(DB_PATH)
        sys.exit(1)

    with DB_PATH.open("r", encoding="utf-8") as f:
        data = json.load(f)

    knowledge = data.get("knowledge", {})
    relations = data.get("relations", {})
    evidence = data.get("evidence", {})

    print("=" * 70)
    print("B+ KNOWLEDGE BASE QUERY")
    print("QUERY:", query)
    print("DATABASE:", DB_PATH)
    print("=" * 70)

    # ---------------------------------------------------------
    # FACTS
    # ---------------------------------------------------------

    found_facts = []

    for fact_id, fact in knowledge.items():
        text = json.dumps(
            fact,
            ensure_ascii=False
        ).lower()

        if query.lower() in text:
            found_facts.append((fact_id, fact))

    print()
    print("FACTS:", len(found_facts))

    for fact_id, fact in found_facts[:100]:
        print()
        print("FACT", fact_id)
        print_json(fact)

    # ---------------------------------------------------------
    # RELATIONS
    # ---------------------------------------------------------

    found_relations = []

    for rel_id, rel in relations.items():
        text = json.dumps(
            rel,
            ensure_ascii=False
        ).lower()

        if query.lower() in text:
            found_relations.append((rel_id, rel))

    print()
    print("=" * 70)
    print("RELATIONS:", len(found_relations))
    print("=" * 70)

    for rel_id, rel in found_relations[:200]:
        print()
        print("RELATION", rel_id)
        print_json(rel)

    # ---------------------------------------------------------
    # EVIDENCE
    # ---------------------------------------------------------

    found_evidence = []

    for evidence_id, ev in evidence.items():
        text = evidence_text(ev).lower()

        if query.lower() in text:
            found_evidence.append((evidence_id, ev))

    print()
    print("=" * 70)
    print("EVIDENCE:", len(found_evidence))
    print("=" * 70)

    for evidence_id, ev in found_evidence[:200]:
        print()
        print("EVIDENCE", evidence_id)
        print_json(ev)

    # ---------------------------------------------------------
    # EVIDENCE CLASSIFICATION
    # ---------------------------------------------------------

    direct = []

    for evidence_id, ev in found_evidence:
        if direct_evidence_supports(query, ev):
            direct.append((evidence_id, ev))

    # ---------------------------------------------------------
    # STATUS
    # ---------------------------------------------------------

    print()
    print("=" * 70)

    if direct:
        status = "VERIFIED"

        print("STATUS:", status)
        print()
        print(
            "Direct project evidence supports the queried subject."
        )

        print()
        print("DIRECT EVIDENCE:", len(direct))

        for evidence_id, ev in direct[:100]:
            print()
            print("DIRECT", evidence_id)
            print(
                "FILE:",
                ev.get("file")
            )
            print(
                "LINES:",
                ev.get("line_start"),
                "-",
                ev.get("line_end")
            )
            print(
                "TEXT:",
                ev.get("text", "")
            )

    elif found_facts or found_relations or found_evidence:
        status = "UNKNOWN"

        print("STATUS:", status)
        print()
        print(
            "INSUFFICIENT EVIDENCE"
        )
        print()
        print(
            "The Knowledge Base contains matching records, "
            "but the available evidence does not directly "
            "establish the queried claim."
        )
        print()
        print(
            "IMPORTANT:"
        )
        print(
            "A relation or textual occurrence alone is not proof."
        )

    else:
        status = "UNKNOWN"

        print("STATUS:", status)
        print()
        print(
            "INSUFFICIENT EVIDENCE"
        )
        print()
        print(
            "No relevant Knowledge Base evidence was found."
        )

    print("=" * 70)


if __name__ == "__main__":
    main()