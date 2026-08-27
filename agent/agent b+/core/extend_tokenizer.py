import sys
import os
import json
import time

AGENT_BPLUS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT_DIR = os.path.dirname(AGENT_BPLUS)

sys.path.insert(0, AGENT_BPLUS)
sys.path.insert(0, AGENT_DIR)

import torch
from pathlib import Path


XML_TOKENS = [
    "<system>", "</system>",
    "<instruction>", "</instruction>",
    "<context>", "</context>",
    "<answer>", "</answer>",
    "<task>", "</task>",
    "<error>", "</error>",
    "<source>", "</source>",
]

EXTRA_TOKENS = [
    "GPU", "CPU", "VRAM", "RAM", "NVMe", "SSD",
    "CUDA", "OpenGL", "Vulkan", "DX12", "Metal",
    "What", "is", "does", "Where", "Why", "How",
    "fix", "create", "explain", "find", "search",
    "the", "a", "an", "to", "in", "of", "for", "on", "at", "by",
    "this", "that", "it", "with", "from", "into", "about",
    "not", "no", "yes", "if", "then", "else", "when",
    "function", "struct", "enum", "method", "type", "module",
    "error", "pointer", "slice", "array", "vector",
    "file", "line", "code", "test", "debug", "build",
    " scheduler", "GPU scheduler",
    "Что", "это", "такое", "где", "как", "почему", "зачем",
    "привет", "покажи", "найди", "объясни", "исправь", "создай",
    "напиши", "проверь", "запусти", "выполни", "структура", "функция",
    "метод", "тип", "файл", "код", "тест", "ошибка", "билд",
    "扫黑除к", "контекст", "вопрос", "ответ", "задача",
]


def get_missing_concepts():
    concepts_path = Path(AGENT_DIR) / "memory" / "concepts.json"
    with open(concepts_path, encoding="utf-8") as f:
        data = json.load(f)
    items = data.get("items", [])
    names = [item.get("name", "") for item in items if item.get("name")]

    from knowledge.tokenizer import ZigTokenizer
    tok_path = Path(AGENT_BPLUS) / "knowledge" / "corpus" / "zig_tokenizer.json"
    t = ZigTokenizer.load(tok_path)

    missing = []
    for n in names:
        if n not in t.token_to_id and len(n) > 1:
            missing.append(n)
    return sorted(set(missing))


def extend_tokenizer():
    print("STEP 1: Extend Tokenizer (append-only)")
    print("-" * 50)

    from knowledge.tokenizer import ZigTokenizer
    tok_path = Path(AGENT_BPLUS) / "knowledge" / "corpus" / "zig_tokenizer.json"
    tokenizer = ZigTokenizer.load(tok_path)
    old_size = tokenizer.vocab_size()
    old_max_id = max(tokenizer.vocab.values()) if tokenizer.vocab else -1

    print(f"  Old vocab: {old_size} tokens (max ID: {old_max_id})")

    new_tokens = []

    for tok in XML_TOKENS:
        if tok not in tokenizer.token_to_id:
            new_tokens.append(tok)

    for tok in EXTRA_TOKENS:
        if tok not in tokenizer.token_to_id:
            new_tokens.append(tok)

    missing_concepts = get_missing_concepts()
    for concept in missing_concepts:
        if concept not in tokenizer.token_to_id:
            new_tokens.append(concept)

    print(f"  New tokens to add: {len(new_tokens)}")
    print(f"    XML tags: {len([t for t in new_tokens if t.startswith('<')])}")
    print(f"    Concepts: {len([t for t in new_tokens if not t.startswith('<')])}")

    next_id = old_max_id + 1
    for tok in new_tokens:
        tokenizer.vocab[f"tok_{tok}"] = next_id
        tokenizer.token_to_id[tok] = next_id
        tokenizer.inv_vocab[next_id] = f"tok_{tok}"
        next_id += 1

    new_size = tokenizer.vocab_size()
    print(f"  New vocab: {new_size} tokens")
    print(f"  Added: {new_size - old_size} tokens")

    backup_path = tok_path.with_suffix(".json.bak")
    if not backup_path.exists():
        import shutil
        shutil.copy2(tok_path, backup_path)
        print(f"  Backup: {backup_path}")

    tokenizer.save(tok_path)
    print(f"  Saved: {tok_path}")

    return tokenizer, old_size, new_size


def expand_model(new_vocab_size):
    print("\nSTEP 2: Expand Model (embedding + LM head)")
    print("-" * 50)

    from core.model import build_model
    model = build_model()
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = model.to(device)

    old_vocab = model.get_config()["vocab_size"]
    print(f"  Old model vocab: {old_vocab}")

    if new_vocab_size <= old_vocab:
        print(f"  No expansion needed (new={new_vocab_size} <= old={old_vocab})")
        return model, old_vocab

    old_emb_weight = model.tok_emb.weight.data.clone()

    old_dim = old_emb_weight.shape[1]
    print(f"  Embedding dim: {old_dim}")

    new_emb = torch.nn.Embedding(new_vocab_size, old_dim)
    new_emb = new_emb.to(device)
    new_emb.weight.data[:old_vocab] = old_emb_weight

    nn_init_range = 0.02
    new_emb.weight.data[old_vocab:].normal_(0, nn_init_range)

    model.tok_emb = new_emb

    old_out_weight = model.output.weight.data.clone()

    model.output = torch.nn.Linear(old_dim, new_vocab_size, bias=False).to(device)
    model.output.weight.data[:old_vocab] = old_out_weight
    model.output.weight.data[old_vocab:].normal_(0, nn_init_range)

    print(f"  New model vocab: {new_vocab_size}")
    print(f"  Old embedding weights: PRESERVED")
    print(f"  New embedding weights: initialized (normal 0.02)")
    print(f"  Old output weights: PRESERVED")
    print(f"  New output weights: initialized (normal 0.02)")

    config = model.get_config()
    print(f"  Model config: {config}")

    return model, old_vocab


