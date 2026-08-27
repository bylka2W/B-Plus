import os
import re
import sys

from common import (
    CHUNK_SIZE,
    EVIDENCE_PATH,
    INDEX_PATH,
    RELATIONS_PATH,
    SYMBOLS_PATH,
    iter_zig_files,
    load_json,
    save_json,
    sha256_file,
    short_id,
)

from source_symbols import strip_code

CHAIN_RX = re.compile(r"(?<![\w.@])([A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*)\s*(\()?")
LOCAL_VAR_RX = re.compile(r"^\s+(?:pub\s+)?(?:var|const)\s+[A-Za-z_]\w*\s*:\s*([^=;]+)=")
IMPORT_PATH_RX = re.compile(r'@import\(\s*"([^"]+)"\s*\)')

PRIMITIVES = {
    "u1", "u8", "u16", "u32", "u64", "u128", "usize",
    "i0", "i8", "i16", "i32", "i64", "i128", "isize",
    "f16", "f32", "f64", "f128",
    "c_short", "c_ushort", "c_int", "c_uint", "c_long", "c_ulong",
    "c_longlong", "c_ulonglong", "c_longdouble",
    "bool", "void", "noreturn", "type", "anytype", "anyopaque",
    "comptime_float", "comptime_int", "comptime",
}

RESERVED_HEADS = {"error", "undefined", "null", "true", "false"}

ZIG_KEYWORDS = {
    "if", "for", "while", "switch", "catch", "try", "orelse",
    "return", "break", "continue", "defer", "errdefer", "comptime",
    "fn", "test", "var", "const", "enum", "struct", "union", "error",
    "usingnamespace", "export", "extern", "inline", "packed", "align",
    "and", "or", "suspend", "resume", "async", "await", "anytype",
    "anyframe", "allowzero", "volatile", "linksection", "callconv",
    "threadlocal", "anyerror", "asm", "else", "noalias", "nosuspend",
    "noinline", "opaque", "pub", "unreachable",
}

DECL_PRECEDING = {"fn", "test"}

REFERENCABLE_KINDS = {"function", "struct", "enum", "union", "error_set", "const", "type", "var"}
CONTAINER_KINDS = {"struct", "enum", "union", "error_set"}


def split_top_level(text, sep=","):
    parts = []
    depth = 0
    cur = []
    i = 0
    n = len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            cur.append(c)
            if c == "\\" and i + 1 < n:
                cur.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            cur.append(c)
            i += 1
            continue
        if c in "(<[{":
            depth += 1
        elif c in ")>]}":
            depth -= 1
        elif depth == 0 and c == sep:
            parts.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    if "".join(cur).strip():
        parts.append("".join(cur))
    return [p.strip() for p in parts]


