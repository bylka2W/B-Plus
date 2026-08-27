from pathlib import Path
import json
import hashlib
import re

# ============================================================
# B+ LANGUAGE MINER
# ============================================================

SOURCE_ROOT = Path(r"C:\B-Plus\zig\src")
MEMORY_FILE = Path(r"C:\B-Plus\agent\memory\learned_knowledge.json")

# B+ project compiler/runtime source
KNOWN_EXTENSIONS = {
    ".b",
    ".b+",
    ".bplus",
    ".bpp",
    ".bpx",
    ".zig",
}

IGNORED_DIRS = {
    ".git",
    ".zig-cache",
    "zig-out",
    "__pycache__",
}


# ============================================================
# MEMORY
# ============================================================

def load_memory():
    if not MEMORY_FILE.exists():
        return {
            "candidates": [],
            "evidence": [],
            "concepts": [],
            "relations": [],
        }

    try:
        with MEMORY_FILE.open(
            "r",
            encoding="utf-8",
        ) as f:
            data = json.load(f)

    except Exception as e:
        print(
            f"WARNING: cannot load memory: {e}"
        )

        return {
            "candidates": [],
            "evidence": [],
            "concepts": [],
            "relations": [],
        }

    if not isinstance(data, dict):
        data = {}

    # IMPORTANT:
    # Existing project memory may contain dictionaries instead
    # of lists. Normalize everything safely.

    for key in (
        "candidates",
        "evidence",
        "concepts",
        "relations",
    ):
        value = data.get(key)

        if value is None:
            data[key] = []

        elif isinstance(value, list):
            pass

        elif isinstance(value, dict):
            # Preserve existing dictionary records by converting
            # them to a list of records.
            converted = []

            for k, v in value.items():
                if isinstance(v, dict):
                    item = dict(v)
                    item.setdefault("id", str(k))
                    converted.append(item)
                else:
                    converted.append({
                        "id": str(k),
                        "value": v,
                    })

            data[key] = converted

        else:
            data[key] = []

    return data


def save_memory(memory):
    MEMORY_FILE.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    temporary = MEMORY_FILE.with_suffix(
        ".tmp"
    )

    with temporary.open(
        "w",
        encoding="utf-8",
    ) as f:
        json.dump(
            memory,
            f,
            indent=2,
            ensure_ascii=False,
        )

    temporary.replace(MEMORY_FILE)


# ============================================================
# FILE DISCOVERY
# ============================================================

def is_ignored(path):
    for part in path.parts:
        if part in IGNORED_DIRS:
            return True

    return False


def looks_like_bplus_source(path):
    extension = path.suffix.lower()

    if extension in KNOWN_EXTENSIONS:
        return True

    # Files without extensions:
    if extension == "":
        try:
            text = path.read_text(
                encoding="utf-8",
                errors="ignore",
            )

        except Exception:
            return False

        indicators = (
            "B+",
            "BPLUS",
            "bplus",
            "BIR",
            "MIR",
            "THIR",
            "import ",
            "pub fn ",
            "pub const ",
            "const ",
            "fn ",
        )

        return any(
            item in text
            for item in indicators
        )

    return False


def collect_source_files():
    if not SOURCE_ROOT.exists():
        print()
        print(
            "ERROR: SOURCE ROOT DOES NOT EXIST."
        )
        print()
        print(
            f"SOURCE ROOT: {SOURCE_ROOT}"
        )
        print()

        return []

    files = []

    for path in SOURCE_ROOT.rglob("*"):

        if not path.is_file():
            continue

        if is_ignored(path):
            continue

        if looks_like_bplus_source(path):
            files.append(path)

    return sorted(files)


# ============================================================
# TEXT ANALYSIS
# ============================================================

def count_nonempty_lines(text):
    return sum(
        1
        for line in text.splitlines()
        if line.strip()
    )


