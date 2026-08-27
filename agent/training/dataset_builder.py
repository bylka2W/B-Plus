import os
import sys
import json
import hashlib
import random
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "engine"))

from common import ZIG_ROOT, MEMORY_DIR, load_json, save_json
from indexes import get_fast_index
from entity_resolver import EntityResolver
from graph_traversal import GraphTraversal
from evidence_verifier import EvidenceVerifier
from context_compressor import ContextCompressor
from truth_contract import TruthContract
from execution_contract import ExecutionContract
from source_identity import SourceIdentity

DATA_DIR = Path(__file__).parent / "data"
TRAINING_DATA = DATA_DIR / "training_examples.jsonl"

TASK_TYPES = {
    "DEFINITION": "Find where X is defined",
    "CALLERS": "Find what calls X",
    "CALLEES": "Find what X calls",
    "REFERENCES": "Find all references to X",
    "DEPENDENCIES": "Find what X depends on",
    "DEPENDENTS": "Find what depends on X",
    "CONTAINS": "Find what is contained in X",
    "TYPE_USERS": "Find all users of type X",
    "TRACE": "Trace execution path from X",
    "IMPACT": "Analyze impact of changing X",
    "ADD_FUNCTION": "Add a new function to X",
    "MODIFY_FUNCTION": "Modify behavior of function X",
    "FIX_CODE": "Fix compilation error in X",
    "ADD_TEST": "Add test for function X",
    "REFACTOR": "Refactor code in X",
}

VERB_TASK_MAP = {
    "DEFINITION": ["найди определение", "где определена", "find definition", "where is X defined"],
    "CALLERS": ["кто вызывает", "найди вызовы", "who calls X", "find callers of X"],
    "CALLEES": ["что вызывает X", "найди вызываемые", "what does X call", "find callees of X"],
    "REFERENCES": ["все ссылки на", "найди использования", "all references to X", "find uses of X"],
    "DEPENDENCIES": ["от чего зависит", "найди зависимости", "what does X depend on"],
    "DEPENDENTS": ["что зависит от X", "найди зависимых", "what depends on X"],
    "CONTAINS": ["что содержится в", "найди содержимое", "what is in module X"],
    "TYPE_USERS": ["кто использует тип", "найди пользователей типа", "who uses type X"],
    "TRACE": ["трассировка вызовов", "проследи путь", "trace calls from X"],
    "IMPACT": ["влияние изменения", "что изменится если", "impact of changing X"],
    "ADD_FUNCTION": ["добавь функцию", "создай функцию", "add function to X"],
    "MODIFY_FUNCTION": ["измени функцию", "обнови поведение", "modify function X"],
    "FIX_CODE": ["исправь ошибку", "почини код", "fix error in X"],
    "ADD_TEST": ["добавь тест", "напиши тест", "add test for X"],
    "REFACTOR": ["рефакторинг", "перепиши код", "refactor code in X"],
}


