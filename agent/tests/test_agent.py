import sys, os, time
sys.path.insert(0, r"C:\B-Plus\agent\engine")
from agent import KnowledgeAgent, AnswerPacket, SUPPORTED_MODES, FAST_INTENTS
from indexes import get_fast_index, FastIndex

def test_answer_packet():
    p = AnswerPacket()
    assert p.status == "UNKNOWN"
    assert p.confidence == "UNSUPPORTED"
    assert p.terminal is False
    assert p.fast_path is False
    d = p.to_dict()
    assert "fast_path" in d
    ctx = p.to_context()
    assert "STATUS:" in ctx
    print("PASS: test_answer_packet")

def test_supported_modes():
    assert "FACT" in SUPPORTED_MODES
    assert "DEFINITION" in SUPPORTED_MODES
    assert "RELATION" in SUPPORTED_MODES
    assert "TRACE" in SUPPORTED_MODES
    assert "SOURCE" in SUPPORTED_MODES
    assert "EXPLAIN" in SUPPORTED_MODES
    assert "DEEP" in SUPPORTED_MODES
    print("PASS: test_supported_modes")

def test_fast_intents():
    assert "DEFINITION" in FAST_INTENTS
    assert "CALLERS" in FAST_INTENTS
    assert "CALLEES" in FAST_INTENTS
    print("PASS: test_fast_intents")

def test_agent_load():
    agent = KnowledgeAgent.load()
    stats = agent.stats()
    assert stats["concepts"] > 0
    assert stats["facts"] > 0
    assert stats["relations"] > 0
    assert "fast_index" in stats
    print("PASS: test_agent_load")

def test_fast_index_load():
    idx = get_fast_index()
    s = idx.stats()
    assert s["concepts"] == 9636
    assert s["symbols"] == 9235
    assert s["evidence"] == 9151
    assert s["facts"] == 26910
    assert s["relations"] == 31730
    assert s["files"] == 401
    assert s["load_time_ms"] > 0
    print("PASS: test_fast_index_load")

def test_fast_index_resolve():
    idx = get_fast_index()
    cids = idx.resolve_concept("foldConstantOp")
    assert len(cids) == 1
    assert cids[0].startswith("CN-")
    cids2 = idx.resolve_concept("FOLDCONSTANTOP")
    assert len(cids2) == 1
    assert cids2[0] == cids[0]
    print("PASS: test_fast_index_resolve")

def test_fast_index_callers():
    idx = get_fast_index()
    cids = idx.resolve_concept("foldConstantOp")
    callers = idx.get_callers(cids[0])
    assert len(callers) > 0
    caller = idx.concept_by_id.get(callers[0])
    assert caller is not None
    assert caller["canonical_name"] == "runConstantFolding"
    print("PASS: test_fast_index_callers")

def test_fast_index_callees():
    idx = get_fast_index()
    cids = idx.resolve_concept("foldConstantOp")
    callees = idx.get_callees(cids[0])
    assert len(callees) > 0
    callee = idx.concept_by_id.get(callees[0])
    assert callee is not None
    assert callee["canonical_name"] == "getConstValue"
    print("PASS: test_fast_index_callees")

def test_fast_index_evidence():
    idx = get_fast_index()
    cids = idx.resolve_concept("foldConstantOp")
    ev_ids = idx.get_concept_evidence(cids[0])
    assert len(ev_ids) > 0
    ev = idx.get_evidence(ev_ids[0])
    assert ev is not None
    assert "source_file" in ev
    assert "sha256" in ev
    print("PASS: test_fast_index_evidence")

def test_fast_index_facts():
    idx = get_fast_index()
    keys = list(idx.facts_by_subject.keys())
    assert len(keys) > 0
    facts = idx.get_facts_by_subject(keys[0])
    assert len(facts) > 0
    f = idx.fact_by_id[facts[0]]
    assert "fact_type" in f
    print("PASS: test_fast_index_facts")

def test_fast_index_relations():
    idx = get_fast_index()
    keys = list(idx.relations_by_source.keys())
    assert len(keys) > 0
    rels = idx.get_relations_by_source(keys[0])
    assert len(rels) > 0
    r = idx.relation_by_id[rels[0]]
    assert "relation_type" in r
    print("PASS: test_fast_index_relations")

def test_agent_fast_path_callers():
    agent = KnowledgeAgent.load()
    p = agent.ask("Who calls foldConstantOp?")
    assert p.fast_path is True
    assert p.status == "ANSWER_READY"
    assert p.confidence == "VERIFIED"
    assert p.terminal is True
    assert "runConstantFolding" in p.direct_answer
    assert p.elapsed_ms < 1.0
    print("PASS: test_agent_fast_path_callers  time=%.2fms" % p.elapsed_ms)

