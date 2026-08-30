"""Chat — safe VRAM, leave 3GB free."""
import torch, sys, os, gc
os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "expandable_segments:True"
sys.path.insert(0, r"C:\B-Plus\agent\agent b+")

from knowledge.tokenizer import ZigTokenizer

CKPT = r"C:\B-Plus\agent\agent b+\checkpoints\model_bf16.pt"
TOK_PATH = r"C:\B-Plus\agent\agent b+\knowledge\corpus\ru_zig_tokenizer.json"
RESERVE_MB = 3000  # leave 3GB free

def main():
    free, total = torch.cuda.mem_get_info()
    total_mb = total / 1e6
    free_mb = free / 1e6
    budget_mb = free_mb - RESERVE_MB
    print(f"GPU: {total_mb:.0f}MB total, {free_mb:.0f}MB free, budget: {budget_mb:.0f}MB")

    if budget_mb < 2000:
        print("ERROR: Not enough free VRAM. Close other GPU apps or reboot.")
        return

    # Limit to budget
    fraction = budget_mb / total_mb
    torch.cuda.set_per_process_memory_fraction(fraction, device=0)
    print(f"Memory limit: {fraction*100:.0f}% ({budget_mb:.0f}MB)")

    tok = ZigTokenizer.load(TOK_PATH)
    vs = tok.vocab_size()
    print(f"Tokenizer: {vs} tokens")

    # Build on CPU first (safe), then move to GPU
    print("Building model...")
    from core.model import build_model
    model = build_model(vs)
    print(f"Model: {sum(p.numel() for p in model.parameters())/1e6:.0f}M params")
    model = model.to(torch.bfloat16).cuda()
    gc.collect()
    torch.cuda.empty_cache()

    print("Loading weights...")
    ckpt = torch.load(CKPT, map_location="cuda", weights_only=False, mmap=True)
    model.load_state_dict(ckpt["model_state"])
    del ckpt
    gc.collect()
    torch.cuda.empty_cache()

    used = torch.cuda.memory_allocated() / 1e6
    free2 = torch.cuda.mem_get_info()[0] / 1e6
    print(f"Ready: {used:.0f}MB used, {free2:.0f}MB free")

    print("\n=== B+ Zig Agent ===")
    print("Type 'quit' to exit\n")

    while True:
        try:
            user = input("You> ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not user or user == "quit":
            break

        prompt = f"INSTRUCTION:\n{user}\n\nOUTPUT:\n"
        ids = tok.encode(prompt)
        x = torch.tensor([ids], dtype=torch.long, device="cuda")

        model.eval()
        with torch.no_grad():
            for _ in range(200):
                logits = model(x)[:, -1] / 0.8
                v, _ = torch.topk(logits, 50)
                logits[logits < v[:, [-1]]] = float("-inf")
                nxt = torch.multinomial(torch.softmax(logits, dim=-1), 1)
                x = torch.cat([x, nxt], dim=1)
                if nxt.item() == 0:
                    break

        full = tok.decode(x[0].cpu().tolist())
        if "OUTPUT:" in full:
            resp = full.split("OUTPUT:", 1)[1].strip()
        else:
            resp = full[len(prompt):].strip()
        for s in ["\n\n\n", "INSTRUCTION:"]:
            if s in resp:
                resp = resp.split(s)[0].strip()
        print(f"Agent> {resp}\n")


if __name__ == "__main__":
    main()
