import time, sys, os
sys.path.insert(0, r"C:\B-Plus\agent\agent b+")
import torch
from core.memory_engine.store import MemoryStore
from core.memory_engine.index import KnowledgeIndex
from core.memory_engine.knowledge_query import KnowledgeQuery
from core.memory_engine.prefetch import PrefetchPlanner
from knowledge.tokenizer import ZigTokenizer

OUT = r"C:\B-Plus\agent\agent b+\core\memory_engine\store_data"

store = MemoryStore.load(OUT)
idx = KnowledgeIndex(store)
idx.seed_hot_by_degree(5000)
kq = KnowledgeQuery(idx)
print(f"loaded: symbols={len(store.s_file):,}  relations={len(store.r_from):,}  ev={len(store.e_sym):,}")

# ---- L4 SOURCE: line-offset -> O(1) span read on a huge file ----
# find a file with many lines
big = max(range(len(store.f_path)), key=lambda f: store.f_lines[f])
print(f"biggest file: #{big} {idx.file_path(big)} lines={store.f_lines[big]:,}")
for ln in (1, store.f_lines[big] // 2, store.f_lines[big]):
    t = time.perf_counter()
    kq._read_source(big, ln, ln)
    print(f"  SOURCE read line {ln}: {(time.perf_counter()-t)*1000:.2f} ms  (byte span {store.byte_span(big, ln, ln)})")

# ---- L0 query cache (exact/normalized) ----
q = "KnowledgeQuery"
r1 = kq.retrieve(q)
r2 = kq.retrieve(q)
print(f"QUERY '{q}': first={r1['total_ms']:.2f} ms (tiers {r1['tiers_ms']}); second={r2['total_ms']:.3f} ms cached={r2['cached']}")

# ---- canonical ranking (test/vendor de-prioritised) ----
r = kq.retrieve("config", top_k=3)
for m in r["matches"]:
    print(f"  canon: {m['name']} ({m['kind']}) score={m['score']} file=...{m['file'][-40:]}")

# ---- prefetch: WARM(pinned) -> GPU L2 async H2D of retrieved evidence ----
tok = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json")
planner = PrefetchPlanner("cuda")
# build a batch of evidence spans as token-id sequences
batch = []
for m in r1["matches"]:
    ev = m.get("evidence", "")
    if ev:
        batch.append(tok.encode(ev[:200]))
print(f"prefetch batch: {len(batch)} spans, max_len={max((len(b) for b in batch), default=0)}")
t = time.perf_counter()
gpu = planner.plan(batch)
planner.sync()
print(f"async H2D batch -> GPU working set: {tuple(gpu.shape)} in {(time.perf_counter()-t)*1000:.2f} ms "
      f"(pinned CPU -> RTX 5060 Ti, model never sees full C:\\B-Plus)")
