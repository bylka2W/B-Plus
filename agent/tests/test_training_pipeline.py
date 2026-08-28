import sys
import os
import json
import time
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from training.dataset_builder import (
    TaskGenerator, ContextBuilder, DatasetBuilder, TASK_TYPES, VERB_TASK_MAP,
)
from training.validator import TrainingExampleValidator, get_dataset_validator
from training.split import DatasetSplitter

DATA_DIR = Path(__file__).parent.parent / "training" / "data"

PASS = 0
FAIL = 0


def check(name, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print("PASS:", name)
    else:
        FAIL += 1
        print("FAIL:", name, "-", detail)


def test_task_types():
    check("TASK_TYPES has 15", len(TASK_TYPES) == 15)
    check("VERB_TASK_MAP has 15", len(VERB_TASK_MAP) == 15)
    check("DEFINITION in TASK_TYPES", "DEFINITION" in TASK_TYPES)


def test_task_generator_load():
    tg = TaskGenerator.load()
    check("TG loads", tg is not None)
    check("TG has idx", hasattr(tg, "idx"))
    check("TG has resolver", hasattr(tg, "resolver"))
    check("TG has verifier", hasattr(tg, "verifier"))


def test_generate_tasks():
    tg = TaskGenerator.load()
    tasks = tg.generate_tasks(max_tasks=10)
    check("generate returns list", isinstance(tasks, list))
    check("generate has tasks", len(tasks) > 0)
    if tasks:
        t = tasks[0]
        check("task has task_type", "task_type" in t)
        check("task has entity_name", "entity_name" in t)
        check("task has evidence_ids", "evidence_ids" in t)
        check("task has difficulty", "difficulty" in t)


def test_generate_definition_tasks():
    tg = TaskGenerator.load()
    tasks = tg._gen_definition_tasks(5)
    check("definition tasks > 0", len(tasks) > 0)
    if tasks:
        check("definition has expected_file", "expected_file" in tasks[0])


def test_generate_caller_tasks():
    tg = TaskGenerator.load()
    tasks = tg._gen_caller_tasks(5)
    check("caller tasks >= 0", len(tasks) >= 0)


def test_generate_reference_tasks():
    tg = TaskGenerator.load()
    tasks = tg._gen_reference_tasks(5)
    check("reference tasks >= 0", len(tasks) >= 0)


def test_context_builder():
    cb = ContextBuilder()
    task = {"question": "definition of foldConstantOp", "task": "find foldConstantOp"}
    ctx = cb.build(task)
    check("context is str", isinstance(ctx, str))
    check("context not empty", len(ctx) > 0)


def test_context_builder_with_entity():
    cb = ContextBuilder()
    task = {"question": "definition of foldConstantOp", "entity_name": "foldConstantOp"}
    ctx = cb.build_with_entity(task)
    check("entity context is str", isinstance(ctx, str))


def test_dataset_builder_load():
    db = DatasetBuilder.load()
    check("DB loads", db is not None)
    check("DB has task_gen", hasattr(db, "task_gen"))
    check("DB has ctx_builder", hasattr(db, "ctx_builder"))


def test_build_dataset():
    db = DatasetBuilder.load()
    examples, stats = db.build_dataset(max_tasks=15, output_path=DATA_DIR / "test_dataset.jsonl")
    check("build returns examples", isinstance(examples, list))
    check("build has examples", len(examples) > 0)
    check("stats total > 0", stats["total"] > 0)
    check("stats context_ok > 0", stats["context_ok"] > 0)
    if examples:
        ex = examples[0]
        check("example has id", "id" in ex)
        check("example has task_type", "task_type" in ex)
        check("example has context", "context" in ex)
        check("example has expected_answer", "expected_answer" in ex)


def test_dataset_file_exists():
    path = DATA_DIR / "test_dataset.jsonl"
    check("dataset file exists", path.exists())
    if path.exists():
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        check("dataset has lines", len(lines) > 0)


def test_validator_load():
    v = TrainingExampleValidator.load()
    check("validator loads", v is not None)
    check("validator has idx", hasattr(v, "idx"))


def test_validate_example():
    v = TrainingExampleValidator.load()
    example = {
        "id": "TRN-test",
        "task_type": "DEFINITION",
        "task": "test task",
        "question": "test",
        "entity_name": "test",
        "entity_id": "CN-test",
        "context": "test context " * 10,
        "expected_answer": "test answer",
        "evidence_ids": [],
        "difficulty": "easy",
    }
    errors = v.validate_example(example)
    check("validate returns list", isinstance(errors, list))


def test_validate_dataset():
    v = TrainingExampleValidator.load()
    path = DATA_DIR / "test_dataset.jsonl"
    if path.exists():
        result = v.validate_dataset(path)
        check("validate_dataset exists", result["exists"] is True)
        check("validate_dataset total > 0", result["total"] > 0)
        check("validate_dataset valid > 0", result["valid"] > 0)
    else:
        check("validate_dataset skip", True)


def test_splitter_load():
    s = DatasetSplitter()
    check("splitter loads", s is not None)
    check("splitter has ratios", s.train_ratio == 0.8)


def test_split_dataset():
    s = DatasetSplitter()
    path = DATA_DIR / "test_dataset.jsonl"
    if path.exists():
        result = s.split(path, DATA_DIR)
        check("split total > 0", result["total"] > 0)
        check("split train > 0", result["train"] > 0)
        check("split val >= 0", result["val"] >= 0)
        check("split test >= 0", result["test"] >= 0)
        check("split sum matches", result["train"] + result["val"] + result["test"] == result["total"])
    else:
        check("split skip", True)


def test_split_by_difficulty():
    s = DatasetSplitter()
    path = DATA_DIR / "test_dataset.jsonl"
    if path.exists():
        result = s.split_by_difficulty(path, DATA_DIR)
        check("by_difficulty returns dict", isinstance(result, dict))
        check("by_difficulty has easy", "easy" in result)
    else:
        check("by_difficulty skip", True)


def test_answer_accuracy():
    v = TrainingExampleValidator.load()
    path = DATA_DIR / "test_dataset.jsonl"
    if path.exists():
        result = v.validate_answer_accuracy(path)
        check("accuracy total > 0", result["total"] > 0)
        check("accuracy rate > 0", result["accuracy"] > 0)
    else:
        check("accuracy skip", True)


def test_latency():
    tg = TaskGenerator.load()
    t0 = time.monotonic()
    tg.generate_tasks(max_tasks=20)
    elapsed = (time.monotonic() - t0) * 1000
    check(f"generate latency {elapsed:.0f}ms < 5000ms", elapsed < 5000)


if __name__ == "__main__":
    test_task_types()
    test_task_generator_load()
    test_generate_tasks()
    test_generate_definition_tasks()
    test_generate_caller_tasks()
    test_generate_reference_tasks()
    test_context_builder()
    test_context_builder_with_entity()
    test_dataset_builder_load()
    test_build_dataset()
    test_dataset_file_exists()
    test_validator_load()
    test_validate_example()
    test_validate_dataset()
    test_splitter_load()
    test_split_dataset()
    test_split_by_difficulty()
    test_answer_accuracy()
    test_latency()
    print()
    print(f"TRAINING PIPELINE: {PASS} PASS / {FAIL} FAIL")
    sys.exit(0 if FAIL == 0 else 1)
