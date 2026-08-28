import sys, os, time
sys.path.insert(0, r"C:\B-Plus\agent\engine")
from entity_resolver import (
    EntityResolver, ResolvedEntity, get_entity_resolver,
    ENTITY_FUNCTION, ENTITY_STRUCT, ENTITY_MODULE, ENTITY_FILE,
    ENTITY_UNKNOWN, RESOLVED, AMBIGUOUS, NOT_FOUND, TYPE_MISMATCH,
)

def test_entity_types():
    assert ENTITY_FUNCTION == "FUNCTION"
    assert ENTITY_STRUCT == "STRUCT"
    assert ENTITY_MODULE == "MODULE"
    assert ENTITY_FILE == "FILE"
    assert ENTITY_UNKNOWN == "UNKNOWN"
    print("PASS: test_entity_types")

def test_resolved_entity():
    r = ResolvedEntity()
    assert r.status == NOT_FOUND
    d = r.to_dict()
    assert "name" in d
    assert "entity_type" in d
    assert "status" in d
    print("PASS: test_resolved_entity")

def test_resolver_load():
    resolver = EntityResolver.load()
    assert resolver.idx is not None
    print("PASS: test_resolver_load")

def test_resolve_function():
    resolver = EntityResolver.load()
    r = resolver.resolve("foldConstantOp")
    assert r.status == RESOLVED
    assert r.entity_type == ENTITY_FUNCTION
    assert r.concept_id.startswith("CN-")
    assert "foldConstantOp" in r.canonical_name
    assert len(r.evidence_ids) > 0
    assert r.line_start is not None
    assert r.file != ""
    print("PASS: test_resolve_function")

def test_resolve_case_insensitive():
    resolver = EntityResolver.load()
    r1 = resolver.resolve("foldConstantOp")
    r2 = resolver.resolve("FoldConstantOp")
    r3 = resolver.resolve("FOLDCONSTANTOP")
    assert r1.status == RESOLVED
    assert r2.status == RESOLVED
    assert r3.status == RESOLVED
    assert r1.concept_id == r2.concept_id == r3.concept_id
    print("PASS: test_resolve_case_insensitive")

def test_resolve_file():
    resolver = EntityResolver.load()
    r = resolver.resolve("manager.zig")
    assert r.status == RESOLVED
    assert r.entity_type == ENTITY_FILE
    assert "manager.zig" in r.file
    print("PASS: test_resolve_file")

def test_resolve_file_partial():
    resolver = EntityResolver.load()
    r = resolver.resolve("build.zig")
    assert r.status == RESOLVED
    assert r.entity_type == ENTITY_FILE
    print("PASS: test_resolve_file_partial")

def test_resolve_not_found():
    resolver = EntityResolver.load()
    r = resolver.resolve("nonexistentFuncXYZ123")
    assert r.status == NOT_FOUND
    assert r.entity_type == ENTITY_UNKNOWN
    print("PASS: test_resolve_not_found")

def test_resolve_ambiguous():
    resolver = EntityResolver.load()
    r = resolver.resolve("emit")
    assert r.status == AMBIGUOUS
    assert len(r.candidates) > 0
    for c in r.candidates:
        assert "concept_id" in c
        assert "entity_type" in c
        assert "name" in c
    print("PASS: test_resolve_ambiguous  candidates=%d" % len(r.candidates))

def test_resolve_ambiguous_std():
    resolver = EntityResolver.load()
    r = resolver.resolve("std")
    assert r.status == AMBIGUOUS
    assert len(r.candidates) > 0
    print("PASS: test_resolve_ambiguous_std  candidates=%d" % len(r.candidates))

def test_resolve_file_line():
    resolver = EntityResolver.load()
    r = resolver.resolve("manager.zig:184")
    assert r.status == RESOLVED
    assert r.entity_type == ENTITY_FILE
    assert r.line_start == 184
    assert r.line_end == 184
    print("PASS: test_resolve_file_line")

def test_resolve_module():
    resolver = EntityResolver.load()
    r = resolver.resolve("manager.zig", expected_type=ENTITY_MODULE)
    if r.status == TYPE_MISMATCH:
        assert r.entity_type != ENTITY_MODULE
        print("PASS: test_resolve_module  TYPE_MISMATCH (expected)")
    else:
        print("PASS: test_resolve_module  status=%s" % r.status)

