import os
import time
import json
import torch
from pathlib import Path
from typing import Any, Dict, List, Optional

AGENT_BPLUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT_DIR = os.path.dirname(AGENT_BPLUS)

from core.tool_registry import ToolExecutionEngine, ToolResult, RiskLevel
from core.system_tools import register_all_tools
from core.query_engine import QueryEngine, QueryIntent, QueryResult
from core.planner import Planner, Plan, PlanStep
from core.verification import VerificationLayer, VerificationReport
from core.conversation import ConversationState, ConversationTurn
from core.state_tables import StateStore, Session, Turn, Plan as PlanRecord, short_id
from core.symbol_graph import SymbolGraph


class AgentRuntimeV2:
    def __init__(self, model, tokenizer, knowledge, source_index, zig_runner):
        self.model = model
        self.tokenizer = tokenizer
        self.knowledge = knowledge
        self.source_index = source_index
        self.zig_runner = zig_runner

        self.device = "cuda" if torch.cuda.is_available() else "cpu"

        self.engine = ToolExecutionEngine(allowed_risk=[
            RiskLevel.READ, RiskLevel.ANALYSIS, RiskLevel.EXECUTION,
        ])
        register_all_tools(self.engine, knowledge, source_index, zig_runner)

        self.symbol_graph = SymbolGraph(source_index, knowledge)
        self._graph_built = False
        self._graph_cache = os.path.join(AGENT_BPLUS, "state", "symbol_graph.json")

        self.query_engine = QueryEngine(self.engine, symbol_graph=self.symbol_graph)
        self.knowledge_web = None
        self._web_built = False
        self.planner = Planner()
        self.verifier = VerificationLayer()
        self.conversation = ConversationState()

        self.state = StateStore()
        self.state.load()
        if not self.state._current_session:
            self.state.new_session()

        self._execution_trace = []
        self._current_trace_id = None

    def get_knowledge_web(self):
        self._ensure_web()
        return self.knowledge_web

    def _ensure_web(self):
        if self._web_built:
            return
        self._ensure_graph()
        from core.knowledge_web import KnowledgeWebEngine
        self.knowledge_web = KnowledgeWebEngine(
            self.source_index, self.symbol_graph, self.knowledge)
        self.knowledge_web.build()
        self._web_built = True

    def get_knowledge_web_stats(self) -> Dict:
        self._ensure_web()
        sym = self.knowledge_web.symbol_coverage_report()
        rep = self.knowledge_web.coverage_report()
        return {
            "nodes": len(self.knowledge_web.nodes),
            "edges": len(self.knowledge_web.edges),
            "density": sym.get("knowledge_density"),
            "coverage": sym.get("coverage", {}),
            "levels": sym.get("levels", {}),
            "orphan_rate": sym.get("orphan_rate"),
            "kcs": rep.get("kcs"),
        }

    def _ensure_graph(self):
        if self._graph_built:
            return
        if os.path.exists(self._graph_cache):
            try:
                self.symbol_graph.load(self._graph_cache)
                self._graph_built = True
                return
            except Exception:
                pass
        self.symbol_graph.build()
        os.makedirs(os.path.dirname(self._graph_cache), exist_ok=True)
        try:
            self.symbol_graph.save(self._graph_cache)
        except Exception:
            pass
        self._graph_built = True

    def execute(self, question: str) -> Dict:
        t0 = time.monotonic()
        trace = []

        session = self.state.get_session()
        turn = self.state.new_turn(session.session_id, question)

        self._current_trace_id = self.state.new_trace(turn.turn_id)

        resolved = self.conversation.resolve_reference(question)
        turn.resolved_question = resolved
        trace.append({"step": "resolve_reference", "input": question, "output": resolved})

        intent = self.query_engine.analyze_intent(resolved)
        turn.intent = intent.intent_type
        turn.entities = intent.entities
        turn.symbols = intent.symbols
        trace.append({"step": "analyze_intent", "intent": intent.intent_type, "confidence": intent.confidence, "entities": intent.entities})

        plan = self.planner.plan(resolved, intent)
        plan_record = self.state.new_plan(resolved, intent.intent_type)
        plan_record.steps = [{"action": s.action, "tool": s.tool, "params": s.params} for s in plan.steps]
        plan_record.status = "running"
        turn.plan_id = plan_record.plan_id
        trace.append({"step": "create_plan", "steps": len(plan.steps), "plan_id": plan_record.plan_id})

        self._add_trace("plan", "planner", "create_plan",
                       resolved, f"{len(plan.steps)} steps", 0)

        query_result = self.query_engine.query(resolved)
        self._sync_executions(plan_record.plan_id, turn.turn_id)
        trace.append({"step": "query_engine", "facts": len(query_result.facts), "evidence": len(query_result.evidence), "source_files": len(query_result.source_files)})

        self._add_trace("query", "query_engine", "query",
                       resolved, f"facts={len(query_result.facts)} evidence={len(query_result.evidence)}",
                       0, evidence_ids=[])

        verified_context = query_result.verified_context
        trace.append({"step": "assemble_context", "context_length": len(verified_context)})

        answer = self._generate_answer(resolved, intent, verified_context)
        trace.append({"step": "generate_answer", "answer_length": len(answer)})

        self._add_trace("generate", "model", "generate",
                       resolved, answer[:200], 0)

        verification = self.verifier.verify(answer, query_result)
        turn.verification_id = short_id("VER", turn.turn_id)
        turn.confidence = verification.overall_confidence
        trace.append({"step": "verify", "verified": verification.verified_count, "total": verification.total_count, "confidence": verification.overall_confidence})

        self._add_trace("verify", "verification", "verify",
                       answer[:200], f"verified={verification.overall_verified} confidence={verification.overall_confidence}",
                       0)

        if not verification.overall_verified and query_result.facts:
            answer = self._qualify_answer(answer, verification, query_result)
            trace.append({"step": "qualify_answer", "new_answer_length": len(answer)})

        elapsed = (time.monotonic() - t0) * 1000

        turn.answer = answer
        turn.status = "completed"
        turn.duration_ms = elapsed
        turn.tools_used = list(set(s.get("tool", "") for s in trace if "tool" in s))

        plan_record.status = "completed"
        self.state.save()

        self.conversation.add_turn(ConversationTurn(
            question=question, answer=answer, intent=intent.intent_type,
            entities=intent.entities, symbols=intent.symbols, files=intent.files,
            verified=verification.overall_verified, confidence=verification.overall_confidence,
            tools_used=turn.tools_used, timestamp=time.monotonic(), duration_ms=elapsed,
        ))

        self._execution_trace = trace

        return {
            "answer": answer,
            "verified": verification.overall_verified,
            "confidence": verification.overall_confidence,
            "intent": intent.intent_type,
            "entities": intent.symbols,
            "latency_ms": round(elapsed, 1),
            "trace": trace,
            "verification": self.verifier.format_report(verification),
            "provenance": query_result.provenance,
            "turn_id": turn.turn_id,
            "plan_id": plan_record.plan_id,
            "trace_id": self._current_trace_id,
        }

    def _add_trace(self, step: str, component: str, operation: str,
                  input_summary: str, output_summary: str, duration_ms: float,
                  evidence_ids: List[str] = None):
        if self._current_trace_id:
            self.state.add_trace_step(
                self._current_trace_id, step, component, operation,
                input_summary, output_summary, duration_ms, evidence_ids or [],
            )

    def _sync_executions(self, plan_id: str, turn_id: str):
        if not hasattr(self.engine, "get_execution_log"):
            return
        for rec in self.engine.get_execution_log():
            if self.state.get_execution(rec.execution_id):
                continue
            self.state.new_execution_record(
                rec.execution_id, plan_id, turn_id, rec.tool,
                rec.input, rec.output, rec.status, rec.duration_ms, rec.error,
            )

    def _generate_answer(self, question: str, intent: QueryIntent, context: str) -> str:
        if intent.intent_type == "greet":
            return "Привет! Я B+ Zig coding assistant. Задайте вопрос по Zig коду."

        prompt_parts = [
            "<system>You are a B+ Zig coding assistant. Answer concisely based on provided context. Do not hallucinate facts. If context doesn't contain enough info, say so.</system>",
        ]

        if context:
            prompt_parts.append(f"<context>{context[:2000]}</context>")

        prompt_parts.append(f"<instruction>{question}</instruction>")
        prompt_parts.append("<answer>")

        prompt = "\n".join(prompt_parts)
        ids = self.tokenizer.encode(prompt)

        max_len = 4096 - 256
        if len(ids) > max_len:
            ids = ids[:max_len]

        input_tensor = torch.tensor([ids], device=self.device)

        with torch.no_grad():
            output = self.model.generate(
                input_tensor, max_new_tokens=200, temperature=0.3, top_k=40,
            )

        response = self.tokenizer.decode(output[0].tolist())
        answer = response.split("<answer>")[-1] if "<answer>" in response else response
        answer = answer.split("</answer>")[0].strip()
        answer = answer.split("<system>")[0].strip()

        if len(answer) < 5:
            answer = "I don't have enough information to answer this question."

        return answer

    def _qualify_answer(self, answer: str, verification: VerificationReport, query_result: QueryResult) -> str:
        qualified = answer
        rejected = [vr for vr in verification.claims if not vr.verified and not vr.evidence_found]
        if rejected:
            qualified += "\n\n[Note: Some claims could not be verified against the knowledge base.]"
        if query_result.facts:
            sources = set()
            for f in query_result.facts:
                sf = f.get("source_file", "")
                if sf:
                    sources.add(sf.split("\\")[-1] if "\\" in sf else sf)
            if sources:
                qualified += f"\n\n[Sources: {', '.join(list(sources)[:3])}]"
        return qualified

    def inspect_symbol(self, name: str) -> Dict:
        self._ensure_graph()
        return self.symbol_graph.inspect(name)

    def get_tools(self) -> List[Dict]:
        tools = self.engine.list_tools()
        return [{"name": t.name, "description": t.description, "category": t.category.value,
                 "risk": t.risk_level.value, "cost_ms": t.cost_ms,
                 "input_schema": t.input_schema, "mutates_source": t.mutates_source}
                for t in tools]

    def get_trace(self) -> List[Dict]:
        return self._execution_trace

    def get_persisted_trace(self, trace_id: str = None) -> List[Dict]:
        tid = trace_id or self._current_trace_id
        if not tid:
            return []
        steps = self.state.get_trace(tid)
        return [s.to_dict() for s in steps]

    def get_conversation_stats(self) -> Dict:
        return self.conversation.get_stats()

    def get_state_stats(self) -> Dict:
        return self.state.get_stats()

    def get_symbol_graph_stats(self) -> Dict:
        self._ensure_graph()
        return self.symbol_graph.get_stats()
