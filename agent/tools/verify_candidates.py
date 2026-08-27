import json
import pathlib
import subprocess
import sys
from datetime import datetime, timezone


BASE = pathlib.Path(r"C:\B-Plus\agent")
MEMORY = BASE / "memory"
LEARNED = MEMORY / "learned_knowledge.json"

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

    try:

        with path.open(
            "r",
            encoding="utf-8"
        ) as f:

            return json.load(f)

    except Exception as exc:

        print()
        print("JSON LOAD ERROR:")
        print(path)
        print(exc)

        return default if default is not None else {}


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
# SCHEMA
# ============================================================

def ensure_schema(data):

    if not isinstance(data, dict):
        data = {}

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

    data.setdefault(
        "evidence",
        {}
    )

    # Keep the major collections in predictable forms.
    #
    # Candidates are intentionally NOT forced to dict here.
    # The miner may store candidates as a list.

    if not isinstance(
        data["verified"],
        dict
    ):
        data["verified"] = {}

    if not isinstance(
        data["rejected"],
        dict
    ):
        data["rejected"] = {}

    if not isinstance(
        data["needs_review"],
        dict
    ):
        data["needs_review"] = {}

    if not isinstance(
        data["duplicates"],
        dict
    ):
        data["duplicates"] = {}

    if not isinstance(
        data["concepts"],
        dict
    ):
        data["concepts"] = {}

    if not isinstance(
        data["relations"],
        dict
    ):
        data["relations"] = {}

    if not isinstance(
        data["research_sessions"],
        dict
    ):
        data["research_sessions"] = {}

    if not isinstance(
        data["evidence"],
        dict
    ):
        data["evidence"] = {}

    return data


# ============================================================
# CANDIDATE NORMALIZATION
# ============================================================

def normalize_evidence_ids(value):

    if value is None:

        return []

    if isinstance(
        value,
        list
    ):

        return value

    if isinstance(
        value,
        tuple
    ):

        return list(value)

    if isinstance(
        value,
        set
    ):

        return list(value)

    if isinstance(
        value,
        str
    ):

        return [value]

    return []


def normalize_candidate(
    item,
    fallback_id=None
):

    # --------------------------------------------------------
    # Already a normal candidate dictionary
    # --------------------------------------------------------

    if isinstance(
        item,
        dict
    ):

        candidate = dict(
            item
        )

        candidate_id = (
            candidate.get(
                "id"
            )
            or candidate.get(
                "candidate_id"
            )
            or fallback_id
        )

        if not candidate_id:
            return None

        candidate["id"] = str(
            candidate_id
        )

        if not candidate.get(
            "subject"
        ):

            candidate["subject"] = "B+"

        if not candidate.get(
            "claim"
        ):

            candidate["claim"] = ""

        candidate["supporting_evidence"] = (
            normalize_evidence_ids(
                candidate.get(
                    "supporting_evidence",
                    []
                )
            )
        )

        if not candidate.get(
            "type"
        ):

            candidate["type"] = (
                "unknown"
            )

        return candidate

    # --------------------------------------------------------
    # List / tuple candidate
    # --------------------------------------------------------

    if isinstance(
        item,
        (list, tuple)
    ):

        if not item:
            return None

        # ----------------------------------------------------
        # Common 4-field miner record:
        #
        # [id, subject, claim, evidence]
        #
        # ----------------------------------------------------

        if len(item) >= 4:

            candidate_id = (
                item[0]
                or fallback_id
            )

            if not candidate_id:
                return None

            evidence = (
                normalize_evidence_ids(
                    item[3]
                )
            )

            return {

                "id":
                    str(candidate_id),

                "subject":
                    item[1]
                    if item[1]
                    else "B+",

                "claim":
                    item[2]
                    if item[2]
                    else "",

                "type":
                    "source_evidence",

                "supporting_evidence":
                    evidence,

                "weak_evidence":
                    [],

                "contradicting_evidence":
                    [],

                "created_at":
                    now()
            }

        # ----------------------------------------------------
        # 3-field fallback:
        #
        # [id, subject, claim]
        # ----------------------------------------------------

        if len(item) == 3:

            candidate_id = (
                item[0]
                or fallback_id
            )

            if not candidate_id:
                return None

            return {

                "id":
                    str(candidate_id),

                "subject":
                    item[1]
                    if item[1]
                    else "B+",

                "claim":
                    item[2]
                    if item[2]
                    else "",

                "type":
                    "source_evidence",

                "supporting_evidence":
                    [],

                "weak_evidence":
                    [],

                "contradicting_evidence":
                    [],

                "created_at":
                    now()
            }

        # ----------------------------------------------------
        # 2-field fallback:
        #
        # [id, claim]
        # ----------------------------------------------------

        if len(item) == 2:

            candidate_id = (
                item[0]
                or fallback_id
            )

            if not candidate_id:
                return None

            return {

                "id":
                    str(candidate_id),

                "subject":
                    "B+",

                "claim":
                    item[1]
                    if item[1]
                    else "",

                "type":
                    "source_evidence",

                "supporting_evidence":
                    [],

                "weak_evidence":
                    [],

                "contradicting_evidence":
                    [],

                "created_at":
                    now()
            }

    return None


