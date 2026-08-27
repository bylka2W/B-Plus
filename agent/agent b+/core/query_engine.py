import re
import json
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional
from core.tool_registry import ToolExecutionEngine, ToolResult


@dataclass
class QueryIntent:
    intent_type: str = "unknown"
    confidence: float = 0.0
    entities: List[str] = field(default_factory=list)
    files: List[str] = field(default_factory=list)
    symbols: List[str] = field(default_factory=list)
    language: str = "unknown"
    requires_code: bool = False
    requires_explanation: bool = False


@dataclass
class RouteStep:
    tool: str
    params: Dict
    result: Optional[Dict] = None


@dataclass
class QueryResult:
    intent: QueryIntent
    facts: List[Dict] = field(default_factory=list)
    evidence: List[Dict] = field(default_factory=list)
    relations: List[Dict] = field(default_factory=list)
    source_files: List[Dict] = field(default_factory=list)
    verified_context: str = ""
    provenance: List[Dict] = field(default_factory=list)
    errors: List[str] = field(default_factory=list)
    route: str = ""
    steps: List[RouteStep] = field(default_factory=list)
    trace: List[Dict] = field(default_factory=list)


INTENT_PATTERNS = {
    "locate": [
        r"(?:где|where)\s+(?:находится|is|located|определ)",
        r"(?:в|in|inside)\s+(?:каком|which)\s+(?:файле|file)",
        r"(?:в|in)\s+какой\s+(?:директории|папке|folder|directory)",
        r"(?:где|where)\s+(?:определ|объявл|defined|declared)",
        r"^\s*(?:где|where)\s+[A-Za-zА-Яа-я_]+",
    ],
    "references": [
        r"(?:кто|who)\s+(?:использует|uses|calls|вызывает)",
        r"(?:где|where)\s+(?:используется|is\s+used|used)",
        r"(?:кто)\s+(?:ссылается|references|refs)",
        r"(?:references|refs)\s+(?:to|на)\s+",
        r"(?:зависит|depends\s+on)\s+",
    ],
    "how": [
        r"(?:как|how)\s+(?:работает|works|does|устроен|implemented|реализован)",
        r"(?:как|how)\s+(?:сделано|built|is\s+built)",
    ],
    "why": [
        r"(?:почему|why)\s+(?!.*\b(?:не|not)\b)",
        r"(?:зачем|what.*for)\s+",
        r"(?:причина|reason)\s+",
    ],
    "compare": [
        r"(?:сравни|compare)\s+",
        r"(?:разница|difference)\s+(?:между|between)",
        r"(?:vs\.?|versus)\s+",
        r"(?:отличие|distinguish)\s+",
    ],
    "trace": [
        r"(?:проследи|trace|follow)\s+",
        r"(?:цепочк|chain)\s+",
        r"(?:путь|path)\s+(?:вызова|call)\s+",
    ],
    "explain": [
        r"(?:что|what)\s+(?:такое|is)\s+",
        r"(?:объясни|explain)\s+",
    ],
    "fix": [
        r"(?:почему|why)\s+.*(?:не|not)\s+(?:работает|works)",
        r"(?:исправь|fix|repair)\s+",
        r"(?:ошибка|error)\s+",
        r"(?:поломал|broken)\s+",
    ],
    "create": [
        r"(?:создай|create|make|write)\s+",
        r"(?:напиши|write)\s+",
        r"(?:добавь|add)\s+",
    ],
    "greet": [
        r"(?:привет|hello|hi|hey|здравствуй)",
    ],
    "test": [
        r"(?:запусти|run|execute)\s+(?:тест|test)",
        r"(?:проверь|check|verify)\s+",
    ],
}

ENTITY_PATTERNS = [
    re.compile(r"\b([A-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)*)\b"),
    re.compile(r"\b(\w+\.(?:zig|json|txt|md))\b"),
    re.compile(r"\b(\w+_\w+)\b"),
]


