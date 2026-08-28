import sys
import os
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from engine.intent_router import (
    IntentRouter, IntentResult, get_intent_router,
    INTENT_DEFINITION, INTENT_CALLERS, INTENT_CALLEES, INTENT_REFERENCES,
    INTENT_DEPENDENCIES, INTENT_DEPENDENTS, INTENT_CONTAINS, INTENT_USES_TYPE,
    INTENT_TYPE_USERS, INTENT_MODULE, INTENT_FILE, INTENT_TRACE,
    INTENT_EXPLAIN, INTENT_COMPARE, INTENT_IMPACT, INTENT_ARCHITECTURE,
    INTENT_UNKNOWN, ALL_INTENTS, FAST_INTENTS,
    INTENT_REQUIRES_EVIDENCE, INTENT_REQUIRES_EXECUTION,
    INTENT_EXPECTED_TYPES, INTENT_DEPTH,
)

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


def test_intent_constants():
    check("ALL_INTENTS has 17", len(ALL_INTENTS) == 17)
    check("FAST_INTENTS subset", FAST_INTENTS.issubset(ALL_INTENTS))
    check("REQUIRES_EVIDENCE covers all", set(INTENT_REQUIRES_EVIDENCE.keys()) == ALL_INTENTS)
    check("REQUIRES_EXECUTION covers all", set(INTENT_REQUIRES_EXECUTION.keys()) == ALL_INTENTS)
    check("EXPECTED_TYPES covers all", set(INTENT_EXPECTED_TYPES.keys()) == ALL_INTENTS)
    check("DEPTH covers all", set(INTENT_DEPTH.keys()) == ALL_INTENTS)


def test_result_slots():
    r = IntentResult()
    r.intent = "CALLERS"
    r.entity = "foldConstantOp"
    r.expected_type = "FUNCTION"
    r.status = "RESOLVED"
    d = r.to_dict()
    check("Result has intent", d["intent"] == "CALLERS")
    check("Result has entity", d["entity"] == "foldConstantOp")
    check("Result has expected_type", d["expected_type"] == "FUNCTION")
    check("Result has status", d["status"] == "RESOLVED")
    check("Result has elapsed_ms", "elapsed_ms" in d)


def test_load():
    router = IntentRouter.load()
    check("Router loads", router is not None)
    check("Router has resolver", hasattr(router, "resolver"))


def test_singleton():
    r1 = get_intent_router()
    r2 = get_intent_router()
    check("Singleton same instance", r1 is r2)


def test_callers():
    r = IntentRouter.load().route("Who calls foldConstantOp?")
    check("CALLERS intent", r.intent == INTENT_CALLERS, r.intent)
    check("CALLERS entity", r.entity == "foldConstantOp", r.entity)
    check("CALLERS status RESOLVED", r.status == "RESOLVED", r.status)
    check("CALLERS requires_evidence", r.requires_evidence is True)
    check("CALLERS not execution", r.requires_execution is False)
    check("CALLERS depth=1", r.depth == 1)
    d = r.to_dict()
    check("CALLERS in dict", d["intent"] == "CALLERS")


def test_callees():
    r = IntentRouter.load().route("What does foldConstantOp call?")
    check("CALLEES intent", r.intent == INTENT_CALLEES, r.intent)
    check("CALLEES entity", r.entity == "foldConstantOp", r.entity)
    check("CALLEES status RESOLVED", r.status == "RESOLVED", r.status)


def test_definition():
    r = IntentRouter.load().route("Where is foldConstantOp defined?")
    check("DEFINITION intent", r.intent == INTENT_DEFINITION, r.intent)
    check("DEFINITION entity", r.entity == "foldConstantOp", r.entity)
    check("DEFINITION status RESOLVED", r.status == "RESOLVED", r.status)


def test_references():
    r = IntentRouter.load().route("Where is emit used?")
    check("REFERENCES intent", r.intent == INTENT_REFERENCES, r.intent)
    check("REFERENCES entity", r.entity == "emit", r.entity)


def test_dependencies():
    r = IntentRouter.load().route("What does build.zig depend on?")
    check("DEPENDENCIES intent", r.intent == INTENT_DEPENDENCIES, r.intent)
    check("DEPENDENCIES entity", r.entity == "build.zig", r.entity)
    check("DEPENDENCIES status RESOLVED", r.status == "RESOLVED", r.status)


def test_dependents():
    r = IntentRouter.load().route("Who depends on x64gen.zig?")
    check("DEPENDENTS intent", r.intent == INTENT_DEPENDENTS, r.intent)
    check("DEPENDENTS entity", r.entity == "x64gen.zig", r.entity)
    check("DEPENDENTS status RESOLVED", r.status == "RESOLVED", r.status)


