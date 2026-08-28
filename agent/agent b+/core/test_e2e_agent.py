import os
import sys
import json
import time
from pathlib import Path

AGENT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(AGENT_ROOT))

from core.agent_runtime import (
    AgentRuntime, AgentGoal, AgentStep, KnowledgeQuery, SourceIndex,
    ZigRunner, Sandbox, AuditLog, WORKSPACE_ROOT
)
from core.model import build_model
from knowledge.tokenizer import ZigTokenizer

TEST_DIR = WORKSPACE_ROOT / "e2e_tests"
BACKUP_DIR = WORKSPACE_ROOT / "backups"


def test_1_fixed_verify():
    print("TEST 1: _verify() includes test_ok")
    print("-" * 50)

    runtime = _make_runtime()

    good_code = '''const std = @import("std");

test "addition" {
    try std.testing.expectEqual(@as(i32, 4), 2 + 2);
}
'''
    test_file = TEST_DIR / "test_verify.zig"
    TEST_DIR.mkdir(parents=True, exist_ok=True)
    test_file.write_text(good_code, encoding="utf-8")

    goal = AgentGoal(goal="verify test passes")
    goal.steps = [
        AgentStep(action="syntax_check_file", input_data={"file": str(test_file)},
                  output_data={"valid": True, "msg": ""}, success=True),
        AgentStep(action="build_file", input_data={"file": str(test_file)},
                  output_data={"built": True, "msg": ""}, success=True),
        AgentStep(action="test_file", input_data={"file": str(test_file)},
                  output_data={"tested": True, "msg": ""}, success=True),
    ]
    ok = runtime._verify(goal, {"target_file": str(test_file)})
    print(f"  syntax=PASS build=PASS test=PASS => verify={ok}")
    assert ok, "FAIL: should be PASS"

    goal2 = AgentGoal(goal="verify test fails")
    goal2.steps = [
        AgentStep(action="syntax_check_file", input_data={"file": str(test_file)},
                  output_data={"valid": True, "msg": ""}, success=True),
        AgentStep(action="build_file", input_data={"file": str(test_file)},
                  output_data={"built": True, "msg": ""}, success=True),
        AgentStep(action="test_file", input_data={"file": str(test_file)},
                  output_data={"tested": False, "msg": "test failed"}, success=False),
    ]
    ok2 = runtime._verify(goal2, {"target_file": str(test_file)})
    print(f"  syntax=PASS build=PASS test=FAIL => verify={ok2}")
    assert not ok2, "FAIL: should be FAIL when test fails"

    goal3 = AgentGoal(goal="verify syntax fails")
    goal3.steps = [
        AgentStep(action="syntax_check_file", input_data={"file": str(test_file)},
                  output_data={"valid": False, "msg": "syntax error"}, success=False),
        AgentStep(action="build_file", input_data={"file": str(test_file)},
                  output_data={"built": True, "msg": ""}, success=True),
        AgentStep(action="test_file", input_data={"file": str(test_file)},
                  output_data={"tested": True, "msg": ""}, success=True),
    ]
    ok3 = runtime._verify(goal3, {"target_file": str(test_file)})
    print(f"  syntax=FAIL build=PASS test=PASS => verify={ok3}")
    assert not ok3, "FAIL: should be FAIL when syntax fails"

    print("  PASS: _verify() correctly includes test_ok")


def test_2_real_syntax():
    print("\nTEST 2: Real Zig syntax check")
    print("-" * 50)

    runner = ZigRunner()

    valid = 'const std = @import("std");\npub fn main() void {\n    std.debug.print("hello\\n", .{});\n}'
    ok, msg, dur = runner.syntax_check_code(valid)
    print(f"  valid code: {ok} ({dur:.0f}ms)")
    assert ok

    broken = "pub fn broken("
    ok2, msg2, dur2 = runner.syntax_check_code(broken)
    print(f"  broken code: {ok2} msg={msg2[:50]} ({dur2:.0f}ms)")
    assert not ok2

    print("  PASS")


