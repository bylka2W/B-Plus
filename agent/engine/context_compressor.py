import os
import sys
import time
import hashlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import ZIG_ROOT

DEFAULT_MAX_TOKENS = 256000
CHARS_PER_TOKEN = 4
MAX_SOURCE_LINES = 500
MAX_EVIDENCE_ITEMS = 50
MAX_GRAPH_NODES = 100
MAX_GRAPH_EDGES = 100

STATUS_VERIFIED = "VERIFIED"
STATUS_STALE = "STALE"
STATUS_MISSING = "MISSING"
STATUS_INVALID = "INVALID"
STATUS_NOT_FOUND = "NOT_FOUND"
STATUS_PARTIAL = "PARTIAL"
STATUS_INSUFFICIENT = "INSUFFICIENT_CONTEXT"
STATUS_COMPLETE = "COMPLETE"
STATUS_NO_CONTEXT = "NO_CONTEXT"


class ContextBudget:
    __slots__ = ("max_tokens", "max_chars", "used_chars", "sections")

    def __init__(self, max_tokens=DEFAULT_MAX_TOKENS):
        self.max_tokens = max_tokens
        self.max_chars = max_tokens * CHARS_PER_TOKEN
        self.used_chars = 0
        self.sections = {}

    def allocate(self, section_name, char_estimate):
        if self.used_chars + char_estimate > self.max_chars:
            remaining = max(0, self.max_chars - self.used_chars)
            self.used_chars = self.max_chars
            self.sections[section_name] = remaining
            return remaining
        self.used_chars += char_estimate
        self.sections[section_name] = char_estimate
        return char_estimate

    def remaining(self):
        return max(0, self.max_chars - self.used_chars)

    def usage_ratio(self):
        return self.used_chars / max(self.max_chars, 1)


class ContextSection:
    __slots__ = ("name", "content", "char_count", "token_estimate",
                 "verification_status", "priority")

    def __init__(self, name="", content="", priority=0):
        self.name = name
        self.content = content
        self.char_count = len(content)
        self.token_estimate = self.char_count // CHARS_PER_TOKEN
        self.verification_status = STATUS_VERIFIED
        self.priority = priority

    def to_dict(self):
        return {
            "name": self.name,
            "char_count": self.char_count,
            "token_estimate": self.token_estimate,
            "verification_status": self.verification_status,
            "priority": self.priority,
        }


class CompressedContext:
    __slots__ = (
        "sections", "status", "total_chars", "total_tokens",
        "budget_used_ratio", "verification_summary", "elapsed_ms",
        "question", "intent", "entity", "entity_type",
    )

    def __init__(self):
        self.sections = []
        self.status = STATUS_COMPLETE
        self.total_chars = 0
        self.total_tokens = 0
        self.budget_used_ratio = 0.0
        self.verification_summary = {}
        self.elapsed_ms = 0.0
        self.question = ""
        self.intent = ""
        self.entity = ""
        self.entity_type = ""

    def add_section(self, section):
        self.sections.append(section)
        self.total_chars += section.char_count
        self.total_tokens += section.token_estimate
        st = section.verification_status
        self.verification_summary[st] = self.verification_summary.get(st, 0) + 1

    def to_dict(self):
        return {
            "status": self.status,
            "total_chars": self.total_chars,
            "total_tokens": self.total_tokens,
            "budget_used_ratio": round(self.budget_used_ratio, 4),
            "section_count": len(self.sections),
            "verification_summary": self.verification_summary,
            "elapsed_ms": self.elapsed_ms,
            "question": self.question,
            "intent": self.intent,
            "entity": self.entity,
            "entity_type": self.entity_type,
            "sections": [s.to_dict() for s in self.sections],
        }

    def render(self):
        parts = []
        for s in self.sections:
            parts.append(f"=== {s.name.upper()} ===")
            parts.append(s.content)
            parts.append("")
        return "\n".join(parts)


