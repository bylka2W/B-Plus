import bisect
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from graph import KnowledgeGraph

PREFIX_LIMIT = 50

RESOLVED = "RESOLVED"
AMBIGUOUS = "AMBIGUOUS"
NOT_FOUND = "NOT_FOUND"


def _summary(concepts, module_of, cid):
    c = concepts[cid]
    return {
        "concept_id": cid,
        "concept_type": c["concept_type"],
        "name": c["canonical_name"],
        "file_id": c["file_id"],
        "module_id": module_of.get(cid),
    }


class Search:
    def __init__(self, kg):
        self.kg = kg
        self.concepts = kg.concepts
        self.module_of = kg.idx["concept_module"]
        self.by_name = kg.idx["by_name"]
        self.by_name_lower = kg.idx["by_name_lower"]
        self.file_paths = kg.idx["file_paths"]
        self._keys_lower = sorted(self.by_name_lower.keys())
        self._summaries = {
            cid: _summary(self.concepts, self.module_of, cid)
            for cid in self.concepts
        }
        self._modules = sorted(
            (
                cid
                for cid, c in self.concepts.items()
                if c["concept_type"] == "MODULE"
            ),
            key=lambda cid: self.concepts[cid]["canonical_name"],
        )
        self._mod_by_base = {}
        self._mod_by_stem = {}
        for cid in self._modules:
            base = self.concepts[cid]["canonical_name"].rsplit("/", 1)[-1]
            self._mod_by_base.setdefault(base, []).append(cid)
            stem = base.rsplit(".", 1)[0] if "." in base else base
            self._mod_by_stem.setdefault(stem.lower(), []).append(cid)
        self._file_paths_lower = {k.lower(): v for k, v in self.file_paths.items()}

    @classmethod
    def load(cls):
        return cls(KnowledgeGraph.load())

    def _payload(self, kind, targets, items):
        if not targets:
            status = NOT_FOUND
        elif len(targets) > 1:
            status = AMBIGUOUS
        else:
            status = RESOLVED
        return {
            "status": status,
            "query_kind": kind,
            "targets": targets,
            "count": len(items),
            "items": items,
        }

    def _resolve(self, ref):
        if ref in self.concepts:
            return [ref]
        ids = self.by_name.get(ref)
        if ids:
            return list(ids)
        ids = self.by_name_lower.get(ref.lower())
        if ids:
            return list(ids)
        return []

    def find_symbol(self, name):
        ids = self._resolve(name)
        targets = [self._summaries[i] for i in ids]
        items = targets
        return self._payload("SYMBOL", targets, items)

    def find_symbols(self, prefix, limit=PREFIX_LIMIT):
        p = prefix.lower()
        i = bisect.bisect_left(self._keys_lower, p)
        collected = []
        truncated = False
        while i < len(self._keys_lower) and not truncated:
            key = self._keys_lower[i]
            if not key.startswith(p):
                break
            for cid in self.by_name_lower[key]:
                if len(collected) >= limit:
                    truncated = True
                    break
                collected.append(self._summaries[cid])
            i += 1
        collected.sort(key=lambda s: (s["name"].lower(), s["concept_id"]))
        return {
            "status": RESOLVED if collected else NOT_FOUND,
            "query_kind": "SYMBOL_PREFIX",
            "prefix": prefix,
            "count": len(collected),
            "truncated": truncated,
            "items": collected,
        }

    def _resolve_module(self, name):
        mods = [
            cid
            for cid in self._modules
            if self.concepts[cid]["canonical_name"] == name
        ]
        if not mods:
            mods = self._mod_by_base.get(name.rsplit("/", 1)[-1], [])
        if not mods:
            stem = name.rsplit("/", 1)[-1].rsplit(".", 1)[0]
            mods = self._mod_by_stem.get(stem.lower(), [])
        return mods

    def find_module(self, name):
        ids = self._resolve_module(name)
        targets = [self._summaries[i] for i in ids]
        return self._payload("MODULE", targets, targets)

    def find_file(self, path):
        mid = self.file_paths.get(path) or self._file_paths_lower.get(
            path.lower()
        )
        if mid is None:
            return self._payload("FILE", [], [])
        target = self._summaries[mid]
        item = dict(target)
        item["matched_path"] = path
        return self._payload("FILE", [target], [item])

    def _adjacent(self, kind, ref, section):
        ids = self._resolve(ref)
        targets = [self._summaries[i] for i in ids]
        if not ids:
            return self._payload(kind, [], [])
        seen = set()
        items = []
        for cid in ids:
            for x in self.kg.idx[section].get(cid, []):
                if x not in seen:
                    seen.add(x)
                    items.append(self._summaries[x])
        items.sort(key=lambda s: (s["concept_type"], s["name"], s["concept_id"]))
        return self._payload(kind, targets, items)

    def find_callers(self, symbol):
        return self._adjacent("CALLERS", symbol, "callers")

    def find_callees(self, symbol):
        return self._adjacent("CALLEES", symbol, "callees")

    def find_references(self, symbol):
        return self._adjacent("REFERENCES", symbol, "references")

    def find_referenced_by(self, symbol):
        return self._adjacent("REFERENCED_BY", symbol, "referenced_by")

    def find_types_used(self, symbol):
        return self._adjacent("TYPES_USED", symbol, "types_used")

    def find_type_users(self, type_ref):
        return self._adjacent("TYPE_USERS", type_ref, "type_users")

    def find_contains(self, container):
        return self._adjacent("CONTAINS", container, "contains")

    def _module_adjacent(self, kind, name, section):
        ids = self._resolve_module(name)
        if not ids and name in self.concepts:
            ids = [name]
        targets = [self._summaries[i] for i in ids]
        if not ids:
            return self._payload(kind, [], [])
        seen = set()
        items = []
        for cid in ids:
            for x in self.kg.idx[section].get(cid, []):
                if x not in seen:
                    seen.add(x)
                    items.append(self._summaries[x])
        items.sort(key=lambda s: (s["concept_type"], s["name"], s["concept_id"]))
        return self._payload(kind, targets, items)

    def find_dependencies(self, module):
        return self._module_adjacent("DEPENDENCIES", module, "dependencies")

    def find_dependents(self, module):
        return self._module_adjacent("DEPENDENTS", module, "dependents")


def main():
    s = Search.load()
    print("SEARCH READY")
    print(f"CONCEPTS: {len(s.concepts)}")
    print(f"NAMES: {len(s.by_name)}")
    print(f"MODULES: {len(s._modules)}")
    print(f"FILES: {len(s.file_paths)}")
    sys.exit(0)


if __name__ == "__main__":
    main()
