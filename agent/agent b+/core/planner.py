import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional
from core.query_engine import QueryIntent


@dataclass
class PlanStep:
    action: str
    tool: str
    params: Dict[str, Any] = field(default_factory=dict)
    depends_on: List[int] = field(default_factory=list)
    description: str = ""


@dataclass
class Plan:
    question: str
    intent: str
    steps: List[PlanStep] = field(default_factory=list)
    confidence: float = 0.0

    def add_step(self, action: str, tool: str, params: Dict = None, depends_on: List[int] = None, description: str = ""):
        idx = len(self.steps)
        self.steps.append(PlanStep(
            action=action, tool=tool,
            params=params or {},
            depends_on=depends_on or [],
            description=description,
        ))
        return idx


class Planner:
    def __init__(self):
        self._plan_templates = {
            "greet": self._plan_greet,
            "explain": self._plan_explain,
            "locate": self._plan_locate,
            "fix": self._plan_fix,
            "create": self._plan_create,
            "test": self._plan_test,
        }

    def plan(self, question: str, intent: QueryIntent) -> Plan:
        plan = Plan(
            question=question,
            intent=intent.intent_type,
            confidence=intent.confidence,
        )

        template_fn = self._plan_templates.get(intent.intent_type, self._plan_explain)
        template_fn(plan, intent)

        return plan

    def _plan_greet(self, plan: Plan, intent: QueryIntent):
        plan.add_step(
            action="greet",
            tool="none",
            description="Respond to greeting",
        )

    def _plan_explain(self, plan: Plan, intent: QueryIntent):
        for symbol in intent.symbols:
            plan.add_step(
                action="symbol_lookup",
                tool="symbol_lookup",
                params={"symbol": symbol},
                description=f"Look up symbol: {symbol}",
            )
            plan.add_step(
                action="search_knowledge",
                tool="knowledge_search",
                params={"query": symbol},
                depends_on=[len(plan.steps) - 1],
                description=f"Search knowledge for: {symbol}",
            )
            plan.add_step(
                action="search_source",
                tool="source_search",
                params={"query": symbol},
                depends_on=[len(plan.steps) - 1],
                description=f"Search source for: {symbol}",
            )
            plan.add_step(
                action="get_evidence",
                tool="knowledge_evidence",
                params={"query": symbol},
                depends_on=[len(plan.steps) - 1],
                description=f"Get evidence for: {symbol}",
            )

        plan.add_step(
            action="generate_answer",
            tool="model_generate",
            depends_on=list(range(len(plan.steps))),
            description="Generate answer from verified context",
        )

    def _plan_locate(self, plan: Plan, intent: QueryIntent):
        for symbol in intent.symbols:
            plan.add_step(
                action="symbol_lookup",
                tool="symbol_lookup",
                params={"symbol": symbol},
                description=f"Find symbol: {symbol}",
            )
            plan.add_step(
                action="search_source",
                tool="source_search",
                params={"query": symbol},
                description=f"Search source files for: {symbol}",
            )
            plan.add_step(
                action="get_evidence",
                tool="knowledge_evidence",
                params={"query": symbol},
                description=f"Get evidence for: {symbol}",
            )

        plan.add_step(
            action="generate_answer",
            tool="model_generate",
            depends_on=list(range(len(plan.steps))),
            description="Generate location answer",
        )

    def _plan_fix(self, plan: Plan, intent: QueryIntent):
        for symbol in intent.symbols:
            plan.add_step(
                action="symbol_lookup",
                tool="symbol_lookup",
                params={"symbol": symbol},
                description=f"Find symbol: {symbol}",
            )

        for fl in intent.files:
            plan.add_step(
                action="read_file",
                tool="source_read_file",
                params={"file_path": fl},
                description=f"Read file: {fl}",
            )

        if intent.symbols:
            symbol = intent.symbols[0]
            plan.add_step(
                action="search_source",
                tool="source_search",
                params={"query": symbol},
                description=f"Search for implementation of: {symbol}",
            )
            plan.add_step(
                action="get_relations",
                tool="knowledge_relations",
                params={"symbol": symbol},
                description=f"Get relations for: {symbol}",
            )

        plan.add_step(
            action="diagnose",
            tool="model_generate",
            depends_on=list(range(len(plan.steps))),
            description="Diagnose the problem",
        )

        plan.add_step(
            action="generate_fix",
            tool="model_generate",
            depends_on=[len(plan.steps) - 1],
            description="Generate fix",
        )

        plan.add_step(
            action="syntax_check",
            tool="zig_syntax_check",
            depends_on=[len(plan.steps) - 1],
            description="Verify fix compiles",
        )

    def _plan_create(self, plan: Plan, intent: QueryIntent):
        plan.add_step(
            action="search_existing",
            tool="source_search",
            params={"query": " ".join(intent.symbols[:3]) if intent.symbols else intent.entities[0] if intent.entities else ""},
            description="Search for existing similar code",
        )

        plan.add_step(
            action="generate_code",
            tool="model_generate",
            depends_on=[0],
            description="Generate code",
        )

        plan.add_step(
            action="syntax_check",
            tool="zig_syntax_check",
            depends_on=[1],
            description="Verify generated code",
        )

    def _plan_test(self, plan: Plan, intent: QueryIntent):
        for fl in intent.files:
            plan.add_step(
                action="run_tests",
                tool="zig_test",
                params={"file_path": fl},
                description=f"Run tests: {fl}",
            )

        for symbol in intent.symbols:
            plan.add_step(
                action="symbol_lookup",
                tool="symbol_lookup",
                params={"symbol": symbol},
                description=f"Look up: {symbol}",
            )

        plan.add_step(
            action="generate_answer",
            tool="model_generate",
            depends_on=list(range(len(plan.steps))),
            description="Summarize test results",
        )

    def describe(self, plan: Plan) -> str:
        lines = [f"PLAN [{plan.intent}] (confidence={plan.confidence:.1f})"]
        for i, step in enumerate(plan.steps):
            deps = f" <- {step.depends_on}" if step.depends_on else ""
            params = f" {step.params}" if step.params else ""
            lines.append(f"  {i}: {step.action} [{step.tool}]{params}{deps}")
        return "\n".join(lines)
