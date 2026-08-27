import os
import sys
import json
import time
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "engine"))

from common import ZIG_ROOT, load_json, save_json
from indexes import get_fast_index
from entity_resolver import EntityResolver
from evidence_verifier import EvidenceVerifier
from truth_contract import TruthContract
from execution_contract import ExecutionContract

DATA_DIR = Path(__file__).parent / "data"


class TrainingExampleValidator:
    def __init__(self):
        self.idx = get_fast_index()
        self.resolver = EntityResolver()
        self.verifier = EvidenceVerifier.load()
        self.truth = TruthContract.load()
        self.exec_contract = ExecutionContract.load()

    @classmethod
    def load(cls):
        return cls()

    def validate_example(self, example):
        errors = []

        required_fields = ["id", "task_type", "task", "question", "entity_name",
                          "entity_id", "context", "expected_answer", "evidence_ids",
                          "difficulty"]
        for field in required_fields:
            if field not in example or not example[field]:
                errors.append(f"missing field: {field}")

        if "task_type" in example:
            valid_types = {
                "DEFINITION", "CALLERS", "CALLEES", "REFERENCES",
                "DEPENDENCIES", "DEPENDENTS", "CONTAINS", "TYPE_USERS",
                "TRACE", "IMPACT", "ADD_FUNCTION", "MODIFY_FUNCTION",
                "FIX_CODE", "ADD_TEST", "REFACTOR",
            }
            if example["task_type"] not in valid_types:
                errors.append(f"invalid task_type: {example['task_type']}")

        if "difficulty" in example:
            if example["difficulty"] not in {"easy", "medium", "hard", "very_hard"}:
                errors.append(f"invalid difficulty: {example['difficulty']}")

        if "entity_id" in example and example["entity_id"]:
            cid = example["entity_id"]
            concept = self.idx.concept_by_id.get(cid)
            if not concept:
                errors.append(f"entity not found: {cid}")

        if "evidence_ids" in example and example["evidence_ids"]:
            for eid in example["evidence_ids"][:3]:
                ev = self.idx.evidence_by_id.get(eid)
                if not ev:
                    errors.append(f"evidence not found: {eid}")

        if "context" in example:
            ctx = example["context"]
            if len(ctx) < 50:
                errors.append(f"context too short: {len(ctx)} chars")
            if len(ctx) > 100000:
                errors.append(f"context too long: {len(ctx)} chars")

        return errors

    def validate_dataset(self, dataset_path=None):
        path = Path(dataset_path) if dataset_path else DATA_DIR / "training_examples.jsonl"
        if not path.exists():
            return {"exists": False, "errors": ["file not found"]}

        examples = []
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    examples.append(json.loads(line))

        all_errors = []
        valid_count = 0
        for i, ex in enumerate(examples):
            errors = self.validate_example(ex)
            if errors:
                all_errors.append({"index": i, "id": ex.get("id", "?"), "errors": errors})
            else:
                valid_count += 1

        return {
            "exists": True,
            "total": len(examples),
            "valid": valid_count,
            "invalid": len(examples) - valid_count,
            "errors": all_errors[:50],
            "validity_rate": valid_count / max(len(examples), 1),
        }

    def validate_answer_accuracy(self, dataset_path=None):
        path = Path(dataset_path) if dataset_path else DATA_DIR / "training_examples.jsonl"
        if not path.exists():
            return {"exists": False}

        examples = []
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    examples.append(json.loads(line))

        accurate = 0
        total = 0
        for ex in examples:
            if not ex.get("expected_answer"):
                continue
            total += 1
            answer = ex["expected_answer"]
            entity = ex.get("entity_name", "")
            if entity and entity in answer:
                accurate += 1

        return {
            "total": total,
            "accurate": accurate,
            "accuracy": accurate / max(total, 1),
        }


_instance = None


def get_dataset_validator():
    global _instance
    if _instance is None:
        _instance = TrainingExampleValidator.load()
    return _instance


def main():
    print("VALIDATING TRAINING DATASET...")
    validator = TrainingExampleValidator.load()
    result = validator.validate_dataset()
    print(f"\nVALIDATION RESULT:")
    print(f"  exists: {result['exists']}")
    print(f"  total: {result.get('total', 0)}")
    print(f"  valid: {result.get('valid', 0)}")
    print(f"  invalid: {result.get('invalid', 0)}")
    print(f"  validity_rate: {result.get('validity_rate', 0):.2%}")
    if result.get("errors"):
        print(f"\n  First errors:")
        for e in result["errors"][:3]:
            print(f"    [{e['id']}] {e['errors']}")

    acc = validator.validate_answer_accuracy()
    print(f"\nANSWER ACCURACY:")
    print(f"  total: {acc.get('total', 0)}")
    print(f"  accurate: {acc.get('accurate', 0)}")
    print(f"  accuracy: {acc.get('accuracy', 0):.2%}")
    sys.exit(0)


if __name__ == "__main__":
    main()
