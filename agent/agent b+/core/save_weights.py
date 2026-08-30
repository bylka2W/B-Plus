"""Save weights as safetensors — no pickle, minimal RAM."""
import torch, os, json

src = r"C:\B-Plus\agent\agent b+\checkpoints\pilot_final.pt"
out_dir = r"C:\B-Plus\agent\agent b+\checkpoints\weights"

os.makedirs(out_dir, exist_ok=True)

print("Loading checkpoint...")
ckpt = torch.load(src, map_location="cpu", weights_only=False)
sd = ckpt["model_state"]

print(f"Saving {len(sd)} tensors...")
# Save each tensor as raw bytes
manifest = {}
for name, tensor in sd.items():
    tensor = tensor.to(torch.bfloat16)
    fname = name.replace(".", "_") + ".bin"
    fpath = os.path.join(out_dir, fname)
    tensor.numpy().tofile(fpath)
    manifest[name] = {"file": fname, "shape": list(tensor.shape), "dtype": "bf16"}
    print(f"  {name}: {tensor.shape}")

with open(os.path.join(out_dir, "manifest.json"), "w") as f:
    json.dump(manifest, f)

total = sum(os.path.getsize(os.path.join(out_dir, m["file"])) for m in manifest.values())
print(f"\nTotal: {total/1e6:.0f}MB in {out_dir}")
