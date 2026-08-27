import os
import re
import json
import hashlib
import time
import copy
from pathlib import Path
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional, Any


@dataclass
class ActiveContext:
    symbols: list = field(default_factory=list)
    files: list = field(default_factory=list)
    relations: list = field(default_factory=list)
    evidence_ids: list = field(default_factory=list)
    chunks: list = field(default_factory=list)
    error_history: list = field(default_factory=list)
    generation_count: int = 0
    total_tokens_used: int = 0

    def summary(self):
        return {
            "symbols": len(self.symbols),
            "files": len(self.files),
            "relations": len(self.relations),
            "evidence": len(self.evidence_ids),
            "chunks": len(self.chunks),
            "errors": len(self.error_history),
            "generations": self.generation_count,
            "total_tokens": self.total_tokens_used,
        }


class ConfidenceDrivenBudgeter:
    TIERS = [
        (0.9, 1024, "minimal"),
        (0.7, 2048, "focused"),
        (0.5, 4096, "standard"),
        (0.3, 8192, "expanded"),
        (0.15, 16384, "deep"),
        (0.0, 32768, "investigation"),
        (0.0, 65536, "comprehensive"),
        (0.0, 131072, "full"),
        (0.0, 262144, "maximum"),
    ]

    def __init__(self, max_tokens=262144):
        self.max_tokens = max_tokens
        self.current_confidence = 0.5

    def update_confidence(self, confidence):
        self.current_confidence = max(0.0, min(1.0, confidence))

    def get_budget(self, confidence=None):
        if confidence is not None:
            self.current_confidence = confidence
        for threshold, budget, label in self.TIERS:
            if self.current_confidence > threshold:
                return min(budget, self.max_tokens)
        return min(self.TIERS[-1][1], self.max_tokens)

    def expand_on_failure(self, current_budget, error_type):
        expansions = {
            "syntax_error": 1.5,
            "build_error": 2.0,
            "test_failure": 2.5,
            "timeout": 1.5,
            "unknown": 2.0,
        }
        multiplier = expansions.get(error_type, 2.0)
        new_budget = int(current_budget * multiplier)
        return min(new_budget, self.max_tokens)

    def allocate(self, total_budget):
        return {
            "system": int(total_budget * 0.02),
            "task": int(total_budget * 0.03),
            "knowledge": int(total_budget * 0.20),
            "source": int(total_budget * 0.50),
            "evidence": int(total_budget * 0.15),
            "error_context": int(total_budget * 0.05),
            "output": int(total_budget * 0.05),
        }


class PersistentContextState:
    def __init__(self):
        self.active = ActiveContext()
        self._previous_prompts = []
        self._context_version = 0

    def update_from_generation(self, symbols=None, files=None, evidence=None, error=None):
        if symbols:
            for s in symbols:
                if s not in self.active.symbols:
                    self.active.symbols.append(s)
        if files:
            for f in files:
                if f not in self.active.files:
                    self.active.files.append(f)
        if evidence:
            for e in evidence:
                eid = e.get("fact_id", "")
                if eid and eid not in self.active.evidence_ids:
                    self.active.evidence_ids.append(eid)
        if error:
            self.active.error_history.append({
                "error": error[:500],
                "timestamp": time.time(),
                "generation": self.active.generation_count,
            })
        self.active.generation_count += 1
        self._context_version += 1

    def update_from_failure(self, error, failed_symbols=None, failed_files=None):
        self.active.error_history.append({
            "error": error[:1000],
            "timestamp": time.time(),
            "generation": self.active.generation_count,
            "failed_symbols": failed_symbols or [],
            "failed_files": failed_files or [],
        })
        self._context_version += 1

    def get_previous_errors(self, last_n=3):
        return [e["error"] for e in self.active.error_history[-last_n:]]

    def get_version(self):
        return self._context_version

    def reset(self):
        self.active = ActiveContext()
        self._previous_prompts.clear()
        self._context_version = 0

    def snapshot(self):
        return {
            "symbols": list(self.active.symbols),
            "files": list(self.active.files),
            "evidence_ids": list(self.active.evidence_ids),
            "error_count": len(self.active.error_history),
            "generation": self.active.generation_count,
            "version": self._context_version,
        }


