import sys, time
from pathlib import Path
AGENT_ROOT = Path(r"C:\B-Plus\agent\agent b+")
sys.path.insert(0, str(AGENT_ROOT))
import torch
import torch.nn.functional as F
# Force FlashAttention backend for SDPA (fast fwd + bwd); disable slow math path
torch.backends.cuda.enable_flash_sdp(True)
torch.backends.cuda.enable_mem_efficient_sdp(True)
torch.backends.cuda.enable_math_sdp(False)
torch.backends.cudnn.benchmark = True

from core.train_new_model import MixedZigRuDataset, Trainer
from knowledge.tokenizer import ZigTokenizer
from core.model import build_model_600m
from torch.utils.data import DataLoader

SEQ, BS, N = 1024, 2, 6
tok = ZigTokenizer.load(r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json")
ds = MixedZigRuDataset.__new__(MixedZigRuDataset)
ds.__init__(tok, seq_len=SEQ, max_zig_tokens=8_000_000)
tr, _ = torch.utils.data.random_split(ds, [len(ds)-200, 200])
dl = DataLoader(tr, batch_size=BS, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)
model = build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000)
trainer = Trainer(model, tok, lr=3e-4, warmup_steps=2, total_steps=N)
it = iter(dl)
for i in range(N):
    batch = next(it)
    x = batch[0].to(trainer.device, non_blocking=True)
    y = batch[1].to(trainer.device, non_blocking=True)
    t0 = time.monotonic()
    with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
        logits, loss = model(x, targets=y)
    t1 = time.monotonic()
    loss.backward()
    t2 = time.monotonic()
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    trainer.optimizer.step()
    trainer.optimizer.zero_grad(set_to_none=True)
    t3 = time.monotonic()
    print(f"step {i+1}: fwd={ (t1-t0)*1000:.0f}ms bwd={ (t2-t1)*1000:.0f}ms opt={ (t3-t2)*1000:.0f}ms total={ (t3-t0)*1000:.0f}ms", flush=True)
print("DONE", flush=True)
