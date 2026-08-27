import os
import sys
import time
from collections import deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from entity_resolver import get_entity_resolver, ALL_ENTITY_TYPES

REL_CALLS = "CALLS"
REL_CALLED_BY = "CALLED_BY"
REL_DEPENDS_ON = "DEPENDS_ON"
REL_DEPENDENT_OF = "DEPENDENT_OF"
RELREFERENCES = "REFERENCES"
RELREFERENCED_BY = "REFERENCED_BY"
RELUSES_TYPE = "USES_TYPE"
RELTYPE_USER = "TYPE_USER"
RELCONTAINS = "CONTAINS"
RELCONTAINED_BY = "CONTAINED_BY"
RELIMPORTS = "IMPORTS"
RELIMPLEMENTED_BY = "IMPLEMENTED_BY"

EDGE_TYPES = {
    REL_CALLS, REL_CALLED_BY, REL_DEPENDS_ON, REL_DEPENDENT_OF,
    RELREFERENCES, RELREFERENCED_BY, RELUSES_TYPE, RELTYPE_USER,
    RELCONTAINS, RELCONTAINED_BY, RELIMPORTS, RELIMPLEMENTED_BY,
}

ADJACENCY_CALLERS = "callers"
ADJACENCY_CALLEES = "callees"
ADJACENCY_REFERENCES = "references"
ADJACENCY_REFERENCED_BY = "referenced_by"
ADJACENCY_DEPENDENCIES = "dependencies"
ADJACENCY_DEPENDENTS = "dependents"
ADJACENCY_CONTAINS = "contains"
ADJACENCY_TYPES_USED = "types_used"
ADJACENCY_TYPE_USERS = "type_users"

OUTGOING_EDGES = {
    ADJACENCY_CALLEES: REL_CALLED_BY,
    ADJACENCY_DEPENDENCIES: REL_DEPENDS_ON,
    ADJACENCY_REFERENCES: RELREFERENCES,
    ADJACENCY_CONTAINS: RELCONTAINS,
    ADJACENCY_TYPES_USED: RELUSES_TYPE,
}

INCOMING_EDGES = {
    ADJACENCY_CALLERS: REL_CALLS,
    ADJACENCY_DEPENDENTS: REL_DEPENDENT_OF,
    ADJACENCY_REFERENCED_BY: RELREFERENCES,
    ADJACENCY_TYPE_USERS: RELTYPE_USER,
}

REVERSE_EDGE = {
    REL_CALLS: REL_CALLED_BY,
    REL_CALLED_BY: REL_CALLS,
    REL_DEPENDS_ON: REL_DEPENDENT_OF,
    REL_DEPENDENT_OF: REL_DEPENDS_ON,
    RELREFERENCES: RELREFERENCES,
    RELREFERENCES: RELREFERENCES,
    RELUSES_TYPE: RELTYPE_USER,
    RELTYPE_USER: RELUSES_TYPE,
    RELCONTAINS: RELCONTAINED_BY,
    RELCONTAINED_BY: RELCONTAINS,
}

IGNORE_ID = "__IGNORE__"


class GraphEdge:
    __slots__ = (
        "relation_id", "source_id", "target_id", "relation_type",
        "evidence_id", "evidence_file", "evidence_line_start",
        "evidence_line_end", "evidence_text",
    )

    def __init__(self):
        self.relation_id = ""
        self.source_id = ""
        self.target_id = ""
        self.relation_type = ""
        self.evidence_id = ""
        self.evidence_file = ""
        self.evidence_line_start = 0
        self.evidence_line_end = 0
        self.evidence_text = ""

    def to_dict(self):
        return {
            "relation_id": self.relation_id,
            "source_id": self.source_id,
            "target_id": self.target_id,
            "relation_type": self.relation_type,
            "evidence_id": self.evidence_id,
            "evidence_file": self.evidence_file,
            "evidence_line_start": self.evidence_line_start,
            "evidence_line_end": self.evidence_line_end,
            "evidence_text": self.evidence_text,
        }


