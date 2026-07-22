#!/usr/bin/env python3
"""Run all tests through bpc dll, report crashes vs expected errors."""
import os, subprocess, glob, sys, time

BPC = r"C:\B-Plus\zig\zig-out\bin\bpc.exe"
TESTS = os.path.dirname(os.path.abspath(__file__))

def run_one(path):
    try:
        r = subprocess.run(
            [BPC, "dll", path],
            capture_output=True, timeout=30, text=True
        )
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return -999, "TIMEOUT"
    except Exception as e:
        return -998, str(e)

categories = {
    "Parser Fuzz":     "fuzz/parser/*.b+",
    "Symbol Resolution":"fuzz/symbols/*.b+",
    "Recursion":       "fuzz/recursion/*.b+",
    "Import Hell":     "stress/generated/import_hell_*.b+",
    "State Hell":      "stress/generated/state_hell_*.b+",
    "Context Var Hell":"stress/generated/ctxvar_hell_*.b+",
    "Expression Hell": "stress/generated/expr_*.b+",
    "IfElse Nest":     "stress/generated/ifelse_nest_*.b+",
    "Integer Overflow":"fuzz/overflow/*.b+",
    "Memory":          "fuzz/memory/*.b+",
    "Struct Layout":   "fuzz/struct/*.b+",
    "Codegen Stress":  "stress/generated/codegen_stress_*.b+",
    "Golden Regression":"regressions/0*.b+",
}

crash_codes = {3221225477, -1073741819, -1073740940, -1073740791}
CRASH_THRESHOLD = 3000000000  # detect as crash

total_pass = 0
total_fail = 0
total_crash = 0
total_timeout = 0
all_crashes = []
all_results = []

t0 = time.time()
for cat_name, pattern in categories.items():
    files = sorted(glob.glob(os.path.join(TESTS, pattern)))
    if not files:
        print(f"[{cat_name}] 0 files found")
        continue
    
    cat_pass = 0
    cat_fail = 0
    cat_crash = 0
    cat_timeout = 0
    
    for f in files:
        name = os.path.relpath(f, TESTS)
        code, output = run_one(f)
        
        if code == -999:
            cat_timeout += 1
            all_results.append((name, "TIMEOUT", code))
            print(f"  TIMEOUT {name}")
        elif code == -998:
            cat_crash += 1
            all_crashes.append((name, code, output))
            all_results.append((name, "CRASH (exception)", code))
            print(f"  CRASH! {name} (exception: {output})")
        elif code < 0 or code > CRASH_THRESHOLD:
            cat_crash += 1
            all_crashes.append((name, code, output[:200]))
            all_results.append((name, f"CRASH (exit={code})", code))
            print(f"  CRASH! {name} exit={code}")
        elif code == 1:
            cat_pass += 1  # expected compile error
            all_results.append((name, "expected error", code))
        elif code == 0:
            cat_pass += 1
            all_results.append((name, "OK", code))
        else:
            cat_fail += 1
            all_results.append((name, f"UNEXPECTED exit={code}", code))
            print(f"  UNEXPECTED {name} exit={code}")
    
    status = "PASS" if cat_crash == 0 and cat_timeout == 0 else "FAIL"
    print(f"[{cat_name}] {status} - pass={cat_pass} fail={cat_fail} crash={cat_crash} timeout={cat_timeout} ({len(files)} files)")
    total_pass += cat_pass
    total_fail += cat_fail
    total_crash += cat_crash
    total_timeout += cat_timeout

elapsed = time.time() - t0
print(f"\n{'='*60}")
print(f"TOTAL: pass={total_pass} fail={total_fail} crash={total_crash} timeout={total_timeout}")
print(f"Time: {elapsed:.1f}s")
if all_crashes:
    print(f"\nCRASHES ({len(all_crashes)}):")
    for name, code, out in all_crashes:
        print(f"  {name} exit={code}")
        if out:
            print(f"    {out[:200]}")
else:
    print("\nNO CRASHES!")
