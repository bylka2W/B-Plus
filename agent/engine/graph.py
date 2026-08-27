import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import (
    CONCEPTS_PATH,
    FACTS_PATH,
    GRAPH_PATH,
    SEMANTIC_RELATIONS_PATH,
    load_json,
    save_json,
)
from source_store import SourceStore

ADJACENCY_RULES = {
    "CALLS": ("callees", "callers"),
    "REFERENCES": ("references", "referenced_by"),
    "USES_TYPE": ("types_used", "type_users"),
    "DEPENDS_ON": ("dependencies", "dependents"),
}


def _idx(adj, key, val):
    arr = adj.setdefault(key, [])
    if val not in arr:
        arr.append(val)


def build_graph(facts_doc, concepts_doc, relations_doc, files=None):
    facts_ev = {f["fact_id"]: f["evidence_id"] for f in facts_doc["items"]}
    modules = {}
    file_module = {}
    by_name = {}
    by_name_lower = {}
    module_concepts = {}
    concept_module = {}
    concept_evidence = {}

    adj = {
        "callees": {}, "callers": {},
        "references": {}, "referenced_by": {},
        "types_used": {}, "type_users": {},
        "dependencies": {}, "dependents": {},
        "contains": {},
    }

    for c in concepts_doc["items"]:
        cid = c["concept_id"]
        name = c["canonical_name"]
        by_name.setdefault(name, []).append(cid)
        by_name_lower.setdefault(name.lower(), []).append(cid)
        ev = sorted(
            {facts_ev[fid] for fid in c["fact_ids"] if fid in facts_ev}
        )
        if ev:
            concept_evidence[cid] = ev
        if c["concept_type"] == "MODULE":
            modules[cid] = True
            file_module[c["file_id"]] = cid
            module_concepts.setdefault(cid, [])

    belongs = {}
    defines = {}
    for r in relations_doc["items"]:
        t = r["relation_type"]
        a = r["from_concept"]
        b = r["to_concept"]
        if t == "BELONGS_TO":
            belongs[a] = b
            _idx(module_concepts, b, a)
        elif t == "DEFINES":
            defines.setdefault(a, [])
            if b not in defines[a]:
                defines[a].append(b)

    for cid, mid in belongs.items():
        concept_module[cid] = mid

    file_paths = {}
    if files:
        for path, entry in files.items():
            mid = file_module.get(entry["id"])
            if mid is not None:
                file_paths[path] = mid

    for r in relations_doc["items"]:
        rule = ADJACENCY_RULES.get(r["relation_type"])
        if rule is None:
            continue
        fwd, rev = rule
        a = r["from_concept"]
        b = r["to_concept"]
        _idx(adj[fwd], a, b)
        _idx(adj[rev], b, a)

    for m, kids in defines.items():
        for k in sorted(kids):
            _idx(module_concepts, m, k)

    for r in relations_doc["items"]:
        if r["relation_type"] != "CONTAINS":
            continue
        _idx(adj["contains"], r["from_concept"], r["to_concept"])

    indexes = {
        "by_name": {k: sorted(v) for k, v in by_name.items()},
        "by_name_lower": {k: sorted(v) for k, v in by_name_lower.items()},
        "file_module": file_module,
        "file_paths": file_paths,
        "concept_module": concept_module,
        "module_concepts": {k: sorted(set(v)) for k, v in module_concepts.items()},
        "concept_evidence": concept_evidence,
    }
    indexes.update({k: {n: sorted(v) for n, v in adj[k].items()} for k in adj})
    return {"indexes": indexes, "modules": modules}


SCALAR_SECTIONS = {"concept_module", "file_module", "file_paths"}
NAME_SECTIONS = {"by_name", "by_name_lower"}


