#!/usr/bin/env python3
"""
B+ AST Fuzzer — generates random B+ programs and compiles them.
Any crash, panic, stack overflow, or access violation = found bug.
"""
import os, sys, random, string, subprocess, tempfile, time, json

_base = os.path.dirname(os.path.abspath(__file__))
for candidate in [
    os.path.join(_base, "..", "..", "..", "bpc.exe"),
    os.path.join(_base, "..", "..", "..", "zig-out", "bin", "bpc.exe"),
    r"C:\B-Plus\zig\bpc.exe",
    r"C:\B-Plus\bpc.exe",
]:
    if os.path.exists(candidate):
        BPC = os.path.abspath(candidate)
        break
else:
    BPC = ""

SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 42
NUM_TESTS = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
REPORT = os.path.join(os.path.dirname(__file__), "..", "..", "fuzz_report.json")

rng = random.Random(SEED)
stats = {"total": 0, "compile_ok": 0, "compile_err": 0, "run_ok": 0, "run_err": 0,
         "crashes": [], "interesting_errors": []}

KEYWORDS = ["state", "entry", "fn", "var", "if", "else", "while", "return", "print",
            "free", "struct", "enum", "import", "on", "always", "run"]
IDENTS = [chr(c) for c in range(ord('a'), ord('z')+1)] + ["_"]
TYPES = ["int", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64"]
OPS = ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">="]
NUMS = ["0", "1", "-1", "42", "99", "255", "65535", "2147483647", "-2147483648",
        "9223372036854775807", "-9223372036854775808", "0x0", "0xFF", "0xDEADBEEF"]

def rand_ident():
    length = rng.randint(1, 12)
    return rng.choice(IDENTS) + "".join(rng.choices(IDENTS + [str(i) for i in range(10)], k=length-1))

def rand_num():
    return rng.choice(NUMS)

def rand_expr(depth=0):
    if depth > 5 or rng.random() < 0.3:
        if rng.random() < 0.5:
            return rand_num()
        return rand_ident()
    kind = rng.randint(0, 5)
    if kind == 0:
        return f"({rand_expr(depth+1)} {rng.choice(OPS)} {rand_expr(depth+1)})"
    elif kind == 1:
        return f"{rand_ident()}({rand_expr(depth+1)})"
    elif kind == 2:
        return f"if ({rand_expr(depth+1)}) {{ {rand_expr(depth+1)} }} else {{ {rand_expr(depth+1)} }}"
    elif kind == 3:
        return f"while ({rand_expr(depth+1)}) {{ {rand_expr(depth+1)} }}"
    elif kind == 4:
        return f"var {rand_ident()} = {rand_expr(depth+1)}"
    else:
        return f"print({rand_expr(depth+1)})"

def gen_random_program():
    """Generate a random but syntactically-plausible B+ program."""
    parts = []

    # Random chance of imports
    if rng.random() < 0.1:
        parts.append(f'import "{rand_ident()}.b+"')

    # Random structs
    if rng.random() < 0.2:
        sname = rand_ident()
        parts.append(f"struct {sname} {{")
        for _ in range(rng.randint(1, 5)):
            parts.append(f"    {rand_ident()}: {rng.choice(TYPES)}")
        parts.append("}")

    # Random enums
    if rng.random() < 0.15:
        ename = rand_ident()
        parts.append(f"enum {ename} {{")
        for _ in range(rng.randint(2, 6)):
            parts.append(f"    {rand_ident()}")
        parts.append("}")

    # Random states
    num_states = rng.randint(1, 10)
    state_names = []
    for _ in range(num_states):
        sname = rand_ident()
        state_names.append(sname)
        parts.append(f"state {sname} {{")
        # Variables
        for _ in range(rng.randint(0, 5)):
            parts.append(f"    {rand_ident()}: {rng.choice(TYPES)} = {rand_num()}")
        # Transitions
        for _ in range(rng.randint(0, 3)):
            if len(state_names) > 1:
                target = rng.choice(state_names)
                parts.append(f"    on {rand_ident()} -> {target}")
        # Entry body
        if rng.random() < 0.7:
            parts.append("    entry {")
            for _ in range(rng.randint(1, 8)):
                parts.append(f"        {rand_expr(2)}")
            parts.append("    }")
        parts.append("}")

    # Random functions
    num_fns = rng.randint(0, 5)
    for _ in range(num_fns):
        fname = rand_ident()
        params = ", ".join(rand_ident() for _ in range(rng.randint(0, 3)))
        parts.append(f"fn {fname}({params}) {{")
        for _ in range(rng.randint(0, 5)):
            parts.append(f"    {rand_expr(3)}")
        parts.append("}")

    # Main entry
    parts.append("state Main {")
    parts.append("    entry {")
    for _ in range(rng.randint(1, 10)):
        parts.append(f"        {rand_expr(3)}")
    parts.append("    }")
    parts.append("}")

    return "\n".join(parts)

