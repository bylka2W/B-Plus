import os
import sys
import json
import random
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "engine"))

DATA_DIR = Path(__file__).parent / "data"


class DatasetSplitter:
    def __init__(self, train_ratio=0.8, val_ratio=0.1, test_ratio=0.1, seed=42):
        self.train_ratio = train_ratio
        self.val_ratio = val_ratio
        self.test_ratio = test_ratio
        self.seed = seed

    def split(self, dataset_path=None, output_dir=None):
        path = Path(dataset_path) if dataset_path else DATA_DIR / "training_examples.jsonl"
        out = Path(output_dir) if output_dir else DATA_DIR
        out.mkdir(parents=True, exist_ok=True)

        examples = []
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    examples.append(json.loads(line))

        random.seed(self.seed)
        random.shuffle(examples)

        n = len(examples)
        n_train = int(n * self.train_ratio)
        n_val = int(n * self.val_ratio)

        train = examples[:n_train]
        val = examples[n_train:n_train + n_val]
        test = examples[n_train + n_val:]

        splits = {"train": train, "val": val, "test": test}
        for name, data in splits.items():
            path_out = out / f"{name}.jsonl"
            with open(path_out, "w", encoding="utf-8") as f:
                for ex in data:
                    f.write(json.dumps(ex, ensure_ascii=False) + "\n")

        return {
            "total": n,
            "train": len(train),
            "val": len(val),
            "test": len(test),
            "train_path": str(out / "train.jsonl"),
            "val_path": str(out / "val.jsonl"),
            "test_path": str(out / "test.jsonl"),
        }

    def split_by_difficulty(self, dataset_path=None, output_dir=None):
        path = Path(dataset_path) if dataset_path else DATA_DIR / "training_examples.jsonl"
        out = Path(output_dir) if output_dir else DATA_DIR
        out.mkdir(parents=True, exist_ok=True)

        examples = []
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    examples.append(json.loads(line))

        by_difficulty = {}
        for ex in examples:
            d = ex.get("difficulty", "easy")
            if d not in by_difficulty:
                by_difficulty[d] = []
            by_difficulty[d].append(ex)

        result = {}
        for diff, exs in by_difficulty.items():
            path_out = out / f"difficulty_{diff}.jsonl"
            with open(path_out, "w", encoding="utf-8") as f:
                for ex in exs:
                    f.write(json.dumps(ex, ensure_ascii=False) + "\n")
            result[diff] = len(exs)

        return result


def main():
    print("SPLITTING DATASET...")
    splitter = DatasetSplitter()
    result = splitter.split()
    print(f"\nSPLIT RESULT:")
    print(f"  total: {result['total']}")
    print(f"  train: {result['train']}")
    print(f"  val: {result['val']}")
    print(f"  test: {result['test']}")

    by_diff = splitter.split_by_difficulty()
    print(f"\nBY DIFFICULTY:")
    for diff, count in by_diff.items():
        print(f"  {diff}: {count}")
    sys.exit(0)


if __name__ == "__main__":
    main()
