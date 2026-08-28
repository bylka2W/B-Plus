import json
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "engine"))

import pytest
from budget import BudgetTracker, BudgetExceeded, WALL_CLOCK_LIMITS, TOOL_BUDGETS, CONTEXT_BUDGETS
from evidence_bundle import (
    ANSWER_READY, NEEDS_DEEP_SEARCH, UNKNOWN, PARTIAL,
    classify_complexity, CONTEXT_LIMITS, build_evidence_bundle,
    format_compact, SIMPLE_INTENTS, DIRECT_INTENTS,
)
from knowledge import Knowledge
from query_cache import QueryCache, MAX_CACHE_ENTRIES
from source_snapshot import SourceSnapshot
from telemetry import Telemetry, PERF_GATES

_k = None


def _get_k():
    global _k
    if _k is None:
        _k = Knowledge.load()
    return _k


@pytest.fixture(scope="module")
def knowledge():
    return _get_k()


@pytest.fixture(scope="module")
def snapshot():
    s = SourceSnapshot.load()
    if s is None:
        s = SourceSnapshot.build()
        s.save()
    return s


@pytest.fixture(scope="module")
def tree_sha(snapshot):
    return snapshot.tree_sha()


@pytest.fixture(scope="module")
def cache(tree_sha):
    return QueryCache.load(tree_sha)


@pytest.fixture(scope="module")
def telemetry():
    return Telemetry.load()


@pytest.fixture(scope="module")
def fast_path():
    from fast_path import FastPath
    return FastPath.load()


class TestEvidenceBundle:
    def test_answer_ready_callers(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Кто вызывает foldConstantOp?"
        )
        assert b.status == ANSWER_READY
        assert b.intent == "CALLERS"
        assert b.entity == "foldConstantOp"
        assert b.confidence == "VERIFIED"
        assert b.completeness == ANSWER_READY
        assert len(b.evidence) > 0
        assert b.direct_answer is not None
        assert "runConstantFolding" in b.direct_answer

    def test_answer_ready_definition(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Где определён foldConstantOp?"
        )
        assert b.status == ANSWER_READY
        assert b.intent == "DEFINITION"
        assert b.confidence == "VERIFIED"

    def test_answer_ready_callees(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Что вызывает foldConstantOp?"
        )
        assert b.status == ANSWER_READY
        assert b.intent == "CALLEES"

    def test_answer_ready_dependencies(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "От чего зависит x64gen.zig?"
        )
        assert b.status == ANSWER_READY
        assert b.intent == "DEPENDENCIES"

    def test_to_dict_schema(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Кто вызывает foldConstantOp?"
        )
        d = b.to_dict()
        assert d["schema"] == "evidence_bundle"
        assert d["version"] == 1
        assert "telemetry" in d
        assert "routing_ms" in d["telemetry"]
        assert "query_ms" in d["telemetry"]
        assert "answer_ms" in d["telemetry"]
        assert "total_ms" in d["telemetry"]

    def test_format_compact(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Кто вызывает foldConstantOp?"
        )
        text = format_compact(b)
        assert "STATUS: ANSWER_READY" in text
        assert "foldConstantOp" in text

    def test_entity_not_found(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Кто вызывает nonexistentSymbol123?"
        )
        assert b.status in (NEEDS_DEEP_SEARCH, PARTIAL, UNKNOWN)

    def test_unknown_intent(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "random question about weather"
        )
        assert b.status in (UNKNOWN, NEEDS_DEEP_SEARCH, PARTIAL)

    def test_complexity_simple(self):
        assert classify_complexity("DEFINITION", 1, True) == "simple"
        assert classify_complexity("CALLERS", 2, True) == "simple"
        assert classify_complexity("MODULE", 1, True) == "simple"

    def test_complexity_normal(self):
        assert classify_complexity("CALLERS", 15, True) == "normal"

    def test_complexity_complex(self):
        assert classify_complexity("CALLERS", 50, True) == "complex"
        assert classify_complexity("CALLERS", 5, False) == "complex"

    def test_context_limits_cover_all(self):
        for c in ("simple", "normal", "complex"):
            assert c in CONTEXT_LIMITS
            lim = CONTEXT_LIMITS[c]
            assert lim["max_evidence"] > 0
            assert lim["max_claims"] > 0
            assert lim["max_tokens_estimate"] > 0

    def test_evidence_truncated(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Кто вызывает foldConstantOp?"
        )
        max_ev = CONTEXT_LIMITS["simple"]["max_evidence"]
        assert len(b.evidence) <= max_ev

    def test_claims_truncated(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Кто вызывает foldConstantOp?"
        )
        max_cl = CONTEXT_LIMITS["simple"]["max_claims"]
        assert len(b.claims) <= max_cl

    def test_timing_nonzero(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Кто вызывает foldConstantOp?"
        )
        assert b.total_ms >= 0
        assert b.routing_ms >= 0

    def test_provenance(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Кто вызывает foldConstantOp?"
        )
        assert b.provenance.get("engine") == "bplus-knowledge-engine"
        assert b.provenance.get("read_only") is True