def test_resolve_expected_type():
    resolver = EntityResolver.load()
    r = resolver.resolve("foldConstantOp", expected_type=ENTITY_FUNCTION)
    assert r.status == RESOLVED
    assert r.entity_type == ENTITY_FUNCTION
    print("PASS: test_resolve_expected_type")

def test_resolve_wrong_expected_type():
    resolver = EntityResolver.load()
    r = resolver.resolve("foldConstantOp", expected_type=ENTITY_STRUCT)
    assert r.status == TYPE_MISMATCH
    assert r.entity_type == ENTITY_FUNCTION
    print("PASS: test_resolve_wrong_expected_type")

def test_resolve_latency():
    resolver = EntityResolver.load()
    times = []
    for _ in range(1000):
        t0 = time.monotonic()
        resolver.resolve("foldConstantOp")
        times.append((time.monotonic() - t0) * 1000)
    avg = sum(times) / len(times)
    p50 = sorted(times)[len(times)//2]
    p99 = sorted(times)[int(len(times)*0.99)]
    assert avg < 0.5, "avg=%.3fms" % avg
    assert p99 < 1.0, "p99=%.3fms" % p99
    print("PASS: test_resolve_latency  avg=%.3fms p50=%.3fms p99=%.3fms" % (avg, p50, p99))

def test_resolve_file_latency():
    resolver = EntityResolver.load()
    times = []
    for _ in range(1000):
        t0 = time.monotonic()
        resolver.resolve("manager.zig")
        times.append((time.monotonic() - t0) * 1000)
    avg = sum(times) / len(times)
    p99 = sorted(times)[int(len(times)*0.99)]
    assert avg < 0.5, "avg=%.3fms" % avg
    assert p99 < 1.0, "p99=%.3fms" % p99
    print("PASS: test_resolve_file_latency  avg=%.3fms p99=%.3fms" % (avg, p99))

def test_resolve_evidence_chain():
    resolver = EntityResolver.load()
    r = resolver.resolve("foldConstantOp")
    assert r.status == RESOLVED
    assert len(r.evidence_ids) > 0
    ev = resolver.idx.get_evidence(r.evidence_ids[0])
    assert ev is not None
    assert "sha256" in ev
    assert ev["sha256"] != ""
    print("PASS: test_resolve_evidence_chain")

def test_resolve_module_chain():
    resolver = EntityResolver.load()
    r = resolver.resolve("foldConstantOp")
    assert r.status == RESOLVED
    assert r.module_id != ""
    mc = resolver.idx.concept_by_id.get(r.module_id)
    assert mc is not None
    assert mc["concept_type"] == "MODULE"
    print("PASS: test_resolve_module_chain")

def test_resolve_quoted():
    resolver = EntityResolver.load()
    r = resolver.resolve('"foldConstantOp"')
    assert r.status == RESOLVED
    assert r.entity_type == ENTITY_FUNCTION
    print("PASS: test_resolve_quoted")

def test_resolve_empty():
    resolver = EntityResolver.load()
    r = resolver.resolve("")
    assert r.status == NOT_FOUND
    print("PASS: test_resolve_empty")

def test_resolve_none_like():
    resolver = EntityResolver.load()
    r = resolver.resolve(None)
    assert r.status == NOT_FOUND
    print("PASS: test_resolve_none_like")

if __name__ == "__main__":
    test_entity_types()
    test_resolved_entity()
    test_resolver_load()
    test_resolve_function()
    test_resolve_case_insensitive()
    test_resolve_file()
    test_resolve_file_partial()
    test_resolve_not_found()
    test_resolve_ambiguous()
    test_resolve_ambiguous_std()
    test_resolve_file_line()
    test_resolve_module()
    test_resolve_expected_type()
    test_resolve_wrong_expected_type()
    test_resolve_latency()
    test_resolve_file_latency()
    test_resolve_evidence_chain()
    test_resolve_module_chain()
    test_resolve_quoted()
    test_resolve_empty()
    test_resolve_none_like()
    print("\nALL ENTITY RESOLVER TESTS PASSED")
