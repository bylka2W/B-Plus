"""KnowledgeQuery: the only interface the agent loop uses to reach external memory.

Lookup order (each miss cascades down; hits are promoted up):
  HOT   exact-ID LRU        ~ sub-ms
  WARM  full name index     ~ sub-ms
  COLD  mmap column read    ~ ms   (only if not in WARM dict)
  SOURCE file line read     ~ ms   (evidence spans)

Nothing here touches the model weights. It returns a compact, retrieved context
(fact names, relations, evidence source spans + text) that the agent packs into
the prompt before generation.
"""
import re
import time


def _tokens(query):
    toks = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", query)
    # also keep the whole query as a candidate exact name
    return set(toks + [query.strip()])


def _norm(query):
    # normalized key for the L0 exact/semantic cache
    return re.sub(r"[^a-z0-9]", "", query.lower())


class KnowledgeQuery:
    def __init__(self, index):
        self.idx = index
        self.store = index.store
        self.st = index.store.st
        self.qcache = {}  # L0 exact/normalized query cache

    def _read_source(self, fid, l0, l1):
        # L4 SOURCE: go straight to the byte span via the line-offset index
        # (no scanning/reading the whole file -> O(1) even for 466k-line files).
        path = self.idx.file_path(fid)
        try:
            off0, off1 = self.store.byte_span(fid, l0, l1)
            if off1 <= off0:
                return ""
            with open(path, "rb") as f:
                f.seek(off0)
                return f.read(off1 - off0).decode("utf-8", "replace")
        except Exception:
            return ""

    def retrieve(self, query, top_k=8, with_source=True):
        nq = _norm(query)
        if nq in self.qcache:
            r = dict(self.qcache[nq])
            r["cached"] = True
            return r
        t0 = time.perf_counter()
        tiers = {"hot": 0.0, "warm": 0.0, "cold": 0.0, "source": 0.0}
        matched = []  # (sym_id, tier)
        seen = set()
        for name in _tokens(query):
            if name in self.idx.hot:
                th = time.perf_counter()
                ids = self.idx.hot.get(name)
                tiers["hot"] += time.perf_counter() - th
                for s in ids:
                    if s not in seen:
                        seen.add(s); matched.append((s, "hot"))
                continue
            ids = self.idx.syms_by_name(name)
            if ids:
                th = time.perf_counter()
                tiers["warm"] += time.perf_counter() - th
                self.idx.hot.promote(name, ids)
                for s in ids:
                    if s not in seen:
                        seen.add(s); matched.append((s, "warm"))
        # rank: canonical first (most relations; de-prioritise test/vendor paths)
        scored = []
        for sid, tier in matched:
            rels = self.idx.degree(sid)
            fpath = self.idx.file_path(self.store.s_file[sid]).lower()
            penalty = 0.3 if ("test" in fpath or "vendor" in fpath or "venv" in fpath) else 1.0
            scored.append((sid, tier, rels * penalty))
        scored.sort(key=lambda x: x[2], reverse=True)
        ctx_syms = []
        for sid, tier, _ in scored[:top_k]:
            rec = {
                "sid": sid,
                "name": self.st[self.store.s_name[sid]],
                "kind": self.st[self.store.s_kind[sid]],
                "file": self.idx.file_path(self.store.s_file[sid]),
                "lines": (self.store.s_line0[sid], self.store.s_line1[sid]),
                "tier": tier,
                "score": round(_, 1),
            }
            rec["relations"] = self.idx.degree(sid)
            if with_source:
                tc = time.perf_counter()
                evs = self.idx.evidence_of(sid)
                span_text = ""
                if evs:
                    e = evs[0]
                    span_text = self._read_source(self.store.e_file[e], self.store.e_line0[e], self.store.e_line1[e])
                tiers["source"] += time.perf_counter() - tc
                rec["evidence"] = span_text[:400]
            ctx_syms.append(rec)
        total = time.perf_counter() - t0
        result = {"query": query, "total_ms": total * 1000, "tiers_ms": tiers,
                  "matches": ctx_syms, "cached": False}
        self.qcache[nq] = result
        return result