class TestBudget:
    def test_simple_limits(self):
        b = BudgetTracker("simple")
        s = b.budget_summary()
        assert s["wall_limit_sec"] == 1.0
        assert s["tool_limit"] == 3
        assert s["search_limit"] == 1
        assert s["grep_limit"] == 0

    def test_normal_limits(self):
        b = BudgetTracker("normal")
        s = b.budget_summary()
        assert s["wall_limit_sec"] == 5.0
        assert s["tool_limit"] == 8

    def test_complex_limits(self):
        b = BudgetTracker("complex")
        s = b.budget_summary()
        assert s["wall_limit_sec"] == 30.0
        assert s["tool_limit"] == 12

    def test_tool_call_increments(self):
        b = BudgetTracker("normal")
        assert b.tool_calls == 0
        b.check_tool("search")
        assert b.tool_calls == 1
        assert b.search_calls == 1

    def test_source_read_increments(self):
        b = BudgetTracker("normal")
        b.check_tool("source_read")
        assert b.source_reads == 1

    def test_grep_increments(self):
        b = BudgetTracker("complex")
        b.check_tool("grep")
        assert b.grep_calls == 1

    def test_tool_budget_exceeded(self):
        b = BudgetTracker("simple")
        b.check_tool("generic")
        b.check_tool("generic")
        b.check_tool("generic")
        with pytest.raises(BudgetExceeded) as exc_info:
            b.check_tool("generic")
        assert exc_info.value.budget_type == "tool_calls"

    def test_search_budget_exceeded(self):
        b = BudgetTracker("simple")
        b.check_tool("search")
        with pytest.raises(BudgetExceeded) as exc_info:
            b.check_tool("search")
        assert exc_info.value.budget_type == "search_calls"

    def test_grep_budget_exceeded_simple(self):
        b = BudgetTracker("simple")
        with pytest.raises(BudgetExceeded) as exc_info:
            b.check_tool("grep")
        assert exc_info.value.budget_type == "grep_calls"

    def test_grep_allowed_complex(self):
        b = BudgetTracker("complex")
        b.check_tool("grep")
        assert b.grep_calls == 1

    def test_context_budget_check(self):
        b = BudgetTracker("normal")
        b.check_context(1000, 200)
        assert b.input_tokens_est == 1000
        assert b.output_tokens_est == 200

    def test_context_budget_exceeded(self):
        b = BudgetTracker("simple")
        with pytest.raises(BudgetExceeded):
            b.check_context(2000, 100)

    def test_can_afford_true(self):
        b = BudgetTracker("normal")
        assert b.can_afford("search") is True
        assert b.search_calls == 0

    def test_can_afford_false(self):
        b = BudgetTracker("simple")
        b.check_tool("search")
        assert b.can_afford("search") is False

    def test_remaining_budget(self):
        b = BudgetTracker("normal")
        r = b.remaining_budget()
        assert r["tool_calls"] == 8
        assert r["search_calls"] == 3

    def test_is_expired_false(self):
        b = BudgetTracker("complex")
        assert b.is_expired() is False

    def test_all_budget_configs_exist(self):
        for c in ("simple", "normal", "complex"):
            assert c in WALL_CLOCK_LIMITS
            assert c in TOOL_BUDGETS
            assert c in CONTEXT_BUDGETS


