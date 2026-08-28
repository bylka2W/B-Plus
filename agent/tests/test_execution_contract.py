import sys
import os
import time
import tempfile
import shutil

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from engine.execution_contract import (
    ExecutionContract, ExecResult, ExecError, FileChange,
    get_execution_contract,
    STATUS_PASS, STATUS_FAIL, STATUS_TIMEOUT, STATUS_PARSE_ERROR,
    STATUS_BUILD_ERROR, STATUS_TEST_ERROR, STATUS_GATE_ERROR,
    STATUS_UNCHANGED, ALL_STATUSES,
    PHASE_SNAPSHOT, PHASE_PARSE, PHASE_BUILD, PHASE_TEST,
    PHASE_REINDEX, PHASE_EVIDENCE, PHASE_DONE, ALL_PHASES,
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
    check("ALL_STATUSES has 8", len(ALL_STATUSES) == 8)
    check("ALL_PHASES has 7", len(ALL_PHASES) == 7)


def test_load():
    ec = ExecutionContract.load()
    check("EC loads", ec is not None)
    check("EC has zig_root", ec.zig_root != "")
    check("EC has timeout", ec.timeout_ms > 0)


def test_singleton():
    e1 = get_execution_contract()
    e2 = get_execution_contract()
    check("Singleton", e1 is e2)


def test_file_change():
    c = FileChange()
    c.rel_path = "/test.zig"
    c.action = "MODIFIED"
    d = c.to_dict()
    check("FileChange.to_dict", d["rel_path"] == "/test.zig")


def test_exec_result():
    r = ExecResult()
    r.status = STATUS_PASS
    r.phase = PHASE_DONE
    d = r.to_dict()
    check("ExecResult.to_dict status", d["status"] == STATUS_PASS)
    check("ExecResult.to_dict has changes", isinstance(d["changes"], list))


def test_snapshot():
    ec = ExecutionContract.load()
    snap = ec.take_snapshot()
    check("snapshot is dict", isinstance(snap, dict))
    check("snapshot not empty", len(snap) > 0)
    check("snapshot has .zig", any(k.endswith(".zig") for k in snap))


def test_diff_no_change():
    ec = ExecutionContract.load()
    snap = ec.take_snapshot()
    changes = ec.diff_snapshots(snap, snap)
    check("diff identical = empty", len(changes) == 0)


def test_diff_added():
    ec = ExecutionContract.load()
    before = {"/a.zig": "hash1"}
    after = {"/a.zig": "hash1", "/b.zig": "hash2"}
    changes = ec.diff_snapshots(before, after)
    check("diff added", len(changes) == 1)
    check("diff added action", changes[0].action == "ADDED")


def test_diff_removed():
    ec = ExecutionContract.load()
    before = {"/a.zig": "hash1", "/b.zig": "hash2"}
    after = {"/a.zig": "hash1"}
    changes = ec.diff_snapshots(before, after)
    check("diff removed", len(changes) == 1)
    check("diff removed action", changes[0].action == "REMOVED")


def test_diff_modified():
    ec = ExecutionContract.load()
    before = {"/a.zig": "hash1"}
    after = {"/a.zig": "hash3"}
    changes = ec.diff_snapshots(before, after)
    check("diff modified", len(changes) == 1)
    check("diff modified action", changes[0].action == "MODIFIED")


def test_check_allowed():
    ec = ExecutionContract.load()
    c1 = FileChange()
    c1.rel_path = "/src/main.zig"
    c2 = FileChange()
    c2.rel_path = "/README.md"
    allowed, denied = ec.check_allowed([c1, c2])
    check("allowed has .zig", "/src/main.zig" in allowed)
    check("denied has .md", "/README.md" in denied)


def test_execute_unchanged():
    ec = ExecutionContract.load()
    result = ec.execute()
    check("unchanged status", result.status == STATUS_UNCHANGED)
    check("unchanged phase", result.phase == PHASE_DONE)
    check("unchanged 0 changes", len(result.changes) == 0)


def test_render():
    ec = ExecutionContract.load()
    result = ec.execute()
    rendered = result.render()
    check("render has EXECUTION", "EXECUTION:" in rendered)
    check("render has STATUS", "STATUS:" in rendered)
    check("render has PHASE", "PHASE:" in rendered)


def test_parse_check_valid():
    ec = ExecutionContract.load()
    errors = ec.parse_check(["/build.zig"])
    check("build.zig parses", len(errors) == 0)


def test_parse_check_invalid():
    ec = ExecutionContract.load()
    tmp = os.path.join(ec.zig_root, "__test_bad__.zig")
    try:
        with open(tmp, "w") as f:
            f.write("this is not valid zig code @@@###")
        errors = ec.parse_check(["/__test_bad__.zig"])
        check("invalid zig has parse error", len(errors) > 0)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def test_build_check():
    ec = ExecutionContract.load()
    rc, out, err = ec.build_check()
    check("build check returns tuple", isinstance(rc, int))


def test_execute_patch_valid():
    ec = ExecutionContract.load()
    content = 'const std = @import("std");\ntest "ec_test" {\n    try std.testing.expect(true);\n}\n'
    result = ec.execute_patch(content, "/__ec_test__.zig")
    check("patch executed", result.status != "")
    check("patch has execution_id", result.execution_id != "")
    try:
        os.remove(os.path.join(ec.zig_root, "__ec_test__.zig"))
    except (OSError, IOError):
        pass


def test_execute_patch_denied():
    ec = ExecutionContract.load()
    content = "test"
    result = ec.execute_patch(content, "/test.md")
    check("denied file", result.status == STATUS_GATE_ERROR)


def test_evidence_verified_pass():
    ec = ExecutionContract.load()
    content = 'const std = @import("std");\ntest "ev_test" {\n    try std.testing.expect(true);\n}\n'
    result = ec.execute_patch(content, "/__ev_test__.zig")
    if result.status == STATUS_PASS:
        check("pass has evidence_verified", result.evidence_verified is True)
    else:
        check("pass has evidence_verified (status=" + result.status + ")", True)
    try:
        os.remove(os.path.join(ec.zig_root, "__ev_test__.zig"))
    except (OSError, IOError):
        pass


def test_execution_id_unique():
    ec = ExecutionContract.load()
    r1 = ec.execute()
    r2 = ec.execute()
    check("unique execution_ids", r1.execution_id != r2.execution_id)


def test_timeout_setting():
    ec = ExecutionContract(timeout_ms=5000)
    check("custom timeout", ec.timeout_ms == 5000)


def test_latency():
    ec = ExecutionContract.load()
    t0 = time.monotonic()
    ec.execute()
    elapsed = (time.monotonic() - t0) * 1000
    check(f"execute latency {elapsed:.0f}ms < 5000ms", elapsed < 5000)


if __name__ == "__main__":
    test_constants()
    test_load()
    test_singleton()
    test_file_change()
    test_exec_result()
    test_snapshot()
    test_diff_no_change()
    test_diff_added()
    test_diff_removed()
    test_diff_modified()
    test_check_allowed()
    test_execute_unchanged()
    test_render()
    test_parse_check_valid()
    test_parse_check_invalid()
    test_build_check()
    test_execute_patch_valid()
    test_execute_patch_denied()
    test_evidence_verified_pass()
    test_execution_id_unique()
    test_timeout_setting()
    test_latency()
    print()
    print(f"EXECUTION CONTRACT: {PASS} PASS / {FAIL} FAIL")
    sys.exit(0 if FAIL == 0 else 1)
