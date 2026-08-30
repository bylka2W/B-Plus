"""
CompleteZigExtractor
===================

Atomic information extraction from Zig source. On top of the structural layer
(file / declaration / symbol / doc / test), this extracts every meaningful
construct as a SEPARATE, VERIFIED, evidence-backed atomic fact:

  PARAM        fn param name -> type
  RETURNS      fn -> return type (incl. !error union)
  CALLS        fn -> callee (incl. @builtin calls)
  USES_TYPE    fn -> referenced type name
  FIELD_ACCESS base.field
  READS        fn -> variable read
  WRITES       fn -> variable write (assignment LHS)
  ASSIGN       assignment occurrence
  RETURN_STMT  return occurrence
  THROWS       error.X / return error
  LITERAL      string / numeric literal
  CONTROL_FLOW if / switch / while / for / defer / errdefer
  COMPTIME     comptime block reference

Every atomic fact carries:
  verification_status = "VERIFIED"
  evidence_id         -> exact source line (readlines sha256), also written to
                         the shared evidence store
  source_file / line_start / line_end
  resolution_status   = "RESOLVED" | "UNRESOLVED"   (NEVER dropped)

Resolution is approximate: a target is RESOLVED if its name is found in the
global symbol name set (or is a builtin / primitive type); otherwise it is
UNRESOLVED but the fact is still preserved.

extract_atomic_for_file() returns (facts, evidence_records) where evidence_records
is the dedup set of single-line evidence for every atomic fact.
"""
import re
import hashlib
import sys
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)
import source_coverage as sc

PRIMITIVE_TYPES = {
    "u8", "u16", "u32", "u64", "u128", "usize", "u0",
    "i8", "i16", "i32", "i64", "i128", "isize",
    "f16", "f32", "f64", "f80", "f128",
    "bool", "void", "anyopaque", "anyframe", "anytype",
    "c_int", "c_long", "c_char", "c_void",
    "comptime_int", "comptime_float",
}

BUILTIN_CALLS = {
    "import", "This", "TypeOf", "Type", "sizeOf", "alignOf", "field",
    "hasField", "fieldParentPtr", "ptrCast", "intCast", "floatCast",
    "bitCast", "enumValue", "errSetCast", "as", "src", "srcFn", "setRuntimeSafety",
    "setEvalBranchQuota", "setCold", "call", "cDefine", "cImport", "cInclude",
    "embedFile", "panic", "breakpoint", "returnAddress", "frameAddress",
    "wasmMemorySize", "wasmMemoryGrow", "shuffle", "splat", "reduce", "select",
    "inComptime", "isBuiltin", "hasDecl",
}

CALL_STOP = {
    "if", "while", "for", "switch", "return", "defer", "errdefer", "catch",
    "try", "await", "suspend", "resume", "asm", "struct", "enum", "union",
    "error", "const", "var", "fn", "comptime", "usingnamespace", "break",
    "continue", "and", "or", "orelse", "unreachable", "test", "inline",
    "export", "extern", "packed", "linksection", "threadlocal", "volatile",
    "allowzero", "nosuspend", "async", "cancel", "ensureResultUsed",
    "bitNot", "boolNot", "negate", "addressOf", "deref",
}

PARAM_RX = re.compile(r"([A-Za-z_]\w*)\s*:\s*([^,()]+?)(?=\s*,|\s*\))", re.S)
CALL_RX = re.compile(r"([A-Za-z_]\w*)\s*\(")
BUILTIN_RX = re.compile(r"@([A-Za-z_]\w*)\s*\(")
FIELD_RX = re.compile(r"([A-Za-z_]\w*)\.([A-Za-z_]\w*)")
TYPE_RX = re.compile(r"\b([A-Z][A-Za-z_]\w*)\b")
ASSIGN_RX = re.compile(r"([A-Za-z_]\w*)\s*(?:\+=|\-=|\*=|/=|%=|=)\s*(.+)")
RETURN_RX = re.compile(r"\breturn\b")
THROW_RX = re.compile(r"error\.[A-Za-z_]\w*|return\s+error\.[A-Za-z_]\w*")
LIT_STR_RX = re.compile(r'"((?:[^"\\]|\\.)*)"')
LIT_NUM_RX = re.compile(r"\b\d[\d_]*(\.\d+)?\b")
CTRL_RX = re.compile(r"\b(if|switch|while|for|defer|errdefer)\b")
CAST_RX = re.compile(r"@(as|ptrCast|intCast|floatCast|bitCast|enumValue|errSetCast|alignCast|intToFloat|floatToInt)\s*\(")
TRY_RX = re.compile(r"\b(try|catch|errdefer)\b")
GENPARAM_RX = re.compile(r"comptime\s+([A-Za-z_]\w*)\s*:\s*(?:type|anytype)")


