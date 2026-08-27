import os
import re
import sys

from common import (
    CHUNK_SIZE,
    EVIDENCE_PATH,
    INDEX_PATH,
    SYMBOLS_PATH,
    iter_zig_files,
    load_json,
    read_lines,
    save_json,
    sha256_file,
    short_id,
)

IMPORT_RX = re.compile(r'^(?:pub\s+)?(?:const|var)\s+([A-Za-z_]\w*)\s*=\s*@import\s*\(')
CONTAINER_RX = re.compile(
    r'^(?:pub\s+)?const\s+([A-Za-z_]\w*)\s*(?::[^=]*)?=\s*'
    r'(?:packed\s+|extern\s+)*?(struct|enum|union|error)\b'
)
FN_RX = re.compile(r'^(?:pub\s+)?(?:export\s+)?(?:inline\s+)?fn\s+([A-Za-z_]\w*)')
VAR_RX = re.compile(r'^(?:pub\s+)?var\s+([A-Za-z_]\w*)')
CONST_RX = re.compile(r'^(?:pub\s+)?const\s+([A-Za-z_]\w*)\b')
FIELD_RX = re.compile(r'^\s*(?:pub\s+)?([A-Za-z_]\w*)\s*:')

KIND_MAP = {"struct": "struct", "enum": "enum", "union": "union", "error": "error_set"}
CONTAINER_KINDS = set(KIND_MAP.values())


