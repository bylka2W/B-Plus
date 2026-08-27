import json
import hashlib
import time
from pathlib import Path


class ContextBuilder:
    BUDGET_reserved_output = 512
    BUDGET_system = 128
    BUDGETGoal = 256

    def __init__(self, tokenizer, knowledge, source_index, max_tokens=4096):
        self.tokenizer = tokenizer
        self.knowledge = knowledge
        self.source_index = source_index
        self.max_tokens = max_tokens

    def _count_tokens(self, text):
        return len(self.tokenizer.encode(text))

    def _truncate_to_tokens(self, text, budget):
        ids = self.tokenizer.encode(text)
        if len(ids) <= budget:
            return text
        truncated_ids = ids[:budget]
        return self.tokenizer.decode(truncated_ids)

    def build(self, goal, target_file=None, previous_error=None, extra_context=None):
        sections = []
        used_tokens = 0
        total_budget = self.max_tokens - self.BUDGET_reserved_output

        system_text = (
            "You are a Zig programming expert. "
            "You are given: a task, relevant knowledge from a codebase, "
            "and source code context. "
            "Generate correct, compilable Zig code. "
            "Output ONLY valid Zig code, no explanations."
        )
        system_tokens = self._count_tokens(system_text)
        if system_tokens <= total_budget - used_tokens:
            sections.append(("system", system_text))
            used_tokens += system_tokens

        goal_tokens = self._count_tokens(goal)
        goal_budget = min(self.BUDGETGoal, total_budget - used_tokens)
        if goal_tokens <= goal_budget:
            sections.append(("goal", goal))
            used_tokens += goal_tokens
        else:
            truncated = self._truncate_to_tokens(goal, goal_budget)
            sections.append(("goal", truncated))
            used_tokens += goal_budget

        kb_text = self._assemble_knowledge(goal, total_budget - used_tokens)
        kb_tokens = self._count_tokens(kb_text)
        if kb_tokens > 0 and kb_tokens <= total_budget - used_tokens:
            sections.append(("knowledge", kb_text))
            used_tokens += kb_tokens

        if target_file:
            source_text = self._assemble_source(target_file, total_budget - used_tokens)
            source_tokens = self._count_tokens(source_text)
            if source_tokens > 0 and source_tokens <= total_budget - used_tokens:
                sections.append(("source", source_text))
                used_tokens += source_tokens

        if previous_error:
            error_text = f"Previous attempt failed with error:\n{previous_error}\nFix this error."
            error_tokens = self._count_tokens(error_text)
            if error_tokens <= total_budget - used_tokens:
                sections.append(("error", error_text))
                used_tokens += error_tokens

        if extra_context:
            extra_tokens = self._count_tokens(extra_context)
            if extra_tokens <= total_budget - used_tokens:
                sections.append(("context", extra_context))
                used_tokens += extra_tokens

        prompt = self._format_sections(sections)
        return {
            "prompt": prompt,
            "tokens_used": self._count_tokens(prompt),
            "tokens_budget": total_budget,
            "tokens_remaining": total_budget - self._count_tokens(prompt),
            "sections": {s[0]: len(self.tokenizer.encode(s[1])) for s in sections},
        }

    def _assemble_knowledge(self, goal, budget):
        parts = []
        used = 0

        facts = self.knowledge.query_symbol(goal)
        if facts:
            fact_lines = []
            for f in facts[:20]:
                if isinstance(f, dict):
                    sf = f.get("source_file", "")
                    pred = f.get("predicate", "")
                    if sf or pred:
                        fact_lines.append(f"- {pred}: {sf}")
            if fact_lines:
                header = "Relevant facts from codebase:\n"
                header_tokens = self._count_tokens(header)
                if header_tokens < budget:
                    parts.append(header)
                    used += header_tokens
                    for line in fact_lines:
                        line_tokens = self._count_tokens(line)
                        if used + line_tokens < budget:
                            parts.append(line)
                            used += line_tokens

        concepts = self.knowledge.query_symbol(goal)
        concept_lines = []
        for c in concepts[:10]:
            if isinstance(c, dict) and c.get("type") == "concept":
                name = c.get("name", "")
                ctype = c.get("concept_type", "")
                if name:
                    concept_lines.append(f"- {ctype}: {name}")
        if concept_lines:
            header = "\nRelated concepts:\n"
            header_tokens = self._count_tokens(header)
            if used + header_tokens < budget:
                parts.append(header)
                used += header_tokens
                for line in concept_lines:
                    line_tokens = self._count_tokens(line)
                    if used + line_tokens < budget:
                        parts.append(line)
                        used += line_tokens

        return "\n".join(parts)

    def _assemble_source(self, target_file, budget):
        parts = []
        used = 0

        content = self.source_index.read_file_real(target_file)
        if not content:
            return ""

        header = f"Target file: {target_file}\n"
        header_tokens = self._count_tokens(header)
        if header_tokens < budget:
            parts.append(header)
            used += header_tokens

        content_tokens = self._count_tokens(content)
        remaining = budget - used
        if content_tokens <= remaining:
            parts.append(content)
            used += content_tokens
        else:
            truncated = self._truncate_to_tokens(content, remaining)
            parts.append(truncated)
            parts.append("\n... (truncated)")
            used = budget

        related = self.source_index.search(Path(target_file).stem, max_results=3)
        for r in related:
            if r["path"] != target_file:
                related_content = "\n".join(r["lines"][:50])
                related_header = f"\nRelated: {r['path']}\n"
                total = related_header + related_content
                total_tokens = self._count_tokens(total)
                if used + total_tokens < budget:
                    parts.append(total)
                    used += total_tokens

        return "\n".join(parts)

    def _format_sections(self, sections):
        formatted = []
        for name, content in sections:
            if name == "system":
                formatted.append(f"<system>\n{content}\n</system>")
            elif name == "goal":
                formatted.append(f"<task>\n{content}\n</task>")
            elif name == "knowledge":
                formatted.append(f"<knowledge>\n{content}\n</knowledge>")
            elif name == "source":
                formatted.append(f"<source>\n{content}\n</source>")
            elif name == "error":
                formatted.append(f"<error>\n{content}\n</error>")
            elif name == "context":
                formatted.append(f"<context>\n{content}\n</context>")
        return "\n\n".join(formatted)

    def build_training_example(self, goal, target_file, expected_code):
        ctx = self.build(goal, target_file=target_file)
        prompt = ctx["prompt"]
        full = prompt + "\n\n" + expected_code
        return {
            "prompt": prompt,
            "completion": expected_code,
            "full": full,
            "tokens_prompt": ctx["tokens_used"],
            "tokens_completion": self._count_tokens(expected_code),
            "tokens_total": self._count_tokens(full),
        }
