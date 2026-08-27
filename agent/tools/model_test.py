import json
import pathlib
import subprocess
import sys


BASE = pathlib.Path(r"C:\B-Plus\agent")
DATASET = BASE / "memory" / "training_dataset.jsonl"

MODEL = "gpt-oss-20b-128k:latest"


def load_verified_context():
    context = []

    if not DATASET.exists():
        raise FileNotFoundError(
            f"Dataset not found: {DATASET}"
        )

    with DATASET.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()

            if not line:
                continue

            item = json.loads(line)

            metadata = item.get("metadata", {})

            if metadata.get("status") != "VERIFIED":
                continue

            messages = item.get("messages", [])

            for message in messages:
                if message.get("role") == "assistant":
                    context.append(
                        message.get("content", "")
                    )

    return context


def build_prompt():
    verified = load_verified_context()

    knowledge = "\n".join(
        f"- {item}"
        for item in verified
    )

    return f"""You are the B+ project knowledge assistant.

Use ONLY the verified project knowledge below when answering questions
about B+.

Verified knowledge:
{knowledge}

Important:
- Do not invent facts about the B+ project.
- Do not replace project knowledge with general-world interpretations.
- If the available knowledge is insufficient, say NEEDS_REVIEW.
- The user is asking about the B+ project.

Question:
What is known about B+?
"""


def run():
    prompt = build_prompt()

    print("=" * 70)
    print("B+ MODEL TEST")
    print("=" * 70)
    print()
    print("MODEL:", MODEL)
    print()
    print("PROMPT:")
    print(prompt)
    print()
    print("=" * 70)
    print("MODEL RESPONSE")
    print("=" * 70)
    print()

    result = subprocess.run(
        [
            "ollama",
            "run",
            MODEL,
            prompt
        ],
        text=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace"
    )

    if result.returncode != 0:
        print("OLLAMA ERROR:")
        print(result.stderr)
        sys.exit(result.returncode)

    print(result.stdout)


if __name__ == "__main__":
    run()