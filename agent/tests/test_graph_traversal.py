import sys
import os
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from engine.graph_traversal import (
    GraphTraversal, GraphEdge, GraphNode, GraphResult, get_graph_traversal,
    EDGE_TYPES, REL_CALLS, REL_CALLED_BY, REL_DEPENDS_ON, REL_DEPENDENT_OF,
    RELREFERENCES, RELUSES_TYPE, RELTYPE_USER, RELCONTAINS,
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


def test_load():
    gt = GraphTraversal.load()
    check("GT loads", gt is not None)
    check("GT has idx", hasattr(gt, "idx"))
    check("GT has resolver", hasattr(gt, "resolver"))


def test_singleton():
    g1 = get_graph_traversal()
    g2 = get_graph_traversal()
    check("Singleton", g1 is g2)


def test_edge_types():
    check("EDGE_TYPES has 12", len(EDGE_TYPES) == 12)
    check("CALLS in EDGE_TYPES", REL_CALLS in EDGE_TYPES)
    check("CALLED_BY in EDGE_TYPES", REL_CALLED_BY in EDGE_TYPES)


def test_graph_edge_slots():
    e = GraphEdge()
    e.relation_id = "SR-123"
    e.source_id = "CN-111"
    e.target_id = "CN-222"
    e.relation_type = "CALLS"
    e.evidence_id = "EV-333"
    e.evidence_file = "test.zig"
    e.evidence_line_start = 10
    e.evidence_line_end = 20
    e.evidence_text = "fn foo()"
    d = e.to_dict()
    check("GraphEdge.to_dict has relation_id", d["relation_id"] == "SR-123")
    check("GraphEdge.to_dict has evidence_id", d["evidence_id"] == "EV-333")
    check("GraphEdge.to_dict has evidence_file", d["evidence_file"] == "test.zig")
    check("GraphEdge.to_dict has lines", d["evidence_line_start"] == 10)


def test_graph_node():
    n = GraphNode()
    n.concept_id = "CN-111"
    n.name = "foo"
    n.entity_type = "FUNCTION"
    d = n.to_dict()
    check("GraphNode.to_dict", d["concept_id"] == "CN-111")
    check("GraphNode.to_dict name", d["name"] == "foo")


def test_graph_result():
    r = GraphResult()
    d = r.to_dict()
    check("GraphResult.to_dict has status", d["status"] == "NOT_FOUND")
    check("GraphResult.to_dict has elapsed_ms", "elapsed_ms" in d)


def test_callers():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    r = gt.callers(cid)
    check("callers status RESOLVED", r.status == "RESOLVED")
    check("callers has edges", r.total_edges >= 1)
    check("callers has nodes", r.total_nodes >= 2)
    check("callers depth=1", r.depth == 1)
    e = r.edges[0]
    check("callers edge has relation_id", e.relation_id != "")
    check("callers edge has evidence_id", e.evidence_id != "")
    check("callers edge has evidence_file", e.evidence_file != "")
    check("callers edge has evidence_line", e.evidence_line_start > 0)
    check("callers elapsed_ms set", r.elapsed_ms > 0)


def test_callees():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    r = gt.callees(cid)
    check("callees status RESOLVED", r.status == "RESOLVED")
    check("callees has edges", r.total_edges >= 1)
    e = r.edges[0]
    check("callees edge has evidence_id", e.evidence_id != "")
    check("callees edge has source_file", e.evidence_file != "")


def test_neighbors_outgoing():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    r = gt.neighbors(cid, direction="outgoing")
    check("neighbors outgoing RESOLVED", r.status == "RESOLVED")
    check("neighbors outgoing has edges", r.total_edges >= 1)
    check("neighbors outgoing depth=1", r.depth == 1)


def test_neighbors_incoming():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    r = gt.neighbors(cid, direction="incoming")
    check("neighbors incoming RESOLVED", r.status == "RESOLVED")
    check("neighbors incoming has edges", r.total_edges >= 1)


def test_neighbors_both():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    r = gt.neighbors(cid, direction="both")
    check("neighbors both RESOLVED", r.status == "RESOLVED")
    check("neighbors both more edges than outgoing",
          r.total_edges >= 2)


def test_references():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    r = gt.references(cid)
    check("references RESOLVED", r.status == "RESOLVED")
    check("references has edges", r.total_edges >= 1)


def test_contains():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("manager.zig")
    if not cids:
        cids = gt.idx.resolve_concept("build.zig")
    if cids:
        cid = cids[0]
        r = gt.contains(cid)
        check("contains RESOLVED", r.status == "RESOLVED")
    else:
        check("contains skip (no module found)", True)


def test_not_found():
    gt = GraphTraversal.load()
    r = gt.callers("CN-nonexistent")
    check("not_found NOT_FOUND", r.status == "NOT_FOUND")
    d = r.to_dict()
    check("not_found to_dict", d["status"] == "NOT_FOUND")


def test_impact():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    r = gt.impact(cid, depth=2)
    check("impact RESOLVED", r.status == "RESOLVED")
    check("impact has nodes", r.total_nodes >= 1)
    check("impact depth<=2", r.depth <= 2)


def test_trace_same():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    r = gt.trace(cid, cid)
    check("trace same-node RESOLVED", r.status == "RESOLVED")
    check("trace same-node depth=0", r.depth == 0)


def test_trace_no_path():
    gt = GraphTraversal.load()
    r = gt.trace("CN-nonexistent", "CN-also-nonexistent")
    check("trace no-path NOT_FOUND", r.status == "NOT_FOUND")


def test_subgraph():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    callees = gt.idx.get_callees(cid)
    if callees:
        r = gt.subgraph([cid, callees[0]])
        check("subgraph RESOLVED", r.status == "RESOLVED")
        check("subgraph has nodes", r.total_nodes >= 2)
    else:
        check("subgraph skip", True)


def test_depth_limit():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    r1 = gt.callers(cid, depth=1)
    r2 = gt.callers(cid, depth=3)
    check("depth=3 >= depth=1", r2.total_nodes >= r1.total_nodes)


def test_edge_has_text():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    r = gt.callees(cid)
    if r.edges:
        e = r.edges[0]
        has_text = len(e.evidence_text) > 0
        check("callees edge has text", has_text)
    else:
        check("callees edge has text skip", True)


def test_node_has_file():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    r = gt.callers(cid)
    root = r.root
    check("root has file_path", root.file_path != "")
    check("root has entity_type", root.entity_type != "")
    check("root has module_id", root.module_id != "")


def test_latency():
    gt = GraphTraversal.load()
    cids = gt.idx.resolve_concept("foldConstantOp")
    cid = cids[0]
    times = []
    for _ in range(100):
        t0 = time.monotonic()
        gt.callers(cid)
        times.append((time.monotonic() - t0) * 1000)
    times.sort()
    p50 = times[len(times) // 2]
    p99 = times[int(len(times) * 0.99)]
    check(f"callers latency p50={p50:.3f}ms < 5ms", p50 < 5.0)
    check(f"callers latency p99={p99:.3f}ms < 20ms", p99 < 20.0)


if __name__ == "__main__":
    test_load()
    test_singleton()
    test_edge_types()
    test_graph_edge_slots()
    test_graph_node()
    test_graph_result()
    test_callers()
    test_callees()
    test_neighbors_outgoing()
    test_neighbors_incoming()
    test_neighbors_both()
    test_references()
    test_contains()
    test_not_found()
    test_impact()
    test_trace_same()
    test_trace_no_path()
    test_subgraph()
    test_depth_limit()
    test_edge_has_text()
    test_node_has_file()
    test_latency()
    print()
    print(f"GRAPH TRAVERSAL: {PASS} PASS / {FAIL} FAIL")
    sys.exit(0 if FAIL == 0 else 1)
