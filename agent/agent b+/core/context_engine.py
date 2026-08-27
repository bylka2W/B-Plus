import os
import re
import json
import hashlib
import time
from pathlib import Path
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional


class TaskRouter:
    INTENT_PATTERNS = {
        "FIX": [r"\bfix\b", r"\berror\b", r"\bbug\b", r"\bcrash\b", r"\bfail\b", r"\bbroken\b", r"\bwrong\b"],
        "CREATE": [r"\bcreate\b", r"\bwrite\b", r"\bimplement\b", r"\badd\b", r"\bnew\b", r"\bbuild\b"],
        "EXPLAIN": [r"\bexplain\b", r"\bfind\b", r"\bsearch\b", r"\bwhat\b", r"\bhow\b", r"\bwhere\b"],
        "MODIFY": [r"\bmodify\b", r"\bchange\b", r"\bupdate\b", r"\bedit\b", r"\brefactor\b"],
        "TEST": [r"\btest\b", r"\bverify\b", r"\bvalidate\b", r"\bcheck\b"],
        "OPTIMIZE": [r"\boptimize\b", r"\bspeed\b", r"\bperformance\b", r"\bmemory\b", r"\bfaster\b"],
    }

    def __init__(self, knowledge, source_index):
        self.knowledge = knowledge
        self.source_index = source_index

    def route(self, goal):
        goal_lower = goal.lower()

        intent = "UNKNOWN"
        best_score = 0
        for intent_name, patterns in self.INTENT_PATTERNS.items():
            score = sum(1 for p in patterns if re.search(p, goal_lower))
            if score > best_score:
                best_score = score
                intent = intent_name

        entities = self._extract_entities(goal)

        language = "ZIG"
        if any(w in goal_lower for w in ["python", "py"]):
            language = "PYTHON"
        elif any(w in goal_lower for w in ["rust", "rs"]):
            language = "RUST"

        return {
            "intent": intent,
            "entities": entities,
            "language": language,
            "confidence": min(best_score / 3.0, 1.0),
            "raw": goal,
        }

    def _extract_entities(self, goal):
        entities = []
        words = re.findall(r"[A-Z][a-zA-Z0-9_]+", goal)
        for w in words:
            if len(w) > 2:
                entities.append(w)

        snake = re.findall(r"[a-z]+_[a-z_]+", goal)
        for s in snake:
            if len(s) > 3:
                entities.append(s)

        camel = re.findall(r"\b([a-z]+(?:[A-Z][a-z]+)+)\b", goal)
        entities.extend(camel)

        files = re.findall(r"[\w/\\.-]+\.zig", goal)
        entities.extend(files)

        return list(dict.fromkeys(entities))


class SymbolResolver:
    def __init__(self, knowledge, source_index):
        self.knowledge = knowledge
        self.source_index = source_index

    def resolve(self, entity_name):
        results = {
            "exact_matches": [],
            "normalized_matches": [],
            "file_matches": [],
            "concept_matches": [],
        }

        normalized = entity_name.lower().replace("-", "_")
        parts = re.findall(r"[A-Z][a-z]*|[a-z]+|[0-9]+", entity_name)
        sub_parts = [p.lower() for p in parts if len(p) > 1]

        for fp, info in self.source_index.files.items():
            fname = Path(fp).name.lower().replace("-", "_").replace(".zig", "")
            if normalized in fname or fname in normalized:
                results["file_matches"].append(fp)
            for line in info["lines"]:
                if entity_name in line or normalized in line.lower():
                    results["exact_matches"].append({"file": fp, "line": line.strip()})

        for concept_name, concept_data in self.knowledge.concepts.items():
            cn = str(concept_name).lower()
            if normalized in cn or cn in normalized:
                results["concept_matches"].append({"name": concept_name, **(concept_data if isinstance(concept_data, dict) else {})})
            for sp in sub_parts:
                if sp in cn:
                    results["normalized_matches"].append({"name": concept_name, "matched_part": sp})

        for fact in self.knowledge.facts[:5000]:
            if isinstance(fact, dict):
                sf = str(fact.get("source_file", "")).lower()
                if normalized in sf:
                    results["exact_matches"].append({"fact": fact})

        for k in results:
            results[k] = results[k][:20]

        return results


