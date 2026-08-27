import os
import json
import time
import uuid
from pathlib import Path
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional
from enum import Enum


def short_id(prefix: str, *parts) -> str:
    import hashlib
    raw = ":".join(str(p) for p in parts)
    h = hashlib.sha1(raw.encode()).hexdigest()[:16]
    return f"{prefix}-{h}"


class PlanStatus(Enum):
    CREATED = "created"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


class StepStatus(Enum):
    PENDING = "pending"
    RUNNING = "running"
    SUCCESS = "success"
    FAILED = "failed"
    SKIPPED = "skipped"


class TurnStatus(Enum):
    ACTIVE = "active"
    COMPLETED = "completed"
    ERROR = "error"


@dataclass
class Session:
    session_id: str
    user_id: str
    active_topic: str = ""
    active_symbols: Dict[str, str] = field(default_factory=dict)
    active_files: Dict[str, str] = field(default_factory=dict)
    current_goal: str = ""
    created_at: float = 0.0
    turns: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict:
        return {
            "session_id": self.session_id,
            "user_id": self.user_id,
            "active_topic": self.active_topic,
            "active_symbols": self.active_symbols,
            "active_files": self.active_files,
            "current_goal": self.current_goal,
            "created_at": self.created_at,
            "turn_count": len(self.turns),
        }


@dataclass
class Turn:
    turn_id: str
    session_id: str
    question: str
    resolved_question: str = ""
    intent: str = "unknown"
    entities: List[str] = field(default_factory=list)
    symbols: List[str] = field(default_factory=list)
    plan_id: str = ""
    answer: str = ""
    verification_id: str = ""
    confidence: float = 0.0
    status: str = "active"
    tools_used: List[str] = field(default_factory=list)
    timestamp: float = 0.0
    duration_ms: float = 0.0

    def to_dict(self) -> Dict:
        return {
            "turn_id": self.turn_id,
            "session_id": self.session_id,
            "question": self.question,
            "resolved_question": self.resolved_question,
            "intent": self.intent,
            "entities": self.entities,
            "symbols": self.symbols,
            "plan_id": self.plan_id,
            "answer": self.answer[:500],
            "verification_id": self.verification_id,
            "confidence": self.confidence,
            "status": self.status,
            "tools_used": self.tools_used,
            "timestamp": self.timestamp,
            "duration_ms": round(self.duration_ms, 2),
        }


@dataclass
class Plan:
    plan_id: str
    goal: str
    intent: str
    steps: List[Dict] = field(default_factory=list)
    dependencies: Dict[int, List[int]] = field(default_factory=dict)
    status: str = "created"
    created_at: float = 0.0

    def to_dict(self) -> Dict:
        return {
            "plan_id": self.plan_id,
            "goal": self.goal,
            "intent": self.intent,
            "steps": self.steps,
            "dependencies": {str(k): v for k, v in self.dependencies.items()},
            "status": self.status,
            "created_at": self.created_at,
            "step_count": len(self.steps),
        }


@dataclass
class ToolExecution:
    execution_id: str
    plan_id: str
    turn_id: str
    tool: str
    input: Dict
    output: Any
    evidence_ids: List[str] = field(default_factory=list)
    duration_ms: float = 0.0
    status: str = "pending"
    error: Optional[str] = None
    timestamp: float = 0.0

    def to_dict(self) -> Dict:
        return {
            "execution_id": self.execution_id,
            "plan_id": self.plan_id,
            "turn_id": self.turn_id,
            "tool": self.tool,
            "input": self.input,
            "output": str(self.output)[:500] if self.output else None,
            "evidence_ids": self.evidence_ids,
            "duration_ms": round(self.duration_ms, 2),
            "status": self.status,
            "error": self.error,
            "timestamp": self.timestamp,
        }


@dataclass
class EvidenceRecord:
    evidence_id: str
    source_file_id: str
    line_start: int
    line_end: int
    text: str
    hash: str
    evidence_type: str
    verified: bool = False

    def to_dict(self) -> Dict:
        return {
            "evidence_id": self.evidence_id,
            "source_file_id": self.source_file_id,
            "line_start": self.line_start,
            "line_end": self.line_end,
            "text": self.text[:300],
            "hash": self.hash,
            "evidence_type": self.evidence_type,
            "verified": self.verified,
        }