def extract_type_chains(text):
    chains = []
    for m in re.finditer(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*", text):
        parts = m.group(0).split(".")
        if any(p in ZIG_KEYWORDS for p in parts):
            continue
        if len(parts) == 1 and parts[0] in PRIMITIVES:
            continue
        chains.append(parts)
    return chains


def parse_fn_signature(signature):
    sig = signature.strip()
    m = re.match(r"^(?:pub\s+)?(?:export\s+)?(?:inline\s+)?fn\s+[A-Za-z_]\w*", sig)
    if not m:
        return [], []
    rest = sig[m.end():]
    lp = rest.find("(")
    if lp == -1:
        return [], []
    depth = 0
    rp = -1
    in_str = False
    i = lp
    while i < len(rest):
        c = rest[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    rp = i
                    break
        i += 1
    if rp == -1:
        return [], []
    params_src = rest[lp + 1:rp]
    ret_src = rest[rp + 1:].strip()
    if ret_src.startswith("!"):
        ret_src = ret_src[1:].strip()
        if ret_src.startswith("{"):
            d = 0
            j = 0
            while j < len(ret_src):
                if ret_src[j] == "{":
                    d += 1
                elif ret_src[j] == "}":
                    d -= 1
                    if d == 0:
                        break
                j += 1
            ret_src = ret_src[j + 1:].strip()
    param_types = []
    for p in split_top_level(params_src):
        if not p:
            continue
        d = 0
        ci = -1
        for j, ch in enumerate(p):
            if ch in "(<[{":
                d += 1
            elif ch in ")>]}":
                d -= 1
            elif ch == ":" and d == 0:
                ci = j
                break
        if ci != -1:
            param_types.append(p[ci + 1:].strip())
    return param_types, ([ret_src] if ret_src and not re.match(r"^void\b", ret_src) else [])


def field_type_text(signature):
    idx = signature.find(":")
    if idx == -1:
        return ""
    tail = signature[idx + 1:]
    for stop in (",", ";"):
        s = tail.find(stop)
        if s != -1:
            tail = tail[:s]
    return tail.strip()


def chunk_bounds(line_start, total):
    cs = ((line_start - 1) // CHUNK_SIZE) * CHUNK_SIZE + 1
    ce = min(cs + CHUNK_SIZE - 1, total)
    return cs, ce


class RelWriter:
    def __init__(self):
        self.items = []
        self._seen = set()

    def emit(self, rtype, src_id, tgt_id, src_file, ev_id, line, status, target_file="", target_name=""):
        key = (rtype, src_id, tgt_id, ev_id, status, target_file)
        if key in self._seen:
            return
        self._seen.add(key)
        rid = short_id("RL", rtype, src_id, tgt_id, ev_id, line)
        self.items.append({
            "relation_id": rid,
            "relation_type": rtype,
            "source_symbol_id": src_id,
            "target_symbol_id": tgt_id,
            "source_file": src_file,
            "evidence_id": ev_id,
            "line_start": line,
            "line_end": line,
            "verification_status": status,
            **({"target_file": target_file} if target_file else {}),
            **({"target_name": target_name} if target_name else {}),
        })


def main():
    index = load_json(INDEX_PATH)
    symbols_doc = load_json(SYMBOLS_PATH)
    evidence_doc = load_json(EVIDENCE_PATH)

    indexed_paths = {e["path"] for e in index["files"]}
    file_sha = {e["path"]: e["sha256"] for e in index["files"]}
    file_lines = {e["path"]: e["line_count"] for e in index["files"]}

    changed = [p for p in indexed_paths if not os.path.isfile(p) or sha256_file(p) != file_sha[p]]
    if changed:
        print("SOURCE_CHANGED:", len(changed))
        for p in changed[:10]:
            print("  ", p)
        sys.exit(1)

    sym_by_id = {}
    syms_by_file = {}
    for s in symbols_doc["items"]:
        sym_by_id[s["symbol_id"]] = s
        syms_by_file.setdefault(s["source_file"], []).append(s)

    names_in_file = {}
    for f, lst in syms_by_file.items():
        d = {}
        for s in lst:
            d.setdefault(s["name"], []).append(s)
        names_in_file[f] = d

    imports_map = {}
    import_syms_by_file = {}
    field_syms_by_file = {}
    fn_syms_by_file = {}
    container_list_by_file = {}
    for f, lst in syms_by_file.items():
        im = {}
        for s in lst:
            if s["kind"] == "import":
                m = IMPORT_PATH_RX.search(s["signature"])
                if m:
                    rel = m.group(1)
                    cand = os.path.abspath(os.path.normpath(os.path.join(os.path.dirname(f), rel)))
                    im[s["name"]] = cand if cand in indexed_paths else None
            elif s["kind"] == "field":
                field_syms_by_file.setdefault(f, []).append(s)
            elif s["kind"] == "function":
                fn_syms_by_file.setdefault(f, []).append(s)
            elif s["kind"] in CONTAINER_KINDS:
                container_list_by_file.setdefault(f, []).append(s)
        imports_map[f] = im

    ev_by_key = {}
    ev_ids = set()
    for ev in evidence_doc["items"]:
        ev_by_key[(ev["source_file"], ev["line_start"], ev["line_end"])] = ev
        ev_ids.add(ev["id"])

    def ev_for(path, line1):
        total = file_lines[path]
        cs, ce = chunk_bounds(line1, total)
        ev = ev_by_key.get((path, cs, ce))
        return ev

    W = RelWriter()

    def resolve_chain(path, parts):
        if not parts or parts[0] in RESERVED_HEADS:
            return None
        if len(parts) == 1:
            name = parts[0]
            cands = [s for s in names_in_file.get(path, {}).get(name, []) if s["kind"] in REFERENCABLE_KINDS]
            if len(cands) == 1:
                return cands[0]
            return ("UNRESOLVED", name)
        head = parts[0]
        last = parts[-1]
        if head in imports_map.get(path, {}):
            tgt_file = imports_map[path][head]
            if tgt_file is None:
                return None
            cands = [s for s in names_in_file.get(tgt_file, {}).get(last, []) if s["kind"] in REFERENCABLE_KINDS]
            if len(cands) == 1:
                return cands[0]
            return ("UNRESOLVED", last)
        head_syms = [s for s in names_in_file.get(path, {}).get(head, []) if s["kind"] in CONTAINER_KINDS]
        if len(head_syms) == 1:
            return head_syms[0]
        return None

    for path in sorted(indexed_paths):
        lines_raw = open(path, "r", encoding="utf-8", errors="ignore").read().splitlines()
        lines_stripped = [strip_code(l) for l in lines_raw]
        total = len(lines_raw)
        file_syms = syms_by_file.get(path, [])
        fn_list = fn_syms_by_file.get(path, [])

        for s in [x for x in file_syms if x["kind"] == "import"]:
            m = IMPORT_PATH_RX.search(s["signature"])
            if not m:
                continue
            rel = m.group(1)
            cand = os.path.abspath(os.path.normpath(os.path.join(os.path.dirname(path), rel)))
            ev = ev_for(path, s["line_start"])
            if ev is None:
                continue
            if cand in indexed_paths:
                W.emit("IMPORTS", s["symbol_id"], "", path, ev["id"], s["line_start"], "VERIFIED", target_file=cand)
            else:
                W.emit("IMPORTS", s["symbol_id"], "", path, ev["id"], s["line_start"], "UNRESOLVED", target_name=rel)

        for fsym in field_syms_by_file.get(path, []):
            cont = None
            for c in container_list_by_file.get(path, []):
                if c["line_start"] <= fsym["line_start"] <= c["line_end"]:
                    if cont is None or (c["line_end"] - c["line_start"]) < (cont["line_end"] - cont["line_start"]):
                        cont = c
            ev = ev_for(path, fsym["line_start"])
            if ev is None:
                continue
            if cont is not None:
                W.emit("HAS_FIELD", cont["symbol_id"], fsym["symbol_id"], path, ev["id"], fsym["line_start"], "VERIFIED")
            ttext = field_type_text(fsym["signature"])
            for parts in extract_type_chains(ttext):
                r = resolve_chain(path, parts)
                if r is None:
                    continue
                if isinstance(r, tuple):
                    W.emit("FIELD_TYPE", fsym["symbol_id"], "", path, ev["id"], fsym["line_start"], r[0], target_name=r[1])
                else:
                    W.emit("FIELD_TYPE", fsym["symbol_id"], r["symbol_id"], path, ev["id"], fsym["line_start"], "VERIFIED")

        for fn in fn_list:
            ls, le = fn["line_start"], fn["line_end"]
            ev0 = ev_for(path, ls)
            if ev0 is None:
                continue
            param_types, ret_types = parse_fn_signature(fn["signature"])
            for t in param_types:
                for parts in extract_type_chains(t):
                    r = resolve_chain(path, parts)
                    if r is None:
                        continue
                    if isinstance(r, tuple):
                        W.emit("PARAMETER_TYPE", fn["symbol_id"], "", path, ev0["id"], ls, r[0], target_name=r[1])
                    else:
                        W.emit("PARAMETER_TYPE", fn["symbol_id"], r["symbol_id"], path, ev0["id"], ls, "VERIFIED")
            for t in ret_types:
                for parts in extract_type_chains(t):
                    r = resolve_chain(path, parts)
                    if r is None:
                        continue
                    if isinstance(r, tuple):
                        W.emit("RETURNS", fn["symbol_id"], "", path, ev0["id"], ls, r[0], target_name=r[1])
                    else:
                        W.emit("RETURNS", fn["symbol_id"], r["symbol_id"], path, ev0["id"], ls, "VERIFIED")

            for li in range(max(0, ls - 1), min(le, total)):
                stext = lines_stripped[li]
                if not stext.strip():
                    continue
                ev = ev_for(path, li + 1)
                if ev is None:
                    continue
                mv = LOCAL_VAR_RX.match(stext)
                if mv:
                    for parts in extract_type_chains(mv.group(1)):
                        r = resolve_chain(path, parts)
                        if r is None:
                            continue
                        if isinstance(r, tuple):
                            W.emit("USES", fn["symbol_id"], "", path, ev["id"], li + 1, r[0], target_name=r[1])
                        else:
                            W.emit("USES", fn["symbol_id"], r["symbol_id"], path, ev["id"], li + 1, "VERIFIED")
                for m in CHAIN_RX.finditer(stext):
                    parts = [p.strip() for p in m.group(1).split(".")]
                    if parts[0] in ZIG_KEYWORDS or parts[0] in RESERVED_HEADS or parts[0] in PRIMITIVES:
                        continue
                    is_call = m.group(2) is not None
                    pre = stext[:m.start()].rstrip()
                    prev_word = re.search(r"([A-Za-z_]\w*)$", pre)
                    if prev_word and prev_word.group(1) in DECL_PRECEDING:
                        continue
                    if is_call:
                        if len(parts) == 1:
                            name = parts[0]
                            cands = [s for s in names_in_file.get(path, {}).get(name, []) if s["kind"] == "function"]
                            if len(cands) == 1:
                                W.emit("CALLS", fn["symbol_id"], cands[0]["symbol_id"], path, ev["id"], li + 1, "VERIFIED")
                            else:
                                W.emit("CALLS", fn["symbol_id"], "", path, ev["id"], li + 1, "UNRESOLVED", target_name=name)
                        else:
                            r = resolve_chain(path, parts)
                            if r is None:
                                continue
                            if isinstance(r, tuple):
                                W.emit("CALLS", fn["symbol_id"], "", path, ev["id"], li + 1, "UNRESOLVED", target_name=parts[-1])
                            elif r["kind"] in CONTAINER_KINDS:
                                W.emit("REFERENCES", fn["symbol_id"], r["symbol_id"], path, ev["id"], li + 1, "VERIFIED")
                            else:
                                W.emit("CALLS", fn["symbol_id"], r["symbol_id"], path, ev["id"], li + 1, "VERIFIED")
                    else:
                        if len(parts) == 1 and parts[0] not in DECL_PRECEDING:
                            name = parts[0]
                            cands = [s for s in names_in_file.get(path, {}).get(name, []) if s["kind"] in REFERENCABLE_KINDS]
                            if len(cands) == 1:
                                W.emit("REFERENCES", fn["symbol_id"], cands[0]["symbol_id"], path, ev["id"], li + 1, "VERIFIED")
                        elif len(parts) >= 2:
                            r = resolve_chain(path, parts)
                            if r is None or isinstance(r, tuple):
                                continue
                            W.emit("REFERENCES", fn["symbol_id"], r["symbol_id"], path, ev["id"], li + 1, "VERIFIED")

    doc = {
        "schema": "source_relations",
        "version": 1,
        "root": index["root"],
        "file_count": len(index["files"]),
        "symbol_count": symbols_doc["symbol_count"],
        "relation_count": len(W.items),
        "items": sorted(W.items, key=lambda x: x["relation_id"]),
    }
    save_json(RELATIONS_PATH, doc)
    print("RELATIONS:", len(doc["items"]))

    type_counts = {}
    status_counts = {}
    for it in doc["items"]:
        type_counts[it["relation_type"]] = type_counts.get(it["relation_type"], 0) + 1
        status_counts[it["verification_status"]] = status_counts.get(it["verification_status"], 0) + 1

    missing_source = 0
    missing_target = 0
    missing_evidence = 0
    invalid_ranges = 0
    verified_without_evidence = 0
    fabricated = 0
    bad_ids = 0

    real_file_count = len(iter_zig_files())
    slice_cache = {}

    def slice_of(path, cs, ce):
        key = (path, cs, ce)
        if key not in slice_cache:
            with open(path, "rb") as fh:
                data = fh.read().decode("utf-8", errors="ignore").splitlines()
            slice_cache[key] = "\n".join(data[cs - 1:ce])
        return slice_cache[key]

    seen_ids = set()
    for it in doc["items"]:
        rid = short_id(
            "RL", it["relation_type"], it["source_symbol_id"], it["target_symbol_id"],
            it["evidence_id"], it["line_start"],
        )
        if rid != it["relation_id"] or it["relation_id"] in seen_ids:
            bad_ids += 1
        seen_ids.add(it["relation_id"])

        if it["source_symbol_id"] not in sym_by_id:
            missing_source += 1
            continue
        if it["target_symbol_id"] and it["target_symbol_id"] not in sym_by_id:
            missing_target += 1
            continue
        path = it["source_file"]
        if path not in file_lines:
            missing_source += 1
            continue
        total = file_lines[path]
        if not (1 <= it["line_start"] <= it["line_end"] <= total):
            invalid_ranges += 1
            continue
        cs, ce = chunk_bounds(it["line_start"], total)
        ev = ev_by_key.get((path, cs, ce))
        if ev is None or ev["id"] != it["evidence_id"] or it["evidence_id"] not in ev_ids:
            missing_evidence += 1
            if it["verification_status"] == "VERIFIED":
                verified_without_evidence += 1
            continue
        actual_slice = slice_of(path, cs, ce)
        if actual_slice != ev["text"]:
            fabricated += 1
            continue
        if it["verification_status"] != "VERIFIED":
            continue
        if it["relation_type"] == "IMPORTS":
            probe = os.path.basename(it.get("target_file", "")) in ev["text"] and "@import(" in ev["text"]
        else:
            tgt = sym_by_id[it["target_symbol_id"]]
            probe = tgt["name"] in ev["text"]
        if not probe:
            fabricated += 1

    print("SOURCE FILES:", real_file_count)
    print("SYMBOLS:", symbols_doc["symbol_count"])
    print("TYPES:", ", ".join(f"{k}={v}" for k, v in sorted(type_counts.items())))
    print("STATUSES:", ", ".join(f"{k}={v}" for k, v in sorted(status_counts.items())))
    print("MISSING_SOURCE:", missing_source)
    print("MISSING_TARGET:", missing_target)
    print("MISSING_EVIDENCE:", missing_evidence)
    print("INVALID_RANGES:", invalid_ranges)
    print("VERIFIED_RELATIONS_WITHOUT_EVIDENCE:", verified_without_evidence)
    print("FABRICATED_RELATIONS:", fabricated)
    print("DETERMINISTIC_IDS:", "PASS" if bad_ids == 0 else "FAIL")
    print("SOURCE_INTEGRITY:", "PASS" if not changed else "FAIL")
    print("EVIDENCE_INTEGRITY:", "PASS" if fabricated == 0 and missing_evidence == 0 else "FAIL")

    ok = all([
        missing_source == 0,
        missing_target == 0,
        missing_evidence == 0,
        invalid_ranges == 0,
        verified_without_evidence == 0,
        fabricated == 0,
        bad_ids == 0,
        real_file_count == len(index["files"]),
    ])
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