def gen_malformed_program():
    """Generate intentionally malformed B+ programs to stress parser."""
    kind = rng.randint(0, 30)
    if kind == 0:
        # Unclosed braces
        return "state Main { entry { " + "{ " * rng.randint(2, 20)
    elif kind == 1:
        # Unclosed string
        return 'state Main { entry { var x = "' + "".join(rng.choices(string.printable, k=rng.randint(10, 500)))
    elif kind == 2:
        # Garbage bytes
        return "".join(rng.choices(string.printable, k=rng.randint(10, 1000)))
    elif kind == 3:
        # Deeply nested parens
        depth = rng.randint(50, 500)
        return f"state Main {{ entry {{ var x = {'(' * depth}1{')' * depth} }}"
    elif kind == 4:
        # Unclosed parens
        return f"state Main {{ entry {{ var x = ({'1 + ' * 100}1"
    elif kind == 5:
        # Random keywords
        return " ".join(rng.choices(KEYWORDS, k=rng.randint(20, 100)))
    elif kind == 6:
        # Nested states
        result = ""
        for i in range(rng.randint(10, 100)):
            result += f"state S{i} {{ "
        return result
    elif kind == 7:
        # Empty tokens
        return "state Main { entry { " + "; " * rng.randint(10, 100) + "} }"
    elif kind == 8:
        # Mismatched brackets
        brackets = rng.choices(["(", ")", "{", "}", "[", "]"], k=rng.randint(20, 100))
        return "state Main { entry { " + "".join(brackets)
    elif kind == 9:
        # Very long line
        return "state Main { entry { var x = " + " + ".join(["1"] * 10000) + " }}"
    elif kind == 10:
        # Unicode-like garbage (ASCII range only for file safety)
        return "state Main { entry { var x = " + "".join(rng.choices(string.printable, k=rng.randint(100, 300))) + " } }"
    elif kind == 11:
        # Nested unclosed strings
        return 'state Main { entry { var x = "' + '"'.join(["hello" for _ in range(50)])
    elif kind == 12:
        # Just newlines
        return "\n" * rng.randint(100, 10000)
    elif kind == 13:
        # Binary noise — use printable range to avoid encoding errors
        return "".join(rng.choices(string.printable, k=rng.randint(100, 1000)))
    elif kind == 14:
        # Truncated keyword
        kw = rng.choice(KEYWORDS)[:rng.randint(1, len(rng.choice(KEYWORDS))-1)]
        return f"state Main {{ entry {{ {kw} }}"
    elif kind == 15:
        # Nested function calls
        depth = rng.randint(10, 100)
        expr = "a(" * depth + "1" + ")" * depth
        return f"state Main {{ entry {{ {expr} }}}}"
    elif kind == 16:
        code = gen_random_program()
        pos = rng.randint(10, max(10, len(code) - 2))
        return code[:pos]
    elif kind == 17:
        code = gen_random_program()
        inject = rng.choice(["\x00", "\xff", "}", "{{", "}}", "state ", "fn ", "var "])
        pos = rng.randint(0, max(0, len(code) - 1))
        return code[:pos] + inject + code[pos+1:]
    elif kind == 18:
        return "state Main { entry { " + "{}{}{}{}{}{}{}{}{}{}" * rng.randint(3, 20) + " } }"
    elif kind == 19:
        return 'state Main { entry { var x = "' + "\\\\" * rng.randint(10, 500) + '" } }'
    elif kind == 20:
        return "{" * rng.randint(10, 200) + "}" * rng.randint(10, 200)
    elif kind == 21:
        return "state Main " + "{ entry { print(1) } } " * rng.randint(5, 30)
    elif kind == 22:
        return 'import "' + "a" * rng.randint(1, 500)
    elif kind == 23:
        return "".join(chr(rng.randint(0, 127)) for _ in range(rng.randint(50, 2000)))
    elif kind == 24:
        n = rng.randint(50, 200)
        return "".join(f"struct S{i} {{ x: int }} " for i in range(n))
    elif kind == 25:
        return "state Main { " + " ".join(f"on {rand_ident()} -> {rand_ident()}" for _ in range(rng.randint(10, 100))) + " }"
    elif kind == 26:
        return "state Main { entry { " + "print() " * rng.randint(10, 100) + "} }"
    elif kind == 27:
        return " ".join(str(rng.randint(-999999999, 999999999)) for _ in range(rng.randint(50, 500)))
    elif kind == 28:
        code = gen_random_program()
        pos = rng.randint(0, max(0, len(code) - 1))
        return code[:pos] + code[pos+1:]
    elif kind == 29:
        depth = rng.randint(3, 20)
        inner = '"hello"'
        for _ in range(depth):
            inner = '"' + inner + '"'
        return f"state Main {{ entry {{ var x = {inner} }} }}"
    else:
        code = gen_random_program()
        pos = rng.randint(0, max(0, len(code) - 1))
        return code[:pos] + "{" + code[pos:]

