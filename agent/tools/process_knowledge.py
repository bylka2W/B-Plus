import hashlib
import json
import pathlib
import re


SRC_ROOT = pathlib.Path(r"C:\B-Plus\zig\src")
INDEX_FILE = pathlib.Path(r"C:\B-Plus\agent\memory\source_index.txt")
STRUCTURED_FILE = pathlib.Path(r"C:\B-Plus\agent\memory\structured.json")


# ============================================================
# FILE HASH
# ============================================================

def sha256_file(path):
    h = hashlib.sha256()

    with path.open("rb") as f:
        for chunk in iter(
            lambda: f.read(1024 * 1024),
            b"",
        ):
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

    blocks = re.split(
        r"\n(?=FILE:\n)",
        text,
    )

    for block in blocks:

        match = re.search(
            r"FILE:\n([^\n]+)",
            block,
        )

        if not match:
            continue

        rel = match.group(1).strip()

        if (
            rel.endswith(".zig")
            and rel not in seen
        ):
            seen.add(rel)
            entries.append(rel)

    return entries


# ============================================================
# LINE NUMBER
# ============================================================

def line_number(text, position):
    return text.count(
        "\n",
        0,
        position,
    ) + 1


# ============================================================
# SYMBOL EXTRACTION
# ============================================================

def extract_symbols(text):
    symbols = []

    patterns = [
        (
            "function",
            r"\b(?:pub\s+)?fn\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)",
        ),
        (
            "const",
            r"\b(?:pub\s+)?const\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)"
            r"\s*=\s*"
            r"(?!struct\b|enum\b|union\b)",
        ),
        (
            "var",
            r"\b(?:pub\s+)?var\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)",
        ),
        (
            "struct",
            r"\b(?:pub\s+)?const\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)"
            r"\s*=\s*struct\b",
        ),
        (
            "enum",
            r"\b(?:pub\s+)?const\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)"
            r"\s*=\s*enum\b",
        ),
        (
            "union",
            r"\b(?:pub\s+)?const\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)"
            r"\s*=\s*union\b",
        ),
    ]

    for kind, pattern in patterns:

        for match in re.finditer(
            pattern,
            text,
        ):

            start = line_number(
                text,
                match.start(),
            )

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

        if key in seen:
            continue

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

        if item in seen:
            continue

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
# FAST CALL EXTRACTION
# ============================================================

def extract_calls(
    text,
    symbols=None,
    global_funcs=None,
):
    """
    Fast function-call extraction.

    Builds ONE compiled regex containing all known
    function names and scans the source only once.

    Compatible with:

        extract_calls(text)
        extract_calls(text, symbols)
        extract_calls(text, symbols, global_funcs)
    """

    if not text:
        return []

    if symbols is None:
        symbols = extract_symbols(text)

    function_names = {
        symbol["name"]
        for symbol in symbols
        if (
            symbol.get("kind") == "function"
            and symbol.get("name")
        )
    }

    if global_funcs:
        function_names.update(
            name
            for name in global_funcs.keys()
            if name
        )

    if not function_names:
        return []

    escaped_names = sorted(
        (
            re.escape(name)
            for name in function_names
        ),
        key=len,
        reverse=True,
    )

    pattern = re.compile(
        r"\b(?:"
        + "|".join(escaped_names)
        + r")\s*\("
    )

    lines = text.splitlines()

    results = []
    seen = set()

    for match in pattern.finditer(text):

        full = match.group(0)

        name = full[:-1].rstrip()

        if not name:
            continue

        line_no = line_number(
            text,
            match.start(),
        )

        line_index = max(
            0,
            min(
                line_no - 1,
                len(lines) - 1,
            ),
        )

        line_text = (
            lines[line_index]
            if lines
            else ""
        )

        stripped = line_text.strip()

        if not stripped:
            continue

        # ----------------------------------------------------
        # COMMENTS
        # ----------------------------------------------------

        if stripped.startswith("//"):
            continue

        # ----------------------------------------------------
        # FUNCTION DECLARATION
        # ----------------------------------------------------

        prefix = text[
            max(
                0,
                match.start() - 64,
            ):
            match.start()
        ]

        if re.search(
            r"\bfn\s+$",
            prefix,
        ):
            continue

        # ----------------------------------------------------
        # DEDUPLICATE
        # ----------------------------------------------------

        key = (
            name,
            line_no,
        )

        if key in seen:
            continue

        seen.add(key)

        results.append(
            {
                "name": name,
                "line": line_no,
                "text": stripped,
            }
        )

    return results


