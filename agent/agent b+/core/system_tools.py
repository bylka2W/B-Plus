import os
import json
from pathlib import Path
from typing import Any, Dict, List
from core.tool_registry import BaseTool, ToolSpec, ToolResult, ToolCategory, RiskLevel


class KnowledgeSearchTool(BaseTool):
    def __init__(self, knowledge):
        self.knowledge = knowledge
        super().__init__(ToolSpec(
            name="knowledge.search",
            description="Search knowledge base for facts, concepts, and relations",
            category=ToolCategory.KNOWLEDGE,
            risk_level=RiskLevel.READ,
            input_schema={"query": "str"},
            output_schema={"results": "list[dict]"},
            cost_ms=50,
            requires_evidence=True,
            deterministic=True,
        ))

    def execute(self, query: str = "", **kwargs) -> ToolResult:
        results = []
        if self.knowledge:
            facts = self.knowledge.query_symbol(query)
            if facts:
                results.extend([{"type": "fact", **f} for f in facts[:20]])
            concepts = self.knowledge.query_file(query)
            if concepts:
                results.extend([{"type": "concept", **c} for c in concepts[:10]])
        return ToolResult(tool="knowledge.search", success=True, data=results,
                         provenance=[{"source": "knowledge_base", "count": len(results)}])


class KnowledgeRelationsTool(BaseTool):
    def __init__(self, knowledge):
        self.knowledge = knowledge
        super().__init__(ToolSpec(
            name="knowledge.relations",
            description="Get relations for a symbol from the knowledge graph",
            category=ToolCategory.KNOWLEDGE,
            risk_level=RiskLevel.ANALYSIS,
            input_schema={"symbol": "str"},
            output_schema={"relations": "list[dict]"},
            cost_ms=100,
            requires_evidence=True,
            deterministic=True,
        ))

    def execute(self, symbol: str = "", **kwargs) -> ToolResult:
        relations = []
        if self.knowledge and hasattr(self.knowledge, 'relations'):
            for r in self.knowledge.relations:
                s = json.dumps(r, ensure_ascii=False).lower()
                if symbol.lower() in s:
                    relations.append(r)
        return ToolResult(tool="knowledge.relations", success=True, data=relations[:30],
                         provenance=[{"source": "semantic_relations", "count": len(relations)}])


class KnowledgeEvidenceTool(BaseTool):
    def __init__(self, knowledge):
        self.knowledge = knowledge
        super().__init__(ToolSpec(
            name="knowledge.evidence",
            description="Get source evidence for a fact or symbol",
            category=ToolCategory.KNOWLEDGE,
            risk_level=RiskLevel.READ,
            input_schema={"query": "str"},
            output_schema={"evidence": "list[dict]"},
            cost_ms=50,
            requires_evidence=True,
            deterministic=True,
        ))

    def execute(self, query: str = "", **kwargs) -> ToolResult:
        evidence = []
        if self.knowledge and hasattr(self.knowledge, 'evidence'):
            for ev in self.knowledge.evidence:
                s = json.dumps(ev, ensure_ascii=False).lower()
                if query.lower() in s:
                    evidence.append(ev)
        return ToolResult(tool="knowledge.evidence", success=True, data=evidence[:20],
                         provenance=[{"source": "source_evidence", "count": len(evidence)}])


class SourceSearchTool(BaseTool):
    def __init__(self, source_index):
        self.source_index = source_index
        super().__init__(ToolSpec(
            name="source.search",
            description="Search Zig source files by content or symbol name",
            category=ToolCategory.SOURCE,
            risk_level=RiskLevel.READ,
            input_schema={"query": "str"},
            output_schema={"results": "list[dict]"},
            cost_ms=200,
            requires_evidence=True,
            deterministic=True,
        ))

    def execute(self, query: str = "", **kwargs) -> ToolResult:
        results = []
        if self.source_index:
            hits = self.source_index.search(query)
            results = hits[:15] if hits else []
        return ToolResult(tool="source.search", success=True, data=results,
                         provenance=[{"source": "source_index", "count": len(results)}])


