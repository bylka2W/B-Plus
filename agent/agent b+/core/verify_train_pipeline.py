import sys, tempfile, pathlib, time
import torch
sys.path.insert(0, r"C:\B-Plus\agent\agent b+\core")
import train_new_model as T

tmp = pathlib.Path(tempfile.mkdtemp(prefix="ckpt_val_"))
T.CHECKPOINT_DIR = tmp
print("CHECKPOINT_DIR ->", tmp)

tok = T.ZigTokenizer.load(T.TOK_PATH)
ds = T.MixedZigRuDataset(tok, seq_len=1024)
n = len(ds)
val = min(n // 20, 400)
tr, va = torch.utils.data.random_split(ds, [n - val, val])
tl = torch.utils.data.DataLoader(tr, batch_size=2, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)
vl = torch.utils.data.DataLoader(va, batch_size=2, shuffle=False, num_workers=0, pin_memory=True)
print(f"dataset len={n} train={len(tr)} val={len(va)}")

model = T.build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000)
trn = T.Trainer(model, tok, lr=2e-4, warmup_steps=200, total_steps=100)
res = trn.train(tl, vl, max_steps=100, log_interval=10, val_interval=100, save_interval=50)
print("TRAIN DONE", res)

# reload into a fresh model + Trainer and verify it loads + forward works
model2 = T.build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000)
trn2 = T.Trainer(model2, tok, lr=2e-4, warmup_steps=200, total_steps=100)
ok = trn2.load_latest()
print("RELOAD ok=", ok, "step=", trn2.step)
xb, yb = next(iter(vl))
with torch.amp.autocast("cuda", dtype=torch.bfloat16):
    _, loss = trn2.model(xb.to("cuda:0"), targets=yb.to("cuda:0"))
print("RELOAD forward loss=", float(loss), "finite=", torch.isfinite(loss).item())
