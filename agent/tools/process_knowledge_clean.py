import hashlib
import json
import pathlib
import re
import sys


SRC_ROOT = pathlib.Path(r"C:\B-Plus\zig\src")
INDEX_FILE = pathlib.Path(r"C:\B-Plus\agent\memory\source_index.txt")
STRUCTURED_FILE = pathlib.Path(r"C:\B-Plus\agent\memory\structured.json")


# ============================================================
# FILE HASH
# ============================================================

def sha256_file(path):
    h = hashlib.sha256()

    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)

    return h.hexdigest()


# ============================================================
# INDEX
# ============================================================

def read_index():
    if not INDEX_FILE.exists():
        raise FileNotFoundError(INDEX_FILE)

    text = INDEX_FILE.read_text(
        encoding="utf-8",
        errors="ignore",
    )

    entries = []
    seen = set()

    blocks = re.split(r"\n(?=FILE:\n)", text)

    for block in blocks:
        match = re.search(r"FILE:\n([^\n]+)", block)

        if not match:
            continue

        rel = match.group(1).strip()

        if rel.endswith(".zig") and rel not in seen:
            seen.add(rel)
            entries.append(rel)

    return entries


# ============================================================
# LINE NUMBER
# ============================================================

def line_number(text, position):
    return text.count("\n", 0, position) + 1


# ============================================================
# SYMBOL EXTRACTION
# ============================================================

def extract_symbols(text):
    symbols = []

    patterns = [
        (
            "function",
            r"\b(?:pub\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)",
        ),
        (
            "const",
            r"\b(?:pub\s+)?const\s+([A-Za-z_][A-Za-z0-9_]*)"
            r"\s*=\s*(?!struct\b|enum\b|union\b)",
        ),
        (
            "var",
            r"\b(?:pub\s+)?var\s+([A-Za-z_][A-Za-z0-9_]*)",
        ),
        (
            "struct",
            r"\b(?:pub\s+)?const\s+([A-Za-z_][A-Za-z0-9_]*)"
            r"\s*=\s*struct\b",
        ),
        (
            "enum",
            r"\b(?:pub\s+)?const\s+([A-Za-z_][A-Za-z0-9_]*)"
            r"\s*=\s*enum\b",
        ),
        (
            "union",
            r"\b(?:pub\s+)?const\s+([A-Za-z_][A-Za-z0-9_]*)"
            r"\s*=\s*union\b",
        ),
    ]

    for kind, pattern in patterns:
        for match in re.finditer(pattern, text):
            start = line_number(text, match.start())

            symbols.append(
                {
                    "name": match.group(1),
                    "kind": kind,
                    "line_start": start,
                    "line_end": start,
                }
            )

    symbols.sort(
        key=lambda x: (
            x["line_start"],
            x["name"],
            x["kind"],
        )
    )

    unique = []
    seen = set()

    for symbol in symbols:
        key = (
            symbol["name"],
            symbol["kind"],
            symbol["line_start"],
        )

        if key not in seen:
            seen.add(key)
            unique.append(symbol)

    return unique


# ============================================================
# IMPORT EXTRACTION
# ============================================================

def extract_imports(text):
    imports = []

    imports.extend(
        re.findall(
            r'@import\s*\(\s*"([^"]+)"\s*\)',
            text,
        )
    )

    imports.extend(
        re.findall(
            r'@import\s+"([^"]+)"',
            text,
        )
    )

    result = []
    seen = set()

    for item in imports:
        if item not in seen:
            seen.add(item)
            result.append(item)

    return result


# ============================================================
# TEST EXTRACTION
# ============================================================

def extract_tests(text):
    result = []

    for match in re.finditer(
        r'test\s+"([^"]+)"',
        text,
    ):
        result.append(
            {
                "name": match.group(1),
                "line": line_number(
                    text,
                    match.start(),
                ),
            }
        )

    return result


# ============================================================
# ROLE
# ============================================================