class SourceReadFileTool(BaseTool):
    def __init__(self, source_index):
        self.source_index = source_index
        super().__init__(ToolSpec(
            name="source.read_file",
            description="Read a source file by path, with optional line range",
            category=ToolCategory.SOURCE,
            risk_level=RiskLevel.READ,
            input_schema={"file_path": "str"},
            output_schema={"content": "str", "path": "str"},
            cost_ms=30,
            requires_evidence=True,
            deterministic=True,
        ))

    def execute(self, file_path: str = "", line_start: int = 0, line_end: int = 0, **kwargs) -> ToolResult:
        content = ""
        if self.source_index:
            lines = self.source_index.read_file(file_path)
            if lines:
                if line_start > 0 or line_end > 0:
                    s = max(0, line_start - 1)
                    e = line_end if line_end > 0 else len(lines)
                    lines = lines[s:e]
                content = "".join(lines)
        return ToolResult(tool="source.read_file", success=True,
                         data={"content": content[:10000], "path": file_path},
                         provenance=[{"source": "file", "path": file_path}])


class SourceSymbolLookupTool(BaseTool):
    def __init__(self, source_index, knowledge):
        self.source_index = source_index
        self.knowledge = knowledge
        super().__init__(ToolSpec(
            name="source.symbol_lookup",
            description="Look up a symbol: find its definition, file location, and facts",
            category=ToolCategory.SOURCE,
            risk_level=RiskLevel.READ,
            input_schema={"symbol": "str"},
            output_schema={"definition": "dict", "facts": "list", "file_location": "dict"},
            cost_ms=100,
            requires_evidence=True,
            deterministic=True,
        ))

    def execute(self, symbol: str = "", **kwargs) -> ToolResult:
        definition = {"name": symbol, "found": False}
        facts = []
        file_location = {}

        if self.source_index:
            hits = self.source_index.search(symbol)
            if hits:
                definition["found"] = True
                definition["file"] = hits[0].get("path", "")
                definition["score"] = hits[0].get("score", 0)
                file_location = {"path": hits[0].get("path", ""), "line": hits[0].get("line", 0)}

        if self.knowledge:
            kf = self.knowledge.query_symbol(symbol)
            if kf:
                facts = kf[:10]

        return ToolResult(tool="source.symbol_lookup", success=True,
                         data={"definition": definition, "facts": facts, "file_location": file_location},
                         provenance=[{"source": "source_index"}, {"source": "knowledge_base"}])


class ZigSyntaxCheckTool(BaseTool):
    def __init__(self, zig_runner):
        self.zig_runner = zig_runner
        super().__init__(ToolSpec(
            name="zig.syntax_check",
            description="Check Zig code syntax without compiling",
            category=ToolCategory.ZIG,
            risk_level=RiskLevel.EXECUTION,
            input_schema={"code": "str"},
            output_schema={"valid": "bool", "errors": "list"},
            cost_ms=500,
            timeout_ms=10000,
            deterministic=True,
        ))

    def execute(self, code: str = "", **kwargs) -> ToolResult:
        result = {"valid": False, "errors": []}
        if self.zig_runner:
            r = self.zig_runner.syntax_check_code(code)
            result["valid"] = r.get("success", False)
            if not result["valid"]:
                result["errors"] = [r.get("stderr", "Unknown error")]
        return ToolResult(tool="zig.syntax_check", success=True, data=result,
                         provenance=[{"source": "zig_compiler"}])


class ZigBuildTool(BaseTool):
    def __init__(self, zig_runner):
        self.zig_runner = zig_runner
        super().__init__(ToolSpec(
            name="zig.build",
            description="Build a Zig file and return compilation results",
            category=ToolCategory.ZIG,
            risk_level=RiskLevel.EXECUTION,
            input_schema={"file_path": "str"},
            output_schema={"success": "bool", "output": "str"},
            cost_ms=5000,
            timeout_ms=60000,
            deterministic=True,
        ))

    def execute(self, file_path: str = "", **kwargs) -> ToolResult:
        result = {"success": False, "output": ""}
        if self.zig_runner:
            r = self.zig_runner.build_file(file_path)
            result["success"] = r.get("success", False)
            result["output"] = r.get("stdout", "") + r.get("stderr", "")
        return ToolResult(tool="zig.build", success=True, data=result,
                         provenance=[{"source": "zig_compiler", "file": file_path}])