# ============================================================
# ROLE
# ============================================================

def make_role(rel):
    parts = pathlib.PureWindowsPath(
        rel
    ).parts

    lower = [
        p.lower()
        for p in parts
    ]

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
# ID / EVIDENCE / RELATIONS
# ============================================================

def _make_evidence(
    evidence_db,
    counters,
    source_id,
    line_start,
    line_end,
    snippet,
):
    evid_id = next_id(
        counters,
        "EVID",
    )

    evidence_db[evid_id] = {
        "file": source_id,
        "line_start": line_start,
        "line_end": line_end,
        "text": snippet,
    }

    return evid_id


def _add_relation(
    relations,
    counters,
    evidence_db,
    rel_type,
    source_id,
    fr,
    to,
    line_start,
    line_end,
    snippet,
):
    evid = _make_evidence(
        evidence_db,
        counters,
        source_id,
        line_start,
        line_end,
        snippet,
    )

    rel_id = next_id(
        counters,
        "REL",
    )

    relations[rel_id] = {
        "type": rel_type,
        "source": source_id,
        "from": fr,
        "to": to,
        "evidence": evid,
    }


# ============================================================
# EMPTY DATABASE
# ============================================================

def empty_database():
    return {
        "version": 1,
        "sources": {},
        "dependencies": {},
        "tests": {},
        "knowledge": {},
        "evidence": {},
        "relations": {},
    }


# ============================================================
# LOAD DATABASE
# ============================================================

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

        data.setdefault(
            "version",
            1,
        )

        data.setdefault(
            "sources",
            {},
        )

        data.setdefault(
            "dependencies",
            {},
        )

        data.setdefault(
            "tests",
            {},
        )

        data.setdefault(
            "knowledge",
            {},
        )

        data.setdefault(
            "evidence",
            {},
        )

        data.setdefault(
            "relations",
            {},
        )

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
        "REL": 0,
        "EVID": 0,
    }

    containers = {
        "SRC": structured["sources"],
        "DEP": structured["dependencies"],
        "TEST": structured["tests"],
        "KNOW": structured["knowledge"],
        "EVID": structured["evidence"],
        "REL": structured.get(
            "relations",
            {},
        ),
    }

    for prefix, container in containers.items():

        maximum = 0

        for key in container.keys():

            match = re.fullmatch(
                rf"{prefix}-(\d+)",
                key,
            )

            if not match:
                continue

            value = int(
                match.group(1)
            )

            if value > maximum:
                maximum = value

        counters[prefix] = maximum

    return counters


def next_id(counters, prefix):

    counters[prefix] += 1

    return (
        f"{prefix}-"
        f"{counters[prefix]:06d}"
    )


# ============================================================
# DELETE OLD DATA FOR SOURCE
# ============================================================