def validate_graph(doc, store, concepts_doc, relations_doc):
    idx = doc["indexes"]
    concepts = {c["concept_id"]: c for c in concepts_doc["items"]}
    counters = {
        "unknown_ids": 0,
        "unsorted_arrays": 0,
        "duplicate_entries": 0,
        "missing_adjacency": 0,
        "missing_module_map": 0,
        "missing_name_index": 0,
        "missing_evidence": 0,
        "extra_adjacency": 0,
    }

    def check_array(arr):
        if arr != sorted(arr):
            counters["unsorted_arrays"] += 1
        if len(arr) != len(set(arr)):
            counters["duplicate_entries"] += 1

    for section, mapping in idx.items():
        for key, val in mapping.items():
            if section in SCALAR_SECTIONS:
                if val not in concepts:
                    counters["unknown_ids"] += 1
                continue
            if section in NAME_SECTIONS:
                for cid in val:
                    if cid not in concepts:
                        counters["unknown_ids"] += 1
                continue
            if not isinstance(val, list):
                counters["unsorted_arrays"] += 1
                continue
            check_array(val)
            if section == "concept_evidence":
                if key not in concepts:
                    counters["unknown_ids"] += 1
                for e in val:
                    if e not in store.evidence_by_id:
                        counters["missing_evidence"] += 1
                continue
            if key not in concepts:
                counters["unknown_ids"] += 1
            for x in val:
                if x not in concepts:
                    counters["unknown_ids"] += 1

    expected = {}
    for r in relations_doc["items"]:
        rule = ADJACENCY_RULES.get(r["relation_type"])
        if rule:
            fwd, rev = rule
            expected.setdefault(fwd, set()).add(
                (r["from_concept"], r["to_concept"])
            )
            expected.setdefault(rev, set()).add(
                (r["to_concept"], r["from_concept"])
            )
        elif r["relation_type"] == "CONTAINS":
            expected.setdefault("contains", set()).add(
                (r["from_concept"], r["to_concept"])
            )
    for section, pairs in expected.items():
        have = {
            (k, x) for k, arr in idx[section].items() for x in arr
        }
        counters["missing_adjacency"] += len(pairs - have)
        counters["extra_adjacency"] += len(have - pairs)

    for cid, c in concepts.items():
        if c["concept_type"] == "MODULE":
            continue
        if cid not in idx["concept_module"]:
            counters["missing_module_map"] += 1
        if c["canonical_name"] not in idx["by_name"]:
            counters["missing_name_index"] += 1

    gates = {
        "INDEX_INTEGRITY": (
            counters["unsorted_arrays"] == 0
            and counters["duplicate_entries"] == 0
            and counters["unknown_ids"] == 0
        ),
        "ADJACENCY_SYMMETRY": counters["missing_adjacency"] == 0,
        "RELATION_COVERAGE": (
            counters["missing_adjacency"] == 0
            and counters["extra_adjacency"] == 0
        ),
        "MODULE_COVERAGE": counters["missing_module_map"] == 0,
        "NAME_INDEX": counters["missing_name_index"] == 0,
        "EVIDENCE_LINKAGE": counters["missing_evidence"] == 0,
        "CONCEPT_INTEGRITY": len(concepts) == concepts_doc["concept_count"],
    }
    return counters, gates


class KnowledgeGraph:
    def __init__(self, graph_doc, concepts_doc):
        self.doc = graph_doc
        self.idx = graph_doc["indexes"]
        self.concepts = {c["concept_id"]: c for c in concepts_doc["items"]}

    @classmethod
    def load(cls):
        graph_doc = load_json(GRAPH_PATH)
        concepts_doc = load_json(CONCEPTS_PATH)
        return cls(graph_doc, concepts_doc)

    def exists(self, cid):
        return cid in self.concepts

    def get_concept(self, cid):
        return self.concepts.get(cid)

    def find_symbol(self, name, ignore_case=False):
        section = "by_name_lower" if ignore_case else "by_name"
        return self.idx[section].get(name if not ignore_case else name.lower(), [])

    def get_module(self, cid):
        return self.idx["concept_module"].get(cid)

    def module_of_file(self, file_id):
        return self.idx["file_module"].get(file_id)

    def module_concepts(self, mid):
        return self.idx["module_concepts"].get(mid, [])

    def callers(self, cid):
        return self.idx["callers"].get(cid, [])

    def callees(self, cid):
        return self.idx["callees"].get(cid, [])

    def references(self, cid):
        return self.idx["references"].get(cid, [])

    def referenced_by(self, cid):
        return self.idx["referenced_by"].get(cid, [])

    def types_used(self, cid):
        return self.idx["types_used"].get(cid, [])

    def type_users(self, tcid):
        return self.idx["type_users"].get(tcid, [])

    def dependencies(self, mid):
        return self.idx["dependencies"].get(mid, [])

    def dependents(self, mid):
        return self.idx["dependents"].get(mid, [])

    def contains(self, cid):
        return self.idx["contains"].get(cid, [])

    def evidence_ids(self, cid):
        return self.idx["concept_evidence"].get(cid, [])


def main():
    store = SourceStore.load()
    errs = store.validate(deep=True)
    if errs:
        print("STORE ERRORS:", len(errs))
        sys.exit(2)
    facts_doc = load_json(FACTS_PATH)
    concepts_doc = load_json(CONCEPTS_PATH)
    relations_doc = load_json(SEMANTIC_RELATIONS_PATH)

    built = build_graph(
        facts_doc, concepts_doc, relations_doc, files=store.files_by_path
    )
    doc = {
        "schema": "knowledge_graph",
        "version": 1,
        "root": concepts_doc.get("root", ""),
        "concept_count": concepts_doc["concept_count"],
        "relation_count": relations_doc["relation_count"],
        "indexes": built["indexes"],
    }
    save_json(GRAPH_PATH, doc)

    counters, gates = validate_graph(doc, store, concepts_doc, relations_doc)
    adj_sections = (
        "callees", "callers", "references", "referenced_by",
        "types_used", "type_users", "dependencies", "dependents",
        "contains",
    )
    edge_total = sum(
        len(v) for k in adj_sections for v in doc["indexes"][k].values()
    )
    print(f"GRAPH NODES: {doc['concept_count']}")
    print(f"GRAPH ADJACENCY KEYS: {edge_total}")
    sizes = sorted(
        ((k, len(v)) for k, v in doc["indexes"].items()),
        key=lambda kv: kv[0],
    )
    for k, n in sizes:
        print(f"IDX {k}: {n}")
    for k in sorted(counters):
        print(f"{k.upper()}: {counters[k]}")
    for k in sorted(gates):
        print(f"{k}: {'PASS' if gates[k] else 'FAIL'}")
    ok = all(v == 0 for v in counters.values()) and all(gates.values())
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