def normalize_candidates(raw_candidates):

    candidates = {}

    # --------------------------------------------------------
    # Dictionary format
    # --------------------------------------------------------

    if isinstance(
        raw_candidates,
        dict
    ):

        for candidate_id, item in (
            raw_candidates.items()
        ):

            candidate = normalize_candidate(
                item,
                fallback_id=candidate_id
            )

            if candidate is None:

                print()
                print(
                    "WARNING: unable to normalize candidate:",
                    candidate_id
                )

                continue

            candidates[
                candidate["id"]
            ] = candidate

        return candidates

    # --------------------------------------------------------
    # List format
    # --------------------------------------------------------

    if isinstance(
        raw_candidates,
        list
    ):

        for index, item in enumerate(
            raw_candidates
        ):

            candidate = normalize_candidate(
                item
            )

            if candidate is None:

                print()
                print(
                    "WARNING: unable to normalize candidate index:",
                    index
                )

                continue

            candidates[
                candidate["id"]
            ] = candidate

        return candidates

    # --------------------------------------------------------
    # Unknown format
    # --------------------------------------------------------

    print()
    print(
        "WARNING: candidates has unsupported type:",
        type(raw_candidates).__name__
    )

    return {}


# ============================================================
# OLLAMA
# ============================================================

def run_model(prompt):

    try:

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

    except FileNotFoundError:

        print()
        print(
            "OLLAMA ERROR: 'ollama' executable was not found."
        )

        return ""

    except Exception as exc:

        print()
        print(
            "OLLAMA EXECUTION ERROR:"
        )

        print(
            exc
        )

        return ""


    if result.returncode != 0:

        print()
        print(
            "OLLAMA ERROR:"
        )

        print(
            result.stderr
        )

        return ""


    return result.stdout.strip()


# ============================================================
# PROMPT
# ============================================================

def build_prompt(
    candidate,
    evidence
):

    claim = candidate.get(
        "claim",
        ""
    )

    evidence_text = []

    evidence_ids = normalize_evidence_ids(
        candidate.get(
            "supporting_evidence",
            []
        )
    )

    for evidence_id in evidence_ids:

        item = evidence.get(
            evidence_id
        )

        if not item:
            continue

        evidence_text.append(
            "[{}] {}:{}\n{}".format(
                item.get(
                    "id",
                    evidence_id
                ),
                item.get(
                    "file",
                    ""
                ),
                item.get(
                    "line_start",
                    ""
                ),
                item.get(
                    "text",
                    ""
                )
            )
        )

    if evidence_text:

        evidence_block = "\n\n".join(
            evidence_text
        )

    else:

        evidence_block = (
            "NO DIRECT EVIDENCE PROVIDED."
        )


    return f"""You are the B+ project evidence verification engine.

Your job is to determine whether a candidate knowledge claim
is supported by REAL EVIDENCE from the B+ project.

CANDIDATE CLAIM:
{claim}

PROJECT EVIDENCE:
{evidence_block}

STRICT RULES:

1. VERIFIED

Use VERIFIED only if the supplied project evidence directly
supports the candidate claim.

2. REJECTED

Use REJECTED if the supplied project evidence directly
contradicts the candidate claim.

3. NEEDS_REVIEW

Use NEEDS_REVIEW if the evidence is missing, ambiguous,
or insufficient.

IMPORTANT:

- Do NOT use general programming knowledge.
- Do NOT use outside knowledge.
- Do NOT guess.
- Do NOT infer a fact that is not supported by the evidence.
- A filename alone is not proof.
- A random occurrence of a word is not necessarily proof.
- Comments may be evidence, but distinguish comments from
  actual implementation.
- Do not treat the candidate claim itself as evidence.

Return exactly:

STATUS: VERIFIED

or

STATUS: REJECTED

or

STATUS: NEEDS_REVIEW

Then:

REASON: <short reason>
"""


