import sys
import os
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from engine.model_adapter import (
    ModelAdapter, TaskContext, ModelRequest, ModelResponse, TaskResult,
    get_model_adapter,
    STATUS_QUEUED, STATUS_CONTEXT_READY, STATUS_PATCH_READY,
    STATUS_VERIFIED, STATUS_EXECUTED, STATUS_FAILED, STATUS_REJECTED,
    ALL_TASK_STATUSES, OUTPUT_PATCH, OUTPUT_ANSWER, ALL_OUTPUT_FORMATS,
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


def test_constants():
    check("ALL_TASK_STATUSES has 8", len(ALL_TASK_STATUSES) == 8)
    check("ALL_OUTPUT_FORMATS has 3", len(ALL_OUTPUT_FORMATS) == 3)
    check("OUTPUT_PATCH", OUTPUT_PATCH in ALL_OUTPUT_FORMATS)


def test_load():
    ma = ModelAdapter.load()
    check("MA loads", ma is not None)
    check("MA has router", hasattr(ma, "router"))
    check("MA has resolver", hasattr(ma, "resolver"))
    check("MA has compressor", hasattr(ma, "compressor"))
    check("MA has truth", hasattr(ma, "truth"))
    check("MA has verifier", hasattr(ma, "verifier"))
    check("MA has exec_contract", hasattr(ma, "exec_contract"))


def test_singleton():
    m1 = get_model_adapter()
    m2 = get_model_adapter()
    check("Singleton", m1 is m2)


def test_task_context():
    tc = TaskContext()
    tc.task_id = "TSK-001"
    tc.task = "test task"
    d = tc.to_dict()
    check("TC.to_dict task_id", d["task_id"] == "TSK-001")
    check("TC.to_dict has constraints", isinstance(d["constraints"], list))


def test_model_request():
    r = ModelRequest()
    r.task_id = "TSK-001"
    r.prompt = "test prompt"
    d = r.to_dict()
    check("MR.to_dict task_id", d["task_id"] == "TSK-001")
    check("MR.to_dict has prompt", "prompt" in d)


def test_model_response():
    r = ModelResponse()
    r.task_id = "TSK-001"
    r.status = "PATCH_READY"
    d = r.to_dict()
    check("MResp.to_dict status", d["status"] == "PATCH_READY")
    check("MResp.to_dict has patch", "patch" in d)


def test_task_result():
    tr = TaskResult()
    tr.task_id = "TSK-001"
    tr.status = STATUS_QUEUED
    d = tr.to_dict()
    check("TR.to_dict status", d["status"] == STATUS_QUEUED)
    check("TR.to_dict has context", "context" in d)


def test_prepare_task():
    ma = ModelAdapter.load()
    tc = ma.prepare_task("find foldConstantOp", "definition of foldConstantOp")
    check("prepare returns TaskContext", isinstance(tc, TaskContext))
    check("prepare has task_id", tc.task_id != "")
    check("prepare has intent", tc.intent is not None)
    check("prepare has context", tc.context is not None)
    check("prepare has constraints", len(tc.constraints) > 0)


def test_build_request():
    ma = ModelAdapter.load()
    tc = ma.prepare_task("find foldConstantOp")
    req = ma.build_request(tc)
    check("request has prompt", len(req.prompt) > 0)
    check("request has system_prompt", len(req.system_prompt) > 0)
    check("request has task_id", req.task_id == tc.task_id)


def test_parse_patch():
    ma = ModelAdapter.load()
    raw = "STATUS: PATCH_READY\nFILES: src/bplus.zig\n---\nconst std = @import(\"std\");"
    resp = ma.parse_response(raw)
    check("parse PATCH_READY", resp.status == "PATCH_READY")
    check("parse has files", "src/bplus.zig" in resp.changed_files)
    check("parse has patch", len(resp.patch) > 0)


def test_parse_answer():
    ma = ModelAdapter.load()
    raw = "STATUS: ANSWER_READY\n---\nfoldConstantOp is defined in manager.zig"
    resp = ma.parse_response(raw)
    check("parse ANSWER_READY", resp.status == "ANSWER_READY")
    check("parse has answer", len(resp.answer) > 0)


def test_parse_failed():
    ma = ModelAdapter.load()
    raw = "STATUS: FAILED\nREASON: insufficient context"
    resp = ma.parse_response(raw)
    check("parse FAILED", resp.status == "FAILED")
    check("parse has reason", "insufficient" in resp.explanation.lower())


def test_parse_empty():
    ma = ModelAdapter.load()
    resp = ma.parse_response("")
    check("parse empty FAILED", resp.status == "FAILED")


def test_validate_pass():
    ma = ModelAdapter.load()
    resp = ModelResponse()
    resp.status = "PATCH_READY"
    resp.patch = "const x = 1;"
    resp.changed_files = ["src/bplus.zig"]
    tc = TaskContext()
    tc.allowed_files = ["src/bplus.zig"]
    validated = ma.validate_output(resp, tc)
    check("validate PASS", validated.status == "PATCH_READY")


def test_validate_denied_file():
    ma = ModelAdapter.load()
    resp = ModelResponse()
    resp.status = "PATCH_READY"
    resp.patch = "const x = 1;"
    resp.changed_files = ["evil.zig"]
    tc = TaskContext()
    tc.allowed_files = ["src/bplus.zig"]
    validated = ma.validate_output(resp, tc)
    check("validate denied", validated.status == "FAILED")


def test_run_task():
    ma = ModelAdapter.load()
    result = ma.run_task("find foldConstantOp")
    check("run_task returns TaskResult", isinstance(result, TaskResult))
    check("run_task has context_ready", result.status == STATUS_CONTEXT_READY)
    check("run_task has context", result.context is not None)
    check("run_task has request", result.request is not None)


def test_run_task_with_question():
    ma = ModelAdapter.load()
    result = ma.run_task("add function", "add a new function to bplus.zig")
    check("run_task has intent", result.context.intent is not None)
    check("run_task has constraints", len(result.context.constraints) > 0)


def test_render():
    ma = ModelAdapter.load()
    result = ma.run_task("find foldConstantOp")
    rendered = result.render()
    check("render has TASK", "TASK:" in rendered)
    check("render has STATUS", "STATUS:" in rendered)
    check("render has VERIFIED", "VERIFIED:" in rendered)


def test_system_prompt():
    from engine.model_adapter import SYSTEM_PROMPT
    check("system prompt has rules", "RULES:" in SYSTEM_PROMPT)
    check("system prompt has output format", "output" in SYSTEM_PROMPT.lower())


def test_latency():
    ma = ModelAdapter.load()
    t0 = time.monotonic()
    ma.run_task("find foldConstantOp")
    elapsed = (time.monotonic() - t0) * 1000
    check(f"run_task latency {elapsed:.0f}ms < 500ms", elapsed < 500)


if __name__ == "__main__":
    test_constants()
    test_load()
    test_singleton()
    test_task_context()
    test_model_request()
    test_model_response()
    test_task_result()
    test_prepare_task()
    test_build_request()
    test_parse_patch()
    test_parse_answer()
    test_parse_failed()
    test_parse_empty()
    test_validate_pass()
    test_validate_denied_file()
    test_run_task()
    test_run_task_with_question()
    test_render()
    test_system_prompt()
    test_latency()
    print()
    print(f"MODEL ADAPTER: {PASS} PASS / {FAIL} FAIL")
    sys.exit(0 if FAIL == 0 else 1)
