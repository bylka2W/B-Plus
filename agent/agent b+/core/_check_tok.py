import sys
sys.path.insert(0, r"C:\B-Plus\agent\agent b+")
from knowledge.tokenizer import ZigTokenizer
t = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\zig_tokenizer.json")
print(f"vocab: {t.vocab_size()}")
print(f"GPU in token_to_id: {'GPU' in t.token_to_id}")
print(f"What in token_to_id: {'What' in t.token_to_id}")
print(f"privet in token_to_id: {'privet' in t.token_to_id}")
short = [k for k in t.vocab.keys() if k.startswith("tok_") and len(k[4:]) <= 5]
print(f"short tok_ tokens: {len(short)}")
print(f"sample: {short[:10]}")