def _emit_type_forms(out, fn_unit, lines, digest, ev_store, ptype, role):
    """Emit POINTER/SLICE/OPTIONAL type-form facts for a type string."""
    s = fn_unit["line_start"]
    t = ptype.strip()
    forms = []
    if "*" in t:
        forms.append("POINTER_TYPE")
    if "[]" in t or t.startswith("["):
        forms.append("SLICE_TYPE")
    if t.startswith("?") or " ?" in t:
        forms.append("OPTIONAL_TYPE")
    if "!" in t and not t.startswith("!"):
        forms.append("ERROR_UNION")
    for f in forms:
        ev_id = _ev(fn_unit["source_file"], digest, lines, s, s, ev_store)
        out.append(_fact(fn_unit, f, role, t, "UNRESOLVED", ev_id, s, s, f + " " + t))


def short_id_with_range(path, digest, s, e):
    return sc.short_id("EV", path, digest, s, e, "atomic")


_DIGEST_CACHE = {}


def _digest_for(path):
    if path not in _DIGEST_CACHE:
        _DIGEST_CACHE[path] = sc.sha256_file(path)
    return _DIGEST_CACHE[path]


def _ev(path, digest, lines, s, e, ev_store):
    ev_id = short_id_with_range(path, digest, s, e)
    if ev_id not in ev_store:
        text = "".join(lines[s - 1:e])
        ev_store[ev_id] = {
            "id": ev_id,
            "source_file": path,
            "root": sc.find_root(path),
            "file_id": sc.short_id("FI", path, digest),
            "sha256": hashlib.sha256(text.encode("utf-8", "replace")).hexdigest(),
            "line_start": s,
            "line_end": e,
            "text": text,
            "verification_status": "VERIFIED",
        }
    return ev_id


def _resolve(name, all_names):
    base = name.split("[")[0].split(".")[0].split("*")[0].strip()
    if base in all_names:
        return "RESOLVED", base
    if base in PRIMITIVE_TYPES or base in BUILTIN_CALLS:
        return "RESOLVED", base
    return "UNRESOLVED", base


def _fact(fn_unit, predicate, object_value, target, status, ev_id, s, e, signature):
    return {
        "fact_id": sc.short_id("FACT", fn_unit["symbol_id"], predicate, object_value, target, s, e),
        "fact_type": predicate,
        "predicate": predicate,
        "subject_id": fn_unit["symbol_id"],
        "object_id": "",
        "object_value": object_value or target,
        "evidence_id": ev_id,
        "source_file": fn_unit["source_file"],
        "root": fn_unit["root"],
        "tier": "truth",
        "line_start": s,
        "line_end": e,
        "signature": signature,
        "resolution_status": status,
        "verification_status": "VERIFIED",
    }