class HierarchicalCache:
    def __init__(self, l0_max=100, l1_max=500, l2_max=2000, l3_max=5000):
        self.l0_hot = {}
        self.l0_max = l0_max
        self.l1_semantic = {}
        self.l1_max = l1_max
        self.l2_knowledge = {}
        self.l2_max = l2_max
        self.l3_source = {}
        self.l3_max = l3_max
        self.hits = {"L0": 0, "L1": 0, "L2": 0, "L3": 0}
        self.misses = 0

    def _key(self, *parts):
        return hashlib.sha256(json.dumps(parts, default=str).encode()).hexdigest()[:24]

    def get_hot(self, symbol):
        if symbol in self.l0_hot:
            self.hits["L0"] += 1
            return self.l0_hot[symbol]
        return None

    def set_hot(self, symbol, data):
        if len(self.l0_hot) >= self.l0_max:
            del self.l0_hot[list(self.l0_hot.keys())[0]]
        self.l0_hot[symbol] = data

    def get_semantic(self, symbol):
        if symbol in self.l1_semantic:
            self.hits["L1"] += 1
            return self.l1_semantic[symbol]
        return None

    def set_semantic(self, symbol, data):
        if len(self.l1_semantic) >= self.l1_max:
            del self.l1_semantic[list(self.l1_semantic.keys())[0]]
        self.l1_semantic[symbol] = data

    def get_knowledge(self, key):
        if key in self.l2_knowledge:
            self.hits["L2"] += 1
            return self.l2_knowledge[key]
        return None

    def set_knowledge(self, key, data):
        if len(self.l2_knowledge) >= self.l2_max:
            del self.l2_knowledge[list(self.l2_knowledge.keys())[0]]
        self.l2_knowledge[key] = data

    def get_source(self, file_path, file_hash):
        key = self._key(file_path, file_hash)
        if key in self.l3_source:
            self.hits["L3"] += 1
            return self.l3_source[key]
        self.misses += 1
        return None

    def set_source(self, file_path, file_hash, chunks):
        key = self._key(file_path, file_hash)
        if len(self.l3_source) >= self.l3_max:
            del self.l3_source[list(self.l3_source.keys())[0]]
        self.l3_source[key] = chunks

    def promote_to_hot(self, symbol, data):
        self.set_hot(symbol, data)
        if symbol in self.l1_semantic:
            del self.l1_semantic[symbol]

    def invalidate_file(self, file_path):
        keys_to_remove = []
        for k, v in self.l3_source.items():
            for chunk in (v if isinstance(v, list) else []):
                if isinstance(chunk, dict) and file_path in chunk.get("file", ""):
                    keys_to_remove.append(k)
                    break
        for k in keys_to_remove:
            del self.l3_source[k]

    def stats(self):
        total_hits = sum(self.hits.values())
        total = total_hits + self.misses
        return {
            "L0_hot": len(self.l0_hot),
            "L1_semantic": len(self.l1_semantic),
            "L2_knowledge": len(self.l2_knowledge),
            "L3_source": len(self.l3_source),
            "hit_rate": total_hits / max(total, 1),
            "miss_rate": self.misses / max(total, 1),
            "L0_hits": self.hits["L0"],
            "L1_hits": self.hits["L1"],
            "L2_hits": self.hits["L2"],
            "L3_hits": self.hits["L3"],
        }


