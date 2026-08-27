import os
import sys
from collections import deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from context import ContextBuilder


def _env(tool, args, status, data, error=None):
    out = {
        "tool": tool,
        "args": args,
        "status": status,
        "provenance": "graph+facts+evidence",
        "data": data,
    }
    if error is not None:
        out["error"] = error
    return out


class AgentTools:
    def __init__(self, cb):
        self.cb = cb
        self.search = cb.qe.search

    @classmethod
    def load(cls):
        return cls(ContextBuilder.load())

    def call(self, tool_name, **args):
        fn = getattr(self, tool_name, None)
        if fn is None or not getattr(fn, "_is_tool", False):
            return _env(tool_name, args, "UNKNOWN_TOOL", None,
                        error=f"no such tool: {tool_name}")
        try:
            return fn(**args)
        except Exception as exc:
            return _env(tool_name, args, "ERROR", None, error=str(exc))

    @staticmethod
    def _tool(fn):
        fn._is_tool = True
        return fn

    def _resolved_or_404(self, tool, args, result):
        return _env(tool, args, result["status"], result)

    @staticmethod
    def _bfs_paths(start, goal, adj, max_depth):
        if start == goal:
            return [[start]]
        paths = []
        visited = {start}
        q = deque([(start, [start])])
        while q and len(paths) < 3:
            node, path = q.popleft()
            if len(path) > max_depth:
                continue
            for nxt in sorted(adj.get(node, [])):
                if nxt in visited and nxt != goal:
                    continue
                npath = path + [nxt]
                if nxt == goal:
                    paths.append(npath)
                    continue
                if nxt in visited:
                    continue
                visited.add(nxt)
                q.append((nxt, npath))
        return paths

    @_tool
    def search_symbol(self, name):
        r = self.search.find_symbol(name)
        return self._resolved_or_404("search_symbol", {"name": name}, r)

    @_tool
    def search_symbols(self, prefix, limit=25):
        r = self.search.find_symbols(prefix, limit=limit)
        return self._resolved_or_404(
            "search_symbols", {"prefix": prefix, "limit": limit}, r
        )

    @_tool
    def find_callers(self, symbol):
        r = self.search.find_callers(symbol)
        return self._resolved_or_404("find_callers", {"symbol": symbol}, r)

    @_tool
    def find_callees(self, symbol):
        r = self.search.find_callees(symbol)
        return self._resolved_or_404("find_callees", {"symbol": symbol}, r)

    @_tool
    def find_references(self, symbol):
        r = self.search.find_references(symbol)
        return self._resolved_or_404("find_references", {"symbol": symbol}, r)

    @_tool
    def find_type_users(self, type_ref):
        r = self.search.find_type_users(type_ref)
        return self._resolved_or_404("find_type_users", {"type": type_ref}, r)

    @_tool
    def find_dependencies(self, module):
        r = self.search.find_dependencies(module)
        return self._resolved_or_404("find_dependencies", {"module": module}, r)

    @_tool
    def find_dependents(self, module):
        r = self.search.find_dependents(module)
        return self._resolved_or_404("find_dependents", {"module": module}, r)

    @_tool
    def inspect_symbol(self, symbol):
        qr = self.cb.qe.query("DEFINITION", symbol)
        pack = self.cb.build(qr)
        return _env(
            "inspect_symbol", {"symbol": symbol}, pack["status"], pack
        )

    @_tool
    def inspect_module(self, module):
        qr = self.cb.qe.query("MODULE", module)
        deps = self.cb.qe.query("DEPENDENCIES", module)
        dents = self.cb.qe.query("DEPENDENTS", module)
        members = []
        if qr["targets"]:
            mid = qr["targets"][0]["concept_id"]
            members = self.search.module_concepts(mid)
        data = {
            "module": qr["targets"][0] if qr["targets"] else None,
            "member_count": len(members),
            "dependencies": deps["items"][:15],
            "dependents": dents["items"][:15],
            "dependency_count": deps["count"],
            "dependent_count": dents["count"],
        }
        status = qr["status"] if qr["targets"] else "NOT_FOUND"
        return _env("inspect_module", {"module": module}, status, data)

    @_tool
    def get_evidence(self, concept):
        ids = self.search._resolve(concept)
        if not ids:
            return _env("get_evidence", {"concept": concept}, "NOT_FOUND", [])
        eids = []
        for cid in ids:
            eids.extend(
                self.search.kg.idx["concept_evidence"].get(cid, [])[:3]
            )
        seen, uniq = set(), []
        for e in eids:
            if e not in seen:
                seen.add(e)
                uniq.append(e)
        chunks = self.cb._evidence_block(uniq, max_evidence=6)
        return _env("get_evidence", {"concept": concept},
                    "RESOLVED" if chunks else "EMPTY", chunks)

    @_tool
    def trace_dependency(self, from_module, to_module, max_depth=4):
        mods = self.search._resolve_module(from_module)
        goals = self.search._resolve_module(to_module)
        if not mods or not goals:
            return _env(
                "trace_dependency",
                {"from": from_module, "to": to_module},
                "NOT_FOUND", [],
            )
        start, goal = mods[0], goals[0]
        adj = self.search.kg.idx["dependencies"]
        paths = self._bfs_paths(start, goal, adj, max_depth)
        data = [
            {
                "hops": len(p) - 1,
                "modules": [self.search._summaries[m] for m in p],
            }
            for p in paths
        ]
        return _env(
            "trace_dependency",
            {"from": from_module, "to": to_module, "max_depth": max_depth},
            "RESOLVED" if data else "NOT_FOUND",
            data,
        )


def main():
    t = AgentTools.load()
    demo = t.call("inspect_symbol", symbol="foldConstantOp")
    print(f"AGENT TOOLS READY: inspect_symbol -> {demo['status']} "
          f"(claims={len(demo['data']['claims'])}, "
          f"conf={demo['data']['confidence']})")
    sys.exit(0)


if __name__ == "__main__":
    main()
