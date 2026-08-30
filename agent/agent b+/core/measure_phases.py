import sys, time, tempfile, pathlib, torch
sys.path.insert(0, r"C:\B-Plus\agent\agent b+\core")
import train_new_model as T

tmp = pathlib.Path(tempfile.mkdtemp(prefix="timing_"))
T.CHECKPOINT_DIR = tmp

tok = T.ZigTokenizer.load(T.TOK_PATH)
ds = T.MixedZigRuDataset(tok, seq_len=1024)
val = min(len(ds) // 20, 400)
tr, va = torch.utils.data.random_split(ds, [len(ds) - val, val])
tl = torch.utils.data.DataLoader(tr, batch_size=2, shuffle=True, drop_last=True, num_workers=0, pin_memory=True)
vl = torch.utils.data.DataLoader(va, batch_size=2, shuffle=False, num_workers=0, pin_memory=True)
print(f"dataset train={len(tr)} val={len(va)}")

model = T.build_model_600m(vocab_size=tok.vocab_size(), max_seq_len=256000)
trn = T.Trainer(model, tok, lr=2e-4, warmup_steps=200, total_steps=2000)

trn.model.train()
batch_iter = iter(tl)

t_data_list, t_h2d_list, t_fwd_list, t_bwd_list, t_opt_list, t_sync_list = [], [], [], [], [], []
t_total_list = []

N = 40
print(f"\n=== {N}-step timing breakdown ===")
for step in range(1, N + 1):
    torch.cuda.synchronize()
    t0 = time.perf_counter()

    t_d0 = time.perf_counter()
    try:
        batch = next(batch_iter)
    except StopIteration:
        batch_iter = iter(tl)
        batch = next(batch_iter)
    t_data = time.perf_counter() - t_d0

    t_h0 = time.perf_counter()
    x = batch[0].to("cuda:0", non_blocking=True)
    y = batch[1].to("cuda:0", non_blocking=True)
    torch.cuda.synchronize()
    t_h2d = time.perf_counter() - t_h0

    t_f0 = time.perf_counter()
    with torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16):
        _, loss = trn.model(x, targets=y)
    torch.cuda.synchronize()
    t_fwd = time.perf_counter() - t_f0

    t_b0 = time.perf_counter()
    loss.backward()
    torch.cuda.synchronize()
    t_bwd = time.perf_counter() - t_b0

    t_o0 = time.perf_counter()
    T.nn.utils.clip_grad_norm_(trn.model.parameters(), 1.0)
    trn.optimizer.step()
    trn.optimizer.zero_grad()
    torch.cuda.synchronize()
    t_opt = time.perf_counter() - t_o0

    total = time.perf_counter() - t0
    lr = trn.scheduler.get_lr(step)
    for pg in trn.optimizer.param_groups:
        pg["lr"] = lr

    t_data_list.append(t_data)
    t_h2d_list.append(t_h2d)
    t_fwd_list.append(t_fwd)
    t_bwd_list.append(t_bwd)
    t_opt_list.append(t_opt)
    t_total_list.append(total)

    if step % 5 == 0 or step <= 3:
        print(f"step={step:3d} total={total*1000:6.0f}ms  data={t_data*1000:5.0f}  h2d={t_h2d*1000:5.0f}  "
              f"fwd={t_fwd*1000:5.0f}  bwd={t_bwd*1000:5.0f}  opt={t_opt*1000:5.0f}  "
              f"loss={float(loss):.3f}  tok/s={2048/total:.0f}")

# Summary
import statistics
skip = 10  # skip compile warmup
print(f"\n=== AVERAGES (steps {skip+1}-{N}) ===")
for name, vals in [("total", t_total_list), ("data", t_data_list), ("h2d", t_h2d_list),
                    ("fwd", t_fwd_list), ("bwd", t_bwd_list), ("opt", t_opt_list)]:
    s = vals[skip:]
    print(f"  {name:6s} avg={statistics.mean(s)*1000:6.0f}ms  med={statistics.median(s)*1000:6.0f}ms  "
          f"min={min(s)*1000:6.0f}ms  max={max(s)*1000:6.0f}ms")
avg_total = statistics.mean(t_total_list[skip:])
print(f"\n  step/s = {1/avg_total:.2f}")
print(f"  tok/s  = {2048/avg_total:.0f}")
print(f"  ETA 60k = {60000 * avg_total / 3600:.1f}h")