class GraphRetriever:
    MAX_DEPTH = 2
    MAX_NODES = 30

    def __init__(self, knowledge):
        self.knowledge = knowledge
        self.adjacency = defaultdict(set)
        self._build_index()

    def _build_index(self):
        for rel in self.knowledge.relations:
            if isinstance(rel, dict):
                src = rel.get("from_concept", "")
                dst = rel.get("to_concept", "")
                if src and dst:
                    self.adjacency[src].add(dst)
                    self.adjacency[dst].add(src)

    def retrieve(self, start_concepts, depth=2, max_nodes=30):
        visited = set()
        queue = [(c, 0) for c in start_concepts[:5]]
        result_nodes = []

        while queue and len(result_nodes) < max_nodes:
            node, d = queue.pop(0)
            if node in visited or d > depth:
                continue
            visited.add(node)
            result_nodes.append({"concept": node, "depth": d, "neighbors": len(self.adjacency.get(node, set()))})

            for neighbor in self.adjacency.get(node, set()):
                if neighbor not in visited:
                    queue.append((neighbor, d + 1))

        return result_nodes


class EvidenceRetriever:
    def __init__(self, knowledge):
        self.knowledge = knowledge
        self._fact_index = {}
        self._build_index()

    def _build_index(self):
        for fact in self.knowledge.facts:
            if isinstance(fact, dict):
                sf = fact.get("source_file", "")
                if sf:
                    if sf not in self._fact_index:
                        self._fact_index[sf] = []
                    self._fact_index[sf].append(fact)

    def retrieve(self, file_path, max_evidence=10):
        evidence = []
        for sf, facts in self._fact_index.items():
            if file_path and file_path.lower() in sf.lower():
                for f in facts[:max_evidence]:
                    ev = {
                        "fact_id": f.get("fact_id", ""),
                        "predicate": f.get("predicate", ""),
                        "source_file": f.get("source_file", ""),
                        "line_start": f.get("line_start", 0),
                        "line_end": f.get("line_end", 0),
                        "verification_status": f.get("verification_status", ""),
                    }
                    evidence.append(ev)
        return evidence[:max_evidence]

    def retrieve_by_symbol(self, symbol_name, max_evidence=10):
        evidence = []
        for fact in self.knowledge.facts:
            if isinstance(fact, dict):
                sf = str(fact.get("source_file", ""))
                pred = str(fact.get("predicate", ""))
                if symbol_name.lower() in sf.lower() or symbol_name.lower() in pred.lower():
                    evidence.append({
                        "fact_id": fact.get("fact_id", ""),
                        "predicate": fact.get("predicate", ""),
                        "source_file": fact.get("source_file", ""),
                        "line_start": fact.get("line_start", 0),
                        "line_end": fact.get("line_end", 0),
                    })
                    if len(evidence) >= max_evidence:
                        break
        return evidence


class SemanticChunker:
    ZIG_BOUNDARY_PATTERNS = [
        r"^pub\s+(?:const|var|fn|test)\b",
        r"^(?:const|var|fn|test)\b",
        r"^struct\s*\{",
        r"^enum\s*\{",
        r"^union\s*\{",
        r"^error\s*\{",
        r"^comptime\s*\{",
    ]

    def __init__(self, source_index):
        self.source_index = source_index

    def chunk_file(self, file_path, max_chunk_tokens=2048):
        content = self.source_index.read_file_real(file_path)
        if not content:
            return []

        lines = content.split("\n")
        boundaries = [0]
        compiled = [re.compile(p, re.MULTILINE) for p in self.ZIG_BOUNDARY_PATTERNS]

        for i, line in enumerate(lines):
            for pat in compiled:
                if pat.search(line):
                    boundaries.append(i)
                    break

        boundaries.append(len(lines))

        chunks = []
        for i in range(len(boundaries) - 1):
            start = boundaries[i]
            end = boundaries[i + 1]
            chunk_lines = lines[start:end]
            chunk_text = "\n".join(chunk_lines)
            chunk_header = chunk_lines[0].strip() if chunk_lines else ""

            chunks.append({
                "file": file_path,
                "line_start": start + 1,
                "line_end": end,
                "header": chunk_header[:100],
                "text": chunk_text,
                "token_estimate": len(chunk_text) // 3,
            })

        merged = []
        current = None
        for chunk in chunks:
            if current is None:
                current = chunk
            elif current["token_estimate"] + chunk["token_estimate"] < max_chunk_tokens:
                current["line_end"] = chunk["line_end"]
                current["text"] = current["text"] + "\n" + chunk["text"]
                current["token_estimate"] += chunk["token_estimate"]
            else:
                merged.append(current)
                current = chunk
        if current:
            merged.append(current)

        return merged


