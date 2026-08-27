import os
import re
import json
import hashlib
import time
from pathlib import Path
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional, Any


@dataclass
class PageID:
    kind: str
    identifier: str

    def __str__(self):
        return f"{self.kind}:{self.identifier}"

    def __hash__(self):
        return hash((self.kind, self.identifier))

    def __eq__(self, other):
        return self.kind == other.kind and self.identifier == other.identifier


@dataclass
class ContextPage:
    page_id: PageID
    content_hash: str
    token_estimate: int
    data: dict = field(default_factory=dict)
    dependencies: list = field(default_factory=list)
    last_used: float = 0.0
    use_count: int = 0
    resident: bool = False

    def touch(self):
        self.last_used = time.time()
        self.use_count += 1
        self.resident = True


class ContextAddressSpace:
    def __init__(self):
        self.pages = {}
        self.id_counter = 0

    def register(self, kind, identifier, data, token_estimate=0, dependencies=None):
        pid = PageID(kind, identifier)
        if pid in self.pages:
            return pid
        content_str = json.dumps(data, default=str, sort_keys=True)
        content_hash = hashlib.sha256(content_str.encode()).hexdigest()[:16]
        self.pages[pid] = ContextPage(
            page_id=pid,
            content_hash=content_hash,
            token_estimate=token_estimate,
            data=data,
            dependencies=dependencies or [],
            last_used=time.time(),
            resident=False,
        )
        self.id_counter += 1
        return pid

    def get(self, page_id):
        return self.pages.get(page_id)

    def by_kind(self, kind):
        return {pid: page for pid, page in self.pages.items() if pid.kind == kind}

    def invalidate(self, page_id):
        if page_id in self.pages:
            del self.pages[page_id]

    def content_hash(self, page_id):
        page = self.pages.get(page_id)
        return page.content_hash if page else ""

    def total_tokens(self, page_ids=None):
        targets = page_ids or list(self.pages.keys())
        return sum(self.pages[pid].token_estimate for pid in targets if pid in self.pages)

    def stats(self):
        by_kind = defaultdict(int)
        for pid in self.pages:
            by_kind[pid.kind] += 1
        resident = sum(1 for p in self.pages.values() if p.resident)
        return {
            "total_pages": len(self.pages),
            "resident": resident,
            "by_kind": dict(by_kind),
            "total_tokens": self.total_tokens(),
        }


class ContextPageTable:
    def __init__(self, address_space):
        self.address_space = address_space
        self.symbol_pages = {}
        self.file_pages = {}
        self.fact_pages = {}
        self.chunk_pages = {}

    def register_symbol(self, name, definition=None, dependencies=None, callers=None, file_path=None):
        deps = []
        if dependencies:
            for d in dependencies:
                pid = self.address_space.register("symbol", d, {"name": d}, token_estimate=2)
                deps.append(str(pid))
        pid = self.address_space.register(
            "symbol", name,
            {"name": name, "definition": definition, "file": file_path, "dependencies": dependencies or [], "callers": callers or []},
            token_estimate=len(name) // 3 + 10,
            dependencies=deps,
        )
        self.symbol_pages[name] = pid
        return pid

    def register_file(self, file_path, chunks=None):
        chunk_ids = []
        if chunks:
            for chunk in chunks:
                cpid = self.address_space.register("chunk", f"{file_path}:{chunk.get('line_start', 0)}", chunk, token_estimate=chunk.get("token_estimate", 50))
                chunk_ids.append(str(cpid))
        pid = self.address_space.register("file", file_path, {"path": file_path, "chunk_count": len(chunks or [])}, token_estimate=20, dependencies=chunk_ids)
        self.file_pages[file_path] = pid
        return pid

    def register_fact(self, fact_id, predicate, source_file, line_start, line_end):
        pid = self.address_space.register("fact", fact_id, {"predicate": predicate, "file": source_file, "line_start": line_start, "line_end": line_end}, token_estimate=15)
        self.fact_pages[fact_id] = pid
        return pid

    def get_symbol(self, name):
        return self.symbol_pages.get(name)

    def get_file(self, path):
        return self.file_pages.get(path)

    def get_dependencies(self, page_id):
        page = self.address_space.get(page_id)
        if not page:
            return []
        return [PageID.from_str(d) for d in page.dependencies if isinstance(d, str)]

    def expand_symbol(self, name, depth=2):
        visited = set()
        result = []
        queue = [(name, 0)]
        while queue:
            sym, d = queue.pop(0)
            if sym in visited or d > depth:
                continue
            visited.add(sym)
            pid = self.symbol_pages.get(sym)
            if pid:
                page = self.address_space.get(pid)
                result.append({"name": sym, "depth": d, "page": page})
                if page:
                    for dep in page.dependencies:
                        dep_page = self.address_space.get(PageID("symbol", dep.split(":", 1)[1] if ":" in dep else dep))
                        if dep_page:
                            queue.append((dep_page.data.get("name", ""), d + 1))
        return result


