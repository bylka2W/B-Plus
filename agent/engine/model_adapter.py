import os
import sys
import time
import json
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import ZIG_ROOT, MEMORY_DIR, load_json, save_json
from indexes import get_fast_index
from intent_router import IntentRouter
from entity_resolver import EntityResolver
from graph_traversal import GraphTraversal
from context_compressor import ContextCompressor
from truth_contract import TruthContract
from answer_verifier import AnswerVerifier
from execution_contract import ExecutionContract
from source_identity import SourceIdentity

TASK_LOG_PATH = MEMORY_DIR / "task_log.json"

STATUS_QUEUED = "QUEUED"
STATUS_CONTEXT_READY = "CONTEXT_READY"
STATUS_MODELPending = "MODEL_PENDING"
STATUS_PATCH_READY = "PATCH_READY"
STATUS_VERIFIED = "VERIFIED"
STATUS_EXECUTED = "EXECUTED"
STATUS_FAILED = "FAILED"
STATUS_REJECTED = "REJECTED"

ALL_TASK_STATUSES = {
    STATUS_QUEUED, STATUS_CONTEXT_READY, STATUS_MODELPending,
    STATUS_PATCH_READY, STATUS_VERIFIED, STATUS_EXECUTED,
    STATUS_FAILED, STATUS_REJECTED,
}

OUTPUT_PATCH = "PATCH"
OUTPUT_ANSWER = "ANSWER"
OUTPUT_BOTH = "BOTH"

ALL_OUTPUT_FORMATS = {OUTPUT_PATCH, OUTPUT_ANSWER, OUTPUT_BOTH}


class TaskContext:
    __slots__ = (
        "task_id", "task", "question", "intent", "entity",
        "context", "evidence_ids", "source_files", "constraints",
        "allowed_files", "denied_files", "output_format",
        "allowed_verbs", "max_files_changed", "max_lines_changed",
        "requires_compilation", "requires_tests",
        "created_at",
    )

    def __init__(self):
        self.task_id = ""
        self.task = ""
        self.question = ""
        self.intent = None
        self.entity = None
        self.context = ""
        self.evidence_ids = []
        self.source_files = []
        self.constraints = []
        self.allowed_files = []
        self.denied_files = []
        self.output_format = OUTPUT_PATCH
        self.allowed_verbs = ["ADD", "MODIFY", "DELETE"]
        self.max_files_changed = 5
        self.max_lines_changed = 200
        self.requires_compilation = True
        self.requires_tests = True
        self.created_at = ""

    def _context_to_str(self):
        if self.context is None:
            return ""
        if isinstance(self.context, str):
            return self.context
        parts = []
        for section in self.context.sections:
            if section.content:
                parts.append(section.content)
        return "\n\n".join(parts)

    def to_dict(self):
        return {
            "task_id": self.task_id,
            "task": self.task,
            "question": self.question,
            "intent": self.intent.to_dict() if self.intent else None,
            "entity": self.entity.to_dict() if self.entity else None,
            "context": self._context_to_str()[:5000],
            "evidence_ids": self.evidence_ids[:20],
            "source_files": self.source_files[:20],
            "constraints": self.constraints,
            "allowed_files": self.allowed_files,
            "denied_files": self.denied_files,
            "output_format": self.output_format,
            "allowed_verbs": self.allowed_verbs,
            "max_files_changed": self.max_files_changed,
            "max_lines_changed": self.max_lines_changed,
            "requires_compilation": self.requires_compilation,
            "requires_tests": self.requires_tests,
            "created_at": self.created_at,
        }


class ModelRequest:
    __slots__ = (
        "task_id", "prompt", "system_prompt", "context_tokens",
        "max_tokens", "temperature", "format", "metadata",
    )

    def __init__(self):
        self.task_id = ""
        self.prompt = ""
        self.system_prompt = ""
        self.context_tokens = 0
        self.max_tokens = 4096
        self.temperature = 0.0
        self.format = "patch"
        self.metadata = {}

    def to_dict(self):
        return {
            "task_id": self.task_id,
            "prompt": self.prompt[:10000],
            "system_prompt": self.system_prompt[:5000],
            "context_tokens": self.context_tokens,
            "max_tokens": self.max_tokens,
            "temperature": self.temperature,
            "format": self.format,
            "metadata": self.metadata,
        }


