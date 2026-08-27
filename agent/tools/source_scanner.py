import json
import pathlib
import hashlib
import re
import sys
from datetime import datetime, timezone


# ============================================================
# CONFIG
# ============================================================

BASE = pathlib.Path(r"C:\B-Plus\agent")

MEMORY = BASE / "memory"

LEARNED = MEMORY / "learned_knowledge.json"

# Если твой исходный код находится в другом каталоге,
# поменяй только эту строку.
SOURCE_ROOT = BASE


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
# ID
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

    data.setdefault(
        "evidence",
        {}
    )

    return data


# ============================================================
# FILE EXTENSIONS
# ============================================================

SOURCE_EXTENSIONS = {
    ".b+",
    ".b",
    ".zig",
    ".c",
    ".h",
    ".cpp",
    ".hpp",
    ".rs",
    ".asm",
    ".s",
    ".txt",
}


# ============================================================
# IGNORE DIRECTORIES
# ============================================================

IGNORE_DIRS = {
    ".git",
    ".hg",
    ".svn",
    "__pycache__",
    "node_modules",
    "target",
    "build",
    "dist",
    ".venv",
    "venv",
    "memory",
}


# ============================================================
# READ FILE
# ============================================================

def read_text(path):

    encodings = [
        "utf-8",
        "utf-8-sig",
        "cp1252",
        "latin-1",
    ]

    for encoding in encodings:

        try:

            return path.read_text(
                encoding=encoding
            )

        except (
            UnicodeDecodeError,
            UnicodeError
        ):

            continue

    return None


# ============================================================
# ITERATE SOURCE FILES
# ============================================================

def iter_source_files():

    if not SOURCE_ROOT.exists():

        return

    for path in SOURCE_ROOT.rglob("*"):

        if not path.is_file():
            continue

        if any(
            part in IGNORE_DIRS
            for part in path.parts
        ):
            continue

        if path.suffix.lower() not in SOURCE_EXTENSIONS:
            continue

        yield path


# ============================================================
# EVIDENCE
# ============================================================

def make_evidence(
    learned,
    file_path,
    line_number,
    text
):

    relative = str(
        file_path.relative_to(
            BASE
        )
    ).replace(
        "\\",
        "/"
    )

    seed = (
        relative
        + "\n"
        + str(line_number)
        + "\n"
        + text
    )

    evidence_id = make_id(
        "EVID",
        seed
    )

    if evidence_id not in learned["evidence"]:

        learned["evidence"][evidence_id] = {

            "id":
                evidence_id,

            "file":
                relative,

            "line_start":
                line_number,

            "line_end":
                line_number,

            "text":
                text,

            "created_at":
                now()
        }

    return evidence_id


# ============================================================
# ADD CANDIDATE
# ============================================================

def add_candidate(
    learned,
    claim,
    fact_type,
    evidence_id
):

    candidate_id = make_id(
        "CAND",
        claim
    )

    # Already verified
    if candidate_id in learned["verified"]:

        return (
            candidate_id,
            "VERIFIED_EXISTS"
        )

    # Already rejected
    if candidate_id in learned["rejected"]:

        return (
            candidate_id,
            "REJECTED_EXISTS"
        )

    # Already review
    if candidate_id in learned["needs_review"]:

        return (
            candidate_id,
            "REVIEW_EXISTS"
        )

    candidate = learned[
        "candidates"
    ].get(
        candidate_id
    )

    if candidate:

        evidence = candidate.setdefault(
            "supporting_evidence",
            []
        )

        if evidence_id not in evidence:

            evidence.append(
                evidence_id
            )

        return (
            candidate_id,
            "UPDATED"
        )

    learned[
        "candidates"
    ][candidate_id] = {

        "id":
            candidate_id,

        "subject":
            "B+",

        "claim":
            claim,

        "type":
            fact_type,

        "status":
            "CANDIDATE",

        "supporting_evidence":
            [
                evidence_id
            ],

        "created_at":
            now()
    }

    return (
        candidate_id,
        "CREATED"
    )


# ============================================================
# PATTERNS
# ============================================================

def extract_pipeline_facts(
    learned,
    path,
    lines
):

    found = 0

    patterns = [

        (
            re.compile(
                r"B\+\s+source.*?BIR.*?MIR.*?x64\s+COFF",
                re.IGNORECASE
            ),
            "B+ source is processed through BIR and MIR to produce an x64 COFF object.",
            "pipeline"
        ),

        (
            re.compile(
                r"B\+\s+source\s*[→>-]+\s*BIR",
                re.IGNORECASE
            ),
            "B+ source enters the BIR intermediate representation.",
            "pipeline"
        ),

        (
            re.compile(
                r"BIR\s*[→>-]+\s*MIR",
                re.IGNORECASE
            ),
            "BIR is converted to MIR.",
            "pipeline"
        ),

        (
            re.compile(
                r"MIR.*?x64\s+COFF",
                re.IGNORECASE
            ),
            "MIR produces an x64 COFF object.",
            "pipeline"
        ),
    ]

    for index, line in enumerate(
        lines,
        start=1
    ):

        text = line.strip()

        if not text:
            continue

        for pattern, claim, fact_type in patterns:

            if not pattern.search(text):
                continue

            evidence_id = make_evidence(
                learned,
                path,
                index,
                text
            )

            _, result = add_candidate(
                learned,
                claim,
                fact_type,
                evidence_id
            )

            if result == "CREATED":

                found += 1

    return found