def remove_source_data(
    source_id,
    structured,
):
    dependencies = structured[
        "dependencies"
    ]

    tests = structured[
        "tests"
    ]

    knowledge = structured[
        "knowledge"
    ]

    evidence = structured[
        "evidence"
    ]

    relations = structured.get(
        "relations",
        {},
    )

    # --------------------------------------------------------
    # Dependencies
    # --------------------------------------------------------

    for dep_id in list(
        dependencies.keys()
    ):

        dep = dependencies[
            dep_id
        ]

        if dep.get("source") == source_id:
            del dependencies[
                dep_id
            ]

    # --------------------------------------------------------
    # Tests
    # --------------------------------------------------------

    for test_id in list(
        tests.keys()
    ):

        test = tests[
            test_id
        ]

        if test.get("file") == source_id:
            del tests[
                test_id
            ]

    # --------------------------------------------------------
    # Knowledge
    # --------------------------------------------------------

    knowledge_to_remove = []

    for know_id, know in knowledge.items():

        if know.get("file") == source_id:
            knowledge_to_remove.append(
                know_id
            )

    for know_id in knowledge_to_remove:

        know = knowledge.get(
            know_id
        )

        if know:

            evidence_id = know.get(
                "evidence"
            )

            if evidence_id in evidence:
                del evidence[
                    evidence_id
                ]

        del knowledge[
            know_id
        ]

    # --------------------------------------------------------
    # Relations
    # --------------------------------------------------------

    relations_to_remove = []

    for rel_id, relation in relations.items():

        if relation.get("source") == source_id:
            relations_to_remove.append(
                rel_id
            )

    for rel_id in relations_to_remove:

        relation = relations.get(
            rel_id
        )

        if relation:

            evidence_id = relation.get(
                "evidence"
            )

            if evidence_id in evidence:
                del evidence[
                    evidence_id
                ]

        del relations[
            rel_id
        ]


# ============================================================
# BUILD GLOBAL SYMBOL MAPS
# ============================================================

def build_global_symbol_maps(
    files,
    sources,
):
    """
    First pass over all source files.

    This is important because USES/CALLS relations can point
    to symbols defined in another file.

    The old implementation built global maps only from the
    existing database. On a fresh rebuild, this could cause
    cross-file relations to be missed depending on order.
    """

    global_funcs = {}
    global_structs = {}

    # --------------------------------------------------------
    # Existing knowledge
    # --------------------------------------------------------

    for source_id, source in sources.items():

        for symbol in source.get(
            "symbols",
            [],
        ):

            name = symbol.get(
                "name"
            )

            kind = symbol.get(
                "kind"
            )

            if not name:
                continue

            if kind == "function":

                global_funcs[
                    name
                ] = source_id

            elif kind == "struct":

                global_structs[
                    name
                ] = source_id

    # --------------------------------------------------------
    # Current source tree
    #
    # This makes the maps independent of processing order.
    # --------------------------------------------------------

    for rel in files:

        path = SRC_ROOT / rel

        if not path.exists():
            continue

        try:

            text = path.read_text(
                encoding="utf-8",
                errors="ignore",
            )

        except Exception:
            continue

        source_id = None

        for sid, source in sources.items():

            if source.get("path") == rel:
                source_id = sid
                break

        if source_id is None:
            continue

        symbols = extract_symbols(
            text
        )

        for symbol in symbols:

            name = symbol.get(
                "name"
            )

            kind = symbol.get(
                "kind"
            )

            if not name:
                continue

            if kind == "function":

                global_funcs[
                    name
                ] = source_id

            elif kind == "struct":

                global_structs[
                    name
                ] = source_id

    return (
        global_funcs,
        global_structs,
    )


# ============================================================
# PROCESS
# ============================================================