class ModelResponse:
    __slots__ = (
        "task_id", "raw_output", "status", "patch", "changed_files",
        "answer", "explanation", "confidence", "elapsed_ms",
        "token_count", "finish_reason",
    )

    def __init__(self):
        self.task_id = ""
        self.raw_output = ""
        self.status = ""
        self.patch = ""
        self.changed_files = []
        self.answer = ""
        self.explanation = ""
        self.confidence = 0.0
        self.elapsed_ms = 0.0
        self.token_count = 0
        self.finish_reason = ""

    def to_dict(self):
        return {
            "task_id": self.task_id,
            "raw_output": self.raw_output[:10000],
            "status": self.status,
            "patch": self.patch[:10000],
            "changed_files": self.changed_files,
            "answer": self.answer[:5000],
            "explanation": self.explanation[:5000],
            "confidence": round(self.confidence, 4),
            "elapsed_ms": round(self.elapsed_ms, 3),
            "token_count": self.token_count,
            "finish_reason": self.finish_reason,
        }


class TaskResult:
    __slots__ = (
        "task_id", "status", "context", "request", "response",
        "verified", "executed", "execution_result",
        "elapsed_ms", "created_at",
    )

    def __init__(self):
        self.task_id = ""
        self.status = STATUS_QUEUED
        self.context = None
        self.request = None
        self.response = None
        self.verified = False
        self.executed = False
        self.execution_result = None
        self.elapsed_ms = 0.0
        self.created_at = ""

    def to_dict(self):
        return {
            "task_id": self.task_id,
            "status": self.status,
            "context": self.context.to_dict() if self.context else None,
            "request": self.request.to_dict() if self.request else None,
            "response": self.response.to_dict() if self.response else None,
            "verified": self.verified,
            "executed": self.executed,
            "execution_result": self.execution_result.to_dict() if self.execution_result else None,
            "elapsed_ms": round(self.elapsed_ms, 3),
            "created_at": self.created_at,
        }

    def render(self):
        lines = []
        lines.append(f"TASK: {self.task_id}")
        lines.append(f"STATUS: {self.status}")
        if self.context:
            lines.append(f"INTENT: {self.context.intent.intent if self.context.intent else 'N/A'}")
            lines.append(f"ENTITY: {self.context.entity.concept_id if self.context.entity else 'N/A'}")
            lines.append(f"EVIDENCE: {len(self.context.evidence_ids)} items")
            lines.append(f"SOURCE_FILES: {len(self.context.source_files)} files")
            lines.append(f"CONSTRAINTS: {len(self.context.constraints)}")
        if self.response:
            lines.append(f"PATCH: {'YES' if self.response.patch else 'NO'}")
            lines.append(f"ANSWER: {self.response.answer[:80] if self.response.answer else 'N/A'}")
            lines.append(f"CONFIDENCE: {self.response.confidence:.2%}")
        lines.append(f"VERIFIED: {self.verified}")
        lines.append(f"EXECUTED: {self.executed}")
        if self.execution_result:
            lines.append(f"EXEC_STATUS: {self.execution_result.status}")
        lines.append(f"TIME: {self.elapsed_ms:.0f}ms")
        return "\n".join(lines)


SYSTEM_PROMPT = """You are a specialized Zig coding assistant for the B+ project.

RULES:
1. Output ONLY valid Zig code or patches.
2. Never fabricate knowledge — use only provided context.
3. Never declare something VERIFIED — the system verifies.
4. Format output as:
   STATUS: <PATCH_READY|ANSWER_READY|FAILED>
   FILES: <comma-separated changed files>
   ---
   <patch content or answer>
5. If you cannot complete the task, output:
   STATUS: FAILED
   REASON: <why>
6. Stay within the allowed files list.
7. Do not add comments unless asked.
8. Do not change APIs without explicit instruction.
"""


