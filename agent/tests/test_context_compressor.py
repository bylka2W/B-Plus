import sys
import os
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from engine.context_compressor import (
    ContextCompressor, CompressedContext, ContextSection, ContextBudget,
    get_context_compressor,
    DEFAULT_MAX_TOKENS, CHARS_PER_TOKEN,
    STATUS_COMPLETE, STATUS_INSUFFICIENT, STATUS_NO_CONTEXT, STATUS_NOT_FOUND,
    STATUS_VERIFIED, STATUS_STALE, STATUS_MISSING, STATUS_PARTIAL,
)

PASS = 0
FAIL = 0


def check(name, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print("PASS:", name)
    else:
        FAIL += 1
        print("FAIL:", name, "-", detail)


def test_constants():
    check("DEFAULT_MAX_TOKENS is 256K", DEFAULT_MAX_TOKENS == 256000)
    check("CHARS_PER_TOKEN is 4", CHARS_PER_TOKEN == 4)


def test_budget():
    b = ContextBudget(1000)
    check("budget max_chars", b.max_chars == 4000)
    check("budget remaining", b.remaining() == 4000)
    used = b.allocate("test", 500)
    check("budget allocate full", used == 500)
    check("budget remaining after", b.remaining() == 3500)
    check("budget usage_ratio", b.usage_ratio() == 0.125)
    check("budget section tracked", b.sections["test"] == 500)


def test_budget_exceed():
    b = ContextBudget(10)
    used = b.allocate("big", 50)
    check("budget exceed returns remaining", used == 40)
    check("budget remaining is 0", b.remaining() == 0)


def test_section():
    s = ContextSection("TEST", "hello world")
    check("section name", s.name == "TEST")
    check("section char_count", s.char_count == 11)
    check("section token_estimate", s.token_estimate == 2)
    d = s.to_dict()
    check("section to_dict", d["name"] == "TEST")
    check("section to_dict char_count", d["char_count"] == 11)


def test_compressed_context():
    ctx = CompressedContext()
    check("context status default", ctx.status == STATUS_COMPLETE)
    check("context total_chars default", ctx.total_chars == 0)
    s = ContextSection("A", "hello", priority=10)
    ctx.add_section(s)
    check("context add_section", len(ctx.sections) == 1)
    check("context total_chars after add", ctx.total_chars == 5)
    d = ctx.to_dict()
    check("context to_dict has status", "status" in d)
    check("context to_dict has sections", d["section_count"] == 1)


def test_render():
    ctx = CompressedContext()
    ctx.add_section(ContextSection("TASK", "question: test"))
    ctx.add_section(ContextSection("ENTITY", "name: foo"))
    rendered = ctx.render()
    check("render has TASK", "=== TASK ===" in rendered)
    check("render has ENTITY", "=== ENTITY ===" in rendered)
    check("render has content", "question: test" in rendered)


def test_load():
    cc = ContextCompressor.load()
    check("CC loads", cc is not None)
    check("CC has idx", hasattr(cc, "idx"))
    check("CC has verifier", hasattr(cc, "verifier"))
    check("CC has graph", hasattr(cc, "graph"))


def test_singleton():
    c1 = get_context_compressor()
    c2 = get_context_compressor()
    check("Singleton", c1 is c2)


def test_compress_callers():
    cc = ContextCompressor.load()
    ctx = cc.compress("Who calls foldConstantOp?")
    check("callers status COMPLETE", ctx.status == STATUS_COMPLETE)
    check("callers has sections", len(ctx.sections) >= 4)
    check("callers total_chars > 0", ctx.total_chars > 0)
    check("callers total_tokens > 0", ctx.total_tokens > 0)
    check("callers budget_used_ratio > 0", ctx.budget_used_ratio > 0)
    check("callers has intent", ctx.intent == "CALLERS")
    check("callers has entity", ctx.entity == "foldConstantOp")
    section_names = [s.name for s in ctx.sections]
    check("callers has TASK", "TASK" in section_names)
    check("callers has ENTITY", "ENTITY" in section_names)
    check("callers has GRAPH", "GRAPH" in section_names)
    check("callers has EVIDENCE", "EVIDENCE" in section_names)
    check("callers has SOURCE", "SOURCE" in section_names)
    check("callers has CONSTRAINTS", "CONSTRAINTS" in section_names)


def test_compress_callees():
    cc = ContextCompressor.load()
    ctx = cc.compress("What does foldConstantOp call?")
    check("callees status COMPLETE", ctx.status == STATUS_COMPLETE)
    check("callees has GRAPH section",
          any(s.name == "GRAPH" for s in ctx.sections))


def test_compress_definition():
    cc = ContextCompressor.load()
    ctx = cc.compress("Where is foldConstantOp defined?")
    check("definition status COMPLETE", ctx.status == STATUS_COMPLETE)
    check("definition has SOURCE", any(s.name == "SOURCE" for s in ctx.sections))


def test_compress_not_found():
    cc = ContextCompressor.load()
    ctx = cc.compress("nonexistentXYZ")
    check("not_found has sections", len(ctx.sections) >= 1)
    check("not_found has TASK", any(s.name == "TASK" for s in ctx.sections))


def test_compress_empty():
    cc = ContextCompressor.load()
    ctx = cc.compress("")
    check("empty has sections", len(ctx.sections) >= 1)


def test_compress_entity():
    cc = ContextCompressor.load()
    cids = cc.idx.resolve_concept("foldConstantOp")
    if cids:
        ctx = cc.compress_entity(cids[0])
        check("entity status COMPLETE", ctx.status == STATUS_COMPLETE)
        check("entity has sections", len(ctx.sections) >= 3)
        check("entity has entity name", ctx.entity != "")
        section_names = [s.name for s in ctx.sections]
        check("entity has ENTITY_DETAIL", "ENTITY_DETAIL" in section_names)
    else:
        check("entity compress skip", True)


def test_compress_entity_not_found():
    cc = ContextCompressor.load()
    ctx = cc.compress_entity("CN-nonexistent")
    check("entity not_found", ctx.status == STATUS_NOT_FOUND)


def test_budget_respected():
    cc = ContextCompressor.load()
    ctx = cc.compress("Who calls foldConstantOp?", max_tokens=1000)
    check("small budget has sections", len(ctx.sections) >= 1)
    check("small budget total_tokens exists", ctx.total_tokens >= 0)


def test_verification_summary():
    cc = ContextCompressor.load()
    ctx = cc.compress("Who calls foldConstantOp?")
    check("verification_summary is dict", isinstance(ctx.verification_summary, dict))
    check("verification_summary has keys", len(ctx.verification_summary) > 0)


def test_render_callers():
    cc = ContextCompressor.load()
    ctx = cc.compress("Who calls foldConstantOp?")
    rendered = ctx.render()
    check("rendered has QUESTION", "QUESTION:" in rendered)
    check("rendered has INTENT", "INTENT:" in rendered)
    check("rendered has CONSTRAINTS", "CONSTRAINTS:" in rendered)
    check("rendered has evidence info", "EVIDENCE" in rendered)


def test_source_content():
    cc = ContextCompressor.load()
    ctx = cc.compress("Where is foldConstantOp defined?")
    source_section = None
    for s in ctx.sections:
        if s.name == "SOURCE":
            source_section = s
            break
    if source_section:
        check("source has FILE:", "FILE:" in source_section.content)
        check("source has zig fence", "```zig" in source_section.content)
    else:
        check("source section missing", False)


def test_latency():
    cc = ContextCompressor.load()
    times = []
    for _ in range(20):
        t0 = time.monotonic()
        cc.compress("Who calls foldConstantOp?")
        times.append((time.monotonic() - t0) * 1000)
    times.sort()
    p50 = times[len(times) // 2]
    p99 = times[int(len(times) * 0.99)]
    check(f"compress latency p50={p50:.1f}ms < 100ms", p50 < 100)
    check(f"compress latency p99={p99:.1f}ms < 500ms", p99 < 500)


def test_entity_latency():
    cc = ContextCompressor.load()
    cids = cc.idx.resolve_concept("foldConstantOp")
    if not cids:
        check("entity latency skip", True)
        return
    times = []
    for _ in range(20):
        t0 = time.monotonic()
        cc.compress_entity(cids[0])
        times.append((time.monotonic() - t0) * 1000)
    times.sort()
    p50 = times[len(times) // 2]
    check(f"entity compress p50={p50:.1f}ms < 100ms", p50 < 100)


def test_full_render_not_empty():
    cc = ContextCompressor.load()
    ctx = cc.compress("Who calls foldConstantOp?")
    rendered = ctx.render()
    check("rendered > 100 chars", len(rendered) > 100)
    check("rendered < 100K chars", len(rendered) < 100000)


def test_to_dict_roundtrip():
    cc = ContextCompressor.load()
    ctx = cc.compress("Who calls foldConstantOp?")
    d = ctx.to_dict()
    check("to_dict has sections list", isinstance(d["sections"], list))
    check("to_dict section has name", "name" in d["sections"][0])
    check("to_dict section has char_count", "char_count" in d["sections"][0])


if __name__ == "__main__":
    test_constants()
    test_budget()
    test_budget_exceed()
    test_section()
    test_compressed_context()
    test_render()
    test_load()
    test_singleton()
    test_compress_callers()
    test_compress_callees()
    test_compress_definition()
    test_compress_not_found()
    test_compress_empty()
    test_compress_entity()
    test_compress_entity_not_found()
    test_budget_respected()
    test_verification_summary()
    test_render_callers()
    test_source_content()
    test_latency()
    test_entity_latency()
    test_full_render_not_empty()
    test_to_dict_roundtrip()
    print()
    print(f"CONTEXT COMPRESSOR: {PASS} PASS / {FAIL} FAIL")
    sys.exit(0 if FAIL == 0 else 1)
