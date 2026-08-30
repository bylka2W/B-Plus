import os
import sys
import time
import torch
import torch.nn as nn
from pathlib import Path

AGENT_BPLUS = Path(r"C:\B-Plus\agent\agent b+")
sys.path.insert(0, str(AGENT_BPLUS))

from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m
from core.agent_runtime import KnowledgeQuery

TOK_PATH = AGENT_BPLUS / "knowledge" / "corpus" / "ru_zig_tokenizer.json"

print("=" * 70)
print("B+ HARDWARE / PERFORMANCE GATE")
print("=" * 70)

# ---- STEP 1: hardware ----
p = torch.cuda.get_device_properties(0)
bf16 = torch.cuda.is_bf16_supported()
cap = p.major * 10 + p.minor
print(f"[HW] GPU={p.name}  VRAM={p.total_memory/1e9:.2f}GB  compute_cap={cap}")
print(f"[HW] CUDA={torch.version.cuda}  torch={torch.__version__}")
print(f"[HW] BF16_supported={bf16}  FP16=always")
sdpa_ok = hasattr(torch.nn.functional, "scaled_dot_product_attention")
print(f"[HW] SDPA_available={sdpa_ok}")

tok = ZigTokenizer.load(TOK_PATH)
print(f"[HW] tokenizer vocab={tok.vocab_size()}")

# ---- STEP 2: training memory benchmark (batch=1, various seq) ----
def train_peak(seq, batch=1):
    torch.cuda.reset_peak_memory_stats()
    torch.cuda.empty_cache()
    m = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).cuda()
    opt = torch.optim.AdamW(m.parameters(), lr=2e-4)
    try:
        x = torch.randint(0, tok.vocab_size(), (batch, seq), device="cuda")
        with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
            _, loss = m(x, targets=x)
        loss.backward()
        opt.step(); opt.zero_grad()
        peak = torch.cuda.max_memory_allocated() / 1e9
        status = "OK"
    except torch.cuda.OutOfMemoryError:
        peak = -1.0
        status = "OOM"
    del m, opt, x
    torch.cuda.empty_cache()
    return status, peak

print("\n[TRAIN MEM] batch=1, bf16, AdamW(fp32 states)")
for seq in (512, 1024, 2048):
    st, pk = train_peak(seq)
    print(f"  seq={seq:5d}  peak_VRAM={pk:6.2f}GB  {st}")

# ---- STEP 3: inference tok/s (decode) ----
def infer_speed(precision="bf16", quant=None, prompt_len=256, gen=256):
    torch.cuda.empty_cache()
    m = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).cuda().eval()
    if quant == "int8":
        m = torch.quantization.quantize_dynamic(m, {nn.Linear}, dtype=torch.qint8)
    dtype = torch.bfloat16 if precision == "bf16" else torch.float16
    m = m.to(dtype) if quant is None else m
    with torch.no_grad():
        ids = torch.randint(0, tok.vocab_size(), (1, prompt_len), device="cuda")
        if quant is None:
            with torch.amp.autocast(device_type="cuda", dtype=dtype):
                for _ in range(2):
                    _ = m(ids)
        # timed generate (uses model.generate, recompute-each-step baseline)
        t0 = time.monotonic()
        with torch.no_grad():
            if quant is None:
                with torch.amp.autocast(device_type="cuda", dtype=dtype):
                    out = m.generate(ids, max_new_tokens=gen, temperature=1.0, top_k=1)
            else:
                out = m.generate(ids, max_new_tokens=gen, temperature=1.0, top_k=1)
        dt = time.monotonic() - t0
    del m
    torch.cuda.empty_cache()
    tps = gen / dt
    return tps, dt

print("\n[INFER] decode tok/s  (batch=1, prompt=256, gen=256)")
for prec in ("bf16", "fp16"):
    try:
        tps, dt = infer_speed(precision=prec)
        print(f"  {prec:5s}        tok/s={tps:7.1f}  ({dt:.2f}s)")
    except Exception as e:
        print(f"  {prec:5s}        FAIL {type(e).__name__}: {str(e)[:60]}")
try:
    tps, dt = infer_speed(precision="bf16", quant="int8")
    print(f"  int8        tok/s={tps:7.1f}  ({dt:.2f}s)")
except Exception as e:
    print(f"  int8        FAIL {type(e).__name__}: {str(e)[:60]}")

# ---- STEP 4: KnowledgeQuery benchmark ----
print("\n[KNOWLEDGE] retrieval latency")
try:
    kb = KnowledgeQuery(r"C:\B-Plus\agent\memory")
    for q in ("build", "Allocator", "std.fs.File"):
        t0 = time.monotonic()
        r = kb.retrieve_context(q, max_symbols=20, max_facts=200, max_context_kb=64)
        dt = (time.monotonic() - t0) * 1000
        print(f"  q={q:14s} {dt:6.2f}ms  facts={r['stats']['facts']}")
except Exception as e:
    print(f"  KnowledgeQuery bench skipped: {type(e).__name__}: {str(e)[:80]}")

print("\nGATE SUMMARY")
print("  decode >= 150 tok/s : see INFER above")
print("  train fits 16GB     : see TRAIN MEM above (need grad-ckpt / GQA / 8bit opt)")
print("  retrieval < 20ms    : see KNOWLEDGE above")
print("=" * 70)
