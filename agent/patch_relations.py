from pathlib import Path

path = Path(r"C:\B-Plus\agent\tools\process_knowledge.py")

text = path.read_text(encoding="utf-8")


# ============================================================
# 1. DATABASE: add relations
# ============================================================

old = '''        "knowledge": {},
        "evidence": {},
    }'''

new = '''        "knowledge": {},
        "evidence": {},
        "relations": {},
    }'''

if old in text:
    text = text.replace(old, new, 1)
elif '"relations": {}' not in text:
    raise SystemExit("ERROR: empty_database() pattern not found")


# ============================================================
# 2. COUNTER: REL
# ============================================================

old = '''        "KNOW": 0,
        "EVID": 0,
        "DEP": 0,
        "TEST": 0,
    }'''

new = '''        "KNOW": 0,
        "EVID": 0,
        "DEP": 0,
        "TEST": 0,
        "REL": 0,
    }'''

if old in text:
    text = text.replace(old, new, 1)
elif '"REL": 0' not in text:
    raise SystemExit("ERROR: initialise_counters() pattern not found")


# ============================================================
# 3. HELPERS
# ============================================================

marker = '''# ============================================================
# PROCESS
# ============================================================
'''

helpers = r'''
# ============================================================
# RELATIONS
# ============================================================

def add_relation(
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
    evid_id = next_id(counters, "EVID")

    evidence_db[evid_id] = {
        "file": source_id,
        "line_start": line_start,
        "line_end": line_end,
        "text": snippet,
    }

    rel_id = next_id(counters, "REL")

    relations[rel_id] = {
        "type": rel_type,
        "source": source_id,
        "from": fr,
        "to": to,
        "evidence": evid_id,
    }

    return rel_id


def find_call_in_text(text, start_line, target_name):
    pattern = r"\b" + re.escape(target_name) + r"\s*\("
    lines = text.splitlines()

    for idx in range(
        max(0, start_line - 1),
        len(lines),
    ):
        line = lines[idx]

        stripped = line.strip()

        if stripped.startswith("//"):
            continue

        if re.search(pattern, line):
            return idx + 1, line

    return None, None


def find_symbol_in_text(text, symbol_name):
    pattern = r"\b" + re.escape(symbol_name) + r"\b"
    return re.search(pattern, text)


'''

if "def add_relation(" not in text:
    if marker not in text:
        raise SystemExit("ERROR: PROCESS marker not found")

    text = text.replace(
        marker,
        helpers + marker,
        1,
    )


# ============================================================
# 4. RELATIONS DATABASE INSIDE process()
# ============================================================

needle = '''    counters = initialise_counters(
        structured
    )
'''

if needle not in text:
    raise SystemExit(
        "ERROR: counters initialisation not found"
    )

replacement = needle + r'''

    relations = structured.get(
        "relations",
        {},
    )

    # --------------------------------------------------------
    # GLOBAL SYMBOL MAPS
    # --------------------------------------------------------

    global_funcs = {}
    global_structs = {}

    for k_id, k in knowledge_db.items():

        if k.get("type") != "symbol_definition":
            continue

        name = k.get("symbol")
        kind = k.get("kind")

        if not name:
            continue

        if kind == "function":
            global_funcs[name] = k.get("file")

        elif kind == "struct":
            global_structs[name] = k.get("file")

'''

if "relations = structured.get(" in text:
    print("INFO: relations database already exists")
else:
    text = text.replace(
        needle,
        replacement,
        1,
    )


# ============================================================
# 5. RELATION GENERATION
# ============================================================

# We insert this immediately after:
#
#     source_knowledge = []
#     source_dependencies = []
#     source_tests = []
#
# because symbols/text are already available there.

needle = '''            source_knowledge = []
            source_dependencies = []
            source_tests = []
'''

relation_block = r'''
            # ------------------------------------------------
            # RELATIONS
            # ------------------------------------------------

            source_symbols = symbols

            local_funcs = [
                s for s in source_symbols
                if s["kind"] == "function"
            ]

            local_structs = [
                s for s in source_symbols
                if s["kind"] == "struct"
            ]

            # ------------------------------------------------
            # CONTAINS
            # ------------------------------------------------

            for symbol in source_symbols:

                rel_id = add_relation(
                    relations,
                    counters,
                    evidence_db,
                    "CONTAINS",
                    source_id,
                    source_id,
                    symbol["name"],
                    symbol["line_start"],
                    symbol["line_end"],
                    lines[symbol["line_start"] - 1]
                    if lines
                    and symbol["line_start"] <= len(lines)
                    else "",
                )

            # ------------------------------------------------
            # CALLS
            # ------------------------------------------------

            for caller in local_funcs:

                caller_name = caller["name"]

                for callee_name, callee_file in global_funcs.items():

                    if callee_name == caller_name:
                        continue

                    line_start, snippet = find_call_in_text(
                        text,
                        caller["line_start"],
                        callee_name,
                    )

                    if line_start is None:
                        continue

                    # Don't create an obvious self/file noise relation.
                    if (
                        callee_file is None
                        or callee_file == source_id
                    ):
                        pass

                    add_relation(
                        relations,
                        counters,
                        evidence_db,
                        "CALLS",
                        source_id,
                        caller_name,
                        callee_name,
                        line_start,
                        line_start,
                        snippet or "",
                    )

            # ------------------------------------------------
            # USES
            # ------------------------------------------------

            for caller in local_funcs:

                caller_name = caller["name"]

                for struct_name in global_structs:

                    if struct_name == caller_name:
                        continue

                    match = find_symbol_in_text(
                        text,
                        struct_name,
                    )

                    if not match:
                        continue

                    use_line = line_number(
                        text,
                        match.start(),
                    )

                    add_relation(
                        relations,
                        counters,
                        evidence_db,
                        "USES",
                        source_id,
                        caller_name,
                        struct_name,
                        use_line,
                        use_line,
                        text.splitlines()[use_line - 1]
                        if text.splitlines()
                        and use_line <= len(text.splitlines())
                        else "",
                    )

'''

if '# RELATIONS\n            # ------------------------------------------------\n\n            source_symbols = symbols' not in text:
    if needle not in text:
        raise SystemExit(
            "ERROR: source arrays pattern not found"
        )

    text = text.replace(
        needle,
        needle + relation_block,
        1,
    )


# ============================================================
# 6. STATS
# ============================================================

needle = '''    stats["KNOWLEDGE_COUNT"] = len(
        knowledge_db
    )
'''

replacement = needle + '''
    stats["RELATIONS_COUNT"] = len(
        relations
    )
'''

if 'stats["RELATIONS_COUNT"]' not in text:
    if needle not in text:
        raise SystemExit(
            "ERROR: KNOWLEDGE_COUNT stats pattern not found"
        )

    text = text.replace(
        needle,
        replacement,
        1,
    )


# ============================================================
# 7. WRITE RELATIONS
# ============================================================

needle = '''    structured["version"] = 1
    structured["stats"] = stats
'''

replacement = '''    structured["version"] = 1
    structured["stats"] = stats
    structured["relations"] = relations
'''

if 'structured["relations"] = relations' not in text:
    if needle not in text:
        raise SystemExit(
            "ERROR: final structured assignment not found"
        )

    text = text.replace(
        needle,
        replacement,
        1,
    )


# ============================================================
# WRITE
# ============================================================

path.write_text(
    text,
    encoding="utf-8",
)

print("PATCH OK")
print(path)

