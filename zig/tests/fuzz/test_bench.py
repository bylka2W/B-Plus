import subprocess, tempfile, os, time, random, string, sys

BPC = r"C:\B-Plus\zig\bpc.exe"
rng = random.Random(42)

KEYWORDS = ["state","entry","fn","var","if","else","while","return","print","free","struct","enum","import","on","always","run"]
IDENTS = [chr(c) for c in range(ord('a'),ord('z')+1)] + ["_"]
TYPES = ["int","u8","u16","u32","u64","i8","i16","i32","i64"]
OPS = ["+","-","*","/","==","!=","<",">","<=",">="]
NUMS = ["0","1","-1","42","99","255","65535","2147483647"]

def rand_ident():
    return rng.choice(IDENTS) + "".join(rng.choices(IDENTS + [str(i) for i in range(10)], k=rng.randint(1,8)))

def rand_num():
    return rng.choice(NUMS)

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

t0 = time.time()
for i in range(30):
    code = gen_random_program()
    with tempfile.NamedTemporaryFile(mode='w', suffix='.b+', delete=False, dir=tempfile.gettempdir(), encoding='utf-8') as f:
        f.write(code)
        tmp_path = f.name
    try:
        t1 = time.time()
        result = subprocess.run(
            [BPC, "dll", tmp_path],
            capture_output=True, timeout=10, stdin=subprocess.DEVNULL,
            creationflags=0x08000000
        )
        dt = time.time() - t1
        stderr = result.stderr.decode(errors='replace')[:100]
        crashed = "panic" in stderr.lower()
        if crashed:
            print(f"#{i} CRASH {dt:.2f}s stderr={stderr}", flush=True)
        elif dt > 2:
            print(f"#{i} SLOW {dt:.2f}s exit={result.returncode}", flush=True)
        elif (i+1) % 10 == 0:
            print(f"  [{i+1}/30] {dt:.2f}s", flush=True)
    except subprocess.TimeoutExpired:
        print(f"#{i} TIMEOUT", flush=True)
    finally:
        try: os.unlink(tmp_path)
        except: pass
        exe = tmp_path.rsplit('.', 1)[0] + '.dll'
        try:
            if os.path.exists(exe): os.unlink(exe)
        except: pass

elapsed = time.time() - t0
print(f"\n30 tests in {elapsed:.1f}s ({30/elapsed:.1f} tests/s)", flush=True)