def verify_tokenizer(tokenizer, new_vocab_size):
    print("\nSTEP 3: Verify Tokenizer Roundtrip")
    print("-" * 50)

    test_cases = [
        "GPUScheduler",
        "GPU",
        "Scheduler",
        "submit",
        "Что",
        "привет",
        "<system>",
        "</system>",
        "<instruction>",
        "</instruction>",
        "<context>",
        "</context>",
        "<answer>",
        "</answer>",
        "pub fn main() void {}",
    ]

    all_pass = True
    for text in test_cases:
        ids = tokenizer.encode(text)
        decoded = tokenizer.decode(ids)
        has_unk = "?" in decoded and text != "?"
        status = "FAIL" if has_unk else "PASS"
        if has_unk:
            all_pass = False
        print(f"  {text:30s} -> ids={ids[:5]}... -> {repr(decoded[:40]):40s} [{status}]")

    print(f"\n  VERDICT: {'ALL PASS' if all_pass else 'SOME FAIL'}")
    return all_pass


def verify_model(model, tokenizer, new_vocab_size):
    print("\nSTEP 4: Verify Model Forward with Extended Vocab")
    print("-" * 50)

    device = next(model.parameters()).device

    test_tokens = ["GPUScheduler", "GPU", "Scheduler", "<system>", "submit"]
    all_ok = True

    for tok in test_tokens:
        if tok in tokenizer.token_to_id:
            tid = tokenizer.token_to_id[tok]
            x = torch.tensor([[tid]], device=device)
            with torch.no_grad():
                logits, loss = model(x, targets=x)
            finite = torch.isfinite(logits).all().item()
            max_logit = logits.max().item()
            print(f"  {tok:20s} id={tid:5d} logits={logits.shape} finite={finite} max={max_logit:.3f}")
            if not finite or tid >= new_vocab_size:
                all_ok = False
        else:
            print(f"  {tok:20s} NOT IN Vocab")
            all_ok = False

    x = torch.randint(0, new_vocab_size, (1, 32), device=device)
    targets = torch.randint(0, new_vocab_size, (1, 32), device=device)
    with torch.no_grad():
        logits, loss = model(x, targets=targets)

    print(f"\n  Random batch: input={x.shape} logits={logits.shape} loss={loss.item():.4f}")
    print(f"  Logits shape matches vocab: {logits.shape[-1] == new_vocab_size}")

    all_ok = all_ok and logits.shape[-1] == new_vocab_size and torch.isfinite(loss)

    print(f"\n  VERDICT: {'PASS' if all_ok else 'FAIL'}")
    return all_ok


def save_model(model, path):
    print(f"\nSTEP 5: Save Extended Model")
    print("-" * 50)
    state = model.state_dict()
    torch.save(state, path)
    size_mb = os.path.getsize(path) / 1e6
    print(f"  Saved: {path} ({size_mb:.1f} MB)")
    print(f"  Keys: {len(state)} tensors")


def main():
    print("C.13.0.6 TOKENIZER EXTENSION")
    print("=" * 60)

    tokenizer, old_tok_size, new_tok_size = extend_tokenizer()

    model, old_model_vocab = expand_model(new_tok_size)

    tok_ok = verify_tokenizer(tokenizer, new_tok_size)

    model_ok = verify_model(model, tokenizer, new_tok_size)

    if tok_ok and model_ok:
        ckpt_dir = Path(AGENT_BPLUS) / "checkpoints"
        ckpt_dir.mkdir(parents=True, exist_ok=True)
        save_model(model, str(ckpt_dir / "model_extended.pt"))

        tok_path = Path(AGENT_BPLUS) / "knowledge" / "corpus" / "zig_tokenizer.json"
        print(f"\n  Tokenizer: {tok_path}")
        print(f"  Model:     {ckpt_dir / 'model_extended.pt'}")

    print("\n" + "=" * 60)
    if tok_ok and model_ok:
        print("C.13.0.6 TOKENIZER EXTENSION: PASS")
        print(f"  Vocab: {old_tok_size} -> {new_tok_size}")
        print(f"  Model: {old_model_vocab} -> {new_tok_size}")
        print("  Ready to re-run C.13.0.1")
    else:
        print("C.13.0.6 TOKENIZER EXTENSION: FAIL")
        if not tok_ok:
            print("  Tokenizer roundtrip FAILED")
        if not model_ok:
            print("  Model verification FAILED")
    print("=" * 60)


if __name__ == "__main__":
    main()