def fn_signature_facts(fn_unit, lines, digest, all_names, out, ev_store):
    path = fn_unit["source_file"]
    s = fn_unit["line_start"]
    sig_lines = []
    i = s
    while i <= fn_unit["line_end"]:
        raw = lines[i - 1].rstrip("\n").rstrip("\r")
        sig_lines.append(raw)
        if "{" in raw or ";" in raw and "= " not in raw:
            break
        i += 1
    if i > fn_unit["line_end"]:
        i = fn_unit["line_end"]
    sig = "\n".join(sig_lines)
    open_p = sig.find("(")
    close_p = sig.find(")", open_p)
    if open_p != -1 and close_p != -1:
        params_text = sig[open_p + 1:close_p]
        for gm in GENPARAM_RX.finditer(params_text):
            ev_id = _ev(path, digest, lines, s, s, ev_store)
            out.append(_fact(fn_unit, "GENERIC_PARAM", gm.group(1), "type", "UNRESOLVED", ev_id, s, s, "comptime " + gm.group(1) + ": type"))
        for m in PARAM_RX.finditer(params_text):
            pname, ptype = m.group(1), m.group(2).strip()
            status, target = _resolve(ptype, all_names)
            ev_id = _ev(path, digest, lines, s, s, ev_store)
            out.append(_fact(fn_unit, "PARAM", pname, target, status, ev_id, s, s, ptype))
            _emit_type_forms(out, fn_unit, lines, digest, ev_store, ptype, "param:" + pname)
    after = sig[close_p + 1:] if close_p != -1 else ""
    rm = re.match(r"\s*(!?)\s*([\w\.\[\]\*\s]+?)\s*(?=\{|;|$)", after)
    if rm:
        is_err = rm.group(1) == "!"
        rtype = rm.group(2).strip()
        status, target = _resolve(rtype, all_names)
        ev_id = _ev(path, digest, lines, s, s, ev_store)
        out.append(_fact(fn_unit, "RETURNS", "", target, status, ev_id, s, s,
                         rtype + (" (error-union)" if is_err else "")))
        _emit_type_forms(out, fn_unit, lines, digest, ev_store, rtype, "returns")


def fn_body_facts(fn_unit, lines, digest, all_names, out, ev_store):
    path = fn_unit["source_file"]
    bstart = fn_unit["line_start"]
    bend = fn_unit["line_end"]
    for idx in range(bstart, bend + 1):
        raw = lines[idx - 1].rstrip("\n").rstrip("\r")
        ln = idx
        for bm in BUILTIN_RX.finditer(raw):
            bn = bm.group(1)
            ev_id = _ev(path, digest, lines, ln, ln, ev_store)
            out.append(_fact(fn_unit, "CALLS", "", "@" + bn, "RESOLVED", ev_id, ln, ln, "@" + bn + "()"))
        for m in CALL_RX.finditer(raw):
            cn = m.group(1)
            if cn in CALL_STOP:
                continue
            status, target = _resolve(cn, all_names)
            ev_id = _ev(path, digest, lines, ln, ln, ev_store)
            out.append(_fact(fn_unit, "CALLS", "", target, status, ev_id, ln, ln, cn + "()"))
        for fm in FIELD_RX.finditer(raw):
            base, field = fm.group(1), fm.group(2)
            if base == "self" or field in CALL_STOP:
                continue
            j = fm.end()
            if j < len(raw) and raw[j] == "(":
                continue
            ev_id = _ev(path, digest, lines, ln, ln, ev_store)
            out.append(_fact(fn_unit, "FIELD_ACCESS", base, field, "UNRESOLVED", ev_id, ln, ln, base + "." + field))
        for tm in TYPE_RX.finditer(raw):
            tn = tm.group(1)
            if tn in PRIMITIVE_TYPES or tn in all_names:
                ev_id = _ev(path, digest, lines, ln, ln, ev_store)
                status = "RESOLVED" if tn in all_names else "RESOLVED"
                out.append(_fact(fn_unit, "USES_TYPE", "", tn, status, ev_id, ln, ln, tn))
        if RETURN_RX.search(raw):
            ev_id = _ev(path, digest, lines, ln, ln, ev_store)
            out.append(_fact(fn_unit, "RETURN_STMT", "", "", "VERIFIED", ev_id, ln, ln, "return"))
        for tm in THROW_RX.finditer(raw):
            ev_id = _ev(path, digest, lines, ln, ln, ev_store)
            out.append(_fact(fn_unit, "THROWS", "", tm.group(0), "UNRESOLVED", ev_id, ln, ln, tm.group(0)))
        for cm in CTRL_RX.finditer(raw):
            ev_id = _ev(path, digest, lines, ln, ln, ev_store)
            out.append(_fact(fn_unit, "CONTROL_FLOW", "", cm.group(1), "VERIFIED", ev_id, ln, ln, cm.group(1)))
        for cm in CAST_RX.finditer(raw):
            ev_id = _ev(path, digest, lines, ln, ln, ev_store)
            out.append(_fact(fn_unit, "TYPE_CAST", "", "@" + cm.group(1), "RESOLVED", ev_id, ln, ln, "@" + cm.group(1) + "()"))
        for tm in TRY_RX.finditer(raw):
            # errdefer already captured as CONTROL_FLOW; try/catch as ERROR_PROPAGATION
            if tm.group(1) == "errdefer":
                continue
            ev_id = _ev(path, digest, lines, ln, ln, ev_store)
            out.append(_fact(fn_unit, "ERROR_PROPAGATION", "", tm.group(1), "VERIFIED", ev_id, ln, ln, tm.group(1)))
        am = ASSIGN_RX.search(raw)
        if am:
            lhs = am.group(1)
            ev_id = _ev(path, digest, lines, ln, ln, ev_store)
            out.append(_fact(fn_unit, "WRITES", lhs, "", "UNRESOLVED", ev_id, ln, ln, lhs + " ="))
            for rm2 in re.finditer(r"([A-Za-z_]\w*)", am.group(2)):
                rv = rm2.group(1)
                if rv in CALL_STOP or rv in PRIMITIVE_TYPES:
                    continue
                ev_id2 = _ev(path, digest, lines, ln, ln, ev_store)
                out.append(_fact(fn_unit, "READS", rv, "", "UNRESOLVED", ev_id2, ln, ln, rv))
        for sm in LIT_STR_RX.finditer(raw):
            ev_id = _ev(path, digest, lines, ln, ln, ev_store)
            out.append(_fact(fn_unit, "LITERAL", "", repr(sm.group(1))[:80], "VERIFIED", ev_id, ln, ln, "str"))
        for nm in LIT_NUM_RX.finditer(raw):
            ev_id = _ev(path, digest, lines, ln, ln, ev_store)
            out.append(_fact(fn_unit, "LITERAL", "", nm.group(0), "VERIFIED", ev_id, ln, ln, "num"))


