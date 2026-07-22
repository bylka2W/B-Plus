#!/usr/bin/env python3
"""Debug: test fuzzer with import programs to find hang."""
import subprocess, tempfile, os, time, random, string, sys

BPC = r"C:\B-Plus\zig\bpc.exe"
KEYWORDS = ["state","entry","fn","var","if","else","while","return","print","free","struct","enum","import","on","always","run"]
IDENTS = [chr(c) for c in range(ord('a'),ord('z')+1)] + ["_"]
TYPES = ["int","u8","u16","u32","u64","i8","i16","i32","i64"]
OPS = ["+","-","*","/","==","!=","<",">","<=",">="]
NUMS = ["0","1","-1","42","99","255","65535","2147483647"]

rng = random.Random(42)

def rand_ident():
    return rng.choice(IDENTS) + "".join(rng.choices(IDENTS + [str(i) for i in range(10)], k=rng.randint(1,8)))

def rand_expr(depth=0):
    if depth > 5 or rng.random() < 0.3:
        return rng.choice([rand_num(), rand_ident()])
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

def rand_num():
    return rng.choice(NUMS)

def gen_random_program():
    parts = []
    if rng.random() < 0.1:
        parts.append(f'import "{rand_ident()}.b+"')
    if rng.random() < 0.2:
        sname = rand_ident()
        parts.append(f"struct {sname} {{")
        for _ in range(rng.randint(1, 5)):
            parts.append(f"    {rand_ident()}: {rng.choice(TYPES)}")
        parts.append("}")
    if rng.random() < 0.15:
        ename = rand_ident()
        parts.append(f"enum {ename} {{")
        for _ in range(rng.randint(2, 6)):
            parts.append(f"    {rand_ident()}")
        parts.append("}")
    num_states = rng.randint(1, 10)
    state_names = []
    for _ in range(num_states):
        sname = rand_ident()
        state_names.append(sname)
        parts.append(f"state {sname} {{")
        for _ in range(rng.randint(0, 5)):
            parts.append(f"    {rand_ident()}: {rng.choice(TYPES)} = {rand_num()}")
        for _ in range(rng.randint(0, 3)):
            if len(state_names) > 1:
                target = rng.choice(state_names)
                parts.append(f"    on {rand_ident()} -> {target}")
        if rng.random() < 0.7:
            parts.append("    entry {")
            for _ in range(rng.randint(1, 8)):
                parts.append(f"        {rand_expr(2)}")
            parts.append("    }")
        parts.append("}")
    num_fns = rng.randint(0, 5)
    for _ in range(num_fns):
        fname = rand_ident()
        params = ", ".join(rand_ident() for _ in range(rng.randint(0, 3)))
        parts.append(f"fn {fname}({params}) {{")
        for _ in range(rng.randint(0, 5)):
            parts.append(f"    {rand_expr(3)}")
        parts.append("}")
    parts.append("state Main {")
    parts.append("    entry {")
    for _ in range(rng.randint(1, 10)):
        parts.append(f"        {rand_expr(3)}")
    parts.append("    }")
    parts.append("}")
    return "\n".join(parts)

def run_test(code, i):
    with tempfile.NamedTemporaryFile(mode='w', suffix='.b+', delete=False, dir=tempfile.gettempdir(), encoding='utf-8') as f:
        f.write(code)
        tmp_path = f.name
    try:
        t0 = time.time()
        r = subprocess.run(
            [BPC, "run", tmp_path],
            capture_output=True, timeout=10, stdin=subprocess.DEVNULL,
            creationflags=0x08000000 if sys.platform == "win32" else 0
        )
        dt = time.time() - t0
        return r.returncode, r.stderr.decode(errors='replace')[:100], dt, False
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT", 10.0, True
    finally:
        os.unlink(tmp_path)
        exe = tmp_path.rsplit('.', 1)[0] + '.exe'
        if os.path.exists(exe):
            os.unlink(exe)

for i in range(30):
    code = gen_random_program()
    has_import = 'import' in code
    exit_code, stderr, dt, timeout = run_test(code, i)
    status = "CRASH" if "panic" in stderr.lower() else ("TIMEOUT" if timeout else f"exit={exit_code}")
    marker = " [IMPORT]" if has_import else ""
    print(f"#{i:3d}: {status} {dt:.1f}s{marker}", flush=True)
    if dt > 5:
        print(f"  SLOW! stderr={stderr}", flush=True)
