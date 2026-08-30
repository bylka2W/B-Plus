"""Strip checkpoint to just model weights — bf16 only."""
import torch, os

src = r"C:\B-Plus\agent\agent b+\checkpoints\pilot_final.pt"
dst = r"C:\B-Plus\agent\agent b+\checkpoints\model_bf16.pt"

print("Loading...")
ckpt = torch.load(src, map_location="cpu", weights_only=False)

# Convert to bf16
sd = ckpt["model_state"]
sd_bf16 = {k: v.to(torch.bfloat16) for k, v in sd.items()}

# Save just weights
torch.save({"model_state": sd_bf16, "step": ckpt.get("step", 500)}, dst)

old = os.path.getsize(src) / 1e6
new = os.path.getsize(dst) / 1e6
print(f"Old: {old:.0f}MB -> New: {new:.0f}MB")
print(f"Saved: {dst}")
