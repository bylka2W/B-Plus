import json, sys
sys.path.insert(0, r"C:\B-Plus\agent\engine")
from common import load_json, CONCEPTS_PATH, FACTS_PATH, SEMANTIC_RELATIONS_PATH

c = load_json(CONCEPTS_PATH)
f = load_json(FACTS_PATH)
r = load_json(SEMANTIC_RELATIONS_PATH)

ctypes = {}
for item in c["items"]:
    t = item["concept_type"]
    ctypes[t] = ctypes.get(t, 0) + 1

ftypes = {}
for item in f["items"]:
    t = item["fact_type"]
    ftypes[t] = ftypes.get(t, 0) + 1

rtypes = {}
for item in r["items"]:
    t = item["relation_type"]
    rtypes[t] = rtypes.get(t, 0) + 1

print("CONCEPTS:", len(c["items"]))
for t, n in sorted(ctypes.items(), key=lambda x: -x[1]):
    print("  %s: %d" % (t, n))

print("FACTS:", len(f["items"]))
for t, n in sorted(ftypes.items(), key=lambda x: -x[1]):
    print("  %s: %d" % (t, n))

print("RELATIONS:", len(r["items"]))
for t, n in sorted(rtypes.items(), key=lambda x: -x[1]):
    print("  %s: %d" % (t, n))

vc = sum(1 for i in c["items"] if i.get("verification_status") == "VERIFIED")
pc = sum(1 for i in c["items"] if i.get("verification_status") == "PARTIAL")
uc = sum(1 for i in c["items"] if i.get("verification_status") == "UNRESOLVED")
print("CONCEPT STATUS: verified=%d partial=%d unresolved=%d" % (vc, pc, uc))

vf = sum(1 for i in f["items"] if i.get("verification_status") == "VERIFIED")
uf = sum(1 for i in f["items"] if i.get("verification_status") == "UNRESOLVED")
print("FACT STATUS: verified=%d unresolved=%d" % (vf, uf))

samples = []
for item in c["items"][:3]:
    name = item["canonical_name"]
    base = name.rsplit("/", 1)[-1]
    print("SAMPLE: %s type=%s status=%s" % (base, item["concept_type"], item.get("verification_status")))