class GraphNode:
    __slots__ = (
        "concept_id", "name", "entity_type", "file_id", "file_path",
        "line_start", "line_end", "module_id", "module_name",
    )

    def __init__(self):
        self.concept_id = ""
        self.name = ""
        self.entity_type = ""
        self.file_id = ""
        self.file_path = ""
        self.line_start = 0
        self.line_end = 0
        self.module_id = ""
        self.module_name = ""

    def to_dict(self):
        d = {
            "concept_id": self.concept_id,
            "name": self.name,
            "entity_type": self.entity_type,
            "file_id": self.file_id,
            "file_path": self.file_path,
            "line_start": self.line_start,
            "line_end": self.line_end,
            "module_id": self.module_id,
            "module_name": self.module_name,
        }
        return d


class GraphResult:
    __slots__ = (
        "root", "nodes", "edges", "depth", "status", "total_nodes",
        "total_edges", "elapsed_ms",
    )

    def __init__(self):
        self.root = None
        self.nodes = {}
        self.edges = []
        self.depth = 0
        self.status = "NOT_FOUND"
        self.total_nodes = 0
        self.total_edges = 0
        self.elapsed_ms = 0.0

    def to_dict(self):
        return {
            "root": self.root.to_dict() if self.root else None,
            "total_nodes": self.total_nodes,
            "total_edges": self.total_edges,
            "depth": self.depth,
            "status": self.status,
            "elapsed_ms": self.elapsed_ms,
        }