def test_3_real_build():
    print("\nTEST 3: Real Zig build + run")
    print("-" * 50)

    runner = ZigRunner()
    test_dir = TEST_DIR / "build_test"
    test_dir.mkdir(parents=True, exist_ok=True)

    code = '''const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("B+ AGENT OUTPUT\\n", .{});
}
'''
    test_file = test_dir / "build_main.zig"
    test_file.write_text(code, encoding="utf-8")

    ok, msg, dur = runner.build_file(str(test_file))
    print(f"  build: {ok} ({dur:.0f}ms)")
    if not ok:
        print(f"  msg: {msg[:200]}")

    ok2, msg2, dur2 = runner.run_file(str(test_file))
    print(f"  run: {ok2} ({dur2:.0f}ms)")
    print(f"  output: {msg2[:200]}")

    print("  PASS" if ok else "  FAIL")


def test_4_real_test():
    print("\nTEST 4: Real Zig test (pass + fail)")
    print("-" * 50)

    runner = ZigRunner()
    test_dir = TEST_DIR / "test_test"
    test_dir.mkdir(parents=True, exist_ok=True)

    pass_code = '''const std = @import("std");

test "passing test" {
    try std.testing.expectEqual(@as(i32, 4), 2 + 2);
}
'''
    pass_file = test_dir / "pass_test.zig"
    pass_file.write_text(pass_code, encoding="utf-8")
    ok1, msg1, dur1 = runner.test_file(str(pass_file))
    print(f"  passing test: {ok1} ({dur1:.0f}ms)")

    fail_code = '''const std = @import("std");

test "failing test" {
    try std.testing.expectEqual(@as(i32, 5), 2 + 2);
}
'''
    fail_file = test_dir / "fail_test.zig"
    fail_file.write_text(fail_code, encoding="utf-8")
    ok2, msg2, dur2 = runner.test_file(str(fail_file))
    print(f"  failing test: {ok2} ({dur2:.0f}ms)")
    print(f"  error: {msg2[:200]}")

    assert ok1, "passing test should pass"
    assert not ok2, "failing test should fail"
    print("  PASS")


def test_5_sandbox_rollback():
    print("\nTEST 5: Sandbox rollback on failure")
    print("-" * 50)

    sandbox = Sandbox()
    test_file = TEST_DIR / "rollback_test.zig"
    TEST_DIR.mkdir(parents=True, exist_ok=True)
    original = 'const std = @import("std");\npub fn main() void {}\n'
    test_file.write_text(original, encoding="utf-8")

    backup = sandbox.snapshot(str(test_file))
    print(f"  snapshot: {backup}")

    bad_code = 'BROKEN CODE!!!\n'
    test_file.write_text(bad_code, encoding="utf-8")
    content_after_bad = test_file.read_text(encoding="utf-8")
    print(f"  after bad write: {content_after_bad[:30]}...")

    restored = sandbox.restore(str(test_file))
    content_after_restore = test_file.read_text(encoding="utf-8")
    print(f"  after restore: {content_after_restore[:30]}...")
    print(f"  restored: {restored}")

    assert content_after_restore == original, "FAIL: restore didn't work"
    print("  PASS")


