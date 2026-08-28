import hashlib
import json
import os
import re
import sys

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
if ROOT_DIR not in sys.path:
    sys.path.insert(0, ROOT_DIR)

# ---------------------------------------------------------------------------
# SourceCoverage Layer
#
# Builds normalized KNOWLEDGE for ANY Zig root tree, WITHOUT copying raw
# source text into memory. Every extracted unit (declaration / doc comment /
# test / literal / expression) becomes a FACT or RELATION carrying:
#   - deterministic id
#   - evidence pointer (concrete source lines)
#   - real .zig location (path + line range)
#   - tier label (truth = language source of truth, environment = tooling)
#
# The full raw file text is NOT stored here; it is read from disk on demand
# by the runtime retrieval gateway.
# ---------------------------------------------------------------------------

CHUNK_SIZE = 10

EXCLUDED_DIRS = {"node_modules", "zig-cache", "zig-out", ".git", "venv",
                 "dist", "build", "build-debug", "build-release", "CMakeFiles"}

# --- line helpers (byte-identical semantics with evidence_verifier.py) ------

def read_source_lines(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.readlines()


def read_source_text_segment(path, start, end):
    lines = read_source_lines(path)
    return "".join(lines[start - 1:end])


def sha256_segment(lines, start, end):
    seg = "".join(lines[start - 1:end])
    return hashlib.sha256(seg.encode("utf-8", "replace")).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def short_id(prefix, *parts):
    digest = hashlib.sha256("|".join(str(p) for p in parts).encode("utf-8")).hexdigest()
    return prefix + "-" + digest[:16]


def iter_zig_files(root, excluded=None):
    excluded = excluded or EXCLUDED_DIRS
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(
            d for d in dirnames
            if d not in excluded and not d.startswith(".")
        )
        for name in sorted(filenames):
            if name.endswith(".zig"):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


# --- lexical helpers --------------------------------------------------------

def strip_code(line):
    """Remove string/char/comment noise so structural regexes are reliable."""
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
            i = j + 2 if j < n else n
            continue
        if c == "/" and i + 1 < n and line[i + 1] == "/":
            break
        out.append(c)
        i += 1
    return "".join(out)


def brace_delta(stripped):
    return stripped.count("{") - stripped.count("}")


def find_block_end(stripped_lines, start, total):
    depth = 0
    opened = False
    for i in range(start, min(total, len(stripped_lines))):
        depth += brace_delta(stripped_lines[i])
        if depth > 0:
            opened = True
        if opened and depth <= 0:
            return i
        if not opened and ";" in stripped_lines[i]:
            return i
    return total - 1


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


# --- declaration regexes ----------------------------------------------------

IMPORT_RX = re.compile(r'^(?:pub\s+)?(?:const|var)\s+([A-Za-z_]\w*)\s*=\s*@import\s*\(')
CONTAINER_RX = re.compile(
    r'^(?:pub\s+)?const\s+([A-Za-z_]\w*)\s*(?::[^=]*)?=\s*'
    r'(?:packed\s+|extern\s+)*?(struct|enum|union|error)\b'
)
FN_RX = re.compile(r'^(?:pub\s+)?(?:export\s+)?(?:inline\s+)?fn\s+([A-Za-z_]\w*)')
COMPTIME_RX = re.compile(r'^(?:pub\s+)?comptime\s*\{')
USING_NS_RX = re.compile(r'^(?:pub\s+)?usingnamespace\s+(.+)')
VAR_RX = re.compile(r'^(?:pub\s+)?var\s+([A-Za-z_]\w*)')
CONST_RX = re.compile(r'^(?:pub\s+)?const\s+([A-Za-z_]\w*)\b')
FIELD_RX = re.compile(r'^\s*(?:pub\s+)?([A-Za-z_]\w*)\s*:')
TYPE_ALIAS_RX = re.compile(r"^type\b")
TEST_RX = re.compile(r'^test\s+"([^"]*)"|^test\b')
DOC_RX = re.compile(r"^\s*///")

KIND_MAP = {"struct": "struct", "enum": "enum", "union": "union", "error": "error_set"}
CONTAINER_KINDS = set(KIND_MAP.values())


def collect_doc_comment(raw_lines, idx):
    """Gather contiguous /// comment lines ending immediately above idx."""
    docs = []
    j = idx - 1
    while j >= 0 and DOC_RX.match(raw_lines[j]):
        docs.append(raw_lines[j].strip()[3:].strip())
        j -= 1
    docs.reverse()
    if not docs:
        return None
    return {
        "start": j + 2,          # first doc line (1-based)
        "end": idx,               # last doc line (1-based)
        "text": " ".join(docs),
    }


def classify_top_level(stripped):
    m = IMPORT_RX.match(stripped)
    if m:
        return ("import", m.group(1))
    m = CONTAINER_RX.match(stripped)
    if m:
        return (KIND_MAP[m.group(2)], m.group(1))
    m = FN_RX.match(stripped)
    if m:
        return ("function", m.group(1))
    m = VAR_RX.match(stripped)
    if m:
        return ("var", m.group(1))
    m = CONST_RX.match(stripped)
    if m and "=" in stripped:
        rest = stripped.split("=", 1)[1].strip()
        kind = "type" if TYPE_ALIAS_RX.match(rest) else "const"
        return (kind, m.group(1))
    return (None, None)


def extract_file(path, digest):
    """
    Return (units, total_lines) where units is a list of dicts:
      {kind, name, symbol_id, file_id, source_file, line_start, line_end,
       evidence_id, sha256, signature, doc, tier}
    """
    raw_lines = read_source_lines(path)
    total = len(raw_lines)
    stripped_lines = [strip_code(l) for l in raw_lines]
    units = []
    container_ends = []  # stack of end lines for innermost container detection
    counters = {}

    def add(kind, name, s, e, sig, doc, anchor):
        key = (kind, name, s)
        counters[key] = counters.get(key, 0) + 1
        # Evidence = ONLY the declaration line (proves location). The full body
        # is read from disk on demand; we must NOT copy raw source into memory.
        ev_s, ev_e = s, s
        evidence_id = short_id("EV", path, digest, ev_s, ev_e, kind, name, counters[key])
        sha = sha256_segment(raw_lines, ev_s, ev_e)
        units.append({
            "kind": kind,
            "name": name,
            "symbol_id": short_id("SY", path, digest, kind, name, s, counters[key]),
            "file_id": short_id("FI", path, digest),
            "source_file": path,
            "root": find_root(path),
            "line_start": s,
            "line_end": e,
            "evidence_id": evidence_id,
            "sha256": sha,
            "ev_start": ev_s,
            "ev_end": ev_e,
            "signature": sig,
            "doc": doc,
            "anchor": anchor,
            "verification_status": "VERIFIED",
        })

    i = 0
    while i < total:
        while container_ends and container_ends[-1] < i:
            container_ends.pop()

        raw = raw_lines[i].rstrip("\n").rstrip("\r")
        if raw.strip() == "":
            i += 1
            continue

        stripped = stripped_lines[i]
        top_level = not raw[:1].isspace()

        doc = collect_doc_comment(raw_lines, i)
        doc_record = None
        if doc is not None and not stripped.startswith("///"):
            doc_record = doc
            # represent the doc comment block itself as a unit
            dstart, dend = doc["start"], doc["end"]
            doc_sha = sha256_segment(raw_lines, dstart, dend)
            dkey = ("doc_comment", dstart)
            counters[dkey] = counters.get(dkey, 0) + 1
            units.append({
                "kind": "doc_comment",
                "name": f"{path}:{dstart}",
                "symbol_id": short_id("SY", path, digest, "doc", dstart,
                                      doc["text"][:64], counters[dkey]),
                "file_id": short_id("FI", path, digest),
                "source_file": path,
                "root": find_root(path),
                "line_start": dstart,
                "line_end": dend,
                "evidence_id": short_id("EV", path, digest, dstart, dend, "doc_comment", dstart, counters[dkey]),
                "sha256": doc_sha,
                "ev_start": dstart,
                "ev_end": dend,
                "signature": doc["text"][:200],
                "doc": None,
                "anchor": "///",
                "verification_status": "VERIFIED",
            })

        if top_level:
            kind, name = classify_top_level(stripped)
            if kind:
                end = find_block_end(stripped_lines, i, total)
                add(kind, name, i + 1, end + 1, signature_from_raw(raw), doc_record, name)
                if kind in CONTAINER_KINDS and (end > i or brace_delta(stripped) > 0):
                    container_ends.append(end)
            else:
                m = COMPTIME_RX.match(stripped)
                if m:
                    end = find_block_end(stripped_lines, i, total)
                    add("comptime_block", f"comptime@{i + 1}", i + 1, end + 1,
                        signature_from_raw(raw), doc_record, "comptime")
                else:
                    m = USING_NS_RX.match(stripped)
                    if m:
                        add("usingnamespace", m.group(1).strip()[:48], i + 1, i + 1,
                            signature_from_raw(raw), doc_record, "usingnamespace")
        else:
            # nested container members
            innermost = None
            for u in reversed(units):
                if u["kind"] in CONTAINER_KINDS and u["line_start"] - 1 <= i <= u["line_end"] - 1:
                    innermost = u["kind"]
                    break
            if innermost in ("struct", "union"):
                m = FIELD_RX.match(raw)
                if m and "(" not in stripped.split(":")[0]:
                    tail = signature_from_raw(raw)
                    if tail.endswith(",") or "=" in tail or ":" in raw:
                        end = find_block_end(stripped_lines, i, total)
                        add("field", m.group(1), i + 1, end + 1, tail, doc_record, ":")
            elif innermost == "enum":
                m = re.match(r"^\s*(?:pub\s+)?([A-Za-z_]\w*)\s*(?:,|$|=)", raw)
                if m:
                    add("enum_field", m.group(1), i + 1, i + 1,
                        signature_from_raw(raw), doc_record, ",")
            elif innermost == "error_set":
                m = re.match(r"^\s*(?:pub\s+)?([A-Za-z_]\w*)\s*(?:,|$)", raw)
                if m:
                    add("error_name", m.group(1), i + 1, i + 1,
                        signature_from_raw(raw), doc_record, ",")

        # tests
        if TEST_RX.match(stripped):
            m = TEST_RX.match(stripped)
            tname = m.group(1) if m and m.group(1) else ""
            add("test", tname or f"test@{i + 1}", i + 1,
                find_block_end(stripped_lines, i, total) + 1,
                signature_from_raw(raw), doc_record, "test")

        i += 1

    # Guarantee: every NON-EMPTY file is represented by at least one node, so
    # NO source file with content is ever lost. If nothing classifiable was
    # found (comments only / unknown top-level statement), represent the whole
    # file as a module. Empty files are still indexed in source_index.json.
    if not units and total >= 1:
        add("module", os.path.basename(path), 1, total,
            "", None, "module")

    return units, total


_ROOT_CACHE = {}


def find_root(path):
    norm = path.replace("\\", "/")
    for r in ("C:/Users/Local/zig", "C:/B-Plus/zig"):
        if norm.startswith(r.lower()) or norm.startswith(r):
            return r
    return os.path.dirname(os.path.dirname(path))


def evidence_tier(root):
    if "Users/Local/zig" in root.replace("\\", "/"):
        return "truth"
    return "environment"


def build_evidence(units_by_file, digest_by_file):
    """
    Return evidence records. Evidence = the EXACT extracted construct text
    (its own line range), keyed by (path, line_start, line_end, kind).
    This keeps the raw file OUT of memory; the full file is read from disk
    on demand by the runtime gateway.
    """
    ev = {}
    for path, units in units_by_file.items():
        digest = digest_by_file[path]
        lines = read_source_lines(path)
        for u in units:
            s, e = u["ev_start"], u["ev_end"]
            key = (path, s, e, u["kind"], u["name"])
            if key in ev:
                continue
            text = "".join(lines[s - 1:e])
            ev[key] = {
                "id": u["evidence_id"],
                "source_file": path,
                "root": find_root(path),
                "file_id": u["file_id"],
                "sha256": hashlib.sha256(text.encode("utf-8", "replace")).hexdigest(),
                "line_start": s,
                "line_end": e,
                "text": text,
                "verification_status": "VERIFIED",
            }
    return list(ev.values())