class QueryEngine:
    def __init__(self, registry: ToolExecutionEngine, symbol_graph=None):
        self.registry = registry
        self.symbol_graph = symbol_graph

    def analyze_intent(self, question: str) -> QueryIntent:
        intent = QueryIntent()
        q_lower = question.lower()

        for itype, patterns in INTENT_PATTERNS.items():
            for pat in patterns:
                if re.search(pat, q_lower):
                    intent.intent_type = itype
                    intent.confidence = 0.8
                    break
            if intent.intent_type != "unknown":
                break

        if intent.intent_type == "unknown":
            intent.intent_type = "explain"
            intent.confidence = 0.4

        entities = set()
        for pat in ENTITY_PATTERNS:
            for m in pat.finditer(question):
                entities.add(m.group(1))
        intent.entities = list(entities)

        symbols = [e for e in intent.entities
                   if re.match(r"^[A-Z][a-zA-Z0-9_.-]+$", e)]
        intent.symbols = symbols

        files = [e for e in intent.entities
                 if re.search(r"\.(?:zig|json|txt|md|yaml|yml)$", e, re.IGNORECASE)]
        intent.files = files

        intent.language = "russian" if re.search(r"[а-яА-ЯёЁ]", question) else "english"
        intent.requires_code = intent.intent_type in ("create", "fix")
        intent.requires_explanation = intent.intent_type in ("explain", "locate", "how", "why",
                                                             "compare", "trace", "references", "greet")

        return intent

    def query(self, question: str) -> QueryResult:
        intent = self.analyze_intent(question)
        result = QueryResult(intent=intent, route=intent.intent_type)

        try:
            route_method = getattr(self, f"_route_{intent.intent_type}")
        except AttributeError:
            route_method = self._route_explain

        route_method(question, intent, result)

        result.verified_context = self._assemble_context(question, intent, result)
        result.provenance = self._build_provenance(result)
        return result

    def _exec(self, tool: str, result: QueryResult, **params) -> Optional[ToolResult]:
        step = RouteStep(tool=tool, params=params)
        r = self.registry.execute(tool, **params)
        step.result = r.success
        result.steps.append(step)
        if not r.success:
            result.errors.append(f"{tool}: {r.error}")
            return None
        return r

    def _add_facts(self, result: QueryResult, r: ToolResult) -> int:
        count = 0
        if r.data:
            if isinstance(r.data, list):
                for item in r.data:
                    if isinstance(item, dict) and item.get("type") == "fact":
                        result.facts.append(item)
                        count += 1
            elif isinstance(r.data, dict) and r.data.get("facts"):
                result.facts.extend(r.data["facts"])
                count = len(r.data["facts"])
        return count

    def _route_explain(self, question, intent, result):
        for symbol in intent.symbols:
            r = self._exec("source.symbol_lookup", result, symbol=symbol)
            if r and r.data:
                if r.data.get("file_location", {}).get("path"):
                    result.source_files.append({"path": r.data["file_location"]["path"]})
                count = self._add_facts(result, r)
                if count > 0:
                    break

        if not result.facts:
            for symbol in intent.symbols:
                r = self._exec("knowledge.search", result, query=symbol)
                if r and not result.facts:
                    self._add_facts(result, r)

        for symbol in intent.symbols:
            r = self._exec("knowledge.evidence", result, query=symbol)
            if r and r.data:
                result.evidence.extend(r.data[:10])

        if not result.source_files:
            for symbol in intent.symbols:
                r = self._exec("source.search", result, query=symbol)
                if r and r.data:
                    result.source_files.extend(r.data[:5])

        for fl in intent.files:
            r = self._exec("source.read_file", result, file_path=fl)
            if r and r.data and r.data.get("content"):
                result.source_files.append({"path": fl, "content": r.data["content"][:3000]})

    def _route_locate(self, question, intent, result):
        for symbol in intent.symbols:
            r = self._exec("source.symbol_lookup", result, symbol=symbol)
            if r and r.data:
                fl = r.data.get("file_location", {})
                if fl.get("path"):
                    result.source_files.append(fl)

        for symbol in intent.symbols:
            r = self._exec("source.search", result, query=symbol)
            if r and r.data:
                result.source_files.extend(r.data[:5])

        for symbol in intent.symbols:
            r = self._exec("knowledge.evidence", result, query=symbol)
            if r and r.data:
                result.evidence.extend(r.data[:10])

    def _route_references(self, question, intent, result):
        for symbol in intent.symbols:
            r = self._exec("source.symbol_lookup", result, symbol=symbol)
            if r and r.data:
                count = self._add_facts(result, r)

            rel_r = self._exec("knowledge.relations", result, symbol=symbol)
            if rel_r and rel_r.data:
                result.relations.extend(rel_r.data[:30])

            src_r = self._exec("source.search", result, query=symbol)
            if src_r and src_r.data:
                referring = []
                for hit in src_r.data:
                    lines = hit.get("lines") or []
                    matched = [ln for ln in lines if symbol.lower() in ln.lower()]
                    referring.append({"path": hit["path"], "matches": matched[:5]})
                result.source_files.extend(referring)

            ev_r = self._exec("knowledge.evidence", result, query=symbol)
            if ev_r and ev_r.data:
                result.evidence.extend(ev_r.data[:10])

    def _route_how(self, question, intent, result):
        target = intent.symbols[0] if intent.symbols else (intent.entities[0] if intent.entities else "")

        if target:
            r = self._exec("source.symbol_lookup", result, symbol=target)
            if r and r.data:
                count = self._add_facts(result, r)
                fl = r.data.get("file_location", {})
                if fl.get("path"):
                    content_r = self._exec("source.read_file", result, file_path=fl["path"])
                    if content_r and content_r.data:
                        result.source_files.append(
                            {"path": fl["path"], "content": content_r.data.get("content", "")[:3000]})

            rel_r = self._exec("knowledge.relations", result, symbol=target)
            if rel_r and rel_r.data:
                result.relations.extend(rel_r.data[:20])

            ev_r = self._exec("knowledge.evidence", result, query=target)
            if ev_r and ev_r.data:
                result.evidence.extend(ev_r.data[:10])

    def _route_why(self, question, intent, result):
        target = intent.symbols[0] if intent.symbols else (intent.entities[0] if intent.entities else "")
        if target:
            r = self._exec("source.symbol_lookup", result, symbol=target)
            if r and r.data:
                self._add_facts(result, r)
                fl = r.data.get("file_location", {})
                if fl.get("path"):
                    content_r = self._exec("source.read_file", result, file_path=fl["path"])
                    if content_r and content_r.data:
                        result.source_files.append(
                            {"path": fl["path"], "content": content_r.data.get("content", "")[:3000]})

            rel_r = self._exec("knowledge.relations", result, symbol=target)
            if rel_r and rel_r.data:
                result.relations.extend(rel_r.data[:20])

            ev_r = self._exec("knowledge.evidence", result, query=target)
            if ev_r and ev_r.data:
                result.evidence.extend(ev_r.data[:10])

    def _route_compare(self, question, intent, result):
        symbols = intent.symbols[:2]
        for symbol in symbols:
            r = self._exec("source.symbol_lookup", result, symbol=symbol)
            if r and r.data:
                self._add_facts(result, r)
                fl = r.data.get("file_location", {})
                if fl.get("path"):
                    result.source_files.append({"path": fl["path"]})

            ev_r = self._exec("knowledge.evidence", result, query=symbol)
            if ev_r and ev_r.data:
                result.evidence.extend(ev_r.data[:8])

            rel_r = self._exec("knowledge.relations", result, symbol=symbol)
            if rel_r and rel_r.data:
                result.relations.extend(rel_r.data[:15])

    def _split_symbol(self, name: str):
        if "." in name:
            parts = name.split(".")
            return parts[0], ".".join(parts[1:])
        return name, None

    def _route_trace(self, question, intent, result):
        target = intent.symbols[0] if intent.symbols else ""
        if not target:
            return
        base, member = self._split_symbol(target)

        if member:
            self._trace_build_member(result, base, member)
        else:
            self._trace_build(result, base)

    def _trace_build(self, result, symbol):
        r = self._exec("source.symbol_lookup", result, symbol=symbol)
        node = {"symbol": symbol, "kind": None, "file": None, "hops": []}
        if r and r.data:
            self._add_facts(result, r)
            fl = r.data.get("file_location", {})
            defn = r.data.get("definition", {})
            node["kind"] = defn.get("found", False) and "source" or "knowledge"
            if fl.get("path"):
                node["file"] = fl["path"]

        self._append_evidence(result, symbol)
        self._append_relations(result, symbol)

        if self.symbol_graph:
            self._traverse_graph(result, symbol, node, seen=set(), depth=0, max_depth=3)

        result.trace.append(node)
        if node.get("file"):
            result.source_files.append({"path": node["file"]})

    def _trace_build_member(self, result, base, member):
        node = {"symbol": f"{base}.{member}", "kind": "member", "file": None, "hops": []}
        r = self._exec("source.symbol_lookup", result, symbol=base)
        if r and r.data:
            self._add_facts(result, r)
            fl = r.data.get("file_location", {})
            base_file = fl.get("path")
            if base_file:
                node["file"] = base_file
                content_r = self._exec("source.read_file", result, file_path=base_file)
                if content_r and content_r.data:
                    content = content_r.data.get("content", "")
                    for i, line in enumerate(content.split("\n")):
                        if member in line:
                            node["hops"].append(
                                {"symbol": member, "relation": "defined_in",
                                 "file": base_file, "line": i + 1, "text": line.strip()[:160]})
                            break
                result.source_files.append({"path": base_file,
                                            "content": content_r.data.get("content", "")[:3000]})
        self._append_evidence(result, member)
        self._append_relations(result, base)
        if self.symbol_graph:
            self._traverse_graph(result, base, node, seen=set(), depth=0, max_depth=3)
        result.trace.append(node)

    def _append_evidence(self, result, symbol):
        ev_r = self._exec("knowledge.evidence", result, query=symbol)
        if ev_r and ev_r.data:
            result.evidence.extend(ev_r.data[:10])

    def _append_relations(self, result, symbol):
        rel_r = self._exec("knowledge.relations", result, symbol=symbol)
        if rel_r and rel_r.data:
            result.relations.extend(rel_r.data[:40])

    def _traverse_graph(self, result, symbol, node, seen, depth, max_depth):
        if depth >= max_depth or symbol in seen:
            return
        seen.add(symbol)
        if not self.symbol_graph:
            return
        nodes = self.symbol_graph.lookup(symbol)
        for n in nodes[:1]:
            for rel in self.symbol_graph.get_relations(n.symbol_id):
                target = self.symbol_graph.symbols.get(rel.target_id)
                if not target or target.symbol_id == n.symbol_id:
                    continue
                hop = {
                    "symbol": target.name,
                    "relation": rel.relation_type,
                    "relation_id": rel.relation_id,
                    "evidence_id": rel.evidence_id,
                    "file": self.symbol_graph._file_paths.get(target.file_id, ""),
                    "kind": target.kind,
                }
                node["hops"].append(hop)
                ev_r = self._exec("knowledge.evidence", result, query=target.name)
                if ev_r and ev_r.data:
                    result.evidence.extend(ev_r.data[:4])
                if rel.relation_type in ("calls", "uses", "imports"):
                    self._traverse_graph(result, target.name, node, seen, depth + 1, max_depth)

    def _route_fix(self, question, intent, result):
        target = intent.symbols[0] if intent.symbols else ""
        if target:
            r = self._exec("source.symbol_lookup", result, symbol=target)
            if r and r.data:
                self._add_facts(result, r)
                fl = r.data.get("file_location", {})
                if fl.get("path"):
                    content_r = self._exec("source.read_file", result, file_path=fl["path"])
                    if content_r and content_r.data:
                        result.source_files.append(
                            {"path": fl["path"], "content": content_r.data.get("content", "")[:3000]})

            ev_r = self._exec("knowledge.evidence", result, query=target)
            if ev_r and ev_r.data:
                result.evidence.extend(ev_r.data[:10])

    def _route_create(self, question, intent, result):
        for symbol in intent.symbols:
            r = self._exec("knowledge.search", result, query=symbol)
            if r:
                self._add_facts(result, r)

        for symbol in intent.symbols:
            r = self._exec("knowledge.evidence", result, query=symbol)
            if r and r.data:
                result.evidence.extend(r.data[:10])

        if not result.source_files and intent.files:
            for fl in intent.files:
                r = self._exec("source.read_file", result, file_path=fl)
                if r and r.data:
                    result.source_files.append({"path": fl, "content": r.data.get("content", "")[:3000]})

    def _route_test(self, question, intent, result):
        for fl in intent.files:
            r = self._exec("source.read_file", result, file_path=fl)
            if r and r.data:
                result.source_files.append({"path": fl, "content": r.data.get("content", "")[:3000]})

        for symbol in intent.symbols:
            r = self._exec("knowledge.search", result, query=symbol)
            if r:
                self._add_facts(result, r)

    def _route_greet(self, question, intent, result):
        pass

    def _assemble_context(self, question: str, intent: QueryIntent, result: QueryResult) -> str:
        parts = []
        parts.append(f"INTENT: {intent.intent_type}")

        if result.facts:
            fact_lines = []
            for f in result.facts[:10]:
                pred = f.get("predicate", f.get("type", ""))
                subj = f.get("subject", "")
                obj = f.get("object", "")
                sf = f.get("source_file", "")
                if sf:
                    sf = sf.split("\\")[-1] if "\\" in sf else sf
                line = f"  {pred} {subj} {obj}"
                if sf:
                    line += f" (in {sf})"
                fact_lines.append(line)
            parts.append("FACTS:\n" + "\n".join(fact_lines))

        if result.evidence:
            ev_lines = []
            for e in result.evidence[:5]:
                sf = e.get("source_file", "")
                if sf:
                    sf = sf.split("\\")[-1] if "\\" in sf else sf
                text = e.get("text", "")[:200]
                ls = e.get("line_start", 0)
                le = e.get("line_end", 0)
                ev_lines.append(f"  {sf}:{ls}-{le}\n    {text}")
            parts.append("EVIDENCE:\n" + "\n".join(ev_lines))

        if result.source_files:
            src_lines = []
            for sf in result.source_files[:5]:
                path = sf.get("path", sf.get("file", ""))
                if path:
                    path = path.split("\\")[-1] if "\\" in path else path
                content = sf.get("content", "")
                matches = sf.get("matches", [])
                if content:
                    src_lines.append(f"  {path}:\n{content[:500]}")
                elif matches:
                    for mline in matches[:3]:
                        src_lines.append(f"  {path}: {mline.strip()[:120]}")
                else:
                    src_lines.append(f"  {path}")
            parts.append("SOURCE:\n" + "\n".join(src_lines))

        if result.relations:
            rel_lines = []
            for r in result.relations[:5]:
                rel_lines.append(f"  {json.dumps(r, ensure_ascii=False)[:200]}")
            parts.append("RELATIONS:\n" + "\n".join(rel_lines))

        return "\n\n".join(parts)

    def _build_provenance(self, result: QueryResult) -> List[Dict]:
        prov = []
        if result.facts:
            prov.append({"type": "facts", "count": len(result.facts), "source": "knowledge_base"})
        if result.evidence:
            prov.append({"type": "evidence", "count": len(result.evidence), "source": "source_evidence"})
        if result.source_files:
            prov.append({"type": "source_files", "count": len(result.source_files), "source": "source_index"})
        if result.relations:
            prov.append({"type": "relations", "count": len(result.relations), "source": "semantic_relations"})
        return prov