def strip_code(line):
    out = []
    i = 0
    n = len(line)
    in_str = False
    while i < n:
        c = line[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            i += 1
            continue
        if c == "'":
            j = i + 1
            while j < n:
                if line[j] == "\\":
                    j += 2
                    continue
                break
            i = j + 2
            continue
        if c == "/" and i + 1 < n and line[i + 1] == "/":
            break
        out.append(c)
        i += 1
    return "".join(out)


def brace_delta(stripped):
    return stripped.count("{") - stripped.count("}")


def find_block_end(stripped_lines, start):
    depth = 0
    opened = False
    for i in range(start, len(stripped_lines)):
        depth += brace_delta(stripped_lines[i])
        if depth > 0:
            opened = True
        if opened and depth <= 0:
            return i
        if not opened and ";" in stripped_lines[i]:
            return i
    return len(stripped_lines) - 1


def signature_of(stripped):
    body = stripped
    for stop in ("{", ";"):
        idx = body.find(stop)
        if idx != -1:
            body = body[:idx]
    return body.strip()


def signature_from_raw(raw):
    out = []
    i = 0
    n = len(raw)
    in_str = False
    while i < n:
        c = raw[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(raw[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "'":
            out.append(c)
            j = i + 1
            while j < n:
                out.append(raw[j])
                if raw[j] == "\\" and j + 1 < n:
                    out.append(raw[j + 1])
                    j += 2
                    continue
                if raw[j] == "'":
                    j += 1
                    break
                j += 1
            i = j
            continue
        if c in "{;":
            break
        if c == "/" and i + 1 < n and raw[i + 1] == "/":
            break
        out.append(c)
        i += 1
    return "".join(out).strip()


TYPE_ALIASE_RX = re.compile(r"^type\b")


def chunk_bounds(line_start, total):
    cs = ((line_start - 1) // CHUNK_SIZE) * CHUNK_SIZE + 1
    ce = min(cs + CHUNK_SIZE - 1, total)
    return cs, ce


def extract_file(path, digest):
    lines = read_lines(path)
    stripped_lines = [strip_code(l) for l in lines]
    total = len(lines)
    raw_syms = []
    container_ends = []

    def add(kind, name, start, end, signature, anchor):
        raw_syms.append((kind, name, start + 1, end + 1, signature, anchor))

    i = 0
    while i < total:
        while container_ends and i > container_ends[-1]:
            container_ends.pop()
        raw = lines[i]
        if raw.strip() == "":
            i += 1
            continue
        stripped = stripped_lines[i]
        top_level = not raw[:1].isspace()

        if top_level:
            m = IMPORT_RX.match(stripped)
            if m:
                add("import", m.group(1), i, find_block_end(stripped_lines, i), signature_from_raw(raw), "@import")
            else:
                m = CONTAINER_RX.match(stripped)
                if m:
                    end = find_block_end(stripped_lines, i)
                    add(KIND_MAP[m.group(2)], m.group(1), i, end, signature_from_raw(raw), m.group(2))
                    if end > i or brace_delta(stripped) > 0:
                        container_ends.append(end)
                else:
                    m = FN_RX.match(stripped)
                    if m:
                        add("function", m.group(1), i, find_block_end(stripped_lines, i), signature_from_raw(raw), "fn")
                    else:
                        m = VAR_RX.match(stripped)
                        if m:
                            add("var", m.group(1), i, find_block_end(stripped_lines, i), signature_from_raw(raw), "var")
                        else:
                            m = CONST_RX.match(stripped)
                            if m and "=" in stripped:
                                rest = stripped.split("=", 1)[1].strip()
                                kind = "type" if TYPE_ALIASE_RX.match(rest) else "const"
                                add(kind, m.group(1), i, find_block_end(stripped_lines, i), signature_from_raw(raw), m.group(1))
        else:
            if container_ends:
                innermost_kind = None
                for sym in reversed(raw_syms):
                    if sym[0] in CONTAINER_KINDS and sym[2] - 1 <= i <= sym[3] - 1:
                        innermost_kind = sym[0]
                        break
                if innermost_kind in ("struct", "union"):
                    m = FIELD_RX.match(raw)
                    if m and "(" not in stripped.split(":")[0]:
                        tail = signature_from_raw(raw)
                        if tail.endswith(",") or "=" in tail:
                            add("field", m.group(1), i, i, tail, ":")

        i += 1

    items = []
    counters = {}
    for kind, name, ls, le, signature, anchor in raw_syms:
        key = (kind, name, ls)
        counters[key] = counters.get(key, 0) + 1
        cs, ce = chunk_bounds(ls, total)
        items.append({
            "symbol_id": short_id("SY", str(path), digest, kind, name, ls, le, counters[key]),
            "name": name,
            "kind": kind,
            "source_file": str(path),
            "file_id": short_id("FI", str(path), digest),
            "line_start": ls,
            "line_end": le,
            "evidence_id": short_id("EV", str(path), digest, cs, ce),
            "signature": signature,
            "verification_status": "VERIFIED",
        })
    return items, total


def main():
    index = load_json(INDEX_PATH)
    evidence = load_json(EVIDENCE_PATH)

    evidence_by_key = {}
    evidence_ids = set()
    for ev in evidence["items"]:
        evidence_by_key[(ev["source_file"], ev["line_start"], ev["line_end"])] = ev
        evidence_ids.add(ev["id"])

    all_items = []
    file_totals = {}
    for entry in index["files"]:
        items, total = extract_file(entry["path"], entry["sha256"])
        all_items.extend(items)
        file_totals[entry["path"]] = (total, entry["sha256"])

    doc = {
        "schema": "source_symbols",
        "version": 1,
        "root": index["root"],
        "file_count": len(index["files"]),
        "symbol_count": len(all_items),
        "items": all_items,
    }
    save_json(SYMBOLS_PATH, doc)
    print("written:", len(all_items))

    fresh_paths = {str(p) for p in iter_zig_files()}
    missing_files = sum(1 for e in index["files"] if not os.path.isfile(e["path"]))
    unknown_source_files = sum(1 for it in all_items if it["source_file"] not in fresh_paths)

    invalid_ranges = 0
    symbols_without_evidence = 0
    invalid_evidence_id = 0
    duplicate_symbol_id = 0
    fabricated_symbols = 0
    invalid_source_locations = 0

    seen_ids = set()
    for it in all_items:
        path = it["source_file"]
        if path not in file_totals or not os.path.isfile(path):
            missing_files += 1
            continue
        total, stored_sha = file_totals[path]
        actual_sha = sha256_file(path)
        if actual_sha != stored_sha:
            invalid_source_locations += 1
            continue
        ls, le = it["line_start"], it["line_end"]
        if not (1 <= ls <= le <= total):
            invalid_ranges += 1
            invalid_source_locations += 1
            continue
        lines = read_lines(path)
        slice_text = "\n".join(lines[ls - 1:le])
        name_found = it["name"] in slice_text
        if it["kind"] == "import":
            ok = "@import" in slice_text and name_found
        elif it["kind"] in CONTAINER_KINDS:
            word = [k for k, v in KIND_MAP.items() if v == it["kind"]][0]
            ok = word in slice_text and name_found
        elif it["kind"] == "function":
            ok = "fn" in slice_text and name_found
        elif it["kind"] in ("var", "type", "const", "field"):
            ok = name_found
        else:
            ok = False
        if not ok:
            fabricated_symbols += 1
        cs, ce = chunk_bounds(ls, total)
        ev = evidence_by_key.get((path, cs, ce))
        if ev is None:
            symbols_without_evidence += 1
        elif ev["id"] != it["evidence_id"] or it["evidence_id"] not in evidence_ids:
            invalid_evidence_id += 1
        if it["symbol_id"] in seen_ids:
            duplicate_symbol_id += 1
        seen_ids.add(it["symbol_id"])

    kind_counts = {}
    for it in all_items:
        kind_counts[it["kind"]] = kind_counts.get(it["kind"], 0) + 1

    rebuild_ids = []
    for entry in index["files"]:
        items, _ = extract_file(entry["path"], entry["sha256"])
        rebuild_ids.extend(x["symbol_id"] for x in items)
    deterministic = rebuild_ids == [it["symbol_id"] for it in all_items]

    print("source_files:", len(index["files"]))
    print("missing_files:", missing_files)
    print("unknown_source_files:", unknown_source_files)
    print("invalid_ranges:", invalid_ranges)
    print("symbols_without_evidence:", symbols_without_evidence)
    print("invalid_evidence_id:", invalid_evidence_id)
    print("duplicate_symbol_id:", duplicate_symbol_id)
    print("fabricated_symbols:", fabricated_symbols)
    print("invalid_source_locations:", invalid_source_locations)
    print("kinds:", ", ".join(f"{k}={v}" for k, v in sorted(kind_counts.items())))
    print("deterministic_ids:", "PASS" if deterministic else "FAIL")

    ok = all([
        len(index["files"]) == 401,
        missing_files == 0,
        unknown_source_files == 0,
        invalid_ranges == 0,
        symbols_without_evidence == 0,
        invalid_evidence_id == 0,
        duplicate_symbol_id == 0,
        fabricated_symbols == 0,
        invalid_source_locations == 0,
        deterministic,
    ])
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