class ContextController:
    ACTIONS = {"KEEP", "LOAD", "EXPAND", "EVICT", "PROMOTE"}

    def __init__(self, address_space, max_active_pages=50, max_tokens=4096):
        self.address_space = address_space
        self.max_active_pages = max_active_pages
        self.max_tokens = max_tokens
        self.active_set = set()
        self.action_log = []

    def decide(self, page_id, task_relevance, current_tokens):
        page = self.address_space.get(page_id)
        if not page:
            return "LOAD"

        if page_id in self.active_set:
            if task_relevance > 0.8:
                return "KEEP"
            elif task_relevance > 0.4:
                return "KEEP"
            else:
                return "EVICT"

        estimated_new_tokens = current_tokens + page.token_estimate
        if estimated_new_tokens > self.max_tokens:
            return "EVICT" if task_relevance < 0.3 else "LOAD"

        if len(self.active_set) >= self.max_active_pages:
            if task_relevance > 0.6:
                return "LOAD"
            return "EVICT"

        if task_relevance > 0.5:
            return "LOAD"
        elif task_relevance > 0.2:
            return "LOAD" if estimated_new_tokens < self.max_tokens * 0.7 else "EVICT"
        return "EVICT"

    def execute(self, action, page_id):
        page = self.address_space.get(page_id)
        if not page:
            return False

        if action == "KEEP":
            page.touch()
            return True
        elif action == "LOAD":
            page.touch()
            self.active_set.add(page_id)
            return True
        elif action == "EXPAND":
            page.touch()
            return True
        elif action == "EVICT":
            page.resident = False
            self.active_set.discard(page_id)
            return True
        elif action == "PROMOTE":
            page.touch()
            self.active_set.add(page_id)
            return True

        self.action_log.append({"action": action, "page_id": str(page_id), "timestamp": time.time()})
        return False

    def get_active_pages(self):
        return [pid for pid in self.active_set if self.address_space.get(pid)]

    def active_tokens(self):
        return self.address_space.total_tokens(list(self.active_set))

    def stats(self):
        return {
            "active_pages": len(self.active_set),
            "active_tokens": self.active_tokens(),
            "max_pages": self.max_active_pages,
            "max_tokens": self.max_tokens,
            "actions": len(self.action_log),
        }


class ContextSelector:
    def __init__(self, address_space, page_table, controller):
        self.address_space = address_space
        self.page_table = page_table
        self.controller = controller

    def select(self, entities, task_type, budget, previous_error=None):
        selected = []
        total_tokens = 0

        for entity in entities[:10]:
            pid = self.page_table.get_symbol(entity)
            if pid:
                page = self.address_space.get(pid)
                if page:
                    relevance = self._score_relevance(entity, task_type)
                    action = self.controller.decide(pid, relevance, total_tokens)
                    self.controller.execute(action, pid)
                    if action in ("KEEP", "LOAD", "EXPAND", "PROMOTE"):
                        selected.append({"page_id": pid, "entity": entity, "relevance": relevance, "action": action})
                        total_tokens += page.token_estimate

        if previous_error:
            error_tokens = len(previous_error) // 3
            if total_tokens + error_tokens < budget:
                selected.append({"page_id": None, "entity": "error_context", "relevance": 1.0, "action": "LOAD", "content": previous_error})
                total_tokens += error_tokens

        return {"selected": selected, "total_tokens": total_tokens, "budget": budget, "utilization": total_tokens / max(budget, 1)}

    def _score_relevance(self, entity, task_type):
        base_scores = {
            "FIX": 0.7,
            "CREATE": 0.5,
            "MODIFY": 0.6,
            "EXPLAIN": 0.8,
            "TEST": 0.6,
            "OPTIMIZE": 0.7,
        }
        return base_scores.get(task_type, 0.5)