def count_imports(text):
    patterns = [
        r"^\s*import\s+",
        r"^\s*const\s+\w+\s*=\s*@import",
        r"@import\s*\(",
    ]

    total = 0

    for pattern in patterns:
        total += len(
            re.findall(
                pattern,
                text,
                flags=re.MULTILINE,
            )
        )

    return total


def count_functions(text):
    patterns = [
        r"\bfn\s+\w+",
        r"\bpub\s+fn\s+\w+",
    ]

    found = set()

    for pattern in patterns:
        for match in re.finditer(
            pattern,
            text,
        ):
            found.add(match.group(0))

    return len(found)


def count_structs(text):
    return len(
        re.findall(
            r"\b(?:const|pub const)\s+\w+\s*=\s*(?:struct|enum|union)\b",
            text,
        )
    )


def find_pipeline_terms(text):
    terms = (
        "AST",
        "HIR",
        "THIR",
        "BIR",
        "MIR",
        "Machine IR",
        "COFF",
        "x64",
        "linker",
        "parser",
        "lexer",
        "type checker",
        "verifier",
    )

    found = []

    lower = text.lower()

    for term in terms:
        if term.lower() in lower:
            found.append(term)

    return found


# ============================================================
# IDS
# ============================================================

def make_id(prefix, text):
    digest = hashlib.sha256(
        text.encode(
            "utf-8",
            errors="ignore",
        )
    ).hexdigest()[:16]

    return f"{prefix}-{digest}"


# ============================================================
# MEMORY HELPERS
# ============================================================

def existing_ids(records):
    result = set()

    if not isinstance(records, list):
        return result

    for item in records:

        if isinstance(item, dict):

            item_id = item.get("id")

            if item_id is not None:
                result.add(
                    str(item_id)
                )

    return result


def add_evidence(
    memory,
    claim,
    evidence_text,
    source_file,
):
    evidence_id = make_id(
        "EVID",
        claim
        + "\n"
        + evidence_text,
    )

    records = memory.get(
        "evidence",
        [],
    )

    if not isinstance(records, list):
        records = []

    ids = existing_ids(records)

    if evidence_id in ids:
        return (
            evidence_id,
            False,
        )

    records.append({
        "id": evidence_id,
        "claim": claim,
        "evidence": evidence_text,
        "source_file": str(source_file),
        "source_root": str(SOURCE_ROOT),
    })

    memory["evidence"] = records

    return (
        evidence_id,
        True,
    )


def add_candidate(
    memory,
    claim,
    evidence_id,
):
    candidate_id = make_id(
        "CAND",
        claim,
    )

    records = memory.get(
        "candidates",
        [],
    )

    if not isinstance(records, list):
        records = []

    ids = existing_ids(records)

    if candidate_id in ids:
        return False

    records.append({
        "id": candidate_id,
        "claim": claim,
        "evidence_ids": [
            evidence_id
        ],
        "status": "PENDING",
    })

    memory["candidates"] = records

    return True


# ============================================================
# FILE MINING
# ============================================================

def mine_file(
    memory,
    path,
):
    try:
        text = path.read_text(
            encoding="utf-8",
            errors="ignore",
        )

    except Exception as e:
        print(
            f"WARNING: failed to read "
            f"{path}: {e}"
        )

        return (
            0,
            0,
            0,
        )

    nonempty = count_nonempty_lines(
        text
    )

    imports = count_imports(
        text
    )

    functions = count_functions(
        text
    )

    structs = count_structs(
        text
    )

    pipeline_terms = find_pipeline_terms(
        text
    )

    relative = path.relative_to(
        SOURCE_ROOT
    )

    # --------------------------------------------------------
    # Main file-size/source candidate
    # --------------------------------------------------------

    claim = (
        f"B+ project source file "
        f"'{relative}' contains "
        f"{nonempty} non-empty source lines."
    )

    evidence_text = (
        f"File: {path}\n"
        f"Relative path: {relative}\n"
        f"Extension: "
        f"{path.suffix or '<NO EXT>'}\n"
        f"Non-empty source lines: {nonempty}\n"
        f"Imports detected: {imports}\n"
        f"Functions detected: {functions}\n"
        f"Struct/enum/union declarations: "
        f"{structs}\n"
        f"Pipeline terms: "
        f"{', '.join(pipeline_terms)}"
    )

    evidence_id, new_evidence = add_evidence(
        memory,
        claim,
        evidence_text,
        path,
    )

    new_candidate = add_candidate(
        memory,
        claim,
        evidence_id,
    )

    return (
        int(new_candidate),
        int(new_evidence),
        nonempty,
    )


