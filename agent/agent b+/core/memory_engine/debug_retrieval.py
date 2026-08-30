import sys
sys.path.insert(0, r"C:\B-Plus\agent\agent b+")
from core.memory_engine.store import MemoryStore
from core.memory_engine.index import KnowledgeIndex

OUT = r"C:\B-Plus\agent\agent b+\core\memory_engine\store_data"
store = MemoryStore.load(OUT)
idx = KnowledgeIndex(store)
print("name_sorted_ids len", len(idx.name_sorted_ids))
print("first name id", idx.name_sorted_ids[0], "->", repr(store.st[idx.name_sorted_ids[0]]))
print("syms_by_name('main'):", len(idx.syms_by_name("main")))
print("syms_by_name('std'):", len(idx.syms_by_name("std")))

seen = set()
for s in range(200000):
    nm = store.st[store.s_name[s]]
    seen.add(nm)
    if len(seen) >= 20:
        break
print("sample names:", sorted(seen)[:20])

# direct binary-search sanity: find 'std' in name_sorted_ids
a = idx.name_sorted_ids
lo, hi = 0, len(a)
target = "std"
while lo < hi:
    mid = (lo + hi) // 2
    nm = store.st[a[mid]]
    if nm < target:
        lo = mid + 1
    elif nm > target:
        hi = mid
    else:
        print("FOUND 'std' at nid", a[mid], "syms", len(idx.name_syms[idx.name_off[a[mid]]:idx.name_off[a[mid] + 1]]))
        break
else:
    print("'std' NOT in name_sorted_ids")
