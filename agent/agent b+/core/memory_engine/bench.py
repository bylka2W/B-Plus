import time, sys, random
sys.path.insert(0, r"C:\B-Plus\agent\agent b+")
from core.memory_engine.store import MemoryStore
from core.memory_engine.index import KnowledgeIndex
from core.memory_engine.knowledge_query import KnowledgeQuery

OUT = r"C:\B-Plus\agent\agent b+\core\memory_engine\store_data"
t = time.monotonic()
store = MemoryStore.load(OUT)
idx = KnowledgeIndex(store)
idx.seed_hot_by_degree(5000)
kq = KnowledgeQuery(idx)
print("load", round(time.monotonic() - t, 1), "s  symbols", len(store.s_file),
      "rels", len(store.r_from), "ev", len(store.e_sym))
print("HOT size", len(idx.hot))


def avg(fn, n=200):
    fn()
    t0 = time.monotonic()
    for _ in range(n):
        fn()
    return (time.monotonic() - t0) / n * 1000


# SOURCE: sample a few evidence spans (typical small files)
samp = list(range(0, len(store.e_sym), 997))[:5]
for s in samp:
    fid = store.e_file[s]; l0 = store.e_line0[s]; l1 = store.e_line1[s]
    tt = avg(lambda: kq._read_source(fid, l0, l1))
    print(f"SOURCE file#{fid} lines {l0}-{l1}: {tt:.2f} ms")

for q in ("allocator", "GPUScheduler", "config", "KnowledgeQuery", "RMSNorm", "SwiGLU"):
    r = kq.retrieve(q)
    print(f"QUERY {q!r}: {len(r['matches'])} matches total {r['total_ms']:.2f} ms "
          f"(source {r['tiers_ms']['source']*1000:.2f})")