def make_role(rel):
    parts = pathlib.PureWindowsPath(rel).parts
    lower = [p.lower() for p in parts]

    if "frontend" in lower:
        return "frontend"

    if "parser" in lower:
        return "parser"

    if "lexer" in lower:
        return "lexer"

    if "runtime" in lower:
        return "runtime"

    if "backend" in lower:
        return "backend"

    if "hir" in lower:
        return "hir"

    if "thir" in lower:
        return "thir"

    if "bir" in lower:
        return "bir"

    if "mir" in lower:
        return "mir"

    if "plan" in lower:
        return "plan"

    if "metal" in lower:
        return "metal"

    if "compiler" in lower:
        return "compiler"

    return "module"


# ============================================================
# DATABASE
# ============================================================

def empty_database():
    return {
        "version": 1,
        "sources": {},
        "dependencies": {},
        "tests": {},
        "knowledge": {},
        "evidence": {},
    }


def load_existing():
    if not STRUCTURED_FILE.exists():
        return empty_database()

    try:
        data = json.loads(
            STRUCTURED_FILE.read_text(
                encoding="utf-8",
                errors="ignore",
            )
        )

        if not isinstance(data, dict):
            return empty_database()

        data.setdefault("version", 1)
        data.setdefault("sources", {})
        data.setdefault("dependencies", {})
        data.setdefault("tests", {})
        data.setdefault("knowledge", {})
        data.setdefault("evidence", {})

        return data

    except Exception:
        print(
            "WARNING: structured.json is invalid. "
            "Starting fresh."
        )
        return empty_database()


# ============================================================
# COUNTERS
# ============================================================

def initialize_counters(structured):
    counters = {
        "SRC": 0,
        "DEP": 0,
        "TEST": 0,
        "KNOW": 0,
        "EVID": 0,
    }

    containers = {
        "SRC": structured["sources"],
        "DEP": structured["dependencies"],
        "TEST": structured["tests"],
        "KNOW": structured["knowledge"],
        "EVID": structured["evidence"],
    }

    for prefix, container in containers.items():
        maximum = 0

        for key in container.keys():
            match = re.fullmatch(
                rf"{prefix}-(\d+)",
                key,
            )

            if match:
                value = int(match.group(1))

                if value > maximum:
                    maximum = value

        counters[prefix] = maximum

    return counters


def next_id(counters, prefix):
    counters[prefix] += 1
    return f"{prefix}-{counters[prefix]:06d}"


# ============================================================
# DELETE OLD DATA FOR SOURCE
# ============================================================

def remove_source_data(source_id, structured):
    dependencies = structured["dependencies"]
    tests = structured["tests"]
    knowledge = structured["knowledge"]
    evidence = structured["evidence"]

    # Dependencies
    for dep_id in list(dependencies.keys()):
        dep = dependencies[dep_id]

        if dep.get("source") == source_id:
            del dependencies[dep_id]

    # Tests
    for test_id in list(tests.keys()):
        test = tests[test_id]

        if test.get("file") == source_id:
            del tests[test_id]

    # Knowledge + evidence
    knowledge_to_remove = []

    for know_id, know in knowledge.items():
        if know.get("file") == source_id:
            knowledge_to_remove.append(know_id)

    for know_id in knowledge_to_remove:
        know = knowledge.get(know_id)

        if know:
            evidence_id = know.get("evidence")

            if evidence_id in evidence:
                del evidence[evidence_id]

        del knowledge[know_id]


# ============================================================
# PROCESS
# ============================================================