class ContextDelta:
    def __init__(self):
        self.previous_pages = set()
        self.current_pages = set()
        self.added = []
        self.removed = []
        self.unchanged = []

    def compute(self, previous_active, current_active):
        self.previous_pages = set(str(p) for p in previous_active)
        self.current_pages = set(str(p) for p in current_active)
        self.added = list(self.current_pages - self.previous_pages)
        self.removed = list(self.previous_pages - self.current_pages)
        self.unchanged = list(self.previous_pages & self.current_pages)
        return {
            "added": self.added,
            "removed": self.removed,
            "unchanged": self.unchanged,
            "added_count": len(self.added),
            "removed_count": len(self.removed),
            "unchanged_count": len(self.unchanged),
            "reuse_ratio": len(self.unchanged) / max(len(self.current_pages), 1),
        }

    def needs_prefill(self):
        return len(self.added) > 0 or len(self.removed) > 0

    def reuse_tokens(self, address_space):
        total = 0
        for pid_str in self.unchanged:
            for pid in address_space.pages:
                if str(pid) == pid_str:
                    total += address_space.pages[pid].token_estimate
                    break
        return total


class KVSegmentCache:
    def __init__(self, max_segments=200):
        self.max_segments = max_segments
        self.segments = {}
        self.segment_counter = 0
        self.total_reuse_tokens = 0

    def _make_key(self, page_id_str, content_hash):
        return f"{page_id_str}:{content_hash}"

    def register(self, page_id, content_hash, token_range_start, token_range_end, kv_data=None):
        key = self._make_key(str(page_id), content_hash)
        if key in self.segments:
            self.segments[key]["last_used"] = time.time()
            self.segments[key]["use_count"] += 1
            return key

        if len(self.segments) >= self.max_segments:
            oldest = min(self.segments.keys(), key=lambda k: self.segments[k]["last_used"])
            del self.segments[oldest]

        self.segment_counter += 1
        self.segments[key] = {
            "segment_id": self.segment_counter,
            "page_id": str(page_id),
            "content_hash": content_hash,
            "token_range": (token_range_start, token_range_end),
            "kv": kv_data,
            "created": time.time(),
            "last_used": time.time(),
            "use_count": 1,
        }
        return key

    def get_segment(self, page_id, content_hash):
        key = self._make_key(str(page_id), content_hash)
        if key in self.segments:
            seg = self.segments[key]
            seg["last_used"] = time.time()
            seg["use_count"] += 1
            return seg
        return None

    def can_reuse(self, page_id, content_hash):
        return self.get_segment(page_id, content_hash) is not None

    def compute_reusable_tokens(self, page_ids, address_space):
        total = 0
        for pid in page_ids:
            page = address_space.get(pid)
            if page and self.can_reuse(str(pid), page.content_hash):
                total += page.token_estimate
                self.total_reuse_tokens += page.token_estimate
        return total

    def stats(self):
        return {
            "segments": len(self.segments),
            "total_reuse_tokens": self.total_reuse_tokens,
            "segments_by_use": sorted([s["use_count"] for s in self.segments.values()], reverse=True)[:5],
        }