class ContextRanker:
    def __init__(self):
        self.weights = {
            "exact_match": 10.0,
            "concept_match": 5.0,
            "file_match": 8.0,
            "evidence_match": 7.0,
            "graph_distance": -2.0,
            "recency": 1.0,
        }

    def rank(self, candidates, entities, graph_nodes, evidence):
        entity_set = {e.lower() for e in entities}
        graph_set = {n["concept"] for n in graph_nodes}
        evidence_files = {e.get("source_file", "") for e in evidence}

        scored = []
        for c in candidates:
            score = 0.0
            header = c.get("header", "").lower()
            file_path = c.get("file", "").lower()

            for e in entity_set:
                if e in header:
                    score += self.weights["exact_match"]
                if e in file_path:
                    score += self.weights["file_match"]

            for g in graph_set:
                if g.lower() in header:
                    score += self.weights["concept_match"]

            for ef in evidence_files:
                if ef.lower() in file_path:
                    score += self.weights["evidence_match"]

            scored.append({**c, "rank_score": score})

        scored.sort(key=lambda x: x["rank_score"], reverse=True)
        return scored


class ContextBudgeter:
    BUDGET_PRESETS = {
        "simple_query": 1024,
        "function_fix": 4096,
        "multi_function": 8192,
        "subsystem_change": 16384,
        "large_refactor": 32768,
    }

    def __init__(self, max_tokens=4096):
        self.max_tokens = max_tokens
        self.default_tokens = 4096

    def estimate_complexity(self, route_result):
        intent = route_result.get("intent", "UNKNOWN")
        entities = route_result.get("entities", [])

        if intent in ("EXPLAIN", "TEST"):
            return "simple_query"
        elif intent in ("FIX", "OPTIMIZE") and len(entities) <= 2:
            return "function_fix"
        elif intent in ("FIX", "MODIFY") and len(entities) > 2:
            return "multi_function"
        elif intent == "CREATE" and len(entities) > 3:
            return "subsystem_change"
        elif intent == "MODIFY" and len(entities) > 5:
            return "large_refactor"
        else:
            return "function_fix"

    def get_budget(self, route_result):
        complexity = self.estimate_complexity(route_result)
        budget = self.BUDGET_PRESETS.get(complexity, self.default_tokens)
        return min(budget, self.max_tokens)

    def allocate(self, total_budget):
        return {
            "system": int(total_budget * 0.03),
            "task": int(total_budget * 0.05),
            "knowledge": int(total_budget * 0.25),
            "source": int(total_budget * 0.45),
            "evidence": int(total_budget * 0.15),
            "output": int(total_budget * 0.07),
        }