def process(force_rebuild=False):

    structured = load_existing()

    sources = structured[
        "sources"
    ]

    dependencies = structured[
        "dependencies"
    ]

    tests_db = structured[
        "tests"
    ]

    knowledge_db = structured[
        "knowledge"
    ]

    evidence_db = structured[
        "evidence"
    ]

    relations = structured.get(
        "relations",
        {},
    )

    counters = initialize_counters(
        structured
    )

    # --------------------------------------------------------
    # INDEX
    # --------------------------------------------------------

    files = read_index()

    # --------------------------------------------------------
    # PATH MAP
    # --------------------------------------------------------

    path_to_id = {
        source.get("path"): source_id
        for source_id, source
        in sources.items()
        if source.get("path")
    }

    # --------------------------------------------------------
    # GLOBAL SYMBOL MAPS
    #
    # Build from currently indexed source tree BEFORE relation
    # extraction.
    # --------------------------------------------------------

    global_funcs, global_structs = (
        build_global_symbol_maps(
            files,
            sources,
        )
    )

    # --------------------------------------------------------
    # STATS
    # --------------------------------------------------------

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
        "KNOWLEDGE_COUNT": 0,
        "RELATIONS_COUNT": 0,
        "CALLS_COUNT": 0,
        "USES_COUNT": 0,
        "CONTAINS_COUNT": 0,
    }

    stats[
        "FILES_FOUND"
    ] = len(files)

    current_paths = set(
        files
    )

    # ========================================================
    # PROCESS FILES
    # ========================================================

    for index, rel in enumerate(
        files,
        1,
    ):

        path = SRC_ROOT / rel

        try:

            # ------------------------------------------------
            # FILE EXISTS
            # ------------------------------------------------

            if not path.exists():

                stats[
                    "FILES_FAILED"
                ] += 1

                print(
                    f"[{index}/{len(files)}] "
                    f"MISSING: {rel}"
                )

                continue

            # ------------------------------------------------
            # READ
            # ------------------------------------------------

            text = path.read_text(
                encoding="utf-8",
                errors="ignore",
            )

            digest = sha256_file(
                path
            )

            source_id = path_to_id.get(
                rel
            )

            # ------------------------------------------------
            # NEW SOURCE
            # ------------------------------------------------

            if source_id is None:

                source_id = next_id(
                    counters,
                    "SRC",
                )

                path_to_id[
                    rel
                ] = source_id

                status = "NEW"

                stats[
                    "NEW"
                ] += 1

            # ------------------------------------------------
            # EXISTING SOURCE
            # ------------------------------------------------

            else:

                old = sources[
                    source_id
                ]

                if (
                    old.get("sha256")
                    == digest
                    and not force_rebuild
                ):

                    stats[
                        "UNCHANGED"
                    ] += 1

                    print(
                        f"[{index}/{len(files)}] "
                        f"UNCHANGED: {rel}"
                    )

                    continue

                if (
                    old.get("sha256")
                    == digest
                ):

                    status = "REBUILT"

                    stats[
                        "CHANGED"
                    ] += 1

                else:

                    status = "CHANGED"

                    stats[
                        "CHANGED"
                    ] += 1

                remove_source_data(
                    source_id,
                    structured,
                )

            # ------------------------------------------------
            # ANALYZE
            # ------------------------------------------------

            symbols = extract_symbols(
                text
            )

            imports = extract_imports(
                text
            )

            tests = extract_tests(
                text
            )

            # ------------------------------------------------
            # FAST CALL EXTRACTION
            # ------------------------------------------------

            calls = extract_calls(
                text,
                symbols,
                global_funcs,
            )

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
                            symbol[
                                "line_start"
                            ] - 1,
                            len(lines) - 1,
                        ),
                    )

                    snippet = lines[
                        line_index
                    ]

                else:

                    snippet = ""

                evidence_db[
                    evidence_id
                ] = {
                    "file": source_id,
                    "line_start": symbol[
                        "line_start"
                    ],
                    "line_end": symbol[
                        "line_end"
                    ],
                    "text": snippet,
                }

                knowledge_db[
                    know_id
                ] = {
                    "status": "VERIFIED",
                    "type": "symbol_definition",
                    "file": source_id,
                    "symbol": symbol[
                        "name"
                    ],
                    "kind": symbol[
                        "kind"
                    ],
                    "line_start": symbol[
                        "line_start"
                    ],
                    "line_end": symbol[
                        "line_end"
                    ],
                    "evidence": evidence_id,
                }

                source_knowledge.append(
                    know_id
                )

            # ------------------------------------------------
            # RELATIONS: CALLS
            # ------------------------------------------------

            for call in calls:

                caller = None

                call_line = call[
                    "line"
                ]

                # Find nearest function definition
                # above the call.
                for symbol in reversed(
                    symbols
                ):

                    if (
                        symbol["kind"]
                        != "function"
                    ):
                        continue

                    if (
                        symbol[
                            "line_start"
                        ]
                        <= call_line
                    ):
                        caller = symbol[
                            "name"
                        ]
                        break

                if caller is None:
                    caller = "<module>"

                called = call[
                    "name"
                ]

                line_no = call[
                    "line"
                ]

                snippet = call.get(
                    "text",
                    "",
                )

                _add_relation(
                    relations,
                    counters,
                    evidence_db,
                    "CALLS",
                    source_id,
                    caller,
                    called,
                    line_no,
                    line_no,
                    snippet,
                )

                stats[
                    "CALLS_COUNT"
                ] += 1

            # ------------------------------------------------
            # RELATIONS: CONTAINS
            # ------------------------------------------------

            for struct in symbols:

                if (
                    struct["kind"]
                    != "struct"
                ):
                    continue

                struct_name = struct[
                    "name"
                ]

                for sym in symbols:

                    if (
                        sym["kind"]
                        != "function"
                    ):
                        continue

                    # Support names that are represented
                    # as Struct.method.
                    if not sym[
                        "name"
                    ].startswith(
                        struct_name + "."
                    ):
                        continue

                    method_name = sym[
                        "name"
                    ]

                    line_no = sym[
                        "line_start"
                    ]

                    line_index = max(
                        0,
                        min(
                            line_no - 1,
                            len(lines) - 1,
                        ),
                    )

                    snippet = (
                        lines[
                            line_index
                        ].strip()
                        if lines
                        else ""
                    )

                    _add_relation(
                        relations,
                        counters,
                        evidence_db,
                        "CONTAINS",
                        source_id,
                        struct_name,
                        method_name,
                        line_no,
                        line_no,
                        snippet,
                    )

                    stats[
                        "CONTAINS_COUNT"
                    ] += 1

            # ------------------------------------------------
            # RELATIONS: USES
            #
            # Optimized:
            # Scan the source text once for identifiers instead of
            # compiling/scanning the whole source separately for
            # every known struct. This avoids the very expensive
            # O(number_of_structs * source_size) behavior that could
            # make --rebuild appear to hang.
            # ------------------------------------------------

            local_symbol_names = {
                s["name"]
                for s in symbols
            }

            struct_names = set(
                global_structs.keys()
            )

            # Exact identifier tokenizer. We only need to find names
            # that can be Zig identifiers, then check membership in
            # the known global struct set.
            identifier_pattern = re.compile(
                r"\b[A-Za-z_][A-Za-z0-9_]*\b"
            )

            # Avoid creating the same USES relation more than once
            # for the same source / struct / line.
            uses_seen = set()

            for match in identifier_pattern.finditer(text):

                struct_name = match.group(0)

                if struct_name not in struct_names:
                    continue

                line_no = line_number(
                    text,
                    match.start(),
                )

                line_index = max(
                    0,
                    min(
                        line_no - 1,
                        len(lines) - 1,
                    ),
                )

                snippet = (
                    lines[line_index].strip()
                    if lines
                    else ""
                )

                if not snippet:
                    continue

                # ------------------------------------------------
                # Do not create USES for the actual struct
                # declaration:
                #
                # pub const GPUScheduler = struct {
                # ------------------------------------------------

                if re.search(
                    r"\b(?:pub\s+)?const\s+"
                    + re.escape(struct_name)
                    + r"\s*=\s*struct\b",
                    snippet,
                ):
                    continue

                key = (
                    source_id,
                    struct_name,
                    line_no,
                )

                if key in uses_seen:
                    continue

                uses_seen.add(key)

                _add_relation(
                    relations,
                    counters,
                    evidence_db,
                    "USES",
                    source_id,
                    struct_name,
                    struct_name,
                    line_no,
                    line_no,
                    snippet,
                )

                stats[
                    "USES_COUNT"
                ] += 1

            # ------------------------------------------------
            # STATS
            # ------------------------------------------------

            stats[
                "FILES_ANALYZED"
            ] += 1

            stats[
                "SYMBOLS_COUNT"
            ] += len(symbols)

            # ------------------------------------------------
            # DEPENDENCIES
            # ------------------------------------------------

            for imported in imports:

                dep_id = next_id(
                    counters,
                    "DEP",
                )

                dependencies[
                    dep_id
                ] = {
                    "source": source_id,
                    "target": imported,
                }

                source_dependencies.append(
                    dep_id
                )

            # ------------------------------------------------
            # TESTS
            # ------------------------------------------------

            for test in tests:

                test_id = next_id(
                    counters,
                    "TEST",
                )

                tests_db[
                    test_id
                ] = {
                    "file": source_id,
                    "name": test[
                        "name"
                    ],
                    "line": test[
                        "line"
                    ],
                }

                source_tests.append(
                    test_id
                )

            # ------------------------------------------------
            # SOURCE RECORD
            # ------------------------------------------------

            sources[
                source_id
            ] = {
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

            print(
                f"[{index}/{len(files)}] "
                f"{status}: {rel}"
            )

        except Exception as exc:

            stats[
                "FILES_FAILED"
            ] += 1

            print(
                f"[{index}/{len(files)}] "
                f"ERROR: {rel}"
            )

            print(
                f"    {type(exc).__name__}: "
                f"{exc}"
            )

    # ========================================================
    # REMOVED FILES
    # ========================================================

    for source_id in list(
        sources.keys()
    ):

        source = sources[
            source_id
        ]

        rel = source.get(
            "path"
        )

        if rel not in current_paths:

            remove_source_data(
                source_id,
                structured,
            )

            source[
                "status"
            ] = "REMOVED"

            stats[
                "REMOVED"
            ] += 1

    # ========================================================
    # FINAL COUNTS
    # ========================================================

    stats[
        "DEPENDENCIES_COUNT"
    ] = len(
        dependencies
    )

    stats[
        "EVIDENCE_COUNT"
    ] = len(
        evidence_db
    )

    stats[
        "TESTS_COUNT"
    ] = len(
        tests_db
    )

    stats[
        "KNOWLEDGE_COUNT"
    ] = len(
        knowledge_db
    )

    stats[
        "RELATIONS_COUNT"
    ] = len(
        relations
    )

    structured[
        "version"
    ] = 1

    structured[
        "stats"
    ] = stats

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

    print(
        "=========================================="
    )

    print(
        "       B+ KNOWLEDGE BUILD COMPLETE"
    )

    print(
        "=========================================="
    )

    for key, value in stats.items():

        print(
            f"{key:22} {value}"
        )

    print()

    print(
        f"SOURCES:      "
        f"{len(sources)}"
    )

    print(
        f"KNOWLEDGE:    "
        f"{len(knowledge_db)}"
    )

    print(
        f"EVIDENCE:     "
        f"{len(evidence_db)}"
    )

    print(
        f"DEPENDENCIES: "
        f"{len(dependencies)}"
    )

    print(
        f"TESTS:        "
        f"{len(tests_db)}"
    )

    print(
        f"RELATIONS:    "
        f"{len(relations)}"
    )

    print()

    print(
        f"STRUCTURED_FILE: "
        f"{STRUCTURED_FILE}"
    )


# ============================================================
# QUERY HELPERS
# ============================================================

def query_tokens(query):
    """
    Convert a natural query into searchable tokens.

    Examples:

        "USES GPUScheduler"
            -> ["uses", "gpuscheduler"]

        "CALLS init"
            -> ["calls", "init"]

        "runtime scheduler"
            -> ["runtime", "scheduler"]
    """

    return [
        token.lower()
        for token in re.findall(
            r"[A-Za-z_][A-Za-z0-9_.]*",
            query,
        )
        if token
    ]


def query_matches_fact(
    query,
    fact,
):
    lowered = query.lower()

    fields = [
        fact.get("type"),
        fact.get("symbol"),
        fact.get("name"),
        fact.get("kind"),
    ]

    # --------------------------------------------------------
    # Original exact-substring behavior
    # --------------------------------------------------------

    for field in fields:

        if not field:
            continue

        if lowered in str(
            field
        ).lower():
            return True

    # --------------------------------------------------------
    # Token-based behavior
    #
    # Allows:
    #
    #     "struct GPUScheduler"
    #
    # to match:
    #
    #     type = symbol_definition
    #     symbol = GPUScheduler
    #     kind = struct
    # --------------------------------------------------------

    tokens = query_tokens(
        query
    )

    if not tokens:
        return False

    normalized_fields = [
        str(field).lower()
        for field in fields
        if field
    ]

    return all(
        any(
            token in field
            for field in normalized_fields
        )
        for token in tokens
    )


# ============================================================
# QUERY RELATION MATCHING
# ============================================================

def query_matches_relation(
    query,
    relation,
):
    """
    Match a relation against a compound query.

    Examples:

        USES GPUScheduler

        CALLS init

        CALLS runGPUScheduler

    Relation:

        type = USES
        from = GPUScheduler
        to   = GPUScheduler

    The query is split into tokens and every token must
    match at least one relation field.
    """

    tokens = query_tokens(
        query
    )

    if not tokens:
        return False

    values = [
        relation.get("type"),
        relation.get("from"),
        relation.get("to"),
        relation.get("source"),
    ]

    normalized_values = [
        str(value).lower()
        for value in values
        if value
    ]

    return all(
        any(
            token in value
            for value in normalized_values
        )
        for token in tokens
    )


# ============================================================
# QUERY
# ============================================================

def handle_query(query):
    """
    Query structured.json.

    Searches:

      - knowledge
      - relations
      - source paths

    Supports compound queries such as:

        USES GPUScheduler
        CALLS init
        CALLS submit
        struct GPUScheduler
    """

    structured = load_existing()

    knowledge_db = structured.get(
        "knowledge",
        {},
    )

    evidence_db = structured.get(
        "evidence",
        {},
    )

    sources_db = structured.get(
        "sources",
        {},
    )

    relations_db = structured.get(
        "relations",
        {},
    )

    if not query:

        print(
            "Usage:"
        )

        print(
            "  py tools\\process_knowledge.py "
            "--query <name>"
        )

        return

    lowered = query.lower()

    # ========================================================
    # KNOWLEDGE
    # ========================================================

    matches = []

    for fact_id, fact in knowledge_db.items():

        if query_matches_fact(
            query,
            fact,
        ):

            matches.append(
                (
                    fact_id,
                    fact,
                )
            )

    # ========================================================
    # RELATIONS
    # ========================================================

    relation_matches = []

    for rel_id, relation in relations_db.items():

        if query_matches_relation(
            query,
            relation,
        ):

            relation_matches.append(
                (
                    rel_id,
                    relation,
                )
            )

    # ========================================================
    # SOURCE PATHS
    # ========================================================

    source_matches = []

    source_tokens = query_tokens(
        query
    )

    for source_id, source in sources_db.items():

        path = source.get(
            "path",
            "",
        )

        if not path:
            continue

        path_lower = path.lower()

        # Direct query match.
        if lowered in path_lower:

            source_matches.append(
                (
                    source_id,
                    source,
                )
            )

            continue

        # Token match.
        if source_tokens and all(
            token in path_lower
            for token in source_tokens
        ):

            source_matches.append(
                (
                    source_id,
                    source,
                )
            )

    # ========================================================
    # NOTHING FOUND
    # ========================================================

    if (
        not matches
        and not relation_matches
        and not source_matches
    ):

        print(
            f'No knowledge found for query: '
            f'"{query}"'
        )

        return

    # ========================================================
    # FACTS
    # ========================================================

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
                f"  EVIDENCE: "
                f"{evidence_id}"
            )

            file_id = evidence.get(
                "file"
            )

            if file_id:

                print(
                    f"    FILE: "
                    f"{file_id}"
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
                    f"{line_start}-"
                    f"{line_end}"
                )

            source = sources_db.get(
                file_id,
                {},
            )

            path = source.get(
                "path"
            )

            if path:

                print(
                    f"    PATH: "
                    f"{path}"
                )

            sha = source.get(
                "sha256"
            )

            if sha:

                print(
                    f"    SHA256: "
                    f"{sha}"
                )

            evidence_text = evidence.get(
                "text"
            )

            if evidence_text:

                print(
                    f"    TEXT: "
                    f"{evidence_text.strip()}"
                )

        print()

    # ========================================================
    # RELATIONS
    # ========================================================

    if relation_matches:

        print(
            "=========================================="
        )

        print(
            "RELATIONS"
        )

        print(
            "=========================================="
        )

        for rel_id, relation in relation_matches:

            print(
                f"RELATION {rel_id}"
            )

            print(
                f"  TYPE: "
                f"{relation.get('type')}"
            )

            print(
                f"  SOURCE: "
                f"{relation.get('source')}"
            )

            print(
                f"  FROM: "
                f"{relation.get('from')}"
            )

            print(
                f"  TO: "
                f"{relation.get('to')}"
            )

            evidence_id = relation.get(
                "evidence"
            )

            if evidence_id:

                evidence = evidence_db.get(
                    evidence_id,
                    {},
                )

                file_id = evidence.get(
                    "file"
                )

                print(
                    f"  EVIDENCE: "
                    f"{evidence_id}"
                )

                if file_id:

                    print(
                        f"    FILE: "
                        f"{file_id}"
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
                        f"{line_start}-"
                        f"{line_end}"
                    )

                evidence_text = evidence.get(
                    "text"
                )

                if evidence_text:

                    print(
                        f"    TEXT: "
                        f"{evidence_text.strip()}"
                    )

            source = sources_db.get(
                relation.get("source"),
                {},
            )

            path = source.get(
                "path"
            )

            if path:

                print(
                    f"    PATH: "
                    f"{path}"
                )

            print()

    # ========================================================
    # SOURCES
    # ========================================================

    if source_matches:

        print(
            "=========================================="
        )

        print(
            "SOURCE FILES"
        )

        print(
            "=========================================="
        )

        for source_id, source in source_matches:

            print(
                f"SOURCE {source_id}"
            )

            print(
                f"  PATH: "
                f"{source.get('path')}"
            )

            print(
                f"  ROLE: "
                f"{source.get('role')}"
            )

            print(
                f"  STATUS: "
                f"{source.get('status')}"
            )

            print(
                f"  LINES: "
                f"{source.get('lines')}"
            )

            print(
                f"  SYMBOLS: "
                f"{len(source.get('symbols', []))}"
            )

            print()


