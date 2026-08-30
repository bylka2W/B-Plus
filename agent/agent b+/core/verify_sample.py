"""Verify sample of spec-based code_write."""
import json, subprocess, tempfile, os
from pathlib import Path

DATASET = Path(r"C:\B-Plus\agent\agent b+\knowledge\dataset\instruction_train.jsonl")
records = [json.loads(l) for l in open(DATASET, encoding="utf-8") if l.strip()]
code_write = [r for r in records if r.get("category") == "code_write"]


def zig_test(code, timeout=8):
    with tempfile.NamedTemporaryFile(suffix=".zig", mode="w", delete=False, encoding="utf-8") as f:
        f.write(code)
        f.flush()
        tmp = f.name
    try:
        r = subprocess.run(["zig", "test", tmp], capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0
    except:
        return False
    finally:
        try:
            os.unlink(tmp)
        except:
            pass


ok = 0
for r in code_write[:20]:
    out = r["output"]
    sym = r["symbol"]
    harness = 'const std = @import("std");\nconst testing = std.testing;\n\n' + out + '\n\ntest "verify" {\n    _ = ' + sym + ';\n}\n'
    passed = zig_test(harness)
    if passed:
        ok += 1
    print(f"  {'PASS' if passed else 'FAIL'}: {sym}")

print(f"\nCompile rate: {ok}/20 = {ok/20*100:.0f}%")
