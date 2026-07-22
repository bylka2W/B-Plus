#!/usr/bin/env python3
"""Run semantic validation tests and compare actual vs expected behavior."""
import os, subprocess, glob, json, time

BPC = r"C:\B-Plus\zig\zig-out\bin\bpc.exe"
TESTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "semantic")

results = []
for f in sorted(glob.glob(os.path.join(TESTS, "*.b+"))):
    name = os.path.basename(f)
    try:
        r = subprocess.run([BPC, "dll", f], capture_output=True, timeout=15, stdin=subprocess.DEVNULL,
                           creationflags=0x08000000 if os.name == 'nt' else 0)
        exit_code = r.returncode
        stderr = r.stderr.decode(errors="replace").strip()
        stdout = r.stdout.decode(errors="replace").strip()
        output = stderr or stdout
    except subprocess.TimeoutExpired:
        exit_code = -999
        output = "TIMEOUT"
    except Exception as e:
        exit_code = -998
        output = str(e)

    # Classify actual behavior
    if exit_code == 0:
        actual = "accepted"  # compiler accepted the program
    elif exit_code == 1:
        actual = "rejected"  # compiler rejected with error
    elif exit_code < -1000000 or (exit_code > 2000000000):
        actual = "crash"     # compiler itself crashed
    else:
        actual = f"rejected(code={exit_code})"  # some other error code

    results.append({
        "name": name,
        "exit_code": exit_code,
        "actual": actual,
        "output": output[:300],
    })

# Print results as a table
print(f"{'Test':<45} {'Exit':>6} {'Actual':<12} {'Output (first 80 chars)'}")
print("-" * 140)
for r in results:
    out_short = r["output"].replace("\n", " ")[:80]
    print(f"{r['name']:<45} {r['exit_code']:>6} {r['actual']:<12} {out_short}")

# Summary
accepted = sum(1 for r in results if r["actual"] == "accepted")
rejected = sum(1 for r in results if "rejected" in r["actual"])
crashed = sum(1 for r in results if r["actual"] == "crash")
print(f"\nAccepted (exit=0): {accepted}")
print(f"Rejected (error):  {rejected}")
print(f"Crashed:           {crashed}")

# Save full results
report_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "semantic_report.json")
with open(report_path, "w") as f:
    json.dump(results, f, indent=2)
print(f"\nReport saved to {report_path}")
