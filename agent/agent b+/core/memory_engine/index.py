"""WARM/HOT index over the dense MemoryStore (pyramid tiers).

Replaces the old multi-million-entry Python dicts (name_to_syms, sym_relations,
sym_evidence) with COMPACT CSR / sorted-array structures built once from the
store's dense columns. This is what keeps RAM flat instead of ballooning:

  HOT  (L0) : small exact-name LRU (seeded by highest-degree symbols)  -> VRAM
  WARM (L1) : name CSR (binary-searchable) + relation/evidence CSR      -> pinned RAM
  COLD (L3) : the dense columns themselves (mmap, never fully resident)

No per-symbol Python dicts exist anymore. A query resolves a name via a sorted
array + binary search and walks CSR slices -- O(log) / O(degree), not O(3.2M).
"""
import sys
from array import array
sys.path.insert(0, r"C:\B-Plus\agent\agent b+")
from core.memory_engine.store import MemoryStore


class HotCache:
    """Exact-name LRU with promotion on every hit (cost/recency aware)."""

    def __init__(self, cap=20000):
        self.cap = cap
        self.data = {}
        self.order = []
        self.count = {}

    def get(self, name):
        v = self.data.get(name)
        if v is not None:
            self.order.remove(name)
            self.order.append(name)
            self.count[name] = self.count.get(name, 0) + 1
        return v

    def promote(self, name, ids):
        if name in self.data:
            self.order.remove(name)
        self.data[name] = ids
        self.order.append(name)
        self.count[name] = self.count.get(name, 0) + 1
        while len(self.order) > self.cap:
            old = self.order.pop(0)
            self.data.pop(old, None)
            self.count.pop(old, None)

    def __contains__(self, name):
        return name in self.data


class KnowledgeIndex:
    def __init__(self, store: MemoryStore, build=True):
        self.store = store
        self.st = store.st
        if build:
            self.build()

    def file_path(self, fid):
        return self.st[self.store.f_path[fid]]

    # ---- build compact CSR / sorted indexes from dense columns ----
    def build(self):
        store = self.store
        n = len(store.s_file)
        names = store.s_name

        # name CSR: bin symbols by name_id
        max_name = (max(names) + 1) if n else 0
        cnt = [0] * max_name
        for s in range(n):
            cnt[names[s]] += 1
        self.name_off = [0] * (max_name + 1)
        for i in range(max_name):
            self.name_off[i + 1] = self.name_off[i] + cnt[i]
        # unique symbol-name ids sorted by their string -> O(log n) name lookup
        # with ZERO large Python dicts in steady state (only this compact array
        # of unique name ids lives in RAM; strings stay in the mmap'd table).
        uniq = [i for i in range(max_name) if cnt[i] > 0]
        uniq.sort(key=lambda nid: self.st[nid])
        self.name_sorted_ids = array('I', uniq)
        self.name_syms = [0] * n
        cur = list(self.name_off)
        for s in range(n):
            nm = names[s]
            self.name_syms[cur[nm]] = s
            cur[nm] += 1

        # relations CSR by subject (r_from)
        nr = len(store.r_from)
        rfrom = store.r_from
        rcnt = [0] * n
        for i in range(nr):
            rcnt[rfrom[i]] += 1
        self.rel_off = [0] * (n + 1)
        for i in range(n):
            self.rel_off[i + 1] = self.rel_off[i] + rcnt[i]
        self.rel_idx = [0] * nr
        cur = list(self.rel_off)
        for i in range(nr):
            f = rfrom[i]
            self.rel_idx[cur[f]] = i
            cur[f] += 1

        # evidence CSR by subject (e_sym)
        ne = len(store.e_sym)
        esym = store.e_sym
        ecnt = [0] * n
        for i in range(ne):
            ecnt[esym[i]] += 1
        self.ev_off = [0] * (n + 1)
        for i in range(n):
            self.ev_off[i + 1] = self.ev_off[i] + ecnt[i]
        self.ev_idx = [0] * ne
        cur = list(self.ev_off)
        for i in range(ne):
            s = esym[i]
            self.ev_idx[cur[s]] = i
            cur[s] += 1

        # reverse CALLS CSR: target symbol -> caller relation indices
        call_targets = []
        call_rel = []
        for i in range(nr):
            if self.st[store.r_kind[i]] == "CALLS" and store.r_to_type[i] == 0:
                call_targets.append(store.r_to[i])
                call_rel.append(i)
        nt = (max(call_targets) + 1) if call_targets else 0
        tcnt = [0] * nt
        for t in call_targets:
            tcnt[t] += 1
        self.call_off = [0] * (nt + 1)
        for i in range(nt):
            self.call_off[i + 1] = self.call_off[i] + tcnt[i]
        self.call_idx = [0] * len(call_targets)
        cur = list(self.call_off)
        for k, t in enumerate(call_targets):
            self.call_idx[cur[t]] = call_rel[k]
            cur[t] += 1

        # finalise as compact uint32 arrays (no per-element Python objects)
        self.name_off = array('I', self.name_off)
        self.name_syms = array('I', self.name_syms)
        self.rel_off = array('I', self.rel_off)
        self.rel_idx = array('I', self.rel_idx)
        self.ev_off = array('I', self.ev_off)
        self.ev_idx = array('I', self.ev_idx)
        self.call_off = array('I', self.call_off)
        self.call_idx = array('I', self.call_idx)

        self.hot = HotCache()

    # ---- O(log n) name lookup (binary search over mmap strings) ----
    def syms_by_name(self, name):
        if name is None:
            return []
        a = self.name_sorted_ids
        lo, hi = 0, len(a)
        st = self.st
        while lo < hi:
            mid = (lo + hi) // 2
            nid = a[mid]
            nm = st[nid]
            if nm < name:
                lo = mid + 1
            elif nm > name:
                hi = mid
            else:
                return self.name_syms[self.name_off[nid]:self.name_off[nid + 1]]
        return []

    # ---- CSR slices (no Python dicts) ----
    def relations_of(self, sid):
        if sid < 0 or sid >= len(self.rel_off):
            return []
        return self.rel_idx[self.rel_off[sid]:self.rel_off[sid + 1]]

    def evidence_of(self, sid):
        if sid < 0 or sid >= len(self.ev_off):
            return []
        return self.ev_idx[self.ev_off[sid]:self.ev_off[sid + 1]]

    def callers_of(self, sid):
        if sid < 0 or sid >= len(self.call_off):
            return []
        return self.call_idx[self.call_off[sid]:self.call_off[sid + 1]]

    def degree(self, sid):
        return self.rel_off[sid + 1] - self.rel_off[sid] if 0 <= sid < len(self.rel_off) else 0

    def seed_hot_by_degree(self, top_k=5000):
        n = len(self.store.s_file)
        order = sorted(range(n), key=self.degree, reverse=True)
        for s in order[:top_k]:
            nm = self.st[self.store.s_name[s]]
            self.hot.promote(nm, self.syms_by_name(nm))
