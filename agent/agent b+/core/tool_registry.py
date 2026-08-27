import os
import json
import time
import uuid
import hashlib
from pathlib import Path
from dataclasses import dataclass, field, asdict
from typing import Any, Callable, Dict, List, Optional
from enum import Enum


class RiskLevel(Enum):
    READ = "read"
    ANALYSIS = "analysis"
    EXECUTION = "execution"
    MUTATION = "mutation"


class ToolCategory(Enum):
    KNOWLEDGE = "knowledge"
    SOURCE = "source"
    ZIG = "zig"
    FILESYSTEM = "filesystem"
    SYSTEM = "system"


@dataclass
class ToolSpec:
    name: str
    description: str
    category: ToolCategory
    risk_level: RiskLevel
    input_schema: Dict[str, str]
    output_schema: Dict[str, str]
    cost_ms: int = 100
    timeout_ms: int = 30000
    requires_evidence: bool = False
    mutates_source: bool = False
    deterministic: bool = True
    permissions: List[str] = field(default_factory=lambda: ["read"])


@dataclass
class ToolResult:
    tool: str
    success: bool
    data: Any
    error: Optional[str] = None
    duration_ms: float = 0.0
    evidence_ids: List[str] = field(default_factory=list)
    provenance: List[Dict] = field(default_factory=list)
    execution_id: str = ""

    def to_dict(self) -> Dict:
        return {
            "tool": self.tool,
            "success": self.success,
            "data": self.data if isinstance(self.data, (dict, list, str, int, float, bool)) else str(self.data),
            "error": self.error,
            "duration_ms": round(self.duration_ms, 2),
            "evidence_ids": self.evidence_ids,
            "provenance": self.provenance,
            "execution_id": self.execution_id,
        }


@dataclass
class ExecutionRecord:
    execution_id: str
    plan_id: str
    turn_id: str
    tool: str
    input: Dict
    output: Any
    evidence_ids: List[str]
    duration_ms: float
    status: str
    error: Optional[str]
    timestamp: float


class BaseTool:
    def __init__(self, spec: ToolSpec):
        self.spec = spec

    def validate_input(self, **kwargs) -> List[str]:
        errors = []
        for key, type_hint in self.spec.input_schema.items():
            if key not in kwargs:
                errors.append(f"Missing required parameter: {key}")
        return errors

    def validate_output(self, result: Any) -> List[str]:
        return []

    def extract_evidence(self, result: Any) -> List[str]:
        return []

    def execute(self, **kwargs) -> ToolResult:
        raise NotImplementedError

    def _run(self, **kwargs) -> ToolResult:
        exec_id = f"exec-{uuid.uuid4().hex[:12]}"
        errors = self.validate_input(**kwargs)
        if errors:
            return ToolResult(tool=self.spec.name, success=False, data=None,
                            error="; ".join(errors), execution_id=exec_id)
        t0 = time.monotonic()
        try:
            result = self.execute(**kwargs)
            result.duration_ms = (time.monotonic() - t0) * 1000
            result.execution_id = exec_id
            out_errors = self.validate_output(result.data)
            if out_errors:
                result.error = "Output validation: " + "; ".join(out_errors)
            result.evidence_ids = self.extract_evidence(result.data)
            return result
        except Exception as e:
            return ToolResult(
                tool=self.spec.name, success=False, data=None,
                error=str(e), duration_ms=(time.monotonic() - t0) * 1000,
                execution_id=exec_id,
            )


class ToolExecutionEngine:
    def __init__(self, allowed_risk: List[RiskLevel] = None):
        self._tools: Dict[str, BaseTool] = {}
        self._execution_log: List[ExecutionRecord] = []
        self._allowed_risk = allowed_risk or [RiskLevel.READ, RiskLevel.ANALYSIS, RiskLevel.EXECUTION]

    def register(self, tool: BaseTool):
        self._tools[tool.spec.name] = tool

    def get(self, name: str) -> Optional[BaseTool]:
        return self._tools.get(name)

    def list_tools(self) -> List[ToolSpec]:
        return [t.spec for t in self._tools.values()]

    def list_by_category(self) -> Dict[str, List[ToolSpec]]:
        cats = {}
        for t in self._tools.values():
            cat = t.spec.category.value
            if cat not in cats:
                cats[cat] = []
            cats[cat].append(t.spec)
        return cats

    def list_by_risk(self) -> Dict[str, List[ToolSpec]]:
        risk = {}
        for t in self._tools.values():
            level = t.spec.risk_level.value
            if level not in risk:
                risk[level] = []
            risk[level].append(t.spec)
        return risk

    def has_tool(self, name: str) -> bool:
        return name in self._tools

    def can_execute(self, name: str) -> bool:
        tool = self._tools.get(name)
        if not tool:
            return False
        return tool.spec.risk_level in self._allowed_risk

    def execute(self, name: str, plan_id: str = "", turn_id: str = "", **kwargs) -> ToolResult:
        tool = self._tools.get(name)
        if not tool:
            return ToolResult(tool=name, success=False, data=None, error=f"Unknown tool: {name}")

        if not self.can_execute(name):
            return ToolResult(tool=name, success=False, data=None,
                            error=f"Permission denied: risk level {tool.spec.risk_level.value} not allowed")

        result = tool._run(**kwargs)

        record = ExecutionRecord(
            execution_id=result.execution_id,
            plan_id=plan_id,
            turn_id=turn_id,
            tool=name,
            input={k: str(v)[:200] for k, v in kwargs.items()},
            output=result.data if isinstance(result.data, (dict, list, str, int, float, bool)) else str(result.data)[:500],
            evidence_ids=result.evidence_ids,
            duration_ms=result.duration_ms,
            status="success" if result.success else "error",
            error=result.error,
            timestamp=time.time(),
        )
        self._execution_log.append(record)

        return result

    def get_execution_log(self, plan_id: str = None, turn_id: str = None) -> List[ExecutionRecord]:
        log = self._execution_log
        if plan_id:
            log = [r for r in log if r.plan_id == plan_id]
        if turn_id:
            log = [r for r in log if r.turn_id == turn_id]
        return log

    def get_stats(self) -> Dict:
        total = len(self._execution_log)
        success = sum(1 for r in self._execution_log if r.status == "success")
        return {
            "total_executions": total,
            "success": success,
            "errors": total - success,
            "avg_duration_ms": round(sum(r.duration_ms for r in self._execution_log) / max(total, 1), 2),
        }

    def to_dict(self) -> Dict:
        return {
            "tools": [{"name": t.spec.name, "category": t.spec.category.value,
                       "risk": t.spec.risk_level.value, "description": t.spec.description}
                      for t in self._tools.values()],
            "stats": self.get_stats(),
        }