class ContextCache:
    def __init__(self, max_size=1000):
        self.max_size = max_size
        self.L0_exact = {}
        self.L1_task = {}
        self.L2_symbol = {}
        self.L3_source = {}
        self.hits = 0
        self.misses = 0

    def _key(self, *parts):
        h = hashlib.sha256(json.dumps(parts, default=str).encode()).hexdigest()[:32]
        return h

    def get_L0(self, task, source_hash):
        key = self._key(task, source_hash)
        if key in self.L0_exact:
            self.hits += 1
            return self.L0_exact[key]
        self.misses += 1
        return None

    def set_L0(self, task, source_hash, context):
        key = self._key(task, source_hash)
        if len(self.L0_exact) >= self.max_size:
            oldest = list(self.L0_exact.keys())[0]
            del self.L0_exact[oldest]
        self.L0_exact[key] = context

    def get_L2(self, symbol_name):
        if symbol_name in self.L2_symbol:
            self.hits += 1
            return self.L2_symbol[symbol_name]
        self.misses += 1
        return None

    def set_L2(self, symbol_name, data):
        if len(self.L2_symbol) >= self.max_size:
            oldest = list(self.L2_symbol.keys())[0]
            del self.L2_symbol[oldest]
        self.L2_symbol[symbol_name] = data

    def get_L3(self, file_path, file_hash):
        key = self._key(file_path, file_hash)
        if key in self.L3_source:
            self.hits += 1
            return self.L3_source[key]
        self.misses += 1
        return None

    def set_L3(self, file_path, file_hash, chunks):
        key = self._key(file_path, file_hash)
        if len(self.L3_source) >= self.max_size:
            oldest = list(self.L3_source.keys())[0]
            del self.L3_source[oldest]
        self.L3_source[key] = chunks

    def stats(self):
        total = self.hits + self.misses
        return {
            "hits": self.hits,
            "misses": self.misses,
            "hit_rate": self.hits / max(total, 1),
            "L0_size": len(self.L0_exact),
            "L2_size": len(self.L2_symbol),
            "L3_size": len(self.L3_source),
        }


class HashInvalidator:
    def __init__(self):
        self.file_hashes = {}
        self.knowledge_version = ""

    def compute_file_hash(self, file_path):
        try:
            with open(file_path, "rb") as f:
                return hashlib.sha256(f.read()).hexdigest()
        except (OSError, IOError):
            return ""

    def check_invalidation(self, file_path, cached_hash):
        current_hash = self.compute_file_hash(file_path)
        self.file_hashes[file_path] = current_hash
        return current_hash != cached_hash

    def compute_context_key(self, task, model_version, knowledge_version, source_hashes):
        parts = {
            "task": task,
            "model": model_version,
            "knowledge": knowledge_version,
            "sources": source_hashes,
        }
        return hashlib.sha256(json.dumps(parts, default=str).encode()).hexdigest()[:32]


class PrefixCache:
    def __init__(self):
        self.prefix_kv = None
        self.prefix_hash = ""
        self.system_text = ""

    def set_prefix(self, system_text, kv=None):
        self.system_text = system_text
        self.prefix_kv = kv
        self.prefix_hash = hashlib.sha256(system_text.encode()).hexdigest()[:16]

    def get_prefix(self, system_text):
        if hashlib.sha256(system_text.encode()).hexdigest()[:16] == self.prefix_hash:
            return self.prefix_kv
        return None

    def invalidate(self):
        self.prefix_kv = None
        self.prefix_hash = ""


class ModelContextAdapter:
    def __init__(self, tokenizer, max_seq_len=4096):
        self.tokenizer = tokenizer
        self.max_seq_len = max_seq_len

    def prepare(self, context_package):
        prompt = context_package.get("prompt", "")
        ids = self.tokenizer.encode(prompt)

        if len(ids) > self.max_seq_len - 512:
            ids = ids[:self.max_seq_len - 512]
            prompt = self.tokenizer.decode(ids)

        return {
            "prompt": prompt,
            "token_ids": ids,
            "token_count": len(ids),
            "budget_remaining": self.max_seq_len - len(ids) - 512,
        }