class TestQueryCache:
    def test_put_and_get(self, cache, tree_sha):
        cache.put("CALLERS", "testFunc", {
            "status": "TEST",
            "telemetry": {"total_ms": 1},
        }, tree_sha)
        result = cache.get("CALLERS", "testFunc", tree_sha)
        assert result is not None
        assert result["status"] == "TEST"
        cache.invalidate_entity("CALLERS", "testFunc")

    def test_miss(self, cache, tree_sha):
        result = cache.get("CALLERS", "nonexistent_98765", tree_sha)
        assert result is None

    def test_invalidation(self, cache, tree_sha):
        cache.put("CALLERS", "invTest", {"status": "X"}, tree_sha)
        assert cache.get("CALLERS", "invTest", tree_sha) is not None
        cache.invalidate_entity("CALLERS", "invTest")
        assert cache.get("CALLERS", "invTest", tree_sha) is None

    def test_tree_sha_mismatch_invalidates(self, cache, tree_sha):
        cache.put("CALLERS", "shaTest", {"status": "Y"}, tree_sha)
        result = cache.get("CALLERS", "shaTest", "wrong_sha_abc")
        assert result is None
        cache.invalidate_entity("CALLERS", "shaTest")

    def test_ttl_expiry(self, cache, tree_sha):
        cache.put("CALLERS", "ttlTest", {"status": "Z"}, tree_sha, ttl_sec=0)
        time.sleep(0.01)
        result = cache.get("CALLERS", "ttlTest", tree_sha)
        assert result is None

    def test_eviction(self, tree_sha):
        c = QueryCache(tree_sha, max_entries=3)
        for i in range(5):
            c.put("TEST", f"evict_{i}", {"i": i}, tree_sha)
        assert len(c.entries) <= 3
        c.invalidate_tree()

    def test_stats(self, cache):
        s = cache.stats()
        assert "entries" in s
        assert "hits" in s
        assert "misses" in s
        assert "hit_rate" in s

    def test_key_deterministic(self, cache):
        k1 = cache._key("CALLERS", "testFunc")
        k2 = cache._key("CALLERS", "testFunc")
        assert k1 == k2

    def test_key_case_insensitive(self, cache):
        k1 = cache._key("CALLERS", "TestFunc")
        k2 = cache._key("CALLERS", "testfunc")
        assert k1 == k2

    def test_invalidate_tree(self, cache, tree_sha):
        cache.put("CALLERS", "treeInv", {"status": "A"}, tree_sha)
        cache.invalidate_tree()
        assert cache.get("CALLERS", "treeInv", tree_sha) is None


class TestTelemetry:
    def test_record(self, telemetry):
        before = len(telemetry.events)
        telemetry.record({
            "type": "test",
            "total_ms": 42.0,
            "status": "ANSWER_READY",
        })
        assert len(telemetry.events) == before + 1
        telemetry.events.pop()

    def test_stats(self, telemetry):
        s = telemetry.stats(10)
        assert "count" in s

    def test_percentile_empty(self, telemetry):
        p = telemetry.percentile(50, last_n=0)
        assert p == 0.0

    def test_check_gates_no_data(self, telemetry):
        g = telemetry.check_gates(last_n=0)
        assert g["passed"] is True

    def test_perf_gates_defined(self):
        for c in ("simple", "normal", "complex"):
            assert c in PERF_GATES
            g = PERF_GATES[c]
            assert g["p50_ms"] > 0
            assert g["p95_ms"] > g["p50_ms"]
            assert g["max_ms"] > g["p95_ms"]


