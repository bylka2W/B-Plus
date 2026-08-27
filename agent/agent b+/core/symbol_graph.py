import os
import json
import re
import time
import hashlib
from pathlib import Path
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set, Tuple
from core.state_tables import short_id


@dataclass
class SymbolNode:
    symbol_id: str
    name: str
    kind: str
    file_id: str = ""
    line_start: int = 0
    line_end: int = 0
    module: str = ""
    signature: str = ""

    def to_dict(self) -> Dict:
        return {
            "symbol_id": self.symbol_id, "name": self.name,
            "kind": self.kind, "file_id": self.file_id,
            "line_start": self.line_start, "line_end": self.line_end,
            "module": self.module, "signature": self.signature,
        }


@dataclass
class Relation:
    relation_id: str
    source_id: str
    target_id: str
    relation_type: str
    evidence_id: str = ""
    confidence: float = 1.0
    status: str = "verified"

    def to_dict(self) -> Dict:
        return {
            "relation_id": self.relation_id, "source_id": self.source_id,
            "target_id": self.target_id, "relation_type": self.relation_type,
            "evidence_id": self.evidence_id, "confidence": self.confidence,
            "status": self.status,
        }


RELATION_TYPES = {
    "defined_in": "symbol is defined in file",
    "declared_in": "symbol is declared in module",
    "calls": "symbol calls another symbol",
    "called_by": "symbol is called by another",
    "uses": "symbol uses another type/value",
    "used_by": "symbol is used by another",
    "depends_on": "symbol depends on another",
    "referenced_by": "symbol is referenced in code",
    "tested_by": "symbol has tests",
    "imports": "file/module imports another",
    "extends": "symbol extends another",
    "implements": "symbol implements interface",
    "overrides": "symbol overrides another",
    "contains": "file/module contains symbol",
    "imports_from": "file imports from module",
}

SYMBOL_KINDS = {
    "fn": "function",
    "pub fn": "public function",
    "struct": "struct",
    "enum": "enum",
    "union": "union",
    "const": "constant",
    "var": "variable",
    "test": "test",
    "pub": "public declaration",
    "type": "type alias",
    "comptime": "comptime block",
}

IDENT_PATTERN = re.compile(r"\b([A-Z][a-zA-Z0-9_]+|[a-z_][a-zA-Z0-9_]+)\b")
FN_PATTERN = re.compile(r"(?:pub\s+)?fn\s+(\w+)")
STRUCT_PATTERN = re.compile(r"(?:pub\s+)?struct\s+(\w+)")
CONST_STRUCT_PATTERN = re.compile(r"pub\s+const\s+(\w+)\s*=\s*struct\s*\{")
ENUM_PATTERN = re.compile(r"(?:pub\s+)?enum\s+(\w+)")
UNION_PATTERN = re.compile(r"(?:pub\s+)?union\s+(\w+)")
CONST_PATTERN = re.compile(r"(?:pub\s+)?const\s+(\w+)")
VAR_PATTERN = re.compile(r"(?:pub\s+)?var\s+(\w+)")
TEST_PATTERN = re.compile(r"test\s+\"([^\"]+)\"")
IMPORT_PATTERN = re.compile(r'@import\("([^"]+)"\)')
CALL_PATTERN = re.compile(r"(\w+)\s*\(")