class GraphTraversal:
    def __init__(self, idx=None):
        from indexes import get_fast_index
        self.idx = idx or get_fast_index()
        self.resolver = get_entity_resolver()

    @classmethod
    def load(cls):
        return cls()

    def neighbors(self, concept_id, direction="both", edge_types=None):
        t0 = time.monotonic()
        result = GraphResult()
        node = self._make_node(concept_id)
        if not node:
            result.status = "NOT_FOUND"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result
        result.root = node
        result.nodes[concept_id] = node
        edges = []
        if direction in ("outgoing", "both"):
            edges.extend(self._outgoing_edges(concept_id))
        if direction in ("incoming", "both"):
            edges.extend(self._incoming_edges(concept_id))
        if edge_types:
            edges = [e for e in edges if e.relation_type in edge_types]
        for edge in edges:
            target_id = edge.target_id if edge.source_id == concept_id else edge.source_id
            if target_id == IGNORE_ID:
                continue
            target_node = self._make_node(target_id)
            if target_node:
                result.nodes[target_id] = target_node
            result.edges.append(edge)
        result.total_nodes = len(result.nodes)
        result.total_edges = len(result.edges)
        result.depth = 1
        result.status = "RESOLVED"
        result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return result

    def callers(self, concept_id, depth=1):
        return self._traverse_direction(
            concept_id, ADJACENCY_CALLERS, REL_CALLS, depth
        )

    def callees(self, concept_id, depth=1):
        return self._traverse_direction(
            concept_id, ADJACENCY_CALLEES, REL_CALLED_BY, depth
        )

    def dependencies(self, concept_id, depth=1):
        return self._traverse_direction(
            concept_id, ADJACENCY_DEPENDENCIES, REL_DEPENDS_ON, depth
        )

    def dependents(self, concept_id, depth=1):
        return self._traverse_direction(
            concept_id, ADJACENCY_DEPENDENTS, REL_DEPENDENT_OF, depth
        )

    def references(self, concept_id, depth=1):
        return self._traverse_direction(
            concept_id, ADJACENCY_REFERENCES, RELREFERENCES, depth
        )

    def types_used(self, concept_id, depth=1):
        return self._traverse_direction(
            concept_id, ADJACENCY_TYPES_USED, RELUSES_TYPE, depth
        )

    def type_users(self, type_id, depth=1):
        return self._traverse_direction(
            type_id, ADJACENCY_TYPE_USERS, RELTYPE_USER, depth
        )

    def contains(self, container_id, depth=1):
        return self._traverse_direction(
            container_id, ADJACENCY_CONTAINS, RELCONTAINS, depth
        )

    def trace(self, source_id, target_id, max_depth=5):
        t0 = time.monotonic()
        result = GraphResult()
        source_node = self._make_node(source_id)
        if not source_node:
            result.status = "NOT_FOUND"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result
        result.root = source_node
        result.nodes[source_id] = source_node

        if source_id == target_id:
            result.status = "RESOLVED"
            result.depth = 0
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result

        visited = {source_id}
        queue = deque([(source_id, 0)])
        parent = {source_id: None}
        found = False

        while queue:
            current, depth = queue.popleft()
            if depth >= max_depth:
                continue
            neighbors = set()
            for adj_id in self.idx.get_callers(current):
                neighbors.add(adj_id)
            for adj_id in self.idx.get_callees(current):
                neighbors.add(adj_id)
            for adj_id in self.idx.get_references(current):
                neighbors.add(adj_id)
            for adj_id in self.idx.get_referenced_by(current):
                neighbors.add(adj_id)
            for adj_id in self.idx.get_dependencies(current):
                neighbors.add(adj_id)
            for adj_id in self.idx.get_dependents(current):
                neighbors.add(adj_id)

            for neighbor_id in neighbors_id:
                if neighbor_id in visited:
                    continue
                visited.add(neighbor_id)
                parent[neighbor_id] = current
                if neighbor_id == target_id:
                    found = True
                    break
                queue.append((neighbor_id, depth + 1))
            if found:
                break

        if found:
            path = []
            node_id = target_id
            while node_id is not None:
                path.append(node_id)
                node_id = parent.get(node_id)
            path.reverse()
            for i in range(len(path) - 1):
                src = path[i]
                tgt = path[i + 1]
                edge = self._find_edge(src, tgt)
                if edge:
                    result.edges.append(edge)
            for nid in path:
                node = self._make_node(nid)
                if node:
                    result.nodes[nid] = node
            result.status = "RESOLVED"
            result.depth = len(path) - 1
        else:
            result.status = "NO_PATH"

        result.total_nodes = len(result.nodes)
        result.total_edges = len(result.edges)
        result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return result

    def impact(self, concept_id, depth=3):
        t0 = time.monotonic()
        result = GraphResult()
        node = self._make_node(concept_id)
        if not node:
            result.status = "NOT_FOUND"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result
        result.root = node
        result.nodes[concept_id] = node

        visited = {concept_id}
        frontier = [concept_id]
        current_depth = 0

        while frontier and current_depth < depth:
            next_frontier = []
            for nid in frontier:
                callers = self.idx.get_callers(nid)
                dependents = self.idx.get_dependents(nid)
                referenced_by = self.idx.get_referenced_by(nid)
                for adj_id in callers + dependents + referenced_by:
                    if adj_id not in visited:
                        visited.add(adj_id)
                        adj_node = self._make_node(adj_id)
                        if adj_node:
                            result.nodes[adj_id] = adj_node
                        edge = self._find_edge(adj_id, nid)
                        if edge:
                            result.edges.append(edge)
                        next_frontier.append(adj_id)
            frontier = next_frontier
            current_depth += 1

        result.total_nodes = len(result.nodes)
        result.total_edges = len(result.edges)
        result.depth = current_depth
        result.status = "RESOLVED"
        result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return result

    def subgraph(self, concept_ids, depth=1):
        t0 = time.monotonic()
        result = GraphResult()
        all_nodes = set(concept_ids)
        all_edges = []
        for cid in concept_ids:
            node = self._make_node(cid)
            if node:
                result.nodes[cid] = node
            for adj_id in self.idx.get_callers(cid):
                if adj_id not in all_nodes:
                    all_nodes.add(adj_id)
                    n = self._make_node(adj_id)
                    if n:
                        result.nodes[adj_id] = n
                edge = self._find_edge(adj_id, cid)
                if edge:
                    all_edges.append(edge)
            for adj_id in self.idx.get_callees(cid):
                if adj_id not in all_nodes:
                    all_nodes.add(adj_id)
                    n = self._make_node(adj_id)
                    if n:
                        result.nodes[adj_id] = n
                edge = self._find_edge(cid, adj_id)
                if edge:
                    all_edges.append(edge)
            for adj_id in self.idx.get_references(cid):
                if adj_id not in all_nodes:
                    all_nodes.add(adj_id)
                    n = self._make_node(adj_id)
                    if n:
                        result.nodes[adj_id] = n
                edge = self._find_edge(adj_id, cid)
                if edge:
                    all_edges.append(edge)

        seen_edges = set()
        for e in all_edges:
            key = (e.source_id, e.target_id, e.relation_type)
            if key not in seen_edges:
                seen_edges.add(key)
                result.edges.append(e)

        result.root = result.nodes.get(concept_ids[0]) if concept_ids else None
        result.total_nodes = len(result.nodes)
        result.total_edges = len(result.edges)
        result.depth = depth
        result.status = "RESOLVED" if result.nodes else "NOT_FOUND"
        result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return result

    def _traverse_direction(self, concept_id, adjacency_key, edge_type, depth):
        t0 = time.monotonic()
        result = GraphResult()
        node = self._make_node(concept_id)
        if not node:
            result.status = "NOT_FOUND"
            result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
            return result
        result.root = node
        result.nodes[concept_id] = node

        visited = {concept_id}
        frontier = [concept_id]
        current_depth = 0

        while frontier and current_depth < depth:
            next_frontier = []
            for nid in frontier:
                adj_ids = self._get_adjacency(nid, adjacency_key)
                for adj_id in adj_ids:
                    if adj_id in visited:
                        continue
                    visited.add(adj_id)
                    adj_node = self._make_node(adj_id)
                    if adj_node:
                        result.nodes[adj_id] = adj_node
                    edge = self._build_edge(nid, adj_id, edge_type)
                    if edge:
                        result.edges.append(edge)
                    next_frontier.append(adj_id)
            frontier = next_frontier
            current_depth += 1

        result.total_nodes = len(result.nodes)
        result.total_edges = len(result.edges)
        result.depth = current_depth
        result.status = "RESOLVED"
        result.elapsed_ms = round((time.monotonic() - t0) * 1000, 3)
        return result

    def _make_node(self, concept_id):
        c = self.idx.concept_by_id.get(concept_id)
        if not c:
            return None
        node = GraphNode()
        node.concept_id = concept_id
        node.name = c.get("canonical_name", "")
        node.entity_type = c.get("concept_type", "")
        node.file_id = c.get("file_id", "")
        file_entry = self.idx.file_by_id.get(node.file_id)
        if file_entry:
            node.file_path = file_entry.get("path", "")
        node.line_start = c.get("line_start", 0)
        node.line_end = c.get("line_end", 0)
        module_id = self.idx.concept_module.get(concept_id)
        if module_id:
            node.module_id = module_id
            mc = self.idx.concept_by_id.get(module_id)
            if mc:
                node.module_name = mc.get("canonical_name", "")
        return node

    def _build_edge(self, source_id, target_id, relation_type):
        edge = GraphEdge()
        edge.source_id = source_id
        edge.target_id = target_id
        edge.relation_type = relation_type
        for rid in self.idx.get_relations_by_source(source_id):
            r = self.idx.relation_by_id.get(rid)
            if r and r.get("to_concept") == target_id:
                edge.relation_id = rid
                self._attach_edge_evidence(edge, r)
                return edge
        for rid in self.idx.get_relations_by_target(source_id):
            r = self.idx.relation_by_id.get(rid)
            if r and r.get("from_concept") == target_id:
                edge.relation_id = rid
                edge.relation_type = r.get("relation_type", relation_type)
                self._attach_edge_evidence(edge, r)
                return edge
        return edge

    def _find_edge(self, source_id, target_id):
        for rid in self.idx.get_relations_by_source(source_id):
            r = self.idx.relation_by_id.get(rid)
            if r and r.get("to_concept") == target_id:
                edge = GraphEdge()
                edge.source_id = source_id
                edge.target_id = target_id
                edge.relation_type = r.get("relation_type", "")
                edge.relation_id = rid
                self._attach_edge_evidence(edge, r)
                return edge
        for rid in self.idx.get_relations_by_target(source_id):
            r = self.idx.relation_by_id.get(rid)
            if r and r.get("from_concept") == target_id:
                edge = GraphEdge()
                edge.source_id = source_id
                edge.target_id = target_id
                edge.relation_type = r.get("relation_type", "")
                edge.relation_id = rid
                self._attach_edge_evidence(edge, r)
                return edge
        return None

    def _attach_edge_evidence(self, edge, relation):
        fact_ids = relation.get("evidence_fact_ids", [])
        if not fact_ids:
            return
        fid = fact_ids[0]
        fact = self.idx.fact_by_id.get(fid)
        if not fact:
            return
        edge.evidence_id = fact.get("evidence_id", "")
        edge.evidence_file = fact.get("source_file", "")
        edge.evidence_line_start = fact.get("line_start", 0)
        edge.evidence_line_end = fact.get("line_end", 0)
        ev = self.idx.evidence_by_id.get(edge.evidence_id)
        if ev:
            edge.evidence_text = ev.get("text", "")

    def _outgoing_edges(self, concept_id):
        edges = []
        for adj_key, rel_type in OUTGOING_EDGES.items():
            getter = getattr(self.idx, f"get_{adj_key}", None)
            if getter:
                for adj_id in getter(concept_id):
                    edge = self._build_edge(concept_id, adj_id, rel_type)
                    edges.append(edge)
        return edges

    def _incoming_edges(self, concept_id):
        edges = []
        for adj_key, rel_type in INCOMING_EDGES.items():
            getter = getattr(self.idx, f"get_{adj_key}", None)
            if getter:
                for adj_id in getter(concept_id):
                    edge = self._build_edge(adj_id, concept_id, rel_type)
                    edges.append(edge)
        return edges

    def _get_adjacency(self, concept_id, key):
        if key == ADJACENCY_CALLERS:
            return self.idx.get_callers(concept_id)
        if key == ADJACENCY_CALLEES:
            return self.idx.get_callees(concept_id)
        if key == ADJACENCY_REFERENCES:
            return self.idx.get_references(concept_id)
        if key == ADJACENCY_REFERENCED_BY:
            return self.idx.get_referenced_by(concept_id)
        if key == ADJACENCY_DEPENDENCIES:
            return self.idx.get_dependencies(concept_id)
        if key == ADJACENCY_DEPENDENTS:
            return self.idx.get_dependents(concept_id)
        if key == ADJACENCY_CONTAINS:
            return self.idx.get_contains(concept_id)
        if key == ADJACENCY_TYPES_USED:
            return self.idx.get_types_used(concept_id)
        if key == ADJACENCY_TYPE_USERS:
            return self.idx.get_type_users(concept_id)
        return []


