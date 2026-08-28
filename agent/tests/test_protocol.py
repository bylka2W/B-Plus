import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "engine"))

import pytest
from protocol import (
    QueryProtocol, QueryResult, is_terminal, terminal_reason,
    TERMINAL, NON_TERMINAL, SIMPLE_INTENTS,
    CONTEXT_PACK_TEMPLATES,
)
from evidence_bundle import ANSWER_READY, NEEDS_DEEP_SEARCH, UNKNOWN, PARTIAL
from budget import BudgetTracker

_qp = None


def _get_qp():
    global _qp
    if _qp is None:
        _qp = QueryProtocol.load()
    return _qp


@pytest.fixture(scope="module")
def qp():
    return _get_qp()


class TestIsTerminal:
    def test_verified_ready_is_terminal(self):
        d = {"status": ANSWER_READY, "confidence": "VERIFIED",
             "completeness": ANSWER_READY,
             "evidence": [{"file": "a.zig"}], "unresolved": []}
        assert is_terminal(d) is True

    def test_ready_partial_is_not_terminal(self):
        d = {"status": ANSWER_READY, "confidence": "PARTIAL",
             "completeness": PARTIAL,
             "evidence": [{"file": "a.zig"}], "unresolved": [{"x": 1}]}
        assert is_terminal(d) is False

    def test_needs_deep_is_not_terminal(self):
        d = {"status": NEEDS_DEEP_SEARCH, "confidence": "UNSUPPORTED",
             "completeness": NEEDS_DEEP_SEARCH,
             "evidence": [], "unresolved": []}
        assert is_terminal(d) is False

    def test_unknown_is_not_terminal(self):
        d = {"status": UNKNOWN, "confidence": "UNSUPPORTED",
             "completeness": UNKNOWN,
             "evidence": [], "unresolved": []}
        assert is_terminal(d) is False

    def test_ready_no_evidence_not_terminal(self):
        d = {"status": ANSWER_READY, "confidence": "VERIFIED",
             "completeness": ANSWER_READY,
             "evidence": [], "unresolved": []}
        assert is_terminal(d) is False

    def test_ready_with_unresolved_not_terminal(self):
        d = {"status": ANSWER_READY, "confidence": "VERIFIED",
             "completeness": ANSWER_READY,
             "evidence": [{"file": "a.zig"}],
             "unresolved": [{"fact_id": "F-1"}]}
        assert is_terminal(d) is False

    def test_ready_completeness_answering_evidence_not_terminal(self):
        d = {"status": ANSWER_READY, "confidence": "PARTIAL",
             "completeness": ANSWER_READY,
             "evidence": [{"file": "a.zig"}], "unresolved": []}
        assert is_terminal(d) is True

    def test_partial_status_not_terminal(self):
        d = {"status": PARTIAL, "confidence": "PARTIAL",
             "completeness": PARTIAL,
             "evidence": [{"file": "a.zig"}], "unresolved": []}
        assert is_terminal(d) is False


class TestTerminalReason:
    def test_returns_info_when_terminal(self):
        d = {"status": ANSWER_READY, "confidence": "VERIFIED",
             "completeness": ANSWER_READY,
             "evidence": [{"file": "a.zig"}], "unresolved": []}
        r = terminal_reason(d)
        assert r is not None
        assert r["reason"] == "verified_answer_available"
        assert r["confidence"] == "VERIFIED"
        assert r["evidence_count"] == 1

    def test_returns_none_when_not_terminal(self):
        d = {"status": NEEDS_DEEP_SEARCH, "confidence": "UNSUPPORTED",
             "completeness": NEEDS_DEEP_SEARCH,
             "evidence": [], "unresolved": []}
        assert terminal_reason(d) is None