# ============================================================
# INFO
# ============================================================

def handle_info():

    structured = load_existing()

    sources = structured.get(
        "sources",
        {},
    )

    dependencies = structured.get(
        "dependencies",
        {},
    )

    tests = structured.get(
        "tests",
        {},
    )

    knowledge = structured.get(
        "knowledge",
        {},
    )

    evidence = structured.get(
        "evidence",
        {},
    )

    relations = structured.get(
        "relations",
        {},
    )

    stats = structured.get(
        "stats",
        {},
    )

    print()

    print(
        "=========================================="
    )

    print(
        "       B+ KNOWLEDGE DATABASE INFO"
    )

    print(
        "=========================================="
    )

    print(
        f"SOURCES:      {len(sources)}"
    )

    print(
        f"KNOWLEDGE:    {len(knowledge)}"
    )

    print(
        f"EVIDENCE:     {len(evidence)}"
    )

    print(
        f"DEPENDENCIES: {len(dependencies)}"
    )

    print(
        f"TESTS:        {len(tests)}"
    )

    print(
        f"RELATIONS:    {len(relations)}"
    )

    print()

    for key, value in stats.items():

        print(
            f"{key:22} {value}"
        )

    print()

    print(
        f"STRUCTURED_FILE:"
    )

    print(
        f"  {STRUCTURED_FILE}"
    )

    print()


# ============================================================
# MAIN
# ============================================================

def main():

    import sys

    # --------------------------------------------------------
    # QUERY
    # --------------------------------------------------------

    if (
        len(sys.argv) > 1
        and sys.argv[1] == "--query"
    ):

        query = (
            sys.argv[2]
            if len(sys.argv) > 2
            else ""
        )

        handle_query(
            query
        )

        return

    # --------------------------------------------------------
    # INFO
    # --------------------------------------------------------

    if (
        len(sys.argv) > 1
        and sys.argv[1] == "--info"
    ):

        handle_info()

        return

    # --------------------------------------------------------
    # REBUILD
    # --------------------------------------------------------

    if (
        len(sys.argv) > 1
        and sys.argv[1] == "--rebuild"
    ):

        process(
            force_rebuild=True
        )

        return

    # --------------------------------------------------------
    # NORMAL BUILD
    # --------------------------------------------------------

    process()


# ============================================================
# ENTRY POINT
# ============================================================

if __name__ == "__main__":
    main()