@dataclass
class TraceStep:
    step_id: str
    trace_id: str
    turn_id: str
    step: str
    component: str
    operation: str
    input_summary: str
    output_summary: str
    duration_ms: float
    evidence_ids: List[str] = field(default_factory=list)
    status: str = "ok"
    timestamp: float = 0.0

    def to_dict(self) -> Dict:
        return {
            "step_id": self.step_id,
            "trace_id": self.trace_id,
            "turn_id": self.turn_id,
            "step": self.step,
            "component": self.component,
            "operation": self.operation,
            "input_summary": self.input_summary[:200],
            "output_summary": self.output_summary[:200],
            "duration_ms": round(self.duration_ms, 2),
            "evidence_ids": self.evidence_ids,
            "status": self.status,
            "timestamp": self.timestamp,
        }


class StateStore:
    def __init__(self, store_dir: str = None):
        if store_dir is None:
            store_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "state")
        self.store_dir = Path(store_dir)
        self.store_dir.mkdir(parents=True, exist_ok=True)

        self.sessions: Dict[str, Session] = {}
        self.turns: Dict[str, Turn] = {}
        self.plans: Dict[str, Plan] = {}
        self.executions: Dict[str, ToolExecution] = {}
        self.evidence: Dict[str, EvidenceRecord] = {}
        self.traces: Dict[str, List[TraceStep]] = {}

        self._current_session: Optional[Session] = None

    def new_session(self, user_id: str = "default") -> Session:
        session_id = short_id("SES", user_id, time.time())
        session = Session(session_id=session_id, user_id=user_id, created_at=time.time())
        self.sessions[session_id] = session
        self._current_session = session
        return session

    def get_session(self, session_id: str = None) -> Optional[Session]:
        if session_id:
            return self.sessions.get(session_id)
        return self._current_session

    def new_turn(self, session_id: str, question: str) -> Turn:
        turn_id = short_id("TURN", session_id, question, time.time())
        turn = Turn(turn_id=turn_id, session_id=session_id,
                   question=question, timestamp=time.time())
        self.turns[turn_id] = turn
        session = self.sessions.get(session_id)
        if session:
            session.turns.append(turn_id)
        return turn

    def get_turn(self, turn_id: str) -> Optional[Turn]:
        return self.turns.get(turn_id)

    def new_plan(self, goal: str, intent: str) -> Plan:
        plan_id = short_id("PLAN", goal, intent, time.time())
        plan = Plan(plan_id=plan_id, goal=goal, intent=intent, created_at=time.time())
        self.plans[plan_id] = plan
        return plan

    def get_plan(self, plan_id: str) -> Optional[Plan]:
        return self.plans.get(plan_id)

    def new_execution(self, plan_id: str, turn_id: str, tool: str, input_data: Dict) -> ToolExecution:
        exec_id = short_id("EXEC", plan_id, tool, time.time())
        execution = ToolExecution(
            execution_id=exec_id, plan_id=plan_id, turn_id=turn_id,
            tool=tool, input=input_data, output=None, timestamp=time.time(),
        )
        self.executions[exec_id] = execution
        return execution

    def new_execution_record(self, execution_id: str, plan_id: str, turn_id: str,
                             tool: str, input_data: Dict, output: Any, status: str,
                             duration_ms: float, error: str = None) -> ToolExecution:
        execution = ToolExecution(
            execution_id=execution_id, plan_id=plan_id, turn_id=turn_id,
            tool=tool, input=input_data, output=output, status=status,
            duration_ms=duration_ms, error=error, timestamp=time.time(),
        )
        self.executions[execution_id] = execution
        return execution

    def get_execution(self, execution_id: str) -> Optional[ToolExecution]:
        return self.executions.get(execution_id)

    def get_executions(self, plan_id: str = None, turn_id: str = None) -> List[ToolExecution]:
        execs = list(self.executions.values())
        if plan_id:
            execs = [e for e in execs if e.plan_id == plan_id]
        if turn_id:
            execs = [e for e in execs if e.turn_id == turn_id]
        return execs

    def new_evidence(self, source_file_id: str, line_start: int, line_end: int,
                    text: str, evidence_type: str) -> EvidenceRecord:
        import hashlib
        h = hashlib.sha256(text.encode()).hexdigest()[:16]
        ev_id = short_id("EVID", source_file_id, h)
        record = EvidenceRecord(
            evidence_id=ev_id, source_file_id=source_file_id,
            line_start=line_start, line_end=line_end,
            text=text, hash=h, evidence_type=evidence_type,
        )
        self.evidence[ev_id] = record
        return record

    def new_trace(self, turn_id: str) -> str:
        trace_id = short_id("TRACE", turn_id, time.time())
        self.traces[trace_id] = []
        return trace_id

    def add_trace_step(self, trace_id: str, step: str, component: str,
                      operation: str, input_summary: str, output_summary: str,
                      duration_ms: float, evidence_ids: List[str] = None,
                      status: str = "ok") -> TraceStep:
        step_id = short_id("STEP", trace_id, step, time.time())
        ts = TraceStep(
            step_id=step_id, trace_id=trace_id, turn_id="",
            step=step, component=component, operation=operation,
            input_summary=input_summary, output_summary=output_summary,
            duration_ms=duration_ms, evidence_ids=evidence_ids or [],
            status=status, timestamp=time.time(),
        )
        if trace_id in self.traces:
            self.traces[trace_id].append(ts)
        return ts

    def get_trace(self, trace_id: str) -> List[TraceStep]:
        return self.traces.get(trace_id, [])

    def save(self):
        data = {
            "sessions": {k: v.to_dict() for k, v in self.sessions.items()},
            "turns": {k: v.to_dict() for k, v in self.turns.items()},
            "plans": {k: v.to_dict() for k, v in self.plans.items()},
            "executions": {k: v.to_dict() for k, v in self.executions.items()},
            "evidence": {k: v.to_dict() for k, v in self.evidence.items()},
            "traces": {k: [s.to_dict() for s in v] for k, v in self.traces.items()},
        }
        path = self.store_dir / "state.json"
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def load(self):
        path = self.store_dir / "state.json"
        if not path.exists():
            return
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        for sid, sd in data.get("sessions", {}).items():
            self.sessions[sid] = Session(**{k: v for k, v in sd.items()
                                           if k in Session.__dataclass_fields__})
        for tid, td in data.get("turns", {}).items():
            self.turns[tid] = Turn(**{k: v for k, v in td.items()
                                     if k in Turn.__dataclass_fields__})
        for pid, pd in data.get("plans", {}).items():
            deps = pd.get("dependencies", {})
            deps = {int(k): v for k, v in deps.items()}
            self.plans[pid] = Plan(
                plan_id=pd["plan_id"], goal=pd["goal"], intent=pd["intent"],
                steps=pd.get("steps", []), dependencies=deps,
                status=pd.get("status", "created"), created_at=pd.get("created_at", 0),
            )
        for eid, ed in data.get("executions", {}).items():
            self.executions[eid] = ToolExecution(**{k: v for k, v in ed.items()
                                                    if k in ToolExecution.__dataclass_fields__})
        for eid, ed in data.get("evidence", {}).items():
            self.evidence[eid] = EvidenceRecord(**{k: v for k, v in ed.items()
                                                   if k in EvidenceRecord.__dataclass_fields__})
        for tid, steps in data.get("traces", {}).items():
            self.traces[tid] = [TraceStep(**{k: v for k, v in s.items()
                                             if k in TraceStep.__dataclass_fields__})
                                for s in steps]

    def get_stats(self) -> Dict:
        return {
            "sessions": len(self.sessions),
            "turns": len(self.turns),
            "plans": len(self.plans),
            "executions": len(self.executions),
            "evidence": len(self.evidence),
            "traces": len(self.traces),
        }