# ============================================================
# PARSE
# ============================================================

def parse_response(response):

    status = "NEEDS_REVIEW"
    reason = "Invalid model response."

    for line in response.splitlines():

        line = line.strip()

        if line.startswith(
            "STATUS:"
        ):

            value = line[
                len("STATUS:"):
            ].strip()

            if value in {
                "VERIFIED",
                "REJECTED",
                "NEEDS_REVIEW"
            }:

                status = value

        elif line.startswith(
            "REASON:"
        ):

            reason = line[
                len("REASON:"):
            ].strip()


    return status, reason


# ============================================================
# MOVE CANDIDATE
# ============================================================

def remove_candidate(
    learned,
    candidate_id
):

    candidates = learned.get(
        "candidates"
    )

    # --------------------------------------------------------
    # Dictionary candidate storage
    # --------------------------------------------------------

    if isinstance(
        candidates,
        dict
    ):

        candidates.pop(
            candidate_id,
            None
        )

        return

    # --------------------------------------------------------
    # List candidate storage
    # --------------------------------------------------------

    if isinstance(
        candidates,
        list
    ):

        remaining = []

        for item in candidates:

            candidate = normalize_candidate(
                item
            )

            if candidate is None:

                remaining.append(
                    item
                )

                continue

            if candidate.get(
                "id"
            ) == candidate_id:

                continue

            remaining.append(
                item
            )

        learned[
            "candidates"
        ] = remaining


# ============================================================
# SAVE VERIFIED
# ============================================================

def save_verified(
    learned,
    candidate,
    reason
):

    candidate_id = candidate[
        "id"
    ]

    claim = candidate.get(
        "claim",
        ""
    )

    existing = learned[
        "verified"
    ].get(
        candidate_id
    )

    if existing:

        return False


    fact = {

        "id":
            candidate_id,

        "subject":
            candidate.get(
                "subject",
                "B+"
            ),

        "claim":
            claim,

        "type":
            candidate.get(
                "type",
                "unknown"
            ),

        "status":
            "VERIFIED",

        "confidence":
            0.9,

        "supporting_evidence":
            [],

        "weak_evidence":
            [],

        "contradicting_evidence":
            [],

        "verification_method":
            "SOURCE_EVIDENCE",

        "reason":
            reason,

        "source":
            "B+ source scanner",

        "created_at":
            candidate.get(
                "created_at",
                now()
            ),

        "verified_at":
            now()
    }


    for evidence_id in normalize_evidence_ids(
        candidate.get(
            "supporting_evidence",
            []
        )
    ):

        if evidence_id not in fact[
            "supporting_evidence"
        ]:

            fact[
                "supporting_evidence"
            ].append(
                evidence_id
            )


    learned[
        "verified"
    ][candidate_id] = fact

    return True


# ============================================================
# SAVE REJECTED
# ============================================================

def save_rejected(
    learned,
    candidate,
    reason
):

    candidate_id = candidate[
        "id"
    ]

    if candidate_id in learned[
        "rejected"
    ]:

        return False


    learned[
        "rejected"
    ][candidate_id] = {

        "id":
            candidate_id,

        "subject":
            candidate.get(
                "subject",
                "B+"
            ),

        "claim":
            candidate.get(
                "claim",
                ""
            ),

        "type":
            candidate.get(
                "type",
                "unknown"
            ),

        "status":
            "REJECTED",

        "reason":
            reason,

        "source":
            "B+ source scanner",

        "supporting_evidence":
            normalize_evidence_ids(
                candidate.get(
                    "supporting_evidence",
                    []
                )
            ),

        "created_at":
            now()
    }

    return True


# ============================================================
# SAVE REVIEW
# ============================================================

def save_review(
    learned,
    candidate,
    reason
):

    candidate_id = candidate[
        "id"
    ]

    if candidate_id in learned[
        "needs_review"
    ]:

        return False


    learned[
        "needs_review"
    ][candidate_id] = {

        "id":
            candidate_id,

        "subject":
            candidate.get(
                "subject",
                "B+"
            ),

        "claim":
            candidate.get(
                "claim",
                ""
            ),

        "type":
            candidate.get(
                "type",
                "unknown"
            ),

        "status":
            "NEEDS_REVIEW",

        "reason":
            reason,

        "source":
            "B+ source scanner",

        "supporting_evidence":
            normalize_evidence_ids(
                candidate.get(
                    "supporting_evidence",
                    []
                )
            ),

        "created_at":
            now()
    }

    return True


