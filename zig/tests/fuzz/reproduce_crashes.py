import subprocess, tempfile, os, random, string, sys, time

BPC = r"C:\B-Plus\zig\bpc.exe"
rng = random.Random(42)

KEYWORDS = ["state","entry","fn","var","if","else","while","return","print","free","struct","enum","import","on","always","run"]
IDENTS = [chr(c) for c in range(ord('a'),ord('z')+1)] + ["_"]

def rand_ident():
    return rng.choice(IDENTS) + "".join(rng.choices(IDENTS + [str(i) for i in range(10)], k=rng.randint(1,8)))

def gen_malformed_program():
    kind = rng.randint(0, 15)
    if kind == 0:
        return "state Main { entry { " + "{ " * rng.randint(2, 20)
    elif kind == 1:
        return 'state Main { entry { var x = "' + "".join(rng.choices(string.printable, k=rng.randint(10, 500)))
    elif kind == 2:
        return "".join(rng.choices(string.printable, k=rng.randint(10, 1000)))
    elif kind == 3:
        depth = rng.randint(50, 500)
        return f"state Main {{ entry {{ var x = {'(' * depth}1{')' * depth} }}"
    elif kind == 4:
        return f"state Main {{ entry {{ var x = ({'1 + ' * 100}1"
    elif kind == 5:
        return " ".join(rng.choices(KEYWORDS, k=rng.randint(20, 100)))
    elif kind == 6:
        result = ""
        for i in range(rng.randint(10, 100)):
            result += f"state S{i} {{ "
        return result
    elif kind == 7:
        return "state Main { entry { " + "; " * rng.randint(10, 100) + "} }"
    elif kind == 8:
        brackets = rng.choices(["(", ")", "{", "}", "[", "]"], k=rng.randint(20, 100))
        return "state Main { entry { " + "".join(brackets)
    elif kind == 9:
        return "state Main { entry { var x = " + " + ".join(["1"] * 10000) + " }}"
    elif kind == 10:
        return "state Main { entry { var x = " + "".join(rng.choices(string.printable, k=rng.randint(100, 300))) + " } }"
    elif kind == 11:
        return 'state Main { entry { var x = "' + '"'.join(["hello" for _ in range(50)])
    elif kind == 12:
        return "\n" * rng.randint(100, 10000)
    elif kind == 13:
        return "".join(rng.choices(string.printable, k=rng.randint(100, 1000)))
    elif kind == 14:
        kw = rng.choice(KEYWORDS)[:rng.randint(1, len(rng.choice(KEYWORDS))-1)]
        return f"state Main {{ entry {{ {kw} }}"
    else:
        depth = rng.randint(10, 100)
        expr = "a(" * depth + "1" + ")" * depth
        return f"state Main {{ entry {{ {expr} }}}}"

# Skip to id=7 (need to advance rng 7 times)
target_ids = [7, 144, 229, 253]
max_id = max(target_ids)

# Also need to account for the 70% valid / 30% malformed split
# Valid programs call gen_random_program with different rng state
# We need to replicate exactly

def gen_random_program():
    TYPES = ["int","u8","u16","u32","u64","i8","i16","i32","i64"]
    OPS = ["+","-","*","/","==","!=","<",">","<=",">="]
    NUMS = ["0","1","-1","42","99","255","65535","2147483647"]
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
    TYPES2 = TYPES
    parts = []
    if rng.random() < 0.1:
        parts.append(f'import "{rand_ident()}.b+"')
    if rng.random() < 0.2:
        sname = rand_ident()
        parts.append(f"struct {sname} {{")
        for _ in range(rng.randint(1, 5)):
            parts.append(f"    {rand_ident()}: {rng.choice(TYPES2)}")
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
            parts.append(f"    {rand_ident()}: {rng.choice(TYPES2)} = {rand_num()}")
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

# Replay the exact same rng sequence as the fuzzer
crash_codes = {}
for i in range(max_id + 1):
    if rng.random() < 0.3:
        code = gen_malformed_program()
        cat = "malformed"
    else:
        code = gen_random_program()
        cat = "random_valid"

    if i in target_ids:
        with tempfile.NamedTemporaryFile(mode='w', suffix='.b+', delete=False, dir=tempfile.gettempdir(), encoding='utf-8') as f:
            f.write(code)
            tmp = f.name
        t0 = time.time()
        try:
            r = subprocess.run(
                [BPC, "dll", tmp],
                capture_output=True, timeout=10, stdin=subprocess.DEVNULL,
                creationflags=0x08000000
            )
            dt = time.time() - t0
            stderr = r.stderr.decode(errors='replace')
            if r.returncode not in (0, 1):
                print(f"#{i} [{cat}] exit={r.returncode} {dt:.2f}s", flush=True)
                print(f"  stderr: {stderr[:200]}", flush=True)
                print(f"  code ({len(code)} chars):", flush=True)
                print(code[:500], flush=True)
                print("---", flush=True)
            else:
                print(f"#{i} [{cat}] exit={r.returncode} {dt:.2f}s OK", flush=True)
        except subprocess.TimeoutExpired:
            print(f"#{i} [{cat}] TIMEOUT", flush=True)
        finally:
            try: os.unlink(tmp)
            except: pass
            dll = tmp.rsplit('.', 1)[0] + '.dll'
            try:
                if os.path.exists(dll): os.unlink(dll)
            except: pass
