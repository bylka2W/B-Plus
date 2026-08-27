import json
import pathlib
import subprocess
import sys
import hashlib
from datetime import datetime, timezone


BASE = pathlib.Path(r"C:\B-Plus\agent")
MEMORY = BASE / "memory"

LEARNED = MEMORY / "learned_knowledge.json"
SYNC_DATASET = BASE / "tools" / "sync_dataset.py"

MODEL = "gpt-oss-20b-128k:latest"


# ============================================================
# TIME
# ============================================================

def now():
    return datetime.now(timezone.utc).isoformat()


# ============================================================
# JSON
# ============================================================

def load_json(path, default=None):

    if not path.exists():
        return default if default is not None else {}

    with path.open(
        "r",
        encoding="utf-8"
    ) as f:

        return json.load(f)


def save_json(path, data):

    path.parent.mkdir(
        parents=True,
        exist_ok=True
    )

    tmp = path.with_suffix(
        path.suffix + ".tmp"
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

def ensure_schema(data):

    data.setdefault(
        "version",
        3
    )

    data.setdefault(
        "candidates",
        {}
    )

    data.setdefault(
        "verified",
        {}
    )

    data.setdefault(
        "rejected",
        {}
    )

    data.setdefault(
        "needs_review",
        {}
    )

    data.setdefault(
        "duplicates",
        {}
    )

    data.setdefault(
        "concepts",
        {}
    )

    data.setdefault(
        "relations",
        {}
    )

    data.setdefault(
        "research_sessions",
        {}
    )

    return data


# ============================================================
# VERIFIED CONTEXT
# ============================================================

def load_verified_context(data):

    context = []

    for fact in data.get(
        "verified",
        {}
    ).values():

        claim = fact.get(
            "claim",
            ""
        ).strip()

        if claim:
            context.append(
                claim
            )

    return context


# ============================================================
# BUILD MODEL PROMPT
# ============================================================

def build_prompt(
    claim,
    verified_context
):

    if verified_context:

        knowledge = "\n".join(
            f"- {item}"
            for item in verified_context
        )

    else:

        knowledge = (
            "- No verified project knowledge "
            "is available."
        )

    return f"""You are the B+ project knowledge verification engine.

Evaluate the CLAIM using ONLY the verified B+ project knowledge below.

VERIFIED PROJECT KNOWLEDGE:
{knowledge}

RULES:

1. VERIFIED
Use VERIFIED only when the claim is directly supported
by the verified project knowledge.

2. REJECTED
Use REJECTED only when the claim directly contradicts
verified project knowledge.

3. NEEDS_REVIEW
Use NEEDS_REVIEW when there is not enough verified
knowledge to decide.

Do not use general-world knowledge.
Do not guess.
Do not invent information.
Do not interpret B+ as another project.

Return exactly:

STATUS: VERIFIED

or:

STATUS: REJECTED

or:

STATUS: NEEDS_REVIEW

Then:

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

        sys.exit(
            result.returncode
        )

    return result.stdout.strip()


# ============================================================
# PARSE MODEL RESPONSE
# ============================================================

def parse_response(response):

    status = "NEEDS_REVIEW"
    reason = "Model did not provide a valid status."

    for line in response.splitlines():

        clean = line.strip()

        if clean.startswith(
            "STATUS:"
        ):

            value = clean[
                len("STATUS:"):
            ].strip()

            if value in {
                "VERIFIED",
                "REJECTED",
                "NEEDS_REVIEW"
            }:

                status = value

        elif clean.startswith(
            "REASON:"
        ):

            reason = clean[
                len("REASON:"):
            ].strip()

    return (
        status,
        reason
    )


# ============================================================
# SAVE VERIFIED
# ============================================================

def save_verified(
    learned,
    claim,
    reason
):

    fact_id = make_id(
        "CAND",
        claim
    )

    existing = learned[
        "verified"
    ].get(
        fact_id
    )

    if existing:

        return (
            fact_id,
            False
        )

    learned[
        "verified"
    ][fact_id] = {

        "id":
            fact_id,

        "subject":
            "B+",

        "claim":
            claim,

        "type":
            "model_evaluation",

        "status":
            "VERIFIED",

        "confidence":
            0.5,

        "supporting_evidence":
            [],

        "weak_evidence":
            [],

        "contradicting_evidence":
            [],

        "verification_method":
            "MODEL_EVALUATION",

        "reason":
            reason,

        "source":
            MODEL,

        "created_at":
            now(),

        "verified_at":
            now()
    }

    return (
        fact_id,
        True
    )


# ============================================================
# SAVE REJECTED
# ============================================================

def save_rejected(
    learned,
    claim,
    reason
):

    fact_id = make_id(
        "CAND",
        claim
    )

    if (
        fact_id in
        learned["rejected"]
    ):

        return (
            fact_id,
            False
        )

    learned[
        "rejected"
    ][fact_id] = {

        "id":
            fact_id,

        "subject":
            "B+",

        "claim":
            claim,

        "type":
            "model_evaluation",

        "status":
            "REJECTED",

        "reason":
            reason,

        "confidence":
            0.5,

        "source":
            MODEL,

        "created_at":
            now()
    }

    return (
        fact_id,
        True
    )


# ============================================================
# SAVE NEEDS REVIEW
# ============================================================

def save_review(
    learned,
    claim,
    reason
):

    fact_id = make_id(
        "CAND",
        claim
    )

    if (
        fact_id in
        learned["needs_review"]
    ):

        return (
            fact_id,
            False
        )

    learned[
        "needs_review"
    ][fact_id] = {

        "id":
            fact_id,

        "subject":
            "B+",

        "claim":
            claim,

        "type":
            "model_evaluation",

        "status":
            "NEEDS_REVIEW",

        "reason":
            reason,

        "confidence":
            0.25,

        "source":
            MODEL,

        "created_at":
            now()
    }

    return (
        fact_id,
        True
    )


# ============================================================
# SYNC DATASET
# ============================================================

def sync_dataset():

    if not SYNC_DATASET.exists():

        print()
        print(
            "WARNING: sync_dataset.py not found:"
        )

        print(
            SYNC_DATASET
        )

        return False

    print()
    print(
        "SYNCING TRAINING DATASET..."
    )

    result = subprocess.run(
        [
            sys.executable,
            str(SYNC_DATASET)
        ],
        text=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace"
    )

    if result.returncode != 0:

        print()
        print(
            "WARNING: DATASET SYNC FAILED"
        )

        if result.stdout:
            print(result.stdout)

        if result.stderr:
            print(result.stderr)

        return False

    print(
        result.stdout
    )

    return True


# ============================================================
# LEARN CLAIM
# ============================================================

def learn_claim(
    learned,
    claim
):

    verified_context = load_verified_context(
        learned
    )

    prompt = build_prompt(
        claim,
        verified_context
    )

    response = run_model(
        prompt
    )

    status, reason = parse_response(
        response
    )

    print("=" * 70)
    print("B+ LEARNING")
    print("=" * 70)

    print()
    print(
        "MODEL:",
        MODEL
    )

    print()
    print(
        "CLAIM:"
    )

    print(
        claim
    )

    print()
    print(
        "Evaluating..."
    )

    print()
    print("=" * 70)
    print("RESULT")
    print("=" * 70)

    print()

    fact_id = None
    created = False

    if status == "VERIFIED":

        fact_id, created = save_verified(
            learned,
            claim,
            reason
        )

    elif status == "REJECTED":

        fact_id, created = save_rejected(
            learned,
            claim,
            reason
        )

    else:

        fact_id, created = save_review(
            learned,
            claim,
            reason
        )

    save_json(
        LEARNED,
        learned
    )

    print(
        "FACT ID:",
        fact_id
    )

    print(
        "STATUS:",
        status
    )

    print(
        "REASON:",
        reason
    )

    if created:

        print()
        print(
            "MEMORY UPDATED."
        )

    else:

        print()
        print(
            "FACT ALREADY EXISTS."
        )

    # --------------------------------------------------------
    # IMPORTANT:
    # Only VERIFIED knowledge is exported to dataset.
    # --------------------------------------------------------

    if status == "VERIFIED":

        sync_dataset()

    print()
    print(
        "MEMORY:",
        LEARNED
    )


# ============================================================
# MAIN
# ============================================================

def main():

    if len(sys.argv) < 3:

        print(
            'Usage: py learn.py --claim "CLAIM"'
        )

        sys.exit(1)

    command = sys.argv[1]

    if command != "--claim":

        print(
            'Usage: py learn.py --claim "CLAIM"'
        )

        sys.exit(1)

    claim = " ".join(
        sys.argv[2:]
    ).strip()

    if not claim:

        print(
            "ERROR: Empty claim."
        )

        sys.exit(1)

    learned = load_json(
        LEARNED,
        {}
    )

    learned = ensure_schema(
        learned
    )

    learn_claim(
        learned,
        claim
    )


# ============================================================
# ENTRY POINT
# ============================================================

if __name__ == "__main__":
    main()