def test_agent_fast_path_definition():
    agent = KnowledgeAgent.load()
    p = agent.ask("Where is foldConstantOp defined?")
    assert p.fast_path is True
    assert p.status == "ANSWER_READY"
    assert p.confidence == "VERIFIED"
    assert p.terminal is True
    assert "manager.zig" in p.direct_answer
    assert p.elapsed_ms < 1.0
    print("PASS: test_agent_fast_path_definition  time=%.2fms" % p.elapsed_ms)

def test_agent_fast_path_callees():
    agent = KnowledgeAgent.load()
    p = agent.ask("What does foldConstantOp call?")
    assert p.fast_path is True
    assert p.status == "ANSWER_READY"
    assert p.confidence == "VERIFIED"
    assert p.terminal is True
    assert "getConstValue" in p.direct_answer
    assert p.elapsed_ms < 1.0
    print("PASS: test_agent_fast_path_callees  time=%.2fms" % p.elapsed_ms)

def test_agent_fast_path_latency():
    agent = KnowledgeAgent.load()
    times = []
    for _ in range(100):
        t0 = time.monotonic()
        p = agent.ask("Who calls foldConstantOp?")
        times.append((time.monotonic() - t0) * 1000)
    avg = sum(times) / len(times)
    p50 = sorted(times)[len(times)//2]
    p95 = sorted(times)[int(len(times)*0.95)]
    p99 = sorted(times)[int(len(times)*0.99)]
    assert avg < 1.0, "avg=%.2fms" % avg
    assert p50 < 1.0, "p50=%.2fms" % p50
    assert p99 < 2.0, "p99=%.2fms" % p99
    print("PASS: test_agent_fast_path_latency  avg=%.3fms p50=%.3fms p95=%.3fms p99=%.3fms" % (avg, p50, p95, p99))

def test_agent_fallback_to_protocol():
    agent = KnowledgeAgent.load()
    p = agent.ask("Where is emit used?")
    assert p.fast_path is False
    print("PASS: test_agent_fallback_to_protocol  status=%s" % p.status)

def test_agent_to_dict():
    agent = KnowledgeAgent.load()
    p = agent.ask("Where is foldConstantOp defined?")
    d = p.to_dict()
    assert isinstance(d, dict)
    assert d["status"] == "ANSWER_READY"
    assert d["terminal"] is True
    assert d["fast_path"] is True
    print("PASS: test_agent_to_dict")

def test_agent_to_context():
    agent = KnowledgeAgent.load()
    p = agent.ask("Where is foldConstantOp defined?")
    ctx = p.to_context()
    assert "STATUS:" in ctx
    assert "CONFIDENCE:" in ctx
    assert "ENTITY:" in ctx
    assert "INTENT:" in ctx
    assert "ANSWER:" in ctx
    assert "EVIDENCE:" in ctx
    print("PASS: test_agent_to_context")

def test_agent_type_mismatch():
    agent = KnowledgeAgent.load()
    p = agent.ask("Who calls x64gen.zig?")
    assert p.status in ("TYPE_MISMATCH", "ANSWER_READY", "UNKNOWN", "NEEDS_DEEP_SEARCH")
    print("PASS: test_agent_type_mismatch  status=%s" % p.status)

def test_agent_not_found():
    agent = KnowledgeAgent.load()
    p = agent.ask("Where is nonexistentFuncXYZ defined?")
    assert p.status in ("NOT_FOUND", "UNKNOWN", "EMPTY", "NEEDS_DEEP_SEARCH")
    assert p.confidence in ("UNSUPPORTED", "PARTIAL")
    print("PASS: test_agent_not_found  status=%s" % p.status)

def test_agent_mode_override():
    agent = KnowledgeAgent.load()
    p = agent.ask("Where is foldConstantOp defined?", mode="FACT")
    assert p.status == "ANSWER_READY"
    print("PASS: test_agent_mode_override")

if __name__ == "__main__":
    test_answer_packet()
    test_supported_modes()
    test_fast_intents()
    test_agent_load()
    test_fast_index_load()
    test_fast_index_resolve()
    test_fast_index_callers()
    test_fast_index_callees()
    test_fast_index_evidence()
    test_fast_index_facts()
    test_fast_index_relations()
    test_agent_fast_path_callers()
    test_agent_fast_path_definition()
    test_agent_fast_path_callees()
    test_agent_fast_path_latency()
    test_agent_fallback_to_protocol()
    test_agent_to_dict()
    test_agent_to_context()
    test_agent_type_mismatch()
    test_agent_not_found()
    test_agent_mode_override()
    print("\nALL AGENT TESTS PASSED")