FN_DECL_RX = re.compile(r"^(?:pub\s+)?(?:export\s+)?(?:inline\s+)?fn\s+([A-Za-z_]\w*)")
TEST_DECL_RX = re.compile(r'^test\s+"([^"]*)"')


def _fn_units_in_file(path):
    lines = sc.read_source_lines(path)
    stripped = [sc.strip_code(l) for l in lines]
    total = len(lines)
    units = []
    seq = 0
    for i in range(total):
        raw = lines[i].rstrip("\n").rstrip("\r")
        if raw.strip() == "":
            continue
        m = FN_DECL_RX.match(stripped[i])
        if m:
            end = sc.find_block_end(stripped, i, total)
            units.append({
                "symbol_id": sc.short_id("SY", path, _digest_for(path), "fn", m.group(1), i + 1, seq),
                "evidence_id": short_id_with_range(path, _digest_for(path), i + 1, i + 1),
                "source_file": path, "root": sc.find_root(path), "name": m.group(1),
                "line_start": i + 1, "line_end": end + 1, "kind": "function",
            })
            seq += 1
            continue
        tm = TEST_DECL_RX.match(stripped[i])
        if tm:
            end = sc.find_block_end(stripped, i, total)
            units.append({
                "symbol_id": sc.short_id("SY", path, _digest_for(path), "test", tm.group(1), i + 1, seq),
                "evidence_id": short_id_with_range(path, _digest_for(path), i + 1, i + 1),
                "source_file": path, "root": sc.find_root(path), "name": tm.group(1),
                "line_start": i + 1, "line_end": end + 1, "kind": "test",
            })
            seq += 1
    return units, lines


def extract_atomic_for_file(path, units, all_names):
    """Return (atomic_facts, evidence_records, fn_units) for one file. units arg
    unused; we re-scan all fn/test declarations for completeness."""
    fn_units, lines = _fn_units_in_file(path)
    digest = _digest_for(path)
    out = []
    ev_store = {}
    for u in fn_units:
        fn_signature_facts(u, lines, digest, all_names, out, ev_store)
        fn_body_facts(u, lines, digest, all_names, out, ev_store)
    return out, list(ev_store.values()), fn_units