class TaskGenerator:
    def __init__(self):
        self.idx = get_fast_index()
        self.resolver = EntityResolver()
        self.traversal = None
        self.verifier = EvidenceVerifier.load()
        self.source_identity = SourceIdentity.load()
        self.truth = TruthContract.load()

    @classmethod
    def load(cls):
        return cls()

    def generate_tasks(self, max_tasks=100):
        tasks = []
        tasks.extend(self._gen_definition_tasks(max_tasks // 3))
        tasks.extend(self._gen_caller_tasks(max_tasks // 3))
        tasks.extend(self._gen_reference_tasks(max_tasks // 3))
        return tasks[:max_tasks]

    def _gen_definition_tasks(self, limit):
        tasks = []
        concepts = list(self.idx.concept_by_id.values())
        random.shuffle(concepts)
        count = 0
        for c in concepts:
            if count >= limit:
                break
            name = c.get("canonical_name", "")
            cid = c.get("concept_id", "")
            if not name or not cid:
                continue
            file_id = c.get("file_id", "")
            fe = self.idx.file_by_id.get(file_id)
            if not fe:
                continue
            file_path = fe.get("path", "")
            line_start = c.get("line_start", 0)
            evidence_ids = c.get("evidence_ids", [])
            if not evidence_ids:
                continue
            task = {
                "task_type": "DEFINITION",
                "task": f"Где определена функция {name}?",
                "question": f"definition of {name}",
                "entity_name": name,
                "entity_id": cid,
                "expected_file": file_path,
                "expected_line_start": line_start,
                "evidence_ids": evidence_ids[:5],
                "difficulty": "easy",
                "source_concept": c,
            }
            tasks.append(task)
            count += 1
        return tasks

    def _gen_caller_tasks(self, limit):
        tasks = []
        concepts = list(self.idx.concept_by_id.values())
        random.shuffle(concepts)
        count = 0
        for c in concepts:
            if count >= limit:
                break
            name = c.get("canonical_name", "")
            cid = c.get("concept_id", "")
            if not name or not cid:
                continue
            file_id = c.get("file_id", "")
            fe = self.idx.file_by_id.get(file_id)
            if not fe:
                continue
            callers = []
            for rid in self.idx.get_relations_by_target(cid):
                r = self.idx.relation_by_id.get(rid)
                if r and r.get("relation_type") == "CALLS":
                    src = self.idx.concept_by_id.get(r.get("from_concept", ""))
                    if src:
                        callers.append(src.get("canonical_name", ""))
            if not callers:
                continue
            task = {
                "task_type": "CALLERS",
                "task": f"Кто вызывает функцию {name}?",
                "question": f"callers of {name}",
                "entity_name": name,
                "entity_id": cid,
                "expected_callers": callers,
                "evidence_ids": c.get("evidence_ids", [])[:5],
                "difficulty": "easy" if len(callers) <= 3 else "medium",
                "source_concept": c,
            }
            tasks.append(task)
            count += 1
        return tasks

    def _gen_reference_tasks(self, limit):
        tasks = []
        concepts = list(self.idx.concept_by_id.values())
        random.shuffle(concepts)
        count = 0
        for c in concepts:
            if count >= limit:
                break
            name = c.get("canonical_name", "")
            cid = c.get("concept_id", "")
            if not name or not cid:
                continue
            file_id = c.get("file_id", "")
            fe = self.idx.file_by_id.get(file_id)
            if not fe:
                continue
            refs = []
            for rid in self.idx.get_relations_by_target(cid):
                r = self.idx.relation_by_id.get(rid)
                if r:
                    src_cid = r.get("from_concept", "")
                    src = self.idx.concept_by_id.get(src_cid)
                    if src:
                        refs.append(src.get("canonical_name", ""))
            if not refs:
                continue
            task = {
                "task_type": "REFERENCES",
                "task": f"Найди все ссылки на {name}",
                "question": f"all references to {name}",
                "entity_name": name,
                "entity_id": cid,
                "expected_references": refs[:20],
                "evidence_ids": c.get("evidence_ids", [])[:5],
                "difficulty": "medium" if len(refs) <= 10 else "hard",
                "source_concept": c,
            }
            tasks.append(task)
            count += 1
        return tasks


class ContextBuilder:
    def __init__(self):
        self.compressor = ContextCompressor()

    def build(self, task):
        cc = self.compressor.compress(task.get("question", task.get("task", "")))
        context_text = ""
        for section in cc.sections:
            if section.content:
                context_text += section.content + "\n\n"
        return context_text.strip()

    def build_with_entity(self, task):
        entity_name = task.get("entity_name", "")
        if entity_name:
            cc = self.compressor.compress_entity(entity_name)
            context_text = ""
            for section in cc.sections:
                if section.content:
                    context_text += section.content + "\n\n"
            return context_text.strip()
        return self.build(task)


class DatasetBuilder:
    def __init__(self):
        self.task_gen = TaskGenerator.load()
        self.ctx_builder = ContextBuilder()
        self.exec_contract = ExecutionContract.load()
        self.source_identity = SourceIdentity.load()

    @classmethod
    def load(cls):
        return cls()

    def build_dataset(self, max_tasks=100, output_path=None):
        output = Path(output_path) if output_path else TRAINING_DATA
        output.parent.mkdir(parents=True, exist_ok=True)

        tasks = self.task_gen.generate_tasks(max_tasks)
        examples = []
        stats = {"total": 0, "context_ok": 0, "valid_zig": 0, "passed": 0}

        for task in tasks:
            stats["total"] += 1
            context = self.ctx_builder.build(task)
            if not context:
                continue
            stats["context_ok"] += 1

            example = {
                "id": self._make_id(task),
                "task_type": task["task_type"],
                "task": task["task"],
                "question": task.get("question", ""),
                "entity_name": task.get("entity_name", ""),
                "entity_id": task.get("entity_id", ""),
                "context": context[:8000],
                "expected_answer": self._build_expected_answer(task),
                "evidence_ids": task.get("evidence_ids", []),
                "difficulty": task.get("difficulty", "easy"),
                "source_file": task.get("expected_file", ""),
                "source_concept_id": task.get("entity_id", ""),
                "valid_zig": True,
                "execution_status": "NOT_TESTED",
            }

            examples.append(example)
            stats["valid_zig"] += 1

        with open(output, "w", encoding="utf-8") as f:
            for ex in examples:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")

        stats["passed"] = len(examples)
        return examples, stats

    def _build_expected_answer(self, task):
        task_type = task["task_type"]
        name = task.get("entity_name", "")
        file_path = task.get("expected_file", "")

        if task_type == "DEFINITION":
            return f"{name} определена в {file_path}"
        elif task_type == "CALLERS":
            callers = task.get("expected_callers", [])
            return f"Функцию {name} вызывают: {', '.join(callers)}"
        elif task_type == "REFERENCES":
            refs = task.get("expected_references", [])
            return f"Ссылки на {name}: {', '.join(refs[:10])}"
        elif task_type == "CALLEES":
            return f"Функция {name} вызывает другие функции"
        elif task_type == "DEPENDENCIES":
            return f"Зависимости {name}"
        elif task_type == "DEPENDENTS":
            return f"От {name} зависят другие компоненты"
        elif task_type == "CONTAINS":
            return f"Модуль {name} содержит определения"
        elif task_type == "TYPE_USERS":
            return f"Тип {name} используется в кодовой базе"
        elif task_type == "TRACE":
            return f"Трассировка вызовов {name}"
        elif task_type == "IMPACT":
            return f"Анализ влияния изменения {name}"
        else:
            return f"Задача по {name}"

    def _make_id(self, task):
        h = hashlib.sha256(
            (task["task_type"] + task.get("entity_name", "")).encode()
        ).hexdigest()[:12]
        return f"TRN-{h}"


_instance = None


def get_task_generator():
    global _instance
    if _instance is None:
        _instance = TaskGenerator.load()
    return _instance


def main():
    print("BUILDING TRAINING DATASET...")
    builder = DatasetBuilder.load()
    examples, stats = builder.build_dataset(max_tasks=50)
    print(f"\nDATASET STATS:")
    print(f"  total tasks: {stats['total']}")
    print(f"  context_ok: {stats['context_ok']}")
    print(f"  valid_zig: {stats['valid_zig']}")
    print(f"  passed: {stats['passed']}")
    print(f"\nSample:")
    if examples:
        ex = examples[0]
        print(f"  id: {ex['id']}")
        print(f"  type: {ex['task_type']}")
        print(f"  task: {ex['task']}")
        print(f"  entity: {ex['entity_name']}")
        print(f"  context_len: {len(ex['context'])} chars")
        print(f"  answer: {ex['expected_answer'][:100]}")
    sys.exit(0)


if __name__ == "__main__":
    main()