class TestFastPath:
    def test_ask_answer_ready(self, fast_path):
        r = fast_path.ask("Кто вызывает foldConstantOp?")
        assert r["status"] == ANSWER_READY
        assert r["confidence"] == "VERIFIED"
        assert r["completeness"] == ANSWER_READY

    def test_ask_cache_hit(self, fast_path):
        fast_path.ask("Кто вызывает foldConstantOp?")
        r = fast_path.ask("Кто вызывает foldConstantOp?")
        assert r.get("cache_hit") is True

    def test_ask_with_budget_simple(self, fast_path):
        r, b = fast_path.ask_with_budget(
            "Где определён foldConstantOp?", "simple"
        )
        assert r["status"] == ANSWER_READY
        assert b.tool_calls == 0

    def test_ask_with_budget_complex(self, fast_path):
        r, b = fast_path.ask_with_budget(
            "От чего зависит x64gen.zig?", "complex"
        )
        assert r["status"] == ANSWER_READY

    def test_stats(self, fast_path):
        s = fast_path.stats()
        assert "tree_sha" in s
        assert "cache" in s
        assert "telemetry" in s
        assert "gates" in s

    def test_direct_answer_populated(self, fast_path):
        r = fast_path.ask("Кто вызывает foldConstantOp?")
        assert r["direct_answer"] is not None
        assert "runConstantFolding" in r["direct_answer"]

    def test_cache_stats_after_hit(self, fast_path):
        fast_path.ask("Кто вызывает foldConstantOp?")
        fast_path.ask("Кто вызывает foldConstantOp?")
        s = fast_path.cache.stats()
        assert s["hits"] >= 1


class TestPerformanceGates:
    def test_simple_answer_time(self, knowledge):
        times = []
        for _ in range(3):
            t0 = time.monotonic()
            b = build_evidence_bundle(
                knowledge, "Кто вызывает foldConstantOp?"
            )
            elapsed = (time.monotonic() - t0) * 1000
            times.append(elapsed)
            assert b.status == ANSWER_READY
        avg = sum(times) / len(times)
        assert avg < 1000, f"simple avg={avg:.0f}ms exceeds 1000ms"

    def test_definition_answer_time(self, knowledge):
        t0 = time.monotonic()
        b = build_evidence_bundle(
            knowledge, "Где определён foldConstantOp?"
        )
        elapsed = (time.monotonic() - t0) * 1000
        assert b.status == ANSWER_READY
        assert elapsed < 2000, f"definition={elapsed:.0f}ms exceeds 2000ms"

    def test_dependencies_answer_time(self, knowledge):
        t0 = time.monotonic()
        b = build_evidence_bundle(
            knowledge, "От чего зависит x64gen.zig?"
        )
        elapsed = (time.monotonic() - t0) * 1000
        assert b.status == ANSWER_READY
        assert elapsed < 3000, f"dependencies={elapsed:.0f}ms exceeds 3000ms"

    def test_no_global_grep_for_simple(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Где определён foldConstantOp?"
        )
        for lim in b.limitations:
            assert "grep" not in lim.lower()

    def test_evidence_bundle_has_all_fields(self, knowledge):
        b = build_evidence_bundle(
            knowledge, "Кто вызывает foldConstantOp?"
        )
        d = b.to_dict()
        required = [
            "schema", "version", "status", "intent", "entity",
            "question", "direct_answer", "answer_type", "confidence",
            "completeness", "evidence", "claims", "relations",
            "entities", "unresolved", "limitations", "provenance",
            "telemetry",
        ]
        for field in required:
            assert field in d, f"missing field: {field}"

    def test_budget_enforced_for_simple(self):
        b = BudgetTracker("simple")
        for _ in range(3):
            b.check_tool("generic")
        with pytest.raises(BudgetExceeded):
            b.check_tool("generic")

    def test_wall_clock_enforced(self):
        b = BudgetTracker("simple", start_time=time.monotonic() - 10.0)
        assert b.is_expired() is True
        with pytest.raises(BudgetExceeded):
            b.check_tool("generic")
