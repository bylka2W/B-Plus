import sys
sys.path.insert(0, r"C:\B-Plus\agent\agent b+")
from knowledge.tokenizer import ZigTokenizer
t = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\zig_tokenizer.json")

test = "GPUScheduler"
ids = t.encode(test)
print(f"encode({repr(test)}) = {ids}")
for i in ids:
    print(f"  id={i} in inv_vocab={i in t.inv_vocab} key={t.inv_vocab.get(i, 'MISSING')}")
decoded = t.decode(ids)
print(f"decode({ids}) = {repr(decoded)}")
print(f"match: {decoded == test}")

test2 = "GPU"
ids2 = t.encode(test2)
print(f"\nencode({repr(test2)}) = {ids2}")
decoded2 = t.decode(ids2)
print(f"decode({ids2}) = {repr(decoded2)}")
print(f"match: {decoded2 == test2}")

test3 = "Что"
ids3 = t.encode(test3)
print(f"\nencode({repr(test3)}) = {ids3}")
decoded3 = t.decode(ids3)
print(f"decode({ids3}) = {repr(decoded3)}")
print(f"match: {decoded3 == test3}")