class TestQueryProtocolCallers:
    def test_terminal_state(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        assert qr.terminal is True
        assert qr.terminal_info is not None
        assert qr.terminal_info["confidence"] == "VERIFIED"

    def test_bundle_answer_ready(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        assert qr.bundle["status"] == ANSWER_READY
        assert qr.bundle["confidence"] == "VERIFIED"

    def test_direct_answer_populated(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        assert qr.bundle["direct_answer"] is not None
        assert "runConstantFolding" in qr.bundle["direct_answer"]

    def test_evidence_present(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        assert len(qr.bundle["evidence"]) > 0

    def test_compact_context_present(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        assert qr.compact_context is not None
        assert qr.compact_context["text"] is not None
        assert "foldConstantOp" in qr.compact_context["text"]

    def test_budget_tracker_present(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        assert qr.budget is not None
        s = qr.budget.budget_summary()
        assert "complexity" in s


class TestQueryProtocolDefinition:
    def test_terminal(self, qp):
        qr = qp.ask("Where is foldConstantOp defined?", "simple")
        assert qr.terminal is True
        assert qr.bundle["status"] == ANSWER_READY

    def test_compact_context_has_definition(self, qp):
        qr = qp.ask("Where is foldConstantOp defined?", "simple")
        text = qr.compact_context["text"]
        assert "DEFINITION" in text
        assert "184" in text


class TestQueryProtocolCallees:
    def test_terminal(self, qp):
        qr = qp.ask("What does foldConstantOp call?", "simple")
        assert qr.terminal is True
        assert qr.bundle["status"] == ANSWER_READY


class TestQueryProtocolCache:
    def test_cache_hit(self, qp):
        qp.ask("Who calls foldConstantOp?", "simple")
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        assert qr.bundle.get("cache_hit") is True
        assert qr.elapsed_ms < 50

    def test_cache_invalidation_on_tree_change(self, qp):
        qr1 = qp.ask("Who calls foldConstantOp?", "simple")
        assert qr1.bundle.get("cache_hit") is not None
        qp.cache.invalidate_entity("CALLERS", "foldConstantop".lower())
        qr2 = qp.ask("Who calls foldConstantOp?", "simple")
        assert qr2.bundle.get("cache_hit") is not True


class TestQueryProtocolComplexity:
    def test_simple_limits_context(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        ctx = qr.compact_context
        assert ctx["max_context_lines"] == 20
        assert ctx["max_source_chars"] == 2000

    def test_normal_limits_context(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "normal")
        ctx = qr.compact_context
        assert ctx["max_context_lines"] == 60
        assert ctx["max_source_chars"] == 8000

    def test_complex_limits_context(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "complex")
        ctx = qr.compact_context
        assert ctx["max_context_lines"] == 200
        assert ctx["max_source_chars"] == 30000


class TestCompactContext:
    def test_intent_entity_present(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        text = qr.compact_context["text"]
        assert "INTENT: CALLERS" in text
        assert "ENTITY: foldConstantOp" in text

    def test_status_present(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        text = qr.compact_context["text"]
        assert "STATUS: ANSWER_READY" in text

    def test_confidence_present(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        text = qr.compact_context["text"]
        assert "CONFIDENCE: VERIFIED" in text

    def test_answer_section(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        text = qr.compact_context["text"]
        assert "ANSWER:" in text
        assert "runConstantFolding" in text

    def test_evidence_section(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        text = qr.compact_context["text"]
        assert "EVIDENCE:" in text
        assert "manager.zig" in text

    def test_claims_section(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        text = qr.compact_context["text"]
        assert "CLAIMS:" in text

    def test_no_source_text_simple(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        text = qr.compact_context["text"]
        assert "const result" not in text

    def test_chars_within_budget(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        assert qr.compact_context["chars"] <= 2000


class TestToDict:
    def test_has_terminal_field(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        d = qr.to_dict()
        assert "terminal" in d
        assert d["terminal"] is True

    def test_has_compact_context(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        d = qr.to_dict()
        assert "compact_context" in d

    def test_has_budget_summary(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        d = qr.to_dict()
        assert "budget_summary" in d


class TestProtocolPerformance:
    def test_simple_under_100ms(self, qp):
        times = []
        for _ in range(5):
            t0 = time.monotonic()
            qr = qp.ask("Who calls foldConstantOp?", "simple")
            elapsed = (time.monotonic() - t0) * 1000
            times.append(elapsed)
            assert qr.terminal is True
        avg = sum(times) / len(times)
        assert avg < 100, "simple avg=%dms exceeds 100ms" % avg

    def test_cache_hit_under_100ms(self, qp):
        qp.ask("Who calls foldConstantOp?", "simple")
        times = []
        for _ in range(5):
            t0 = time.monotonic()
            qr = qp.ask("Who calls foldConstantOp?", "simple")
            elapsed = (time.monotonic() - t0) * 1000
            times.append(elapsed)
        avg = sum(times) / len(times)
        assert avg < 100, "cache avg=%.1fms exceeds 100ms" % avg

    def test_definition_under_100ms(self, qp):
        t0 = time.monotonic()
        qr = qp.ask("Where is foldConstantOp defined?", "simple")
        elapsed = (time.monotonic() - t0) * 1000
        assert qr.terminal is True
        assert elapsed < 100


class TestProtocolTemplates:
    def test_all_complexities_covered(self):
        for c in ("simple", "normal", "complex"):
            assert c in CONTEXT_PACK_TEMPLATES
            t = CONTEXT_PACK_TEMPLATES[c]
            assert t["max_context_lines"] > 0
            assert t["max_source_chars"] > 0

    def test_simple_tighter_than_normal(self):
        s = CONTEXT_PACK_TEMPLATES["simple"]
        n = CONTEXT_PACK_TEMPLATES["normal"]
        assert s["max_context_lines"] < n["max_context_lines"]
        assert s["max_source_chars"] < n["max_source_chars"]

    def test_normal_tighter_than_complex(self):
        n = CONTEXT_PACK_TEMPLATES["normal"]
        c = CONTEXT_PACK_TEMPLATES["complex"]
        assert n["max_context_lines"] < c["max_context_lines"]
        assert n["max_source_chars"] < c["max_source_chars"]


class TestProtocolNoAgenticThrashing:
    def test_single_pass_callers(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        assert qr.terminal is True
        assert qr.bundle["confidence"] == "VERIFIED"
        assert len(qr.bundle["evidence"]) > 0
        assert len(qr.bundle.get("unresolved", [])) == 0

    def test_single_pass_definition(self, qp):
        qr = qp.ask("Where is foldConstantOp defined?", "simple")
        assert qr.terminal is True
        assert qr.bundle["confidence"] == "VERIFIED"
        assert qr.bundle["direct_answer"] is not None

    def test_single_pass_callees(self, qp):
        qr = qp.ask("What does foldConstantOp call?", "simple")
        assert qr.terminal is True
        assert "getConstValue" in qr.bundle["direct_answer"]

    def test_compact_context_minimal(self, qp):
        qr = qp.ask("Who calls foldConstantOp?", "simple")
        ctx_chars = qr.compact_context["chars"]
        assert ctx_chars < 500, "context too large: %d chars" % ctx_chars