class KVPrefixCache:
    def __init__(self):
        self.prefixes = {}
        self.current_prefix_hash = ""
        self.reuse_count = 0

    def _hash(self, text):
        return hashlib.sha256(text.encode()).hexdigest()[:20]

    def register_prefix(self, prefix_text, kv_data=None):
        h = self._hash(prefix_text)
        self.prefixes[h] = {
            "hash": h,
            "text": prefix_text,
            "kv": kv_data,
            "token_count": len(prefix_text) // 3,
            "registered": time.time(),
        }
        return h

    def get_prefix(self, prefix_text):
        h = self._hash(prefix_text)
        if h in self.prefixes:
            self.reuse_count += 1
            return self.prefixes[h]
        return None

    def get_reuse_stats(self):
        return {
            "prefixes": len(self.prefixes),
            "reuse_count": self.reuse_count,
        }


class IncrementalRetry:
    MAX_RETRIES = 4
    EXPANSION_STRATEGY = {
        "syntax_error": "add_neighboring_chunks",
        "build_error": "add_dependencies",
        "test_failure": "add_test_context",
        "type_error": "add_type_definitions",
        "undefined_symbol": "add_symbol_definition",
        "unknown_error": "expand_all",
    }

    def __init__(self):
        self.attempt = 0
        self.error_log = []
        self.expansion_applied = []

    def classify_error(self, error_msg):
        error_lower = error_msg.lower()
        if "test" in error_lower or "expected" in error_lower and "found" in error_lower:
            return "test_failure"
        elif "undefined" in error_lower or "undeclared" in error_lower:
            return "undefined_symbol"
        elif "type" in error_lower or "mismatch" in error_lower:
            return "type_error"
        elif "syntax" in error_lower or "expected" in error_lower:
            return "syntax_error"
        elif "build" in error_lower or "compile" in error_lower:
            return "build_error"
        else:
            return "unknown_error"

    def should_retry(self):
        return self.attempt < self.MAX_RETRIES

    def get_expansion_strategy(self, error_msg):
        error_type = self.classify_error(error_msg)
        strategy = self.EXPANSION_STRATEGY.get(error_type, "expand_all")
        return error_type, strategy

    def record_attempt(self, error_msg, expansion_used=None):
        self.attempt += 1
        self.error_log.append({
            "attempt": self.attempt,
            "error": error_msg[:500],
            "expansion": expansion_used,
            "timestamp": time.time(),
        })
        if expansion_used:
            self.expansion_applied.append(expansion_used)

    def reset(self):
        self.attempt = 0
        self.error_log.clear()
        self.expansion_applied.clear()


