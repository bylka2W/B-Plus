import json
import pathlib
import subprocess
import sys


BASE = pathlib.Path(r"C:\B-Plus\agent")
DATASET = BASE / "memory" / "training_dataset.jsonl"

MODEL = "gpt-oss-20b-128k:latest"


# ============================================================
# LOAD VERIFIED KNOWLEDGE
# ============================================================

def load_verified_context():
    context = []

    if not DATASET.exists():
        raise FileNotFoundError(
            f"Dataset not found: {DATASET}"
        )

    with DATASET.open(
        "r",
        encoding="utf-8"
    ) as f:

        for line in f:
            line = line.strip()

            if not line:
                continue

            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue

            metadata = item.get(
                "metadata",
                {}
            )

            if metadata.get("status") != "VERIFIED":
                continue

            messages = item.get(
                "messages",
                []
            )

            for message in messages:

                if message.get("role") != "assistant":
                    continue

                content = message.get(
                    "content",
                    ""
                ).strip()

                if content:
                    context.append(content)

    # Remove duplicates while preserving order
    unique = []
    seen = set()

    for item in context:

        if item not in seen:
            seen.add(item)
            unique.append(item)

    return unique


# ============================================================
# BUILD KNOWLEDGE PROMPT
# ============================================================

def build_knowledge_prompt(question):

    verified = load_verified_context()

    knowledge = "\n".join(
        f"- {item}"
        for item in verified
    )

    if not knowledge:
        knowledge = "- No verified project knowledge is available."

    return f"""You are the B+ project knowledge assistant.

You answer questions ONLY from the verified B+ project
knowledge provided below.

Do not use general-world knowledge.
Do not guess.
Do not invent missing information.
Do not interpret B+ as another project.

VERIFIED PROJECT KNOWLEDGE:
{knowledge}

QUESTION:
{question}

Rules:

1. Answer only from VERIFIED PROJECT KNOWLEDGE.
2. If the knowledge directly contains the answer,
   give the answer clearly.
3. If the knowledge does not contain enough information,
   say exactly:

NOT ENOUGH VERIFIED KNOWLEDGE.

4. Do not add facts that are not present in the verified
   knowledge.
5. Keep the answer concise.

Answer:
"""


# ============================================================
# BUILD CLAIM CHECK PROMPT
# ============================================================

def build_check_prompt(claim):

    verified = load_verified_context()

    knowledge = "\n".join(
        f"- {item}"
        for item in verified
    )

    if not knowledge:
        knowledge = "- No verified project knowledge is available."

    return f"""You are the B+ project knowledge verification engine.

Your task is to evaluate a CLAIM about the B+ project.

Use ONLY the verified project knowledge below.

VERIFIED PROJECT KNOWLEDGE:
{knowledge}

Rules:

1. VERIFIED

Use VERIFIED only when the claim is directly supported
by the verified project knowledge.

2. REJECTED

Use REJECTED when the claim directly contradicts
verified project knowledge.

3. NEEDS_REVIEW

Use NEEDS_REVIEW when the verified project knowledge
does not contain enough information to decide.

Do not use general-world knowledge.
Do not guess.
Do not interpret B+ as anything other than the B+ project.

Return exactly:

STATUS: <VERIFIED|REJECTED|NEEDS_REVIEW>
REASON: <short reason>

CLAIM:
{claim}
"""


# ============================================================
# RUN OLLAMA
# ============================================================

def run_model(prompt):

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

    return result.stdout.strip()


# ============================================================
# CHECK CLAIM
# ============================================================

def command_check(claim):

    prompt = build_check_prompt(claim)

    print("=" * 70)
    print("B+ KNOWLEDGE MODEL")
    print("=" * 70)

    print()
    print("MODEL:", MODEL)

    print()
    print("CLAIM:")
    print(claim)

    print()
    print("=" * 70)
    print("MODEL RESPONSE")
    print("=" * 70)
    print()

    response = run_model(prompt)

    print(response)


# ============================================================
# ASK QUESTION
# ============================================================

def command_ask(question):

    prompt = build_knowledge_prompt(question)

    print("=" * 70)
    print("B+ KNOWLEDGE MODEL")
    print("=" * 70)

    print()
    print("MODEL:", MODEL)

    print()
    print("QUESTION:")
    print(question)

    print()
    print("=" * 70)
    print("MODEL RESPONSE")
    print("=" * 70)
    print()

    response = run_model(prompt)

    print(response)


# ============================================================
# SHOW VERIFIED KNOWLEDGE
# ============================================================

def command_knowledge():

    verified = load_verified_context()

    print("=" * 70)
    print("B+ VERIFIED KNOWLEDGE")
    print("=" * 70)
    print()

    if not verified:
        print("No verified knowledge found.")
        return

    for index, item in enumerate(
        verified,
        start=1
    ):
        print(f"{index}. {item}")


# ============================================================
# USAGE
# ============================================================

def print_usage():

    print("Usage:")
    print()
    print('  py knowledge_model.py --check "CLAIM"')
    print('  py knowledge_model.py --ask "QUESTION"')
    print('  py knowledge_model.py --knowledge')


# ============================================================
# MAIN
# ============================================================

def main():

    if len(sys.argv) < 2:
        print_usage()
        sys.exit(1)

    command = sys.argv[1]

    # --------------------------------------------------------
    # --check
    # --------------------------------------------------------

    if command == "--check":

        if len(sys.argv) < 3:
            print(
                'Usage: py knowledge_model.py '
                '--check "CLAIM"'
            )
            sys.exit(1)

        claim = " ".join(sys.argv[2:])

        command_check(claim)
        return

    # --------------------------------------------------------
    # --ask
    # --------------------------------------------------------

    if command == "--ask":

        if len(sys.argv) < 3:
            print(
                'Usage: py knowledge_model.py '
                '--ask "QUESTION"'
            )
            sys.exit(1)

        question = " ".join(sys.argv[2:])

        command_ask(question)
        return

    # --------------------------------------------------------
    # --knowledge
    # --------------------------------------------------------

    if command == "--knowledge":

        command_knowledge()
        return

    # --------------------------------------------------------
    # UNKNOWN COMMAND
    # --------------------------------------------------------

    print(
        f"Unknown command: {command}"
    )

    print()

    print_usage()

    sys.exit(1)


# ============================================================
# ENTRY POINT
# ============================================================

if __name__ == "__main__":
    main()