def process(force_rebuild=False):
    structured = load_existing()

    sources = structured["sources"]
    dependencies = structured["dependencies"]
    tests_db = structured["tests"]
    knowledge_db = structured["knowledge"]
    evidence_db = structured["evidence"]

    counters = initialize_counters(structured)

    path_to_id = {
        source.get("path"): source_id
        for source_id, source in sources.items()
        if source.get("path")
    }

    stats = {
        "FILES_FOUND": 0,
        "FILES_ANALYZED": 0,
        "FILES_FAILED": 0,
        "NEW": 0,
        "CHANGED": 0,
        "UNCHANGED": 0,
        "REMOVED": 0,
        "SYMBOLS_COUNT": 0,
        "DEPENDENCIES_COUNT": 0,
        "EVIDENCE_COUNT": 0,
        "TESTS_COUNT": 0,
        "REBUILT": 0,
    }

    files = read_index()

    stats["FILES_FOUND"] = len(files)

    current_paths = set(files)

    # ========================================================
    # PROCESS FILES
    # ========================================================

    for index, rel in enumerate(files, 1):

        path = SRC_ROOT / rel

        try:
            if not path.exists():
                stats["FILES_FAILED"] += 1

                print(
                    f"[{index}/{len(files)}] MISSING: {rel}"
                )

                continue

            text = path.read_text(
                encoding="utf-8",
                errors="ignore",
            )

            digest = sha256_file(path)

            source_id = path_to_id.get(rel)

            # ------------------------------------------------
            # NEW SOURCE
            # ------------------------------------------------

            if source_id is None:
                source_id = next_id(
                    counters,
                    "SRC",
                )

                path_to_id[rel] = source_id

                status = "NEW"

                stats["NEW"] += 1

            # ------------------------------------------------
            # EXISTING SOURCE
            # ------------------------------------------------

            else:
                old = sources[source_id]

                old_digest = old.get("sha256")

                if old_digest == digest and not force_rebuild:
                    status = "UNCHANGED"

                    stats["UNCHANGED"] += 1

                    print(
                        f"[{index}/{len(files)}] "
                        f"{status}: {rel}"
                    )

                    continue

                if old_digest == digest and force_rebuild:
                    status = "REBUILT"

                    stats["REBUILT"] += 1

                    remove_source_data(
                        source_id,
                        structured,
                    )

                else:
                    status = "CHANGED"

                    stats["CHANGED"] += 1

                    remove_source_data(
                        source_id,
                        structured,
                    )

            # ------------------------------------------------
            # ANALYZE
            # ------------------------------------------------

            symbols = extract_symbols(text)
            imports = extract_imports(text)
            tests = extract_tests(text)

            source_knowledge = []
            source_dependencies = []
            source_tests = []

            lines = text.splitlines()

            # ------------------------------------------------
            # SYMBOLS / KNOWLEDGE
            # ------------------------------------------------

            for symbol in symbols:

                know_id = next_id(
                    counters,
                    "KNOW",
                )

                evidence_id = next_id(
                    counters,
                    "EVID",
                )

                if lines:
                    line_index = max(
                        0,
                        min(
                            symbol["line_start"] - 1,
                            len(lines) - 1,
                        ),
                    )

                    snippet = lines[line_index]

                else:
                    snippet = ""

                evidence_db[evidence_id] = {
                    "file": source_id,
                    "line_start": symbol["line_start"],
                    "line_end": symbol["line_end"],
                    "text": snippet,
                }

                knowledge_db[know_id] = {
                    "status": "VERIFIED",
                    "type": "symbol_definition",
                    "file": source_id,
                    "symbol": symbol["name"],
                    "kind": symbol["kind"],
                    "line_start": symbol["line_start"],
                    "line_end": symbol["line_end"],
                    "evidence": evidence_id,
                }

                source_knowledge.append(know_id)

            # ------------------------------------------------
            # DEPENDENCIES
            # ------------------------------------------------

            for imported in imports:

                dep_id = next_id(
                    counters,
                    "DEP",
                )

                dependencies[dep_id] = {
                    "source": source_id,
                    "target": imported,
                }

                source_dependencies.append(dep_id)

            # ------------------------------------------------
            # TESTS
            # ------------------------------------------------

            for test in tests:

                test_id = next_id(
                    counters,
                    "TEST",
                )

                tests_db[test_id] = {
                    "file": source_id,
                    "name": test["name"],
                    "line": test["line"],
                }

                source_tests.append(test_id)

            # ------------------------------------------------
            # SOURCE RECORD
            # ------------------------------------------------

            sources[source_id] = {
                "path": rel,
                "sha256": digest,
                "size": path.stat().st_size,
                "lines": len(lines),
                "status": status,
                "role": make_role(rel),
                "symbols": symbols,
                "dependencies": source_dependencies,
                "tests": source_tests,
                "knowledge": source_knowledge,
            }

            stats["FILES_ANALYZED"] += 1
            stats["SYMBOLS_COUNT"] += len(symbols)

            print(
                f"[{index}/{len(files)}] {status}: {rel}"
            )

        except Exception as exc:
            stats["FILES_FAILED"] += 1

            print(
                f"[{index}/{len(files)}] ERROR: {rel}"
            )

            print(
                f"    {type(exc).__name__}: {exc}"
            )

    # ========================================================
    # REMOVED FILES
    # ========================================================

    for source_id in list(sources.keys()):

        source = sources[source_id]

        rel = source.get("path")

        if rel not in current_paths:

            remove_source_data(
                source_id,
                structured,
            )

            source["status"] = "REMOVED"

            stats["REMOVED"] += 1

    # ========================================================
    # FINAL COUNTS
    # ========================================================

    stats["DEPENDENCIES_COUNT"] = len(
        dependencies
    )

    stats["EVIDENCE_COUNT"] = len(
        evidence_db
    )

    stats["TESTS_COUNT"] = len(
        tests_db
    )

    stats["KNOWLEDGE_COUNT"] = len(
        knowledge_db
    )

    structured["version"] = 1
    structured["stats"] = stats

    # ========================================================
    # WRITE DATABASE
    # ========================================================

    STRUCTURED_FILE.write_text(
        json.dumps(
            structured,
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    # ========================================================
    # SUMMARY
    # ========================================================

    print()
    print("==========================================")
    print("       B+ KNOWLEDGE BUILD COMPLETE")
    print("==========================================")

    for key, value in stats.items():
        print(
            f"{key:22} {value}"
        )

    print()
    print(
        f"SOURCES:      {len(sources)}"
    )

    print(
        f"KNOWLEDGE:    {len(knowledge_db)}"
    )

    print(
        f"EVIDENCE:     {len(evidence_db)}"
    )

    print(
        f"DEPENDENCIES: {len(dependencies)}"
    )

    print(
        f"TESTS:        {len(tests_db)}"
    )

    print()
    print(
        f"STRUCTURED_FILE: {STRUCTURED_FILE}"
    )


# ============================================================
# QUERY
# ============================================================

def handle_query(query):
    """Search existing structured knowledge."""

    structured = load_existing()

    if "knowledge" not in structured:
        print("No knowledge available.")
        return

    knowledge_db = structured["knowledge"]
    evidence_db = structured.get("evidence", {})
    sources_db = structured.get("sources", {})

    matches = []

    lowered = query.lower()

    for fact_id, fact in knowledge_db.items():

        fields = [
            fact.get("type"),
            fact.get("symbol"),
            fact.get("name"),
            fact.get("kind"),
        ]

        if any(
            field
            and lowered in str(field).lower()
            for field in fields
        ):
            matches.append(
                (fact_id, fact)
            )

    if not matches:
        print(
            f'No knowledge found for query: "{query}"'
        )
        return

    for fact_id, fact in matches:

        status = fact.get(
            "status",
            "UNKNOWN",
        )

        evidence_id = fact.get(
            "evidence"
        )

        print(
            f"FACT {fact_id}"
        )

        print()

        for key, value in fact.items():

            if key == "evidence":
                continue

            print(
                f"  {key}: {value}"
            )

        print(
            f"  STATUS: {status}"
        )

        if evidence_id:

            evidence = evidence_db.get(
                evidence_id,
                {},
            )

            print(
                f"  EVIDENCE: {evidence_id}"
            )

            file_id = evidence.get(
                "file"
            )

            if file_id:

                print(
                    f"    FILE: {file_id}"
                )

            line_start = evidence.get(
                "line_start"
            )

            line_end = evidence.get(
                "line_end"
            )

            if (
                line_start is not None
                and line_end is not None
            ):
                print(
                    f"    LINES: "
                    f"{line_start}-{line_end}"
                )

            source = sources_db.get(
                file_id,
                {},
            )

            sha = source.get(
                "sha256"
            )

            if sha:
                print(
                    f"    SHA256: {sha}"
                )

        print()


# ============================================================
# MAIN
# ============================================================

def main():

    if len(sys.argv) > 1:

        command = sys.argv[1]

        if command == "--query":

            query = (
                sys.argv[2]
                if len(sys.argv) > 2
                else ""
            )

            handle_query(query)
            return

        if command == "--rebuild":

            process(
                force_rebuild=True
            )

            return

    process(
        force_rebuild=False
    )


if __name__ == "__main__":
    main()