class ContextIntelligence:
    def __init__(self, tokenizer, knowledge, source_index, context_engine, max_tokens=262144):
        self.tokenizer = tokenizer
        self.knowledge = knowledge
        self.source_index = source_index
        self.context_engine = context_engine

        self.budgeter = ConfidenceDrivenBudgeter(max_tokens)
        self.state = PersistentContextState()
        self.cache = HierarchicalCache()
        self.kv_cache = KVPrefixCache()
        self.retry = IncrementalRetry()

        self.generation_log = []

    def prepare_generation(self, goal, target_file=None, previous_error=None):
        t0 = time.monotonic()

        if previous_error:
            self.state.update_from_failure(previous_error)

        route = self.context_engine.router.route(goal)
        confidence = self._estimate_confidence(route, previous_error)
        self.budgeter.update_confidence(confidence)

        budget = self.budgeter.get_budget(confidence)
        allocation = self.budgeter.allocate(budget)

        all_chunks = []
        all_evidence = []
        all_graph_nodes = []

        for entity in route["entities"][:8]:
            hot = self.cache.get_hot(entity)
            if hot:
                all_chunks.extend(hot.get("chunks", []))
                all_evidence.extend(hot.get("evidence", []))
                all_graph_nodes.append(entity)
                continue

            semantic = self.cache.get_semantic(entity)
            if semantic:
                all_chunks.extend(semantic.get("chunks", []))
                all_evidence.extend(semantic.get("evidence", []))
                all_graph_nodes.append(entity)
                self.cache.promote_to_hot(entity, semantic)
                continue

            resolved = self.context_engine.resolver.resolve(entity)
            for fp in resolved.get("file_matches", [])[:3]:
                file_hash = self.context_engine.hasher.compute_file_hash(fp)
                cached_chunks = self.cache.get_source(fp, file_hash)
                if cached_chunks:
                    all_chunks.extend(cached_chunks)
                else:
                    chunks = self.context_engine.chunker.chunk_file(fp, max_chunk_tokens=allocation["source"] // 5)
                    self.cache.set_source(fp, file_hash, chunks)
                    all_chunks.extend(chunks)

                file_evidence = self.context_engine.evidence.retrieve(fp, max_evidence=5)
                all_evidence.extend(file_evidence)

            concept_data = {"chunks": [c for c in all_chunks if entity.lower() in c.get("file", "").lower()],
                           "evidence": [e for e in all_evidence if entity.lower() in str(e.get("source_file", "")).lower()]}
            self.cache.set_semantic(entity, concept_data)
            all_graph_nodes.append(entity)

        for cm in resolved.get("concept_matches", [])[:3] if resolved else []:
            all_graph_nodes.append(cm.get("name", ""))

        if all_graph_nodes:
            graph_result = self.context_engine.graph.retrieve(all_graph_nodes, depth=2, max_nodes=20)
            all_graph_nodes_new = [n["concept"] for n in graph_result]
            all_graph_nodes = list(dict.fromkeys(all_graph_nodes + all_graph_nodes_new))

        self.state.update_from_generation(
            symbols=route["entities"],
            files=[c.get("file", "") for c in all_chunks[:5]],
            evidence=all_evidence[:10],
        )

        if target_file and Path(target_file).exists():
            target_content = self.source_index.read_file_real(target_file)
            if target_content:
                target_hash = self.context_engine.hasher.compute_file_hash(target_file)
                self.cache.set_source(target_file, target_hash, [{"text": target_content, "file": target_file, "line_start": 1, "line_end": target_content.count("\n") + 1}])

        ranked_chunks = self.context_engine.ranker.rank(
            all_chunks, route["entities"],
            [{"concept": c} for c in all_graph_nodes], all_evidence
        )

        previous_errors = self.state.get_previous_errors(last_n=3)
        source_text = self._assemble_source_text(ranked_chunks, allocation["source"])
        knowledge_text = self._assemble_knowledge_text(all_graph_nodes, allocation["knowledge"])
        evidence_text = self._assemble_evidence_text(all_evidence, allocation["evidence"])
        error_text = self._assemble_error_text(previous_errors, allocation.get("error_context", 512))

        system_text = (
            "You are a Zig programming expert working on the B+ codebase. "
            "You have access to knowledge graph facts, source code, and evidence. "
            "Generate correct, compilable Zig code. "
            "Output ONLY valid Zig code, no explanations. "
            "If fixing an error, apply targeted fix, not full rewrite."
        )

        prompt = self._format({
            "system": system_text,
            "task": goal,
            "knowledge": knowledge_text,
            "source": source_text,
            "evidence": evidence_text,
            "error": error_text,
        })

        kv_entry = self.kv_cache.register_prefix(system_text)
        prepared = self.context_engine.adapter.prepare({"prompt": prompt})

        duration_ms = (time.monotonic() - t0) * 1000

        result = {
            "prompt": prepared["prompt"],
            "token_ids": prepared["token_ids"],
            "tokens_used": prepared["token_count"],
            "tokens_budget": budget,
            "tokens_remaining": prepared["budget_remaining"],
            "confidence": confidence,
            "route": route,
            "chunks_count": len(ranked_chunks),
            "evidence_count": len(all_evidence),
            "graph_nodes_count": len(all_graph_nodes),
            "active_context": self.state.snapshot(),
            "cache_stats": self.cache.stats(),
            "kv_cache_reuse": self.kv_cache.get_reuse_stats(),
            "duration_ms": round(duration_ms, 1),
            "allocation": allocation,
            "attempt": self.retry.attempt + 1,
        }

        self.generation_log.append(result)
        return result

    def handle_failure(self, error_msg):
        error_type, strategy = self.retry.get_expansion_strategy(error_msg)
        self.retry.record_attempt(error_msg, strategy)
        self.state.update_from_failure(error_msg)

        current_budget = self.budgeter.get_budget()
        new_budget = self.budgeter.expand_on_failure(current_budget, error_type)
        self.budgeter.update_confidence(max(0.0, self.budgeter.current_confidence * 0.5))

        return {
            "error_type": error_type,
            "strategy": strategy,
            "new_budget": new_budget,
            "attempt": self.retry.attempt,
            "should_retry": self.retry.should_retry(),
        }

    def handle_success(self):
        for symbol in self.state.active.symbols:
            hot_data = self.cache.get_semantic(symbol)
            if hot_data:
                self.cache.promote_to_hot(symbol, hot_data)
        self.retry.reset()

    def _estimate_confidence(self, route, previous_error):
        confidence = 0.5
        if route.get("confidence", 0) > 0.5:
            confidence += 0.2
        if len(route.get("entities", [])) > 0:
            confidence += 0.1
        if previous_error:
            confidence *= 0.3
        if self.state.active.generation_count > 0:
            confidence *= 0.8
        return max(0.05, min(0.95, confidence))

    def _assemble_source_text(self, ranked_chunks, budget):
        parts = []
        used = 0
        for chunk in ranked_chunks[:15]:
            text = f"--- {chunk.get('file', '?')}:{chunk.get('line_start', '?')}-{chunk.get('line_end', '?')} ---\n{chunk['text']}\n"
            tokens_est = len(text) // 3
            if used + tokens_est < budget:
                parts.append(text)
                used += tokens_est
        return "\n".join(parts)

    def _assemble_knowledge_text(self, graph_nodes, budget):
        parts = []
        used = 0
        if graph_nodes:
            header = "Related symbols (from knowledge graph):\n"
            parts.append(header)
            used += len(header) // 3
            for node in graph_nodes[:20]:
                line = f"- {node}\n"
                if used + len(line) // 3 < budget:
                    parts.append(line)
                    used += len(line) // 3
        return "".join(parts)

    def _assemble_evidence_text(self, evidence, budget):
        parts = []
        used = 0
        for ev in evidence[:15]:
            line = f"FACT: {ev.get('predicate', '')} | {ev.get('source_file', '')}:{ev.get('line_start', 0)}-{ev.get('line_end', 0)}\n"
            if used + len(line) // 3 < budget:
                parts.append(line)
                used += len(line) // 3
        return "".join(parts)

    def _assemble_error_text(self, errors, budget):
        if not errors:
            return ""
        parts = ["Previous errors:\n"]
        used = len(parts[0]) // 3
        for err in errors:
            line = f"- {err}\n"
            if used + len(line) // 3 < budget:
                parts.append(line)
                used += len(line) // 3
        return "".join(parts)

    def _format(self, sections):
        formatted = []
        for name, content in sections.items():
            if not content:
                continue
            if name == "system":
                formatted.append(f"<system>\n{content}\n</system>")
            elif name == "task":
                formatted.append(f"<task>\n{content}\n</task>")
            elif name == "knowledge":
                formatted.append(f"<knowledge>\n{content}\n</knowledge>")
            elif name == "source":
                formatted.append(f"<source>\n{content}\n</source>")
            elif name == "evidence":
                formatted.append(f"<evidence>\n{content}\n</evidence>")
            elif name == "error":
                formatted.append(f"<error_context>\n{content}\n</error_context>")
        return "\n\n".join(formatted)

    def full_stats(self):
        return {
            "active_context": self.state.snapshot(),
            "cache": self.cache.stats(),
            "kv_cache": self.kv_cache.get_reuse_stats(),
            "retry": {
                "attempt": self.retry.attempt,
                "error_log": len(self.retry.error_log),
                "expansions": self.retry.expansion_applied,
            },
            "generations": len(self.generation_log),
            "budgeter_confidence": self.budgeter.current_confidence,
        }