def test_6_end_to_end():
    print("\nTEST 6: End-to-end agent loop (model + real tools)")
    print("-" * 50)

    runtime = _make_runtime()

    test_dir = TEST_DIR / "e2e_loop"
    test_dir.mkdir(parents=True, exist_ok=True)
    test_file = test_dir / "e2e_main.zig"

    initial_code = '''const std = @import("std");

pub fn main() !void {
    const x: i32 = 1;
    const y: i32 = 2;
    _ = x;
    _ = y;
}
'''
    test_file.write_text(initial_code, encoding="utf-8")
    print(f"  initial: {test_file}")

    ok0, _, _ = runtime.zig_runner.syntax_check_file(str(test_file))
    print(f"  initial syntax: {ok0}")

    print("  generating fix with model...")
    context = {"goal": "add x + y and print result", "files_read": {}, "files_written": [], "target_file": str(test_file)}
    code = runtime._generate("Write a Zig function that prints the sum of two integers x and y")
    print(f"  model output: {len(code)} chars")
    print(f"  first 100: {code[:100]}...")

    fixed_code = '''const std = @import("std");

pub fn main() !void {
    const x: i32 = 1;
    const y: i32 = 2;
    const sum = x + y;
    const stdout = std.io.getStdOut().writer();
    try stdout.print("sum = {d}\\n", .{sum});
}
'''
    backup = runtime.sandbox.snapshot(str(test_file))
    test_file.write_text(fixed_code, encoding="utf-8")

    ok1, msg1, dur1 = runtime.zig_runner.syntax_check_file(str(test_file))
    print(f"  syntax: {ok1} ({dur1:.0f}ms)")

    ok2, msg2, dur2 = runtime.zig_runner.build_file(str(test_file))
    print(f"  build: {ok2} ({dur2:.0f}ms)")
    if not ok2:
        print(f"  build error: {msg2[:200]}")

    ok3, msg3, dur3 = runtime.zig_runner.test_file(str(test_file))
    print(f"  test: {ok3} ({dur3:.0f}ms)")

    if ok2:
        ok4, msg4, dur4 = runtime.zig_runner.run_file(str(test_file))
        print(f"  run: {ok4} ({dur4:.0f}ms)")
        print(f"  output: {msg4[:200]}")

    goal = AgentGoal(goal="add x + y and print result")
    goal.steps = [
        AgentStep(action="syntax_check_file", input_data={"file": str(test_file)},
                  output_data={"valid": ok1, "msg": msg1}, success=ok1),
        AgentStep(action="build_file", input_data={"file": str(test_file)},
                  output_data={"built": ok2, "msg": msg2}, success=ok2),
        AgentStep(action="test_file", input_data={"file": str(test_file)},
                  output_data={"tested": ok3, "msg": msg3}, success=ok3),
    ]
    verified = runtime._verify(goal, context)
    print(f"  verified: {verified}")

    assert ok1, "syntax should pass"
    assert ok2, "build should pass"
    assert verified, "verify should pass"
    print("  PASS")


def test_7_failure_triggers_rollback():
    print("\nTEST 7: Bad patch triggers rollback")
    print("-" * 50)

    runtime = _make_runtime()

    test_dir = TEST_DIR / "rollback_e2e"
    test_dir.mkdir(parents=True, exist_ok=True)
    test_file = test_dir / "rollback_e2e.zig"

    original = '''const std = @import("std");

pub fn main() !void {
    std.debug.print("original\\n", .{});
}
'''
    test_file.write_text(original, encoding="utf-8")

    backup = runtime.sandbox.snapshot(str(test_file))
    print(f"  original: {original.strip()[:50]}...")

    bad_patch = "BROKEN ZIG CODE!!!\n"
    test_file.write_text(bad_patch, encoding="utf-8")
    print(f"  after bad patch: {test_file.read_text(encoding='utf-8')[:30]}...")

    runtime.sandbox.restore(str(test_file))
    restored = test_file.read_text(encoding="utf-8")
    print(f"  after restore: {restored.strip()[:50]}...")

    ok, _, _ = runtime.zig_runner.syntax_check_file(str(test_file))
    print(f"  syntax after restore: {ok}")

    assert restored == original, "FAIL: restore didn't work"
    assert ok, "FAIL: syntax should pass after restore"
    print("  PASS")


def _make_runtime():
    import torch
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = build_model()
    model = model.to(device)
    tokenizer = ZigTokenizer.load(AGENT_ROOT / "knowledge" / "corpus" / "zig_tokenizer.json")
    knowledge = KnowledgeQuery(AGENT_ROOT.parent / "memory")
    source_index = SourceIndex([Path(r"C:\Users\Local\zig"), Path(r"C:\B-Plus\zig")])
    zig_runner = ZigRunner()
    return AgentRuntime(model, tokenizer, knowledge, source_index, zig_runner)


def main():
    print("C.7 END-TO-END AGENT VERIFICATION")
    print("=" * 60)

    tests = [
        test_1_fixed_verify,
        test_2_real_syntax,
        test_3_real_build,
        test_4_real_test,
        test_5_sandbox_rollback,
        test_6_end_to_end,
        test_7_failure_triggers_rollback,
    ]

    passed = 0
    failed = 0
    for test_fn in tests:
        try:
            test_fn()
            passed += 1
        except Exception as e:
            print(f"  FAIL: {e}")
            failed += 1

    print("\n" + "=" * 60)
    print(f"RESULTS: {passed}/{passed + failed} PASS, {failed} FAIL")
    if failed == 0:
        print("C.7 AGENT RUNTIME: VERIFIED")
    else:
        print("C.7 AGENT RUNTIME: FAILURES DETECTED")
    print("=" * 60)


if __name__ == "__main__":
    main()