def compile_test(code, test_id):
    """Compile B+ code and return result."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.b+', delete=False, dir=tempfile.gettempdir(), encoding='utf-8') as f:
        f.write(code)
        tmp_path = f.name

    try:
        result = subprocess.run(
            [BPC, "dll", tmp_path],
            capture_output=True, timeout=10, stdin=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
        )
        return {
            "exit_code": result.returncode,
            "stdout": result.stdout.decode(errors='replace')[:500],
            "stderr": result.stderr.decode(errors='replace')[:500],
            "timed_out": False
        }
    except subprocess.TimeoutExpired:
        return {"exit_code": -1, "stdout": "", "stderr": "TIMEOUT", "timed_out": True}
    except Exception as e:
        return {"exit_code": -2, "stdout": "", "stderr": str(e), "timed_out": False}
    finally:
        os.unlink(tmp_path)
        exe_path = tmp_path.rsplit('.', 1)[0] + '.dll'
        if os.path.exists(exe_path):
            os.unlink(exe_path)

def analyze_result(result):
    """Check if result indicates a bug (crash, panic, etc)."""
    stderr = result["stderr"].lower()
    exit_code = result["exit_code"]

    # Crash indicators
    crash_signals = ["access violation", "segmentation fault", "stack overflow",
                     "panic", "abort", "sigsegv", "sigabrt", "fatal",
                     "exception", "unhandled", "stack overflow"]

    for sig in crash_signals:
        if sig in stderr:
            return "crash", sig

    # Timeout is interesting
    if result["timed_out"]:
        return "timeout", "exceeded 30s"

    # Non-zero exit might be expected error handling
    if exit_code != 0 and exit_code != 1:
        return "unexpected_exit", f"exit={exit_code}"

    return "ok", ""

def main():
    print(f"B+ Fuzzer: {NUM_TESTS} tests (seed={SEED})")
    print(f"BPC: {BPC}")

    if not os.path.exists(BPC):
        print(f"ERROR: bpc not found at {BPC}")
        sys.exit(1)

    t0 = time.time()
    malformed_ratio = 0.3  # 30% malformed, 70% random valid

    for i in range(NUM_TESTS):
        stats["total"] += 1

        # Decide: malformed or random valid
        if rng.random() < malformed_ratio:
            code = gen_malformed_program()
            category = "malformed"
        else:
            code = gen_random_program()
            category = "random_valid"

        result = compile_test(code, i)
        status, detail = analyze_result(result)

        if status == "ok":
            if result["exit_code"] == 0:
                stats["run_ok"] += 1
            else:
                stats["compile_err"] += 1  # Expected parse errors
        elif status == "crash":
            stats["crashes"].append({
                "id": i,
                "category": category,
                "detail": detail,
                "code": code[:200],
                "stderr": result["stderr"][:200]
            })
            print(f"  CRASH #{i}: {detail}")
        elif status == "timeout":
            stats["crashes"].append({
                "id": i,
                "category": category,
                "detail": detail,
                "code": code[:200]
            })
            print(f"  TIMEOUT #{i}")
        elif status == "unexpected_exit":
            stats["interesting_errors"].append({
                "id": i,
                "category": category,
                "detail": detail,
                "stderr": result["stderr"][:200]
            })

        if (i + 1) % 100 == 0:
            elapsed = time.time() - t0
            rate = (i + 1) / elapsed
            crashes = len(stats["crashes"])
            print(f"  [{i+1}/{NUM_TESTS}] {rate:.0f} tests/s, {crashes} crashes")

    elapsed = time.time() - t0
    print(f"\n=== Fuzz Results ===")
    print(f"  Total: {stats['total']}")
    print(f"  Compile OK: {stats['run_ok']}")
    print(f"  Expected errors: {stats['compile_err']}")
    print(f"  Crashes: {len(stats['crashes'])}")
    print(f"  Timeouts: {sum(1 for c in stats['crashes'] if c['detail'] == 'exceeded 30s')}")
    print(f"  Interesting: {len(stats['interesting_errors'])}")
    print(f"  Time: {elapsed:.1f}s ({stats['total']/elapsed:.0f} tests/s)")

    # Save report
    with open(REPORT, "w") as f:
        json.dump(stats, f, indent=2)
    print(f"Report saved to {REPORT}")

    if stats["crashes"]:
        sys.exit(1)

if __name__ == "__main__":
    main()
