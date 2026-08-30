"""Save weights individually — avoid pickle overhead."""
import torch, os, json

src = r"C:\B-Plus\agent\agent b+\checkpoints\pilot_final.pt"
out_dir = r"C:\B-Plus\agent\agent b+\checkpoints\raw"
os.makedirs(out_dir, exist_ok=True)

print("Loading checkpoint (this will use RAM)...")
ckpt = torch.load(src, map_location="cpu", weights_only=False)
sd = ckpt["model_state"]
del ckpt

print(f"Saving {len(sd)} tensors individually...")
index = []
for i, (name, tensor) in enumerate(sd.items()):
    t = tensor.to(torch.bfloat16).contiguous()
    fname = f"{i:04d}.pt"
    torch.save(t, os.path.join(out_dir, fname))
    index.append({"name": name, "shape": list(t.shape), "file": fname})
    if i % 50 == 0:
        print(f"  {i}/{len(sd)}")
    del t

del sd
with open(os.path.join(out_dir, "index.json"), "w") as f:
    json.dump(index, f)

total = sum(os.path.getsize(os.path.join(out_dir, e["file"])) for e in index)
print(f"Done: {len(index)} tensors, {total/1e6:.0f}MB total")