class ContextEngine:
    def __init__(self, tokenizer, knowledge, source_index, max_tokens=4096):
        self.tokenizer = tokenizer
        self.knowledge = knowledge
        self.source_index = source_index

        self.router = TaskRouter(knowledge, source_index)
        self.resolver = SymbolResolver(knowledge, source_index)
        self.graph = GraphRetriever(knowledge)
        self.evidence = EvidenceRetriever(knowledge)
        self.chunker = SemanticChunker(source_index)
        self.ranker = ContextRanker()
        self.budgeter = ContextBudgeter(max_tokens)
        self.cache = ContextCache()
        self.hasher = HashInvalidator()
        self.prefix_cache = PrefixCache()
        self.adapter = ModelContextAdapter(tokenizer, max_tokens)

    def build_context(self, goal, target_file=None, previous_error=None):
        t0 = time.monotonic()

        route = self.router.route(goal)
        budget = self.budgeter.get_budget(route)
        allocation = self.budgeter.allocate(budget)

        all_chunks = []
        all_evidence = []
        all_graph_nodes = []

        for entity in route["entities"][:5]:
            resolved = self.resolver.resolve(entity)

            cached = self.cache.get_L2(entity)
            if cached:
                all_chunks.extend(cached.get("chunks", []))
                all_evidence.extend(cached.get("evidence", []))
            else:
                for fp in resolved.get("file_matches", [])[:3]:
                    chunks = self.chunker.chunk_file(fp, max_chunk_tokens=allocation["source"] // 5)
                    all_chunks.extend(chunks)

                    file_evidence = self.evidence.retrieve(fp, max_evidence=5)
                    all_evidence.extend(file_evidence)

                self.cache.set_L2(entity, {"chunks": all_chunks, "evidence": all_evidence})

            for cm in resolved.get("concept_matches", [])[:3]:
                all_graph_nodes.append(cm.get("name", ""))

        if all_graph_nodes:
            graph_result = self.graph.retrieve(all_graph_nodes, depth=2, max_nodes=20)
            all_graph_nodes = [n["concept"] for n in graph_result]

        ranked_chunks = self.ranker.rank(all_chunks, route["entities"], [{"concept": c} for c in all_graph_nodes], all_evidence)

        source_text = self._assemble_source_text(ranked_chunks, allocation["source"])
        knowledge_text = self._assemble_knowledge_text(all_graph_nodes, all_evidence, allocation["knowledge"])
        evidence_text = self._assemble_evidence_text(all_evidence, allocation["evidence"])

        prompt = self._format({
            "system": "You are a Zig expert. Generate valid, compilable Zig code. Output ONLY code.",
            "task": goal,
            "knowledge": knowledge_text,
            "source": source_text,
            "evidence": evidence_text,
            "error": previous_error or "",
        })

        prepared = self.adapter.prepare({"prompt": prompt})

        duration_ms = (time.monotonic() - t0) * 1000

        return {
            "prompt": prepared["prompt"],
            "token_ids": prepared["token_ids"],
            "tokens_used": prepared["token_count"],
            "tokens_budget": budget,
            "tokens_remaining": prepared["budget_remaining"],
            "route": route,
            "chunks_count": len(ranked_chunks),
            "evidence_count": len(all_evidence),
            "graph_nodes_count": len(all_graph_nodes),
            "duration_ms": round(duration_ms, 1),
            "allocation": allocation,
        }

    def _assemble_source_text(self, ranked_chunks, budget):
        parts = []
        used = 0
        for chunk in ranked_chunks[:10]:
            text = f"--- {chunk.get('file', '?')}:{chunk.get('line_start', '?')}-{chunk.get('line_end', '?')} ---\n{chunk['text']}\n"
            tokens_est = len(text) // 3
            if used + tokens_est < budget:
                parts.append(text)
                used += tokens_est
        return "\n".join(parts)

    def _assemble_knowledge_text(self, graph_nodes, evidence, budget):
        parts = []
        used = 0
        if graph_nodes:
            header = "Related symbols:\n"
            parts.append(header)
            used += len(header) // 3
            for node in graph_nodes[:15]:
                line = f"- {node}\n"
                if used + len(line) // 3 < budget:
                    parts.append(line)
                    used += len(line) // 3
        return "".join(parts)

    def _assemble_evidence_text(self, evidence, budget):
        parts = []
        used = 0
        for ev in evidence[:10]:
            line = f"FACT: {ev.get('predicate', '')} | {ev.get('source_file', '')}:{ev.get('line_start', 0)}-{ev.get('line_end', 0)}\n"
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
                formatted.append(f"<error>\n{content}\n</error>")
        return "\n\n".join(formatted)

    def cache_stats(self):
        return self.cache.stats()