class ContextCompressor:
    def __init__(self, idx=None, verifier=None, graph=None):
        from indexes import get_fast_index
        from evidence_verifier import get_evidence_verifier
        from graph_traversal import get_graph_traversal
        self.idx = idx or get_fast_index()
        self.verifier = verifier or get_evidence_verifier()
        self.graph = graph or get_graph_traversal()

    @classmethod
    def load(cls):
        return cls()

    def compress(self, question, max_tokens=DEFAULT_MAX_TOKENS,
                 include_source=True, include_graph=True,
                 include_evidence=True, depth=1):
        t0 = time.monotonic()
        ctx = CompressedContext()
        ctx.question = question
        budget = ContextBudget(max_tokens)

        from intent_router import IntentRouter
        router = IntentRouter.load()
        intent_result = router.route(question)
        ctx.intent = intent_result.intent
        ctx.entity = intent_result.entity
        ctx.entity_type = intent_result.entity_resolved.entity_type if intent_result.entity_resolved else ""

        self._add_task_section(ctx, budget, question, intent_result)
        self._add_entity_section(ctx, budget, intent_result)

        if include_graph and intent_result.status == "RESOLVED":
            self._add_graph_section(ctx, budget, intent_result, depth)

        if include_evidence and intent_result.status == "RESOLVED":
            self._add_evidence_section(ctx, budget, intent_result)

        if include_source and intent_result.status == "RESOLVED":
            self._add_source_section(ctx, budget, intent_result)

        self._add_constraints_section(ctx, budget)

        ctx.budget_used_ratio = budget.usage_ratio()
        if ctx.total_chars == 0:
            ctx.status = STATUS_NO_CONTEXT
        elif intent_result.status != "RESOLVED":
            ctx.status = STATUS_INSUFFICIENT

        ctx.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return ctx

    def compress_entity(self, concept_id, max_tokens=DEFAULT_MAX_TOKENS,
                        include_source=True, include_graph=True,
                        include_evidence=True, depth=1):
        t0 = time.monotonic()
        ctx = CompressedContext()
        budget = ContextBudget(max_tokens)

        c = self.idx.concept_by_id.get(concept_id)
        if not c:
            ctx.status = STATUS_NOT_FOUND
            ctx.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return ctx

        ctx.entity = c.get("canonical_name", "")
        ctx.entity_type = c.get("concept_type", "")
        ctx.intent = "ENTITY_CONTEXT"

        self._add_entity_detail_section(ctx, budget, concept_id, c)

        if include_graph:
            self._add_graph_section_by_id(ctx, budget, concept_id, depth)

        if include_evidence:
            self._add_evidence_section_by_id(ctx, budget, concept_id)

        if include_source:
            self._add_source_section_by_id(ctx, budget, concept_id, c)

        self._add_constraints_section(ctx, budget)

        ctx.budget_used_ratio = budget.usage_ratio()
        ctx.status = STATUS_COMPLETE
        ctx.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return ctx

    def _add_task_section(self, ctx, budget, question, intent_result):
        lines = [f"QUESTION: {question}"]
        lines.append(f"INTENT: {intent_result.intent}")
        if intent_result.entity:
            lines.append(f"TARGET_ENTITY: {intent_result.entity}")
        if intent_result.entity_resolved:
            er = intent_result.entity_resolved
            lines.append(f"ENTITY_TYPE: {er.entity_type}")
            lines.append(f"ENTITY_ID: {er.concept_id}")
            lines.append(f"ENTITY_STATUS: {er.status}")
        lines.append(f"EVIDENCE_REQUIRED: {intent_result.requires_evidence}")
        content = "\n".join(lines)
        section = ContextSection("TASK", content, priority=100)
        section.verification_status = STATUS_VERIFIED
        budget.allocate("TASK", section.char_count)
        ctx.add_section(section)

    def _add_entity_section(self, ctx, budget, intent_result):
        if not intent_result.entity_resolved:
            return
        er = intent_result.entity_resolved
        if er.status != "RESOLVED":
            return
        c = self.idx.concept_by_id.get(er.concept_id)
        if not c:
            return
        lines = []
        lines.append(f"CONCEPT_ID: {er.concept_id}")
        lines.append(f"NAME: {c.get('canonical_name', '')}")
        lines.append(f"TYPE: {c.get('concept_type', '')}")
        file_id = c.get("file_id", "")
        fe = self.idx.file_by_id.get(file_id)
        if fe:
            lines.append(f"FILE: {fe.get('path', '')}")
        lines.append(f"LINES: {c.get('line_start', 0)}-{c.get('line_end', 0)}")
        module_id = self.idx.concept_module.get(er.concept_id)
        if module_id:
            mc = self.idx.concept_by_id.get(module_id)
            if mc:
                lines.append(f"MODULE: {mc.get('canonical_name', '')}")
        fact_ids = c.get("fact_ids", [])
        lines.append(f"FACT_COUNT: {len(fact_ids)}")
        ev_ids = c.get("evidence_ids", [])
        lines.append(f"EVIDENCE_COUNT: {len(ev_ids)}")
        content = "\n".join(lines)
        section = ContextSection("ENTITY", content, priority=90)
        section.verification_status = STATUS_VERIFIED
        budget.allocate("ENTITY", section.char_count)
        ctx.add_section(section)

    def _add_graph_section(self, ctx, budget, intent_result, depth):
        er = intent_result.entity_resolved
        if not er or er.status != "RESOLVED":
            return
        cid = er.concept_id
        self._add_graph_section_by_id(ctx, budget, cid, depth)

    def _add_graph_section_by_id(self, ctx, budget, concept_id, depth):
        lines = []
        callers = self.graph.callers(concept_id, depth=depth)
        if callers.edges:
            lines.append("CALLERS:")
            for e in callers.edges:
                src = callers.nodes.get(e.source_id)
                name = src.name if src else e.source_id
                lines.append(f"  {name} ({e.source_id})")
                if e.evidence_file:
                    lines.append(f"    evidence: {e.evidence_file}:{e.evidence_line_start}-{e.evidence_line_end}")
        callees = self.graph.callees(concept_id, depth=depth)
        if callees.edges:
            lines.append("CALLEES:")
            for e in callees.edges:
                tgt = callees.nodes.get(e.target_id)
                name = tgt.name if tgt else e.target_id
                lines.append(f"  {name} ({e.target_id})")
                if e.evidence_file:
                    lines.append(f"    evidence: {e.evidence_file}:{e.evidence_line_start}-{e.evidence_line_end}")
        refs = self.graph.references(concept_id, depth=depth)
        if refs.edges:
            lines.append("REFERENCES:")
            for e in refs.edges[:10]:
                tgt = refs.nodes.get(e.target_id)
                name = tgt.name if tgt else e.target_id
                lines.append(f"  {name} ({e.target_id})")
        deps = self.graph.dependencies(concept_id, depth=1)
        if deps.edges:
            lines.append("DEPENDENCIES:")
            for e in deps.edges:
                tgt = deps.nodes.get(e.target_id)
                name = tgt.name if tgt else e.target_id
                lines.append(f"  {name} ({e.target_id})")
        if not lines:
            lines.append("GRAPH: no connections found")
        content = "\n".join(lines)
        section = ContextSection("GRAPH", content, priority=80)
        section.verification_status = STATUS_VERIFIED
        used = budget.allocate("GRAPH", section.char_count)
        if used < section.char_count:
            section.content = content[:used] if used > 0 else "[BUDGET EXCEEDED]"
            section.char_count = len(section.content)
            section.token_estimate = section.char_count // 4
        ctx.add_section(section)

    def _add_evidence_section(self, ctx, budget, intent_result):
        er = intent_result.entity_resolved
        if not er or er.status != "RESOLVED":
            return
        self._add_evidence_section_by_id(ctx, budget, er.concept_id)

    def _add_evidence_section_by_id(self, ctx, budget, concept_id):
        lines = []
        c = self.idx.concept_by_id.get(concept_id)
        if not c:
            return
        ev_ids = c.get("evidence_ids", [])
        fact_ids = c.get("fact_ids", [])
        all_ev = list(ev_ids)
        for fid in fact_ids[:20]:
            fact = self.idx.fact_by_id.get(fid)
            if fact:
                eid = fact.get("evidence_id", "")
                if eid and eid not in all_ev:
                    all_ev.append(eid)
        verified = 0
        stale = 0
        missing = 0
        for eid in all_ev[:MAX_EVIDENCE_ITEMS]:
            ev = self.idx.evidence_by_id.get(eid)
            if not ev:
                missing += 1
                continue
            src = ev.get("source_file", "")
            ls = ev.get("line_start", 0)
            le = ev.get("line_end", 0)
            text = ev.get("text", "")[:200]
            vr = self.verifier.verify_evidence(eid)
            status_tag = vr.status
            if status_tag == STATUS_VERIFIED:
                verified += 1
            elif status_tag == STATUS_STALE:
                stale += 1
            else:
                missing += 1
            lines.append(f"[{status_tag}] {os.path.basename(src)}:{ls}-{le}")
            if text:
                snippet = text.replace("\n", " ")[:120]
                lines.append(f"  {snippet}")
        lines.insert(0, f"EVIDENCE_SUMMARY: verified={verified} stale={stale} missing={missing} total={len(all_ev)}")
        content = "\n".join(lines)
        section = ContextSection("EVIDENCE", content, priority=70)
        if stale > verified:
            section.verification_status = STATUS_STALE
        elif missing > 0:
            section.verification_status = STATUS_PARTIAL
        else:
            section.verification_status = STATUS_VERIFIED
        budget.allocate("EVIDENCE", section.char_count)
        ctx.add_section(section)

    def _add_source_section(self, ctx, budget, intent_result):
        er = intent_result.entity_resolved
        if not er or er.status != "RESOLVED":
            return
        c = self.idx.concept_by_id.get(er.concept_id)
        if not c:
            return
        self._add_source_section_by_id(ctx, budget, er.concept_id, c)

    def _add_source_section_by_id(self, ctx, budget, concept_id, c):
        file_id = c.get("file_id", "")
        fe = self.idx.file_by_id.get(file_id)
        if not fe:
            return
        path = fe.get("path", "")
        if not os.path.exists(path):
            section = ContextSection("SOURCE", "[FILE NOT FOUND]", priority=60)
            section.verification_status = STATUS_MISSING
            budget.allocate("SOURCE", section.char_count)
            ctx.add_section(section)
            return
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                all_lines = f.readlines()
        except (OSError, IOError):
            return
        ls = c.get("line_start", 0)
        le = c.get("line_end", 0)
        if ls < 1:
            ls = 1
        if le < ls:
            le = ls
        context_pad = 10
        start = max(1, ls - context_pad)
        end = min(len(all_lines), le + context_pad)
        segment = all_lines[start - 1:end]
        code = "".join(segment)
        header = f"FILE: {path}\nRANGE: {start}-{end} (entity lines {ls}-{le})\nTOTAL_LINES: {len(all_lines)}\n"
        content = header + "\n```zig\n" + code + "\n```"
        section = ContextSection("SOURCE", content, priority=60)
        section.verification_status = STATUS_VERIFIED
        budget.allocate("SOURCE", section.char_count)
        ctx.add_section(section)

    def _add_constraints_section(self, ctx, budget):
        lines = [
            "CONSTRAINTS:",
            "- DO NOT fabricate facts not present in this context",
            "- If context is insufficient, respond with INSUFFICIENT_CONTEXT",
            "- All claims must reference provided evidence IDs",
            "- Status VERIFIED means checked against live source tree",
            "- Status STALE means source has changed since evidence creation",
            "- Status MISSING means source file no longer exists",
        ]
        content = "\n".join(lines)
        section = ContextSection("CONSTRAINTS", content, priority=50)
        section.verification_status = STATUS_VERIFIED
        budget.allocate("CONSTRAINTS", section.char_count)
        ctx.add_section(section)

    def _add_entity_detail_section(self, ctx, budget, concept_id, c):
        lines = []
        lines.append(f"CONCEPT_ID: {concept_id}")
        lines.append(f"NAME: {c.get('canonical_name', '')}")
        lines.append(f"TYPE: {c.get('concept_type', '')}")
        file_id = c.get("file_id", "")
        fe = self.idx.file_by_id.get(file_id)
        if fe:
            lines.append(f"FILE: {fe.get('path', '')}")
        lines.append(f"LINES: {c.get('line_start', 0)}-{c.get('line_end', 0)}")
        module_id = self.idx.concept_module.get(concept_id)
        if module_id:
            mc = self.idx.concept_by_id.get(module_id)
            if mc:
                lines.append(f"MODULE: {mc.get('canonical_name', '')}")
                lines.append(f"MODULE_ID: {module_id}")
        fact_ids = c.get("fact_ids", [])
        lines.append(f"FACT_COUNT: {len(fact_ids)}")
        for fid in fact_ids[:10]:
            fact = self.idx.fact_by_id.get(fid)
            if fact:
                lines.append(f"  FACT {fid}: {fact.get('predicate', '')} -> {fact.get('object_id', '')}")
        ev_ids = c.get("evidence_ids", [])
        lines.append(f"EVIDENCE_COUNT: {len(ev_ids)}")
        content = "\n".join(lines)
        section = ContextSection("ENTITY_DETAIL", content, priority=95)
        section.verification_status = STATUS_VERIFIED
        budget.allocate("ENTITY_DETAIL", section.char_count)
        ctx.add_section(section)


