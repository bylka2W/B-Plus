"""
Instruction dataset for training on instruction→code pairs.
Reads from instruction_train.jsonl / instruction_val.jsonl.
Supports curriculum weighting by category difficulty.
"""
import json, random
from pathlib import Path
from torch.utils.data import Dataset

DATASET_DIR = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset")


class InstructionDataset(Dataset):
    """
    Tokenizes instruction + output into a single sequence for next-token prediction.
    Format: [instruction_tokens] [output_tokens]
    Target: shifted by 1 (standard autoregressive).
    """

    def __init__(self, tokenizer, split="train", seq_len=1024, max_records=None):
        self.tokenizer = tokenizer
        self.seq_len = seq_len
        self.chunks = []

        # Try combined first, fall back to instruction
        path = DATASET_DIR / f"combined_{split}.jsonl"
        if not path.exists():
            path = DATASET_DIR / f"instruction_{split}.jsonl"
        records = []
        with open(path, encoding="utf-8") as f:
            for i, line in enumerate(f):
                if max_records and i >= max_records:
                    break
                if line.strip():
                    records.append(json.loads(line))

        # Tokenize all records into flat token stream
        all_tokens = []
        for r in records:
            instruction = r.get("instruction", "")
            output = r.get("output", "")
            # Format: "INSTRUCTION:\n{instruction}\n\nOUTPUT:\n{output}"
            text = f"INSTRUCTION:\n{instruction}\n\nOUTPUT:\n{output}"
            ids = tokenizer.encode(text)
            if len(ids) < 10:
                continue
            all_tokens.extend(ids)
            all_tokens.append(tokenizer.eos_token_id() if hasattr(tokenizer, 'eos_token_id') else 0)

        # Chunk into seq_len + 1 windows
        for i in range(0, len(all_tokens) - seq_len, seq_len):
            chunk = all_tokens[i:i + seq_len + 1]
            if len(chunk) == seq_len + 1:
                self.chunks.append(chunk)

    def __len__(self):
        return len(self.chunks)

    def __getitem__(self, idx):
        import torch
        chunk = self.chunks[idx]
        x = torch.tensor(chunk[:-1], dtype=torch.long)
        y = torch.tensor(chunk[1:], dtype=torch.long)
        return x, y


class CurriculumSampler:
    """
    Weighted sampler that gradually increases difficulty.
    Early training: more code_write, zig_syntax.
    Later training: more bplus_*, hard_example.
    """

    def __init__(self, dataset, records, step=0, warmup=1000):
        self.dataset = dataset
        self.weights = self._compute_weights(records, step, warmup)

    def _compute_weights(self, records, step, warmup):
        # Difficulty weights by category
        difficulty = {
            "zig_syntax": 0.3,
            "code_write": 0.5,
            "code_complete": 0.6,
            "code_explain": 0.7,
            "code_test": 0.8,
            "bplus_locate": 0.9,
            "bplus_arch": 0.9,
            "hard_example": 1.0,
        }
        # Progress: 0 at step=0, 1 at step=warmup
        progress = min(1.0, step / max(1, warmup))

        weights = []
        for r in records:
            cat = r.get("category", "code_write")
            base = difficulty.get(cat, 0.5)
            # Early: prefer easier. Later: prefer harder.
            w = base * progress + (1 - progress) * 0.5
            weights.append(w)
        return weights


def build_instruction_dataloaders(tokenizer, seq_len=1024, batch_size=2, split="train"):
    """Build DataLoader from instruction dataset."""
    from torch.utils.data import DataLoader

    ds = InstructionDataset(tokenizer, split=split, seq_len=seq_len)
    loader = DataLoader(ds, batch_size=batch_size, shuffle=(split == "train"),
                       drop_last=True, num_workers=0, pin_memory=True)
    return loader, len(ds)