class ZigTestTool(BaseTool):
    def __init__(self, zig_runner):
        self.zig_runner = zig_runner
        super().__init__(ToolSpec(
            name="zig.test",
            description="Run Zig tests for a file",
            category=ToolCategory.ZIG,
            risk_level=RiskLevel.EXECUTION,
            input_schema={"file_path": "str"},
            output_schema={"passed": "bool", "output": "str"},
            cost_ms=10000,
            timeout_ms=120000,
            deterministic=False,
        ))

    def execute(self, file_path: str = "", **kwargs) -> ToolResult:
        result = {"passed": False, "output": ""}
        if self.zig_runner:
            r = self.zig_runner.test_file(file_path)
            result["passed"] = r.get("success", False)
            result["output"] = r.get("stdout", "") + r.get("stderr", "")
        return ToolResult(tool="zig.test", success=True, data=result,
                         provenance=[{"source": "zig_test", "file": file_path}])


class FileReadTool(BaseTool):
    def __init__(self):
        super().__init__(ToolSpec(
            name="filesystem.read",
            description="Read any file from disk",
            category=ToolCategory.FILESYSTEM,
            risk_level=RiskLevel.READ,
            input_schema={"file_path": "str"},
            output_schema={"content": "str", "path": "str"},
            cost_ms=20,
            deterministic=True,
        ))

    def execute(self, file_path: str = "", **kwargs) -> ToolResult:
        content = ""
        if os.path.exists(file_path):
            with open(file_path, encoding="utf-8", errors="replace") as f:
                content = f.read(50000)
        return ToolResult(tool="filesystem.read", success=True,
                         data={"content": content, "path": file_path},
                         provenance=[{"source": "filesystem", "path": file_path}])


class FileListDirTool(BaseTool):
    def __init__(self):
        super().__init__(ToolSpec(
            name="filesystem.list_dir",
            description="List files in a directory",
            category=ToolCategory.FILESYSTEM,
            risk_level=RiskLevel.READ,
            input_schema={"dir_path": "str"},
            output_schema={"entries": "list[str]"},
            cost_ms=10,
            deterministic=True,
        ))

    def execute(self, dir_path: str = "", **kwargs) -> ToolResult:
        entries = []
        if os.path.isdir(dir_path):
            entries = sorted(os.listdir(dir_path))
        return ToolResult(tool="filesystem.list_dir", success=True, data={"entries": entries},
                         provenance=[{"source": "filesystem", "path": dir_path}])


class SystemInfoTool(BaseTool):
    def __init__(self):
        super().__init__(ToolSpec(
            name="system.info",
            description="Get system information (paths, counts, sizes)",
            category=ToolCategory.SYSTEM,
            risk_level=RiskLevel.READ,
            input_schema={},
            output_schema={"info": "dict"},
            cost_ms=5,
            deterministic=True,
        ))

    def execute(self, **kwargs) -> ToolResult:
        info = {
            "zig_exe": r"C:\tools\zig\zig-windows-x86_64-0.14.0\zig.exe",
            "zig_root": r"C:\B-Plus\zig",
            "agent_root": r"C:\B-Plus\agent",
            "knowledge_dir": r"C:\B-Plus\agent\memory",
        }
        for key in ["zig_exe", "zig_root"]:
            info[f"{key}_exists"] = os.path.exists(info[key])
        return ToolResult(tool="system.info", success=True, data=info,
                         provenance=[{"source": "system"}])


def register_all_tools(engine, knowledge=None, source_index=None, zig_runner=None):
    tools = [
        KnowledgeSearchTool(knowledge),
        KnowledgeRelationsTool(knowledge),
        KnowledgeEvidenceTool(knowledge),
        SourceSearchTool(source_index),
        SourceReadFileTool(source_index),
        SourceSymbolLookupTool(source_index, knowledge),
        ZigSyntaxCheckTool(zig_runner),
        ZigBuildTool(zig_runner),
        ZigTestTool(zig_runner),
        FileReadTool(),
        FileListDirTool(),
        SystemInfoTool(),
    ]
    for t in tools:
        engine.register(t)
    return engine