# ============================================================
# MAIN
# ============================================================

def main():

    print("=" * 70)
    print("B+ LANGUAGE MINER")
    print("=" * 70)

    print()
    print(
        f"SOURCE ROOT: {SOURCE_ROOT}"
    )

    print(
        f"MEMORY: {MEMORY_FILE}"
    )

    print()

    print(
        "Known extensions: "
        + ", ".join(
            sorted(KNOWN_EXTENSIONS)
        )
    )

    print(
        "Files without extension are checked "
        "by B+ content heuristics."
    )

    print()

    source_files = collect_source_files()

    print(
        f"B+ SOURCE FILES: "
        f"{len(source_files)}"
    )

    print()

    if not source_files:

        print(
            "WARNING: NO B+ SOURCE FILES FOUND."
        )

        print()
        print(
            "Checked:"
        )

        print(
            SOURCE_ROOT
        )

        print()

        return

    memory = load_memory()

    files_scanned = 0
    source_lines = 0
    new_candidates = 0
    new_evidence = 0

    # --------------------------------------------------------
    # Scan
    # --------------------------------------------------------

    for path in source_files:

        relative = path.relative_to(
            SOURCE_ROOT
        )

        print(
            f"SCAN: {relative}"
        )

        try:

            candidates, evidence, lines = mine_file(
                memory,
                path,
            )

            files_scanned += 1
            source_lines += lines
            new_candidates += candidates
            new_evidence += evidence

        except Exception as e:

            print(
                f"WARNING: failed to scan "
                f"{path}: {e}"
            )

    # --------------------------------------------------------
    # Save
    # --------------------------------------------------------

    try:
        save_memory(
            memory
        )

    except Exception as e:

        print()
        print(
            "ERROR: failed to save memory:"
        )
        print(e)

        return

    # --------------------------------------------------------
    # Result
    # --------------------------------------------------------

    candidates = memory.get(
        "candidates",
        [],
    )

    evidence = memory.get(
        "evidence",
        [],
    )

    concepts = memory.get(
        "concepts",
        [],
    )

    relations = memory.get(
        "relations",
        [],
    )

    if not isinstance(
        candidates,
        list,
    ):
        candidates = []

    if not isinstance(
        evidence,
        list,
    ):
        evidence = []

    if not isinstance(
        concepts,
        list,
    ):
        concepts = []

    if not isinstance(
        relations,
        list,
    ):
        relations = []

    print()
    print("=" * 70)
    print("MINING RESULT")
    print("=" * 70)

    print()

    print(
        f"FILES SCANNED: "
        f"{files_scanned}"
    )

    print(
        f"SOURCE LINES: "
        f"{source_lines}"
    )

    print(
        f"NEW CANDIDATES: "
        f"{new_candidates}"
    )

    print(
        f"TOTAL CANDIDATES: "
        f"{len(candidates)}"
    )

    print(
        f"NEW EVIDENCE: "
        f"{new_evidence}"
    )

    print(
        f"TOTAL EVIDENCE: "
        f"{len(evidence)}"
    )

    print(
        f"NEW CONCEPTS: 0"
    )

    print(
        f"TOTAL CONCEPTS: "
        f"{len(concepts)}"
    )

    print(
        f"NEW RELATIONS: 0"
    )

    print(
        f"TOTAL RELATIONS: "
        f"{len(relations)}"
    )

    print()

    print(
        f"MEMORY: {MEMORY_FILE}"
    )


if __name__ == "__main__":
    main()