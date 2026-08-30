"""Per-type extractors for the B+ knowledge pyramid.

Each extractor turns one file into a lightweight record dict:
  {
    "symbols": [(name, kind, line0, line1), ...],
    "calls":   [(caller_name, callee_name), ...],   # same-file, resolved later
    "imports": [(src_name_or_None, target_path), ...],
  }
No full source text is kept in memory as objects; only dense integer records
are later written to the store. Binaries yield no symbols (metadata only).
"""
import re
import ast
import json
import tomllib
import configparser

# ---- Zig ----
ZIG_DECL = re.compile(
    r"\b(pub\s+)?(?:fn|const|var|struct|enum|union|opaque|error|type)\b\s+([A-Za-z_][A-Za-z0-9_]*)"
)
ZIG_IMPORT = re.compile(r'(?:@import|import)\s*\(\s*"([^"]+)"\s*\)')
ZIG_CALL = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def _zig(text):
    lines = text.splitlines()
    syms = []
    calls = []
    imports = []
    for i, ln in enumerate(lines, 1):
        for m in ZIG_DECL.finditer(ln):
            name = m.group(2)
            raw = m.group(0).split()
            is_pub = raw[0] == "pub"
            kw = raw[1] if is_pub else raw[0]
            kind = ("pub_" if is_pub else "") + kw
            syms.append((name, "zig_" + kind, i, i))
        for m in ZIG_IMPORT.finditer(ln):
            imports.append((None, m.group(1)))
    # calls: only count call-sites that look like function calls
    for i, ln in enumerate(lines, 1):
        for m in ZIG_CALL.finditer(ln):
            calls.append((i, m.group(1)))
    return {"symbols": syms, "calls": calls, "imports": imports}


# ---- Python ----
def _python(text):
    syms, calls, imports = [], [], []
    try:
        tree = ast.parse(text)
    except Exception:
        return {"symbols": syms, "calls": calls, "imports": imports}
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            syms.append((node.name, "py_func", node.lineno, node.end_lineno or node.lineno))
        elif isinstance(node, ast.ClassDef):
            syms.append((node.name, "py_class", node.lineno, node.end_lineno or node.lineno))
        elif isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            syms.append((node.targets[0].id, "py_const", node.lineno, node.lineno))
        elif isinstance(node, ast.ImportFrom):
            for a in node.names:
                imports.append((None, (node.module or "") + "." + a.name))
        elif isinstance(node, ast.Import):
            for a in node.names:
                imports.append((None, a.name))
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            calls.append((node.lineno, node.func.id))
    return {"symbols": syms, "calls": calls, "imports": imports}


# ---- JSON / TOML / INI / YAML / MD (key/structure extraction) ----
_KEY = re.compile(r'"([^"]+)"\s*:')
_TOML_KV = re.compile(r'^\s*([A-Za-z_][\w.\-]*)\s*=', re.M)
_INI_SEC = re.compile(r'^\s*\[([^\]]+)\]', re.M)
_INI_KV = re.compile(r'^\s*([A-Za-z_][\w.\-]*)\s*=', re.M)
_YAML_KV = re.compile(r'^(\s*)([A-Za-z_][\w.\-]*)\s*:', re.M)
_MD_H = re.compile(r'^(#{1,6})\s+(.*)', re.M)
_MD_CODE = re.compile(r'```', re.M)


def _json(text):
    syms = []
    for i, ln in enumerate(text.splitlines(), 1):
        for m in _KEY.finditer(ln):
            syms.append((m.group(1), "json_key", i, i))
    return {"symbols": syms, "calls": [], "imports": []}


def _toml(text):
    syms = []
    for i, ln in enumerate(text.splitlines(), 1):
        for m in _TOML_KV.finditer(ln):
            syms.append((m.group(1), "toml_key", i, i))
        for m in _INI_SEC.finditer(ln):
            syms.append((m.group(1), "toml_section", i, i))
    return {"symbols": syms, "calls": [], "imports": []}


def _ini(text):
    syms = []
    cur = ""
    for i, ln in enumerate(text.splitlines(), 1):
        for m in _INI_SEC.finditer(ln):
            cur = m.group(1)
            syms.append((cur, "ini_section", i, i))
        for m in _INI_KV.finditer(ln):
            syms.append((f"{cur}.{m.group(1)}" if cur else m.group(1), "ini_key", i, i))
    return {"symbols": syms, "calls": [], "imports": []}


def _yaml(text):
    syms = []
    for i, ln in enumerate(text.splitlines(), 1):
        for m in _YAML_KV.finditer(ln):
            syms.append((m.group(2), "yaml_key", i, i))
    return {"symbols": syms, "calls": [], "imports": []}


def _md(text):
    syms = []
    for i, ln in enumerate(text.splitlines(), 1):
        for m in _MD_H.finditer(ln):
            syms.append((m.group(2).strip(), "md_heading", i, i))
    return {"symbols": syms, "calls": [], "imports": []}


def extract(path, text, ext):
    if ext == ".zig":
        return _zig(text)
    if ext == ".py":
        return _python(text)
    if ext in (".json",):
        return _json(text)
    if ext in (".toml",):
        return _toml(text)
    if ext in (".ini",):
        return _ini(text)
    if ext in (".yaml", ".yml"):
        return _yaml(text)
    if ext in (".md", ".markdown"):
        return _md(text)
    return {"symbols": [], "calls": [], "imports": []}
