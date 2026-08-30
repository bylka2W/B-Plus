"""Fact / Concept compression layer for the knowledge pyramid (L0 working context).

Turns the multi-million-row EVIDENCE / RELATION store into compact, model-facing
FACTs and a small CONCEPT set, so the agent loop never has to ship thousands of
raw source lines to the model. Evidence -> Fact -> Concept -> compact context.

  SOURCE  (raw file spans)      -- only on demand / as proof
    |  extract
  EVIDENCE (def span + hash)
    |  summarise (relation-degree aware)
  FACT    (name/kind/file:lines + calls/imports/used-by)   <-- what we send
    |  aggregate high-degree
  CONCEPT (top API surfaces)                               <-- seed HOT
"""
import sys
sys.path.insert(0, r"C:\B-Plus\agent\agent b+")
from core.memory_engine.index import KnowledgeIndex


class FactCompressor:
    def __init__(self, store, idx: KnowledgeIndex):
        self.store = store
        self.idx = idx
        self.st = store.st

    # ---- helpers ----
    def _rel_target_name(self, ridx):
        if self.store.r_to_type[ridx] == 0:
            sid = self.store.r_to[ridx]
            return self.st[self.store.s_name[sid]]
        return self.st[self.store.r_to[ridx]]

    def calls_of(self, sid):
        out = []
        for ridx in self.idx.relations_of(sid):
            if self.st[self.store.r_kind[ridx]] == "CALLS":
                out.append(self._rel_target_name(ridx))
        return out

    def imports_of(self, sid):
        fid = self.store.s_file[sid]
        out = []
        for ridx in self.idx.relations_of(fid):
            if self.st[self.store.r_kind[ridx]] == "IMPORTS":
                out.append(self.idx.file_path(self.store.r_to[ridx]))
        return out

    def used_by(self, sid, limit=8):
        return [self.st[self.store.s_name[self.store.r_to[r]]]
                for r in self.idx.callers_of(sid)[:limit]
                if self.store.r_to_type[r] == 0]

    # ---- FACT (compact, 1-4 lines) ----
    def fact_text(self, sid, max_calls=6, max_used=4):
        name = self.st[self.store.s_name[sid]]
        kind = self.st[self.store.s_kind[sid]]
        fid = self.store.s_file[sid]
        l0 = self.store.s_line0[sid]; l1 = self.store.s_line1[sid]
        path = self.idx.file_path(fid)
        calls = self.calls_of(sid)[:max_calls]
        imps = self.imports_of(sid)
        used = self.used_by(sid, max_used)
        lines = [f"{name} ({kind}) @ {path}:{l0}-{l1}"]
        if calls:
            lines.append("  calls: " + ", ".join(calls))
        if imps:
            lines.append("  imports: " + ", ".join(imps[:6]))
        if used:
            lines.append(f"  used-by: {len(self.idx.callers_of(sid))} syms (" + ", ".join(used) + ")")
        return "\n".join(lines)

    # ---- CONCEPT (high-degree API surfaces) ----
    def concepts(self, top_n=24, min_calls=3):
        scored = []
        for sid in range(len(self.store.s_file)):
            deg = self.idx.degree(sid)
            if deg >= min_calls:
                scored.append((deg, sid))
        scored.sort(reverse=True)
        out = []
        for deg, sid in scored[:top_n]:
            out.append((self.st[self.store.s_name[sid]],
                        self.st[self.store.s_kind[sid]],
                        self.idx.file_path(self.store.s_file[sid]),
                        deg))
        return out

    # ---- compact context for a set of symbol matches ----
    def compact_context(self, matches, top_facts=12, top_evidence=4, kq=None):
        """matches: list from KnowledgeQuery.retrieve (already canonical-ranked)."""
        lines = ["# Retrieved knowledge (compact)", ""]
        for i, m in enumerate(matches[:top_facts]):
            sid = m.get("sid")
            if sid is None:
                lines.append(f"- {m['name']} ({m['kind']}) @ {m['file']}:{m['lines']}")
                continue
            lines.append(self.fact_text(sid))
            if kq is not None and i < top_evidence and m.get("evidence"):
                lines.append(f"  # proof ({m['file']}:{m['lines'][0]}-{m['lines'][1]}):")
                for sl in m["evidence"].split("\n")[:12]:
                    lines.append("  | " + sl)
            lines.append("")
        return "\n".join(lines)