# ============================================================
# VERIFY ONE
# ============================================================

def verify_candidate(
    learned,
    candidate_id,
    candidate
):

    prompt = build_prompt(
        candidate,
        learned.get(
            "evidence",
            {}
        )
    )

    print()
    print(
        "-" * 70
    )

    print(
        "CANDIDATE:",
        candidate_id
    )

    print(
        "CLAIM:",
        candidate.get(
            "claim",
            ""
        )
    )

    print(
        "EVIDENCE:",
        len(
            normalize_evidence_ids(
                candidate.get(
                    "supporting_evidence",
                    []
                )
            )
        )
    )

    print()


    response = run_model(
        prompt
    )


    if not response:

        status = "NEEDS_REVIEW"

        reason = (
            "Ollama returned no response."
        )

    else:

        status, reason = parse_response(
            response
        )


    print(
        "STATUS:",
        status
    )

    print(
        "REASON:",
        reason
    )


    if status == "VERIFIED":

        save_verified(
            learned,
            candidate,
            reason
        )

        remove_candidate(
            learned,
            candidate_id
        )

        return "VERIFIED"


    if status == "REJECTED":

        save_rejected(
            learned,
            candidate,
            reason
        )

        remove_candidate(
            learned,
            candidate_id
        )

        return "REJECTED"


    save_review(
        learned,
        candidate,
        reason
    )

    remove_candidate(
        learned,
        candidate_id
    )

    return "NEEDS_REVIEW"


# ============================================================
# MAIN VERIFICATION
# ============================================================

def verify_all(
    learned
):

    raw_candidates = learned.get(
        "candidates",
        {}
    )

    candidates = normalize_candidates(
        raw_candidates
    )


    if not candidates:

        print(
            "NO CANDIDATES TO VERIFY."
        )

        return


    verified = 0
    rejected = 0
    review = 0


    print(
        "=" * 70
    )

    print(
        "B+ CANDIDATE VERIFICATION"
    )

    print(
        "=" * 70
    )

    print()

    print(
        "MODEL:",
        MODEL
    )

    print(
        "CANDIDATES:",
        len(candidates)
    )


    # IMPORTANT:
    #
    # verify_candidate() removes candidates from
    # learned["candidates"].
    #
    # Therefore we iterate over a snapshot.
    #
    for candidate_id, candidate in list(
        candidates.items()
    ):

        try:

            result = verify_candidate(
                learned,
                candidate_id,
                candidate
            )

        except Exception as exc:

            print()
            print(
                "VERIFICATION ERROR:"
            )

            print(
                "CANDIDATE:",
                candidate_id
            )

            print(
                "ERROR:",
                repr(exc)
            )

            result = "NEEDS_REVIEW"

            # If an unexpected exception happens,
            # preserve the candidate as review instead
            # of silently losing it.

            save_review(
                learned,
                candidate,
                "Verifier exception: {}".format(
                    exc
                )
            )

            remove_candidate(
                learned,
                candidate_id
            )


        if result == "VERIFIED":

            verified += 1

        elif result == "REJECTED":

            rejected += 1

        else:

            review += 1


        save_json(
            LEARNED,
            learned
        )


    print()

    print(
        "=" * 70
    )

    print(
        "VERIFICATION RESULT"
    )

    print(
        "=" * 70
    )

    print()

    print(
        "VERIFIED:",
        verified
    )

    print(
        "REJECTED:",
        rejected
    )

    print(
        "NEEDS_REVIEW:",
        review
    )

    print()

    print(
        "TOTAL VERIFIED:",
        len(
            learned.get(
                "verified",
                {}
            )
        )
    )

    print(
        "TOTAL REJECTED:",
        len(
            learned.get(
                "rejected",
                {}
            )
        )
    )

    print(
        "TOTAL REVIEW:",
        len(
            learned.get(
                "needs_review",
                {}
            )
        )
    )

    print()

    print(
        "REMAINING CANDIDATES:",
        len(
            normalize_candidates(
                learned.get(
                    "candidates",
                    {}
                )
            )
        )
    )

    print()

    print(
        "MEMORY:",
        LEARNED
    )


# ============================================================
# ENTRY POINT
# ============================================================

def main():

    learned = load_json(
        LEARNED,
        {}
    )

    learned = ensure_schema(
        learned
    )

    verify_all(
        learned
    )

    save_json(
        LEARNED,
        learned
    )


if __name__ == "__main__":

    main()