class WorkingSetManager:
    def __init__(self, address_space, page_table, controller, selector, delta, kv_cache):
        self.address_space = address_space
        self.page_table = page_table
        self.controller = controller
        self.selector = selector
        self.delta = delta
        self.kv_cache = kv_cache
        self.current_working_set = set()
        self.generation_count = 0
        self.generation_log = []

    def prepare_generation(self, entities, task_type, budget, previous_error=None):
        t0 = time.monotonic()

        previous_active = set(self.controller.active_set)

        selection = self.selector.select(entities, task_type, budget, previous_error)

        current_active = set(self.controller.get_active_pages())
        delta_info = self.delta.compute(previous_active, current_active)

        reusable_tokens = self.kv_cache.compute_reusable_tokens(
            [pid for pid in current_active if pid not in set(self.delta.added)],
            self.address_space
        )
        reusable_tokens = min(reusable_tokens, selection["total_tokens"])

        new_tokens_needed = max(0, selection["total_tokens"] - reusable_tokens)

        for pid in current_active:
            page = self.address_space.get(pid)
            if page:
                self.kv_cache.register(str(pid), page.content_hash, 0, page.token_estimate)

        self.current_working_set = current_active
        self.generation_count += 1

        duration_ms = (time.monotonic() - t0) * 1000

        result = {
            "selection": selection,
            "delta": delta_info,
            "kv_reuse": {
                "reusable_tokens": reusable_tokens,
                "new_tokens_needed": max(0, new_tokens_needed),
                "reuse_ratio": reusable_tokens / max(selection["total_tokens"], 1),
            },
            "working_set": {
                "pages": len(current_active),
                "tokens": selection["total_tokens"],
                "budget": budget,
            },
            "controller": self.controller.stats(),
            "kv_cache": self.kv_cache.stats(),
            "generation": self.generation_count,
            "duration_ms": round(duration_ms, 1),
        }

        self.generation_log.append(result)
        return result

    def evict_low_relevance(self, threshold=0.2):
        evicted = []
        for pid in list(self.controller.active_set):
            page = self.address_space.get(pid)
            if page and page.use_count <= 1 and page.last_used < time.time() - 60:
                self.controller.execute("EVICT", pid)
                evicted.append(str(pid))
        return evicted

    def promote_frequent(self, threshold=3):
        promoted = []
        for pid in list(self.controller.active_set):
            page = self.address_space.get(pid)
            if page and page.use_count >= threshold:
                self.controller.execute("PROMOTE", pid)
                promoted.append(str(pid))
        return promoted

    def stats(self):
        return {
            "generations": self.generation_count,
            "working_set": len(self.current_working_set),
            "controller": self.controller.stats(),
            "kv_cache": self.kv_cache.stats(),
        }


class SelectiveContextRuntime:
    def __init__(self, max_active_pages=50, max_tokens=4096):
        self.address_space = ContextAddressSpace()
        self.page_table = ContextPageTable(self.address_space)
        self.controller = ContextController(self.address_space, max_active_pages, max_tokens)
        self.selector = ContextSelector(self.address_space, self.page_table, self.controller)
        self.delta = ContextDelta()
        self.kv_cache = KVSegmentCache()
        self.working_set = WorkingSetManager(
            self.address_space, self.page_table, self.controller,
            self.selector, self.delta, self.kv_cache
        )

    def register_symbol(self, name, definition=None, dependencies=None, callers=None, file_path=None):
        return self.page_table.register_symbol(name, definition, dependencies, callers, file_path)

    def register_file(self, file_path, chunks=None):
        return self.page_table.register_file(file_path, chunks)

    def register_fact(self, fact_id, predicate, source_file, line_start, line_end):
        return self.page_table.register_fact(fact_id, predicate, source_file, line_start, line_end)

    def select_context(self, entities, task_type, budget, previous_error=None):
        return self.working_set.prepare_generation(entities, task_type, budget, previous_error)

    def evict_stale(self):
        return self.working_set.evict_low_relevance()

    def promote_hot(self):
        return self.working_set.promote_frequent()

    def stats(self):
        return {
            "address_space": self.address_space.stats(),
            "working_set": self.working_set.stats(),
            "page_table": {
                "symbols": len(self.page_table.symbol_pages),
                "files": len(self.page_table.file_pages),
                "facts": len(self.page_table.fact_pages),
            },
        }
