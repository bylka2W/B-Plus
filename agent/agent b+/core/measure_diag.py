import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(r"C:\B-Plus\agent\agent b+")))
import torch
import torch.nn.functional as F
from core.train_new_model import MixedZigRuDataset
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m
from torch.utils.data import DataLoader

SEQ, BS, NSTEPS = 1024, 2, 3
tok = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json")
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=8_000_000)
tr, _ = torch.utils.data.random_split(ds, [len(ds)-200, 200])
dl = DataLoader(tr, batch_size=BS, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)

def run(label, autocast="bf16", benchmark=True, sdp=None, do_opt=True, fused=True, tiny=False):
    # reset backends to a known baseline
    torch.backends.cuda.enable_flash_sdp(True)
    torch.backends.cuda.enable_mem_efficient_sdp(True)
    torch.backends.cuda.enable_math_sdp(True)
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    torch.backends.cudnn.benchmark = benchmark
    if sdp is not None:
        torch.backends.cuda.enable_flash_sdp(sdp.get("flash", True))
        torch.backends.cuda.enable_mem_efficient_sdp(sdp.get("mem", True))
        torch.backends.cuda.enable_math_sdp(sdp.get("math", True))
    if tiny:
        from core.model import Transformer
        model = Transformer(vocab_size=1000, dim=128, n_layers=3, n_heads=4, n_kv_heads=2,
                            max_seq_len=8192, hidden_dim=256).cuda()
        dev = "cuda:0"
        it = None
        # random data
        def get_batch():
            x = torch.randint(0, 1000, (BS, SEQ), device=dev)
            y = torch.randint(0, 1000, (BS, SEQ), device=dev)
            return x, y
    else:
        model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000).cuda()
        dev = "cuda:0"
        it = iter(dl)
        def get_batch():
            b = next(it)
            return b[0].to(dev, non_blocking=True), b[1].to(dev, non_blocking=True)
    opt = torch.optim.AdamW(model.parameters(), lr=3e-4, betas=(0.9,0.95), weight_decay=0.1, fused=fused)
    dtype = {"bf16": torch.bfloat16, "fp16": torch.float16, None: None}[autocast]
    times = []
    for i in range(NSTEPS):
        x, y = get_batch()
        t0 = time.monotonic()
        if dtype is None:
            logits, loss = model(x, targets=y)
        else:
            with torch.amp.autocast(device_type="cuda", dtype=dtype):
                logits, loss = model(x, targets=y)
        t1 = time.monotonic()
        loss.backward()
        t2 = time.monotonic()
        if do_opt:
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step(); opt.zero_grad(set_to_none=True)
        else:
            model.zero_grad(set_to_none=True)
        t3 = time.monotonic()
        times.append((t1-t0, t2-t1, t3-t2))
    print(f"[{label}]", " | ".join(f"s{i+1}: fwd={a*1000:.0f} bwd={b*1000:.0f} opt={c*1000:.0f} tot={(a+b+c)*1000:.0f}ms" for i,(a,b,c) in enumerate(times)), flush=True)

print("=== tiny control (random data, fp32) ===", flush=True)
run("TINY-fp32", autocast=None, do_opt=True, tiny=True)
print("=== 606M variants ===", flush=True)
run("A baseline(bf16,bench,mem)", autocast="bf16", benchmark=True, sdp={"flash":False,"mem":True,"math":True}, do_opt=True, fused=True)
run("B benchmark=False", autocast="bf16", benchmark=False, sdp={"flash":False,"mem":True,"math":True}, do_opt=True, fused=True)
run("C no optimizer.step", autocast="bf16", benchmark=True, sdp={"flash":False,"mem":True,"math":True}, do_opt=False, fused=True)
run("D fp16", autocast="fp16", benchmark=True, sdp={"flash":False,"mem":True,"math":True}, do_opt=True, fused=True)
run("E default sdp (flash on)", autocast="bf16", benchmark=True, sdp=None, do_opt=True, fused=True)
run("F non-fused opt", autocast="bf16", benchmark=True, sdp={"flash":False,"mem":True,"math":True}, do_opt=True, fused=False)
print("DONE", flush=True)