# ============================================================
# LANGUAGE / SYNTAX FACTS
# ============================================================

def extract_syntax_facts(
    learned,
    path,
    lines
):

    found = 0

    patterns = [

        (
            re.compile(
                r"\bfn\s+[A-Za-z_][A-Za-z0-9_]*\s*\(",
                re.IGNORECASE
            ),
            "B+ source contains function declarations using the fn syntax.",
            "syntax"
        ),

        (
            re.compile(
                r"\bstruct\s+[A-Za-z_][A-Za-z0-9_]*",
                re.IGNORECASE
            ),
            "B+ source contains struct declarations.",
            "syntax"
        ),

        (
            re.compile(
                r"\benum\s+[A-Za-z_][A-Za-z0-9_]*",
                re.IGNORECASE
            ),
            "B+ source contains enum declarations.",
            "syntax"
        ),

        (
            re.compile(
                r"\bimport\s+[A-Za-z_][A-Za-z0-9_.]*",
                re.IGNORECASE
            ),
            "B+ source contains import declarations.",
            "modules"
        ),

        (
            re.compile(
                r"\bconst\s+[A-Za-z_][A-Za-z0-9_]*",
                re.IGNORECASE
            ),
            "B+ source contains const declarations.",
            "syntax"
        ),
    ]

    for index, line in enumerate(
        lines,
        start=1
    ):

        text = line.strip()

        if not text:
            continue

        # Не считаем обычные комментарии доказательством
        if text.startswith("//"):
            continue

        for pattern, claim, fact_type in patterns:

            if not pattern.search(text):
                continue

            evidence_id = make_evidence(
                learned,
                path,
                index,
                text
            )

            _, result = add_candidate(
                learned,
                claim,
                fact_type,
                evidence_id
            )

            if result == "CREATED":

                found += 1

    return found


# ============================================================
# COMPILER FACTS
# ============================================================

def extract_compiler_facts(
    learned,
    path,
    lines
):

    found = 0

    patterns = [

        (
            re.compile(
                r"\bbpc\b",
                re.IGNORECASE
            ),
            "The B+ project contains references to the bpc compiler tool.",
            "compiler"
        ),

        (
            re.compile(
                r"\bbpc\s+ir\b",
                re.IGNORECASE
            ),
            "The B+ project contains a bpc ir compiler command.",
            "compiler"
        ),
    ]

    for index, line in enumerate(
        lines,
        start=1
    ):

        text = line.strip()

        if not text:
            continue

        for pattern, claim, fact_type in patterns:

            if not pattern.search(text):
                continue

            evidence_id = make_evidence(
                learned,
                path,
                index,
                text
            )

            _, result = add_candidate(
                learned,
                claim,
                fact_type,
                evidence_id
            )

            if result == "CREATED":

                found += 1

    return found


# ============================================================
# SCAN FILE
# ============================================================

def scan_file(
    learned,
    path
):

    text = read_text(
        path
    )

    if text is None:

        return 0

    lines = text.splitlines()

    created = 0

    created += extract_pipeline_facts(
        learned,
        path,
        lines
    )

    created += extract_syntax_facts(
        learned,
        path,
        lines
    )

    created += extract_compiler_facts(
        learned,
        path,
        lines
    )

    return created


# ============================================================
# SCAN PROJECT
# ============================================================

def scan_project(learned):

    files_scanned = 0
    candidates_created = 0

    print("=" * 70)
    print("B+ SOURCE KNOWLEDGE SCANNER")
    print("=" * 70)

    print()
    print(
        "SOURCE ROOT:",
        SOURCE_ROOT
    )

    print(
        "MEMORY:",
        LEARNED
    )

    print()

    for path in iter_source_files():

        files_scanned += 1

        try:

            created = scan_file(
                learned,
                path
            )

            candidates_created += created

        except Exception as exc:

            print(
                "ERROR:",
                path,
                "->",
                exc
            )

    return (
        files_scanned,
        candidates_created
    )


# ============================================================
# PRINT CANDIDATES
# ============================================================

def print_candidates(
    learned
):

    candidates = learned.get(
        "candidates",
        {}
    )

    print()
    print("=" * 70)
    print("CANDIDATES")
    print("=" * 70)

    if not candidates:

        print()
        print(
            "No candidates found."
        )

        return

    for candidate_id, candidate in candidates.items():

        print()
        print(
            candidate_id
        )

        print(
            "TYPE:",
            candidate.get(
                "type",
                ""
            )
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
            ", ".join(
                candidate.get(
                    "supporting_evidence",
                    []
                )
            )
        )


# ============================================================
# MAIN
# ============================================================

def main():

    learned = load_json(
        LEARNED,
        {}
    )

    learned = ensure_schema(
        learned
    )

    files_scanned, candidates_created = scan_project(
        learned
    )

    save_json(
        LEARNED,
        learned
    )

    print()
    print("=" * 70)
    print("SCAN RESULT")
    print("=" * 70)

    print()
    print(
        "FILES SCANNED:",
        files_scanned
    )

    print(
        "NEW CANDIDATES:",
        candidates_created
    )

    print(
        "TOTAL CANDIDATES:",
        len(
            learned["candidates"]
        )
    )

    print(
        "EVIDENCE:",
        len(
            learned["evidence"]
        )
    )

    print()
    print(
        "MEMORY:",
        LEARNED
    )

    print_candidates(
        learned
    )


# ============================================================
# ENTRY POINT
# ============================================================

if __name__ == "__main__":
    main()