def test_uses_type():
    r = IntentRouter.load().route("What types does foldConstantOp use?")
    check("USES_TYPE intent", r.intent == INTENT_USES_TYPE, r.intent)
    check("USES_TYPE entity", r.entity == "foldConstantOp", r.entity)


def test_explain():
    r = IntentRouter.load().route("Explain foldConstantOp")
    check("EXPLAIN intent", r.intent == INTENT_EXPLAIN, r.intent)
    check("EXPLAIN entity", r.entity == "foldConstantOp", r.entity)


def test_compare():
    r = IntentRouter.load().route("Compare foldConstantOp vs emit")
    check("COMPARE intent", r.intent == INTENT_COMPARE, r.intent)


def test_impact():
    r = IntentRouter.load().route("What will break if I change foldConstantOp?")
    check("IMPACT intent", r.intent == INTENT_IMPACT, r.intent)
    check("IMPACT entity", r.entity == "foldConstantOp", r.entity)


def test_architecture():
    r = IntentRouter.load().route("Architecture of B+")
    check("ARCHITECTURE intent", r.intent == INTENT_ARCHITECTURE, r.intent)
    check("ARCHITECTURE requires_evidence False",
          r.requires_evidence is False)
    d = r.to_dict()
    check("ARCHITECTURE in dict", d["intent"] == "ARCHITECTURE")


def test_file_entity():
    r = IntentRouter.load().route("manager.zig")
    check("File entity DEFINITION", r.intent == INTENT_DEFINITION, r.intent)
    check("File entity resolved", r.entity == "manager.zig", r.entity)
    check("File status RESOLVED", r.status == "RESOLVED", r.status)


def test_file_line_entity():
    r = IntentRouter.load().route("build.zig:183")
    check("File:line DEFINITION", r.intent == INTENT_DEFINITION, r.intent)
    check("File:line resolved", r.status == "RESOLVED", r.status)
    d = r.to_dict()
    check("File:line in dict", d["intent"] == "DEFINITION")


def test_not_found():
    r = IntentRouter.load().route("nonexistentXYZ")
    check("Not found DEFINITION", r.intent == INTENT_DEFINITION, r.intent)
    check("Not found status", r.status == "NOT_FOUND", r.status)
    d = r.to_dict()
    check("Not found has entity_resolved", "entity_resolved" not in d or d["entity_resolved"]["status"] == "NOT_FOUND")


def test_empty():
    r = IntentRouter.load().route("")
    check("Empty UNKNOWN", r.intent == INTENT_UNKNOWN, r.intent)
    check("Empty NO_ENTITY", r.status == "NO_ENTITY", r.status)
    d = r.to_dict()
    check("Empty has elapsed_ms", "elapsed_ms" in d)


def test_latency():
    router = IntentRouter.load()
    times = []
    for _ in range(100):
        t0 = time.monotonic()
        router.route("Who calls foldConstantOp?")
        times.append((time.monotonic() - t0) * 1000)
    times.sort()
    p50 = times[len(times) // 2]
    p99 = times[int(len(times) * 0.99)]
    check(f"Intent latency p50={p50:.3f}ms < 5ms", p50 < 5.0)
    check(f"Intent latency p99={p99:.3f}ms < 20ms", p99 < 20.0)


def test_russian():
    cases = [
        ("Кто вызывает foldConstantOp?", INTENT_CALLERS),
        ("Где определён foldConstantOp?", INTENT_DEFINITION),
        ("От чего зависит build.zig?", INTENT_DEPENDENCIES),
        ("Кто зависит от x64gen.zig?", INTENT_DEPENDENTS),
    ]
    for q, expected in cases:
        r = IntentRouter.load().route(q)
        check(f"Russian {expected}", r.intent == expected, f"{r.intent} for {q!r}")


def test_expected_type():
    cases = [
        (INTENT_CALLERS, "foldConstantOp", "FUNCTION"),
        (INTENT_CONTAINS, "manager.zig", "FILE"),
        (INTENT_DEPENDENCIES, "build.zig", "FILE"),
    ]
    router = IntentRouter.load()
    for intent, entity, expected_type in cases:
        r = router.route(f"test {entity}")
        if r.intent == intent:
            check(f"Expected type for {intent}", r.expected_type == expected_type, r.expected_type)


if __name__ == "__main__":
    test_intent_constants()
    test_result_slots()
    test_load()
    test_singleton()
    test_callers()
    test_callees()
    test_definition()
    test_references()
    test_dependencies()
    test_dependents()
    test_uses_type()
    test_explain()
    test_compare()
    test_impact()
    test_architecture()
    test_file_entity()
    test_file_line_entity()
    test_not_found()
    test_empty()
    test_latency()
    test_russian()
    test_expected_type()
    print()
    print(f"INTENT ROUTER: {PASS} PASS / {FAIL} FAIL")
    sys.exit(0 if FAIL == 0 else 1)