_instance = None


def get_context_compressor():
    global _instance
    if _instance is None:
        _instance = ContextCompressor.load()
    return _instance


def main():
    cc = ContextCompressor.load()
    print("CONTEXT COMPRESSOR READY")

    ctx = cc.compress("Who calls foldConstantOp?")
    print(f"\n--- Who calls foldConstantOp? ---")
    print(f"status: {ctx.status}")
    print(f"total_chars: {ctx.total_chars}")
    print(f"total_tokens: {ctx.total_tokens}")
    print(f"budget_used: {ctx.budget_used_ratio:.4f}")
    print(f"sections: {len(ctx.sections)}")
    print(f"verification: {ctx.verification_summary}")
    for s in ctx.sections:
        print(f"  [{s.name}] {s.char_count} chars  status={s.verification_status}")

    ctx2 = cc.compress_entity(
        ctx.entity_resolved.concept_id if hasattr(ctx, 'entity_resolved') else
        list(cc.idx.concept_by_id.keys())[0]
    )
    print(f"\n--- Entity Context ---")
    print(f"status: {ctx2.status}")
    print(f"total_chars: {ctx2.total_chars}")
    print(f"sections: {len(ctx2.sections)}")

    rendered = ctx.render()
    print(f"\n--- Rendered Context ({len(rendered)} chars) ---")
    print(rendered[:500])
    print("...")

    sys.exit(0)


if __name__ == "__main__":
    main()