class ModelAdapter:
    def __init__(self):
        self.router = IntentRouter()
        self.resolver = EntityResolver()
        self.traversal = None
        self.compressor = ContextCompressor()
        self.truth = TruthContract.load()
        self.verifier = AnswerVerifier.load()
        self.exec_contract = ExecutionContract.load()
        self.identity = SourceIdentity.load()

    @classmethod
    def load(cls):
        return cls()

    def prepare_task(self, task, question="", task_id=None):
        t0 = time.monotonic()
        tc = TaskContext()
        tc.task_id = task_id or f"TSK-{int(time.time() * 1000) % 1000000000:09d}"
        tc.task = task
        tc.question = question or task
        tc.created_at = datetime.now(timezone.utc).isoformat()

        tc.intent = self.router.route(tc.question)

        if tc.intent.entity and isinstance(tc.intent.entity, str):
            tc.entity = self.resolver.resolve(tc.intent.entity)

        tc.context = self.compressor.compress(tc.question)

        tc.evidence_ids = []
        tc.source_files = []
        if tc.entity and tc.entity.status == "RESOLVED":
            tc.evidence_ids = (tc.entity.evidence_ids or [])[:20]
            if tc.entity.file:
                tc.source_files = [tc.entity.file]

        tc.constraints = self._build_constraints(tc)
        tc.allowed_files = self._get_allowed_files(tc)
        tc.denied_files = self._get_denied_files(tc)

        elapsed = (time.monotonic() - t0) * 1000
        return tc

    def _compress_to_text(self, cc):
        parts = []
        for section in cc.sections:
            if section.content:
                parts.append(section.content)
        return "\n\n".join(parts)

    def build_request(self, tc):
        req = ModelRequest()
        req.task_id = tc.task_id
        req.format = "patch" if tc.output_format == OUTPUT_PATCH else "answer"
        req.context_tokens = tc.context.total_tokens if hasattr(tc.context, "total_tokens") else 0
        context_text = self._compress_to_text(tc.context) if tc.context else ""

        prompt_parts = []
        prompt_parts.append(f"TASK: {tc.task}")
        if context_text:
            prompt_parts.append(f"\nCONTEXT:\n{context_text[:8000]}")
        if tc.source_files:
            prompt_parts.append(f"\nSOURCE_FILES: {', '.join(tc.source_files[:10])}")
        if tc.allowed_files:
            prompt_parts.append(f"\nALLOWED_FILES: {', '.join(tc.allowed_files[:10])}")
        if tc.constraints:
            prompt_parts.append(f"\nCONSTRAINTS:")
            for c in tc.constraints[:10]:
                prompt_parts.append(f"  - {c}")
        if tc.output_format == OUTPUT_PATCH:
            prompt_parts.append(f"\nOUTPUT FORMAT: PATCH")
        else:
            prompt_parts.append(f"\nOUTPUT FORMAT: ANSWER")

        req.prompt = "\n".join(prompt_parts)
        req.system_prompt = SYSTEM_PROMPT
        req.temperature = 0.0
        req.max_tokens = 4096

        return req

    def parse_response(self, raw_output, tc=None):
        resp = ModelResponse()
        resp.raw_output = raw_output

        if not raw_output or not raw_output.strip():
            resp.status = "FAILED"
            resp.explanation = "empty output"
            return resp

        lines = raw_output.strip().split("\n")
        status_line = ""
        files_line = []
        content_lines = []
        in_content = False

        for line in lines:
            if line.startswith("STATUS:"):
                status_line = line.split(":", 1)[1].strip()
                continue
            if line.startswith("FILES:"):
                files_str = line.split(":", 1)[1].strip()
                files_line = [f.strip() for f in files_str.split(",") if f.strip()]
                continue
            if line.startswith("REASON:"):
                resp.explanation = line.split(":", 1)[1].strip()
                continue
            if line == "---":
                in_content = True
                continue
            if in_content:
                content_lines.append(line)

        resp.status = status_line or "FAILED"
        resp.changed_files = files_line
        content = "\n".join(content_lines).strip()

        if resp.status == "PATCH_READY":
            resp.patch = content
        elif resp.status == "ANSWER_READY":
            resp.answer = content
        else:
            resp.answer = content or raw_output

        return resp

    def validate_output(self, resp, tc=None):
        if resp.status == "FAILED":
            return resp

        if resp.status == "PATCH_READY":
            if not resp.patch:
                resp.status = "FAILED"
                resp.explanation = "PATCH_READY but no patch content"
                return resp
            if tc and tc.allowed_files:
                for f in resp.changed_files:
                    if f not in tc.allowed_files:
                        resp.status = "FAILED"
                        resp.explanation = f"file {f} not in allowed list"
                        return resp

        return resp

    def verify_answer(self, resp, tc=None):
        if resp.status != "PATCH_READY" and resp.answer:
            av_result = self.verifier.verify(resp.answer, tc.question if tc else "")
            resp.confidence = av_result.confidence
            return av_result.overall_status == "PASS"
        if resp.status == "PATCH_READY":
            resp.confidence = 1.0
            return True
        return False

    def execute_patch(self, resp, task_id=""):
        if resp.status != "PATCH_READY" or not resp.patch:
            return None
        file_path = resp.changed_files[0] if resp.changed_files else "/__model_output__.zig"
        return self.exec_contract.execute_patch(resp.patch, file_path, task_id=task_id)

    def run_task(self, task, question="", task_id=None):
        t0 = time.monotonic()
        result = TaskResult()
        result.task_id = task_id or f"TSK-{int(time.time() * 1000) % 1000000000:09d}"
        result.created_at = datetime.now(timezone.utc).isoformat()

        tc = self.prepare_task(task, question, result.task_id)
        result.context = tc

        req = self.build_request(tc)
        result.request = req

        resp = ModelResponse()
        resp.task_id = result.task_id
        resp.status = "PATCH_READY"
        resp.patch = ""
        resp.answer = f"Task prepared: {tc.task}"
        resp.confidence = 0.0
        result.response = resp

        result.status = STATUS_CONTEXT_READY
        result.elapsed_ms = (time.monotonic() - t0) * 1000
        self._log(result)
        return result

    def _build_constraints(self, tc):
        constraints = []
        constraints.append("Only modify allowed files")
        constraints.append("Output must be valid Zig")
        constraints.append("Do not add comments unless asked")
        if tc.requires_compilation:
            constraints.append("Code must compile")
        if tc.requires_tests:
            constraints.append("Existing tests must pass")
        return constraints

    def _get_allowed_files(self, tc):
        if tc.entity and tc.entity.status == "RESOLVED":
            if tc.entity.file:
                return [tc.entity.file]
        return []

    def _get_denied_files(self, tc):
        return []

    def _log(self, result):
        log = load_json(TASK_LOG_PATH) if TASK_LOG_PATH.exists() else {"tasks": []}
        if "tasks" not in log:
            log["tasks"] = []
        log["tasks"].append(result.to_dict())
        if len(log["tasks"]) > 500:
            log["tasks"] = log["tasks"][-500:]
        save_json(TASK_LOG_PATH, log)


_instance = None


def get_model_adapter():
    global _instance
    if _instance is None:
        _instance = ModelAdapter.load()
    return _instance


def main():
    ma = ModelAdapter.load()
    print("MODEL ADAPTER READY")

    result = ma.run_task(
        "Добавь функцию add в src/bplus.zig",
        "add function to bplus.zig",
    )
    print(result.render())

    print("\n--- REQUEST ---")
    if result.request:
        print(result.request.prompt[:500])

    print("\n--- PARSE TEST ---")
    raw = "STATUS: PATCH_READY\nFILES: src/bplus.zig\n---\nconst std = @import(\"std\");\npub fn add(a: i32, b: i32) i32 { return a + b; }"
    resp = ma.parse_response(raw)
    print(f"  status: {resp.status}")
    print(f"  files: {resp.changed_files}")
    print(f"  patch: {resp.patch[:100]}")

    sys.exit(0)


if __name__ == "__main__":
    main()