class SymbolGraph:
    def __init__(self, source_index=None, knowledge=None):
        self.source_index = source_index
        self.knowledge = knowledge
        self.symbols: Dict[str, SymbolNode] = {}
        self.relations: List[Relation] = []
        self._name_index: Dict[str, List[str]] = {}
        self._file_index: Dict[str, List[str]] = {}
        self._file_paths: Dict[str, str] = {}
        self._relation_index: Dict[str, List[Relation]] = {}
        self._built = False

    def build(self):
        if self._built:
            return
        t0 = time.monotonic()

        if self.source_index:
            self._index_source_files()

        if self.knowledge:
            self._index_knowledge()

        self._build_type_relations()

        self._build_relation_indices()
        self._built = True
        elapsed = time.monotonic() - t0
        print(f"  SymbolGraph: {len(self.symbols)} symbols, {len(self.relations)} relations [{elapsed:.1f}s]")

    # ------------------------------------------------------------------
    # Location extraction (balanced braces, aware of strings & comments)
    # ------------------------------------------------------------------
    @staticmethod
    def _in_string_or_comment(text: str, pos: int) -> bool:
        # Slow O(pos) scan; prefer the per-file mask built by _compute_code_mask.
        n = len(text)
        i = 0
        while i < n:
            if i == pos:
                return False
            ch = text[i]
            if ch == '"':
                i += 1
                while i < n and text[i] != '"':
                    if text[i] == "\\":
                        i += 1
                    i += 1
                i += 1
            elif ch == "'":
                i += 1
                while i < n and text[i] != "'":
                    if text[i] == "\\":
                        i += 1
                    i += 1
                i += 1
            elif ch == "/" and i + 1 < n and text[i + 1] == "/":
                while i < n and text[i] != "\n":
                    i += 1
            elif ch == "/" and i + 1 < n and text[i + 1] == "*":
                i += 2
                while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                    i += 1
                i += 1
            else:
                i += 1
        return True

    @staticmethod
    def _compute_code_mask(text: str) -> "bytearray":
        """One-pass mask: code_mask[i] == 1 when position i is inside a
        string literal, char literal, or a // or /* */ comment."""
        n = len(text)
        mask = bytearray(n)
        i = 0
        while i < n:
            ch = text[i]
            if ch == '"':
                mask[i] = 1
                i += 1
                while i < n and text[i] != '"':
                    if text[i] == "\\":
                        mask[i] = 1
                        i += 1
                    mask[i] = 1
                    i += 1
                if i < n:
                    mask[i] = 1
                    i += 1
            elif ch == "'":
                mask[i] = 1
                i += 1
                while i < n and text[i] != "'":
                    if text[i] == "\\":
                        mask[i] = 1
                        i += 1
                    mask[i] = 1
                    i += 1
                if i < n:
                    mask[i] = 1
                    i += 1
            elif ch == "/" and i + 1 < n and text[i + 1] == "/":
                mask[i] = 1
                i += 1
                while i < n and text[i] != "\n":
                    mask[i] = 1
                    i += 1
            elif ch == "/" and i + 1 < n and text[i + 1] == "*":
                mask[i] = 1
                i += 1
                while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                    mask[i] = 1
                    i += 1
                if i + 1 < n:
                    mask[i] = 1
                    mask[i + 1] = 1
                    i += 2
            else:
                i += 1
        return mask

    @staticmethod
    def _compute_line_offsets(text: str) -> List[int]:
        offsets = [0]
        for i, ch in enumerate(text):
            if ch == "\n":
                offsets.append(i + 1)
        return offsets

    @staticmethod
    def _line_of(offsets: List[int], pos: int) -> int:
        lo, hi = 0, len(offsets) - 1
        while lo <= hi:
            mid = (lo + hi) // 2
            if offsets[mid] <= pos:
                lo = mid + 1
            else:
                hi = mid - 1
        return hi + 1

    @staticmethod
    def _matching_close(text: str, open_idx: int) -> Optional[int]:
        depth = 0
        i = open_idx
        n = len(text)
        while i < n:
            ch = text[i]
            if ch == '"':
                i += 1
                while i < n and text[i] != '"':
                    if text[i] == "\\":
                        i += 1
                    i += 1
            elif ch == "'":
                i += 1
                while i < n and text[i] != "'":
                    if text[i] == "\\":
                        i += 1
                    i += 1
                if i > n:
                    break
            elif ch == "/" and i + 1 < n and text[i + 1] == "/":
                while i < n and text[i] != "\n":
                    i += 1
                i -= 1
            elif ch == "/" and i + 1 < n and text[i + 1] == "*":
                i += 2
                while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                    i += 1
                i += 1
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return i
            i += 1
        return None

    def _find_block(self, text: str, open_idx: int):
        close_idx = self._matching_close(text, open_idx)
        if close_idx is None:
            return None
        return (open_idx, close_idx)

    @staticmethod
    def _first_brace_outside(text: str, start: int) -> Optional[int]:
        n = len(text)
        i = start
        while i < n:
            ch = text[i]
            if ch == '"':
                i += 1
                while i < n and text[i] != '"':
                    if text[i] == "\\":
                        i += 1
                    i += 1
            elif ch == "'":
                i += 1
                while i < n and text[i] != "'":
                    if text[i] == "\\":
                        i += 1
                    i += 1
            elif ch == "/" and i + 1 < n and text[i + 1] == "/":
                while i < n and text[i] != "\n":
                    i += 1
                i -= 1
            elif ch == "/" and i + 1 < n and text[i + 1] == "*":
                i += 2
                while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                    i += 1
                i += 1
            elif ch == "{":
                return i
            i += 1
        return None

    def _signature_for(self, text: str, start: int) -> str:
        br = self._first_brace_outside(text, start)
        if br is not None:
            return text[start:br].strip()
        eol = text.find("\n", start)
        semi = text.find(";", start)
        cand = [x for x in (eol, semi) if x != -1]
        end = min(cand) if cand else len(text)
        return text[start:end].strip()

    def _block_signature(self, text: str, ls: int, le: int) -> str:
        start = self._lines[ls - 1]
        end = self._lines[le] if le < len(self._lines) else len(text)
        return text[start:end].strip()

    def _symbol_extent(self, text: str, name_start: int) -> Tuple[int, int]:
        line_offsets = self._lines
        n = len(text)
        brace_start = self._first_brace_outside(text, name_start)
        semicolon = text.find(";", name_start)
        if brace_start is not None and (semicolon == -1 or brace_start < semicolon):
            block = self._find_block(text, brace_start)
            if block is not None:
                _, close_idx = block
                return (self._line_of(line_offsets, name_start),
                        self._line_of(line_offsets, close_idx))
        if semicolon != -1:
            return (self._line_of(line_offsets, name_start),
                    self._line_of(line_offsets, semicolon))
        return (self._line_of(line_offsets, name_start),
                self._line_of(line_offsets, min(n - 1, name_start)))

    def _index_source_files(self):
        files = self.source_index.files if hasattr(self.source_index, 'files') else []
        if isinstance(files, dict):
            file_list = list(files.keys())
        elif isinstance(files, list):
            file_list = files
        else:
            file_list = []

        for fpath in file_list[:1000]:
            if not fpath.endswith(".zig"):
                continue
            try:
                content = self.source_index.read_file(fpath)
                if not content:
                    continue
                text = "".join(content) if isinstance(content, list) else content
                self._parse_file(fpath, text)
            except Exception:
                pass

    def _register(self, name, kind, sym_id, fpath, file_id, module,
                  line_start=0, line_end=0, signature=""):
        node = SymbolNode(symbol_id=sym_id, name=name, kind=kind,
                        file_id=file_id, module=module,
                        line_start=line_start, line_end=line_end,
                        signature=signature)
        self.symbols[sym_id] = node
        self._add_to_name_index(name, sym_id)
        self._add_to_file_index(file_id, sym_id)
        rel = Relation(
            relation_id=short_id("REL", sym_id, "defined_in", file_id),
            source_id=sym_id, target_id=file_id, relation_type="defined_in",
        )
        self.relations.append(rel)
        return node

    def _parse_file(self, fpath: str, text: str):
        file_id = short_id("FILE", fpath)
        self._file_paths[file_id] = fpath
        basename = os.path.basename(fpath)
        module = basename.replace(".zig", "")
        self._lines = self._compute_line_offsets(text)
        self._mask = self._compute_code_mask(text)

        seen = set()
        for m in FN_PATTERN.finditer(text):
            name = m.group(1)
            if self._mask[m.start()]:
                continue
            sym_id = short_id("SYM", fpath, name)
            if sym_id in seen:
                continue
            seen.add(sym_id)
            ls, le = self._symbol_extent(text, m.start())
            sig = self._signature_for(text, m.start())
            self._register(name, "fn", sym_id, fpath, file_id, module, ls, le, sig)

        for m in STRUCT_PATTERN.finditer(text):
            name = m.group(1)
            if self._mask[m.start()]:
                continue
            sym_id = short_id("SYM", fpath, name)
            if sym_id in seen:
                continue
            seen.add(sym_id)
            ls, le = self._symbol_extent(text, m.start())
            sig = self._block_signature(text, ls, le)
            self._register(name, "struct", sym_id, fpath, file_id, module, ls, le, sig)

        for m in CONST_STRUCT_PATTERN.finditer(text):
            name = m.group(1)
            if self._mask[m.start()]:
                continue
            sym_id = short_id("SYM", fpath, name)
            if sym_id in seen:
                continue
            seen.add(sym_id)
            ls, le = self._symbol_extent(text, m.start())
            sig = self._block_signature(text, ls, le)
            self._register(name, "struct", sym_id, fpath, file_id, module, ls, le, sig)

        for m in ENUM_PATTERN.finditer(text):
            name = m.group(1)
            if self._mask[m.start()]:
                continue
            sym_id = short_id("SYM", fpath, name)
            if sym_id in seen:
                continue
            seen.add(sym_id)
            ls, le = self._symbol_extent(text, m.start())
            sig = self._block_signature(text, ls, le)
            self._register(name, "enum", sym_id, fpath, file_id, module, ls, le, sig)

        for m in UNION_PATTERN.finditer(text):
            name = m.group(1)
            if self._mask[m.start()]:
                continue
            sym_id = short_id("SYM", fpath, name)
            if sym_id in seen:
                continue
            seen.add(sym_id)
            ls, le = self._symbol_extent(text, m.start())
            sig = self._block_signature(text, ls, le)
            self._register(name, "union", sym_id, fpath, file_id, module, ls, le, sig)

        for m in CONST_PATTERN.finditer(text):
            name = m.group(1)
            if self._mask[m.start()]:
                continue
            if name.isupper() and len(name) > 2:
                sym_id = short_id("SYM", fpath, name)
                if sym_id in seen:
                    continue
                seen.add(sym_id)
                ls, le = self._symbol_extent(text, m.start())
                sig = self._signature_for(text, m.start())
                self._register(name, "const", sym_id, fpath, file_id, module, ls, le, sig)

        for m in VAR_PATTERN.finditer(text):
            name = m.group(1)
            if self._mask[m.start()]:
                continue
            sym_id = short_id("SYM", fpath, name)
            if sym_id in seen:
                continue
            seen.add(sym_id)
            ls, le = self._symbol_extent(text, m.start())
            sig = self._signature_for(text, m.start())
            self._register(name, "var", sym_id, fpath, file_id, module, ls, le, sig)

        for m in TEST_PATTERN.finditer(text):
            name = m.group(1)
            if self._mask[m.start()]:
                continue
            sym_id = short_id("SYM", fpath, f"test_{name}")
            if sym_id in seen:
                continue
            seen.add(sym_id)
            ls, le = self._symbol_extent(text, m.start())
            self._register(name, "test", sym_id, fpath, file_id, module, ls, le)

        for m in IMPORT_PATTERN.finditer(text):
            mod = m.group(1)
            target_file = os.path.join(os.path.dirname(fpath), mod)
            target_id = short_id("FILE", target_file)
            rel = Relation(
                relation_id=short_id("REL", file_id, "imports", target_id),
                source_id=file_id, target_id=target_id, relation_type="imports",
            )
            self.relations.append(rel)

        calls = CALL_PATTERN.findall(text)
        for call_name in set(calls):
            call_targets = self._name_index.get(call_name, [])
            caller_fns = [sid for sid in self._file_index.get(file_id, [])
                         if self.symbols.get(sid, SymbolNode("", "", "")).kind in ("fn", "pub fn")]
            for caller in caller_fns[:3]:
                for target in call_targets[:3]:
                    if caller != target:
                        rel = Relation(
                            relation_id=short_id("REL", caller, "calls", target),
                            source_id=caller, target_id=target, relation_type="calls",
                        )
                        self.relations.append(rel)

    def _index_knowledge(self):
        if not hasattr(self.knowledge, 'concepts'):
            return
        for name, concept in self.knowledge.concepts.items():
            if isinstance(concept, dict):
                sym_id = short_id("SYM", "kb", name)
                kind = concept.get("concept_type", "concept")
                node = SymbolNode(symbol_id=sym_id, name=name, kind=kind, module="knowledge")
                self.symbols[sym_id] = node
                self._add_to_name_index(name, sym_id)

    def _add_to_name_index(self, name: str, sym_id: str):
        if name not in self._name_index:
            self._name_index[name] = []
        self._name_index[name].append(sym_id)

    def _add_to_file_index(self, file_id: str, sym_id: str):
        if file_id not in self._file_index:
            self._file_index[file_id] = []
        self._file_index[file_id].append(sym_id)

    TYPE_KEYWORDS = {
        "fn", "pub", "const", "struct", "enum", "union", "var", "extern",
        "comptime", "align", "linksection", "callconv", "packed", "opaque",
        "type", "anytype", "void", "bool", "noreturn", "null", "true", "false",
        "undefined", "this", "self", "noalias", "volatile", "error", "return",
        "if", "else", "while", "for", "switch", "case", "break", "continue",
        "try", "catch", "defer", "errdefer", "and", "or", "not", "await",
        "suspend", "resume", "unreachable", "usingnamespace", "test",
        "anyframe", "union", "threadlocal", "asm", "std", "builtin",
        "testing", "mem", "math", "io", "fmt", "heap", "c",
    }

    def _build_type_relations(self):
        if not self.source_index:
            return
        seen = set()
        for sym_id, node in self.symbols.items():
            if node.kind not in ("fn", "struct", "enum", "union"):
                continue
            if not node.signature or not node.file_id or node.line_start < 1:
                continue
            fpath = self._file_paths.get(node.file_id, "")
            if not fpath:
                continue
            source_slice = self.source_index.read_file(
                fpath, node.line_start, node.line_end)
            sha = hashlib.sha256(source_slice.encode("utf-8", "replace")).hexdigest()
            evid = short_id("EVID", node.file_id, node.line_start,
                            node.line_end, sha[:16])
            types = self._extract_types(node)
            for tname, rtype in types:
                tid = self._resolve_type_ref(tname)
                if tid is None or tid == sym_id:
                    continue
                key = (sym_id, tid, rtype)
                if key in seen:
                    continue
                seen.add(key)
                rel = Relation(
                    relation_id=short_id("REL", sym_id, rtype, tid),
                    source_id=sym_id, target_id=tid,
                    relation_type=rtype, evidence_id=evid, status="verified",
                )
                self.relations.append(rel)

    def _extract_types(self, node) -> List[Tuple[str, str]]:
        """Return list of (type_name, relation_type) from a symbol's signature."""
        out = []
        if node.kind == "fn":
            sig = node.signature
            open_i = sig.find("(")
            if open_i == -1:
                return out
            # walk to matching close paren (strings/braces skipped simply)
            depth = 0
            close_i = -1
            for i in range(open_i, len(sig)):
                c = sig[i]
                if c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                    if depth == 0:
                        close_i = i
                        break
            params = sig[open_i + 1: close_i] if close_i != -1 else ""
            ret = sig[close_i + 1:] if close_i != -1 else ""
            # param type refs
            for chunk in self._split_top(params):
                if ":" not in chunk:
                    continue
                colon = chunk.find(":")
                pt = chunk[colon + 1:]
                for ti in self._type_idents(pt):
                    out.append((ti, "use_type"))
            # return / error type refs
            for ti in self._type_idents(ret):
                out.append((ti, "return_type"))
            return out
        if node.kind in ("struct", "enum", "union"):
            # field declarations: NAME : Type
            for m in re.finditer(r"(\b[A-Za-z_]\w*)\s*:\s*", node.signature):
                start = m.end()
                seg = node.signature[start:start + 60]
                seg = seg.split("\n")[0]
                # cut at assignment or comma or brace
                for cut in [" =", ",\n", "\n,", ", ", ";\n", " {"]:
                    idx = seg.find(cut)
                    if idx != -1:
                        seg = seg[:idx]
                        break
                for ti in self._type_idents(seg):
                    out.append((ti, "field_type"))
            return out
        return out

    @staticmethod
    def _split_top(params: str) -> List[str]:
        parts, depth, cur = [], 0, []
        for c in params:
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            if c == "," and depth == 0:
                parts.append("".join(cur))
                cur = []
            else:
                cur.append(c)
        if cur:
            parts.append("".join(cur))
        return parts

    def _type_idents(self, fragment: str) -> List[str]:
        idents = []
        for m in re.finditer(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*", fragment):
            tok = m.group(0)
            head = tok.split(".")[0]
            tail = tok.split(".")[-1]
            cands = []
            if tail not in self.TYPE_KEYWORDS:
                cands.append(tail)
            if head not in self.TYPE_KEYWORDS:
                cands.append(head)
            for c in cands:
                if c.isdigit() or c.lower() in {
                    "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64",
                    "usize", "isize", "f16", "f32", "f64", "c_int", "c_long",
                    "bool", "void", "anyopaque", "anytype", "noreturn",
                }:
                    continue
                if c not in idents:
                    idents.append(c)
        return idents

    def _resolve_type_ref(self, name: str) -> Optional[str]:
        cands = self._name_index.get(name, [])
        if not cands:
            return None
        for sid in cands:
            n = self.symbols.get(sid)
            if n and n.kind in ("struct", "enum", "union", "type", "const"):
                return sid
        return cands[0]

    def _build_relation_indices(self):
        self._relation_index = {}
        for rel in self.relations:
            for key in [rel.source_id, rel.target_id]:
                if key not in self._relation_index:
                    self._relation_index[key] = []
                self._relation_index[key].append(rel)

    def lookup(self, name: str) -> List[SymbolNode]:
        sym_ids = self._name_index.get(name, [])
        return [self.symbols[sid] for sid in sym_ids if sid in self.symbols]

    def get_relations(self, symbol_id: str, relation_type: str = None) -> List[Relation]:
        rels = self._relation_index.get(symbol_id, [])
        if relation_type:
            rels = [r for r in rels if r.relation_type == relation_type]
        return rels

    def get_defined_in(self, symbol_id: str) -> List[Relation]:
        return self.get_relations(symbol_id, "defined_in")

    def get_calls(self, symbol_id: str) -> List[Relation]:
        return self.get_relations(symbol_id, "calls")

    def get_called_by(self, symbol_id: str) -> List[Relation]:
        return [r for r in self.relations
                if r.target_id == symbol_id and r.relation_type == "calls"]

    def get_uses(self, symbol_id: str) -> List[Relation]:
        return self.get_relations(symbol_id, "uses")

    def get_imports(self, file_id: str) -> List[Relation]:
        return self.get_relations(file_id, "imports")

    def get_file_symbols(self, file_id: str) -> List[SymbolNode]:
        sym_ids = self._file_index.get(file_id, [])
        return [self.symbols[sid] for sid in sym_ids if sid in self.symbols]

    def inspect(self, name: str) -> Dict:
        nodes = self.lookup(name)
        if not nodes:
            return {"name": name, "found": False}

        node = nodes[0]
        kind = node.kind
        module = node.module

        files = set()
        callees = set()
        callers = set()
        use_names = set()
        relation_ids = set()

        for n in nodes:
            defined_in = self.get_defined_in(n.symbol_id)
            calls_rels = self.get_calls(n.symbol_id)
            called_by = self.get_called_by(n.symbol_id)
            uses = self.get_uses(n.symbol_id)

            for r in defined_in:
                files.add(self._file_paths.get(r.target_id, r.target_id))
                relation_ids.add(r.relation_id)

            for r in calls_rels:
                relation_ids.add(r.relation_id)
                target = self.symbols.get(r.target_id)
                if target:
                    callees.add(target.name)

            for r in called_by:
                relation_ids.add(r.relation_id)
                source = self.symbols.get(r.source_id)
                if source:
                    callers.add(source.name)

            for r in uses:
                relation_ids.add(r.relation_id)
                target = self.symbols.get(r.target_id)
                if target:
                    use_names.add(target.name)

            for r in self.get_relations(n.symbol_id):
                relation_ids.add(r.relation_id)

        facts = []
        if self.knowledge:
            facts = self.knowledge.query_symbol(name)[:10]

        evidence = []
        if self.knowledge and hasattr(self.knowledge, 'evidence'):
            for ev in self.knowledge.evidence:
                if name.lower() in json.dumps(ev, ensure_ascii=False).lower():
                    evidence.append(ev)

        return {
            "name": name,
            "found": True,
            "kind": kind,
            "module": module,
            "files": list(files),
            "callees": list(callees),
            "callers": list(callers),
            "uses": list(use_names),
            "facts_count": len(facts),
            "evidence_count": len(evidence),
            "relation_count": len(relation_ids),
        }

    def get_stats(self) -> Dict:
        kinds = {}
        for node in self.symbols.values():
            kinds[node.kind] = kinds.get(node.kind, 0) + 1
        rel_types = {}
        for rel in self.relations:
            rel_types[rel.relation_type] = rel_types.get(rel.relation_type, 0) + 1
        return {
            "symbols": len(self.symbols),
            "relations": len(self.relations),
            "kinds": kinds,
            "relation_types": rel_types,
            "built": self._built,
        }

    def save(self, path: str):
        data = {
            "symbols": {k: v.to_dict() for k, v in self.symbols.items()},
            "relations": [r.to_dict() for r in self.relations],
            "file_paths": self._file_paths,
        }
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def load(self, path: str):
        if not os.path.exists(path):
            return
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        self._file_paths = data.get("file_paths", {})
        for sid, sd in data.get("symbols", {}).items():
            self.symbols[sid] = SymbolNode(**{k: v for k, v in sd.items()
                                              if k in SymbolNode.__dataclass_fields__})
        for rd in data.get("relations", []):
            self.relations.append(Relation(**{k: v for k, v in rd.items()
                                              if k in Relation.__dataclass_fields__}))
        for node in self.symbols.values():
            self._add_to_name_index(node.name, node.symbol_id)
            if node.file_id:
                self._add_to_file_index(node.file_id, node.symbol_id)
        self._build_relation_indices()
        self._built = True
