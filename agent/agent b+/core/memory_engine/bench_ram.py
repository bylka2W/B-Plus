import os, sys, time, ctypes, mmap
from ctypes import wintypes, Structure, c_size_t, c_ulong

import torch

# ---- Windows working-set (RSS) via PSAPI ----
class PROCESS_MEMORY_COUNTERS_EX(Structure):
    _fields_ = [
        ("cb", wintypes.DWORD),
        ("PageFaultCount", wintypes.DWORD),
        ("PeakWorkingSetSize", c_size_t),
        ("WorkingSetSize", c_size_t),
        ("QuotaPeakPagedPoolUsage", c_size_t),
        ("QuotaPagedPoolUsage", c_size_t),
        ("QuotaPeakNonPagedPoolUsage", c_size_t),
        ("QuotaNonPagedPoolUsage", c_size_t),
        ("PagefileUsage", c_size_t),
        ("PeakPagefileUsage", c_size_t),
        ("PrivateUsage", c_size_t),
    ]

def rss_mb():
    pmi = PROCESS_MEMORY_COUNTERS_EX()
    pmi.cb = ctypes.sizeof(pmi)
    api = ctypes.windll.psapi.GetProcessMemoryInfo
    api.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESS_MEMORY_COUNTERS_EX), wintypes.DWORD]
    api.restype = wintypes.BOOL
    ok = api(ctypes.windll.kernel32.GetCurrentProcess(), ctypes.byref(pmi), pmi.cb)
    if not ok:
        return 0.0, 0.0
    return pmi.WorkingSetSize / (1024 * 1024), pmi.PrivateUsage / (1024 * 1024)

sys.path.insert(0, r"C:\B-Plus\agent\agent b+")
from core.memory_engine.store import MemoryStore
from core.memory_engine.index import KnowledgeIndex
from core.memory_engine.knowledge_query import KnowledgeQuery

OUT = r"C:\B-Plus\agent\agent b+\core\memory_engine\store_data"

def snap(tag):
    w, p = rss_mb()
    print(f"  [{tag:24s}] RSS={w:8.1f} MB  Private={p:8.1f} MB")
    return w

print("=== RAM / mmap residency check ===")
snap("start (python+torch)")
t0 = time.time()
store = MemoryStore.load(OUT)
snap("after store.load (mmap)")
print(f"  load time = {time.time()-t0:.2f}s")
print(f"  symbols={len(store.s_file)} relations={len(store.r_from)} evidence={len(store.e_sym)}")

t0 = time.time()
idx = KnowledgeIndex(store)
snap("after index.build")
print(f"  index build = {time.time()-t0:.2f}s")

t0 = time.time()
q = KnowledgeQuery(idx)
snap("after query engine init")

for name in ["main", "std", "ArrayList", "std.mem.Allocator", "__init", "json"]:
    r = q.retrieve(name, top_k=3)
    print(f"  query '{name}': {len(r.get('matches', []))} matches")
snap("after warmup queries")

# a heavier scan: resolve first 50000 symbols' names (simulated working-set touch)
t0 = time.time()
c = 0
for s in range(0, min(50000, len(store.s_file))):
    _ = store.st[store.s_name[s]]
    c += 1
print(f"  touched {c} symbol names ({time.time()-t0:.2f}s)")
snap("after touching 50k names")
print("done")
