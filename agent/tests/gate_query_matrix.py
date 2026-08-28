"""
STAGE 2 RELEASE GATE — QUERY CORRECTNESS MATRIX
Tests every entity_type x intent combination.
Expected: VERIFIED (match), TYPE_MISMATCH (wrong type), NOT_FOUND, AMBIGUOUS.
"""
import os
import sys
import json
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "engine"))

from common import MEMORY_DIR, load_json
from knowledge import Knowledge
from evidence_bundle import build_evidence_bundle
from protocol import is_terminal


def pick_sample(concepts_doc, concept_type):
    for c in concepts_doc["items"]:
        if c["concept_type"] == concept_type and c.get("verification_status") == "VERIFIED":
            return c["canonical_name"].rsplit("/", 1)[-1]
    return None


def main():
    print("=" * 70)
    print("STAGE 2 RELEASE GATE — QUERY CORRECTNESS MATRIX")
    print("=" * 70)

    concepts_doc = load_json(MEMORY_DIR / "concepts.json")
    k = Knowledge.load()

    func = pick_sample(concepts_doc, "FUNCTION")
    struct = pick_sample(concepts_doc, "STRUCT")
    module = "build.zig"

    print(f"Samples: func={func}, struct={struct}, module={module}")

    entity_intents = {
        "FUNCTION": {"entity": func, "intents": {
            "DEFINITION": "VERIFIED",
            "CALLERS": "VERIFIED",
            "CALLEES": "VERIFIED",
            "REFERENCES": "VERIFIED",
            "CONTAINS": "TYPE_MISMATCH",
            "DEPENDENCIES": "TYPE_MISMATCH",
        }},
        "STRUCT": {"entity": struct, "intents": {
            "DEFINITION": "VERIFIED",
            "CALLERS": "VERIFIED",
            "CALLEES": "VERIFIED",
            "REFERENCES": "VERIFIED",
            "CONTAINS": "VERIFIED",
            "DEPENDENCIES": "TYPE_MISMATCH",
        }},
        "MODULE": {"entity": module, "intents": {
            "DEFINITION": "VERIFIED",
            "CALLERS": "TYPE_MISMATCH",
            "CALLEES": "TYPE_MISMATCH",
            "REFERENCES": "VERIFIED",
            "CONTAINS": "VERIFIED",
            "DEPENDENCIES": "VERIFIED",
        }},
        "NONEXISTENT": {"entity": "DefinitelyFakeFunction_Matrix999", "intents": {
            "DEFINITION": "NEEDS_DEEP",
            "CALLERS": "NEEDS_DEEP",
            "CALLEES": "NEEDS_DEEP",
            "REFERENCES": "NEEDS_DEEP",
            "CONTAINS": "NEEDS_DEEP",
            "DEPENDENCIES": "NEEDS_DEEP",
        }},
    }

    INTENT_TEMPLATE = {
        "DEFINITION": "Where is {e} defined?",
        "CALLERS": "Who calls {e}?",
        "CALLEES": "What does {e} call?",
        "REFERENCES": "Where is {e} used?",
        "CONTAINS": "What does module {e} contain?",
        "DEPENDENCIES": "What does {e} depend on?",
    }

    results = []
    total = 0
    passed = 0
    failed = 0

    for etype, spec in entity_intents.items():
        entity = spec["entity"]
        if not entity:
            print(f"\n  SKIP {etype}: no sample entity")
            continue
        print(f"\n--- {etype}: {entity} ---")
        for intent, expected in spec["intents"].items():
            template = INTENT_TEMPLATE.get(intent, "Show {e}")
            question = template.format(e=entity)
            bd = build_evidence_bundle(k, question, None).to_dict()
            actual_status = bd["status"]
            actual_answer = bd["answer_type"]

            if expected == "VERIFIED":
                ok = actual_answer != "TYPE_MISMATCH" and actual_status not in (
                    "NEEDS_DEEP_SEARCH", "UNKNOWN")
            elif expected == "TYPE_MISMATCH":
                ok = actual_answer == "TYPE_MISMATCH"
            elif expected == "NEEDS_DEEP":
                ok = actual_status in ("NEEDS_DEEP_SEARCH", "UNKNOWN")
            else:
                ok = True

            total += 1
            if ok:
                passed += 1
                mark = "PASS"
            else:
                failed += 1
                mark = "FAIL"
            results.append({
                "entity_type": etype, "intent": intent,
                "expected": expected, "actual": actual_status,
                "answer_type": actual_answer, "status": mark,
            })
            print(f"  [{mark}] {intent:14} expected={expected:10} "
                  f"got={actual_status:16} answer={actual_answer}")

    print(f"\n{'='*70}")
    print(f"RESULT: {passed}/{total} PASS, {failed} FAIL")
    print(f"STATUS: {'ALL PASS' if failed == 0 else 'GATE FAILED'}")
    print(f"{'='*70}")

    with open(MEMORY_DIR / "query_matrix_audit.json", "w") as f:
        json.dump({
            "timestamp": time.time(),
            "results": results,
            "passed": passed,
            "failed": failed,
            "total": total,
            "all_pass": failed == 0,
        }, f, indent=2)
    print(f"Saved: memory/query_matrix_audit.json")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