_instance = None


def get_graph_traversal():
    global _instance
    if _instance is None:
        _instance = GraphTraversal.load()
    return _instance


def main():
    gt = GraphTraversal.load()
    print("GRAPH TRAVERSAL READY")

    cids = gt.idx.resolve_concept("foldConstantOp")
    if cids:
        cid = cids[0]
        r = gt.callers(cid)
        print(f"\nfoldConstantOp CALLERS: {r.total_nodes} nodes, {r.total_edges} edges")
        for eid, e in enumerate(r.edges[:3]):
            print(f"  edge {eid+1}: {e.source_id} --[{e.relation_type}]--> {e.target_id}")
            print(f"    evidence: {e.evidence_id} {e.evidence_file}:{e.evidence_line_start}-{e.evidence_line_end}")

        r = gt.callees(cid)
        print(f"\nfoldConstantOp CALLEES: {r.total_nodes} nodes, {r.total_edges} edges")
        for eid, e in enumerate(r.edges[:3]):
            print(f"  edge {eid+1}: {e.source_id} --[{e.relation_type}]--> {e.target_id}")

        r = gt.neighbors(cid)
        print(f"\nfoldConstantOp NEIGHBORS: {r.total_nodes} nodes, {r.total_edges} edges")

        r = gt.impact(cid, depth=2)
        print(f"\nfoldConstantOp IMPACT depth=2: {r.total_nodes} nodes, {r.total_edges} edges")

    sys.exit(0)


if __name__ == "__main__":
    main()
