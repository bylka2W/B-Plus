#!/usr/bin/env python3
"""Reproduce the crash at seed=42, test IDs 7 and 144."""
import random, string, subprocess, tempfile, os, sys

BPC = sys.argv[1] if len(sys.argv) > 1 else r"C:\B-Plus\zig\bpc.exe"

def reproduce_seed(seed, target_ids):
    rng = random.Random(seed)
    KEYWORDS = ["state", "entry", "fn", "var", "if", "else", "while", "return", "print",
                "free", "struct", "enum", "import", "on", "always", "run"]
    IDENTS = [chr(c) for c in range(ord('a'), ord('z')+1)] + ["_"]
    TYPES = ["int", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64"]
    OPS = ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">="]
    NUMS = ["0", "1", "-1", "42", "99", "255"]

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
        if kind == 0: return f"({rand_expr(depth+1)} {rng.choice(OPS)} {rand_expr(depth+1)})"
        elif kind == 1: return f"{rand_ident()}({rand_expr(depth+1)})"
        elif kind == 2: return f"if ({rand_expr(depth+1)}) {{ {rand_expr(depth+1)} }} else {{ {rand_expr(depth+1)} }}"
        elif kind == 3: return f"while ({rand_expr(depth+1)}) {{ {rand_expr(depth+1)} }}"
        elif kind == 4: return f"var {rand_ident()} = {rand_expr(depth+1)}"
        else: return f"print({rand_expr(depth+1)})"

    def gen_random_program():
        parts = []
        if rng.random() < 0.1: parts.append(f'import "{rand_ident()}.b+"')
        if rng.random() < 0.2:
            sname = rand_ident()
            parts.append(f"struct {sname} {{")
            for _ in range(rng.randint(1, 5)): parts.append(f"    {rand_ident()}: {rng.choice(TYPES)}")
            parts.append("}")
        if rng.random() < 0.15:
            ename = rand_ident()
            parts.append(f"enum {ename} {{")
            for _ in range(rng.randint(2, 6)): parts.append(f"    {rand_ident()}")
            parts.append("}")
        num_states = rng.randint(1, 10)
        state_names = []
        for _ in range(num_states):
            sname = rand_ident()
            state_names.append(sname)
            parts.append(f"state {sname} {{")
            for _ in range(rng.randint(0, 5)): parts.append(f"    {rand_ident()}: {rng.choice(TYPES)} = {rand_num()}")
            for _ in range(rng.randint(0, 3)):
                if len(state_names) > 1: parts.append(f"    on {rand_ident()} -> {rng.choice(state_names)}")
            if rng.random() < 0.7:
                parts.append("    entry {")
                for _ in range(rng.randint(1, 8)): parts.append(f"        {rand_expr(2)}")
                parts.append("    }")
            parts.append("}")
        num_fns = rng.randint(0, 5)
        for _ in range(num_fns):
            fname = rand_ident()
            params = ", ".join(rand_ident() for _ in range(rng.randint(0, 3)))
            parts.append(f"fn {fname}({params}) {{")
            for _ in range(rng.randint(0, 5)): parts.append(f"    {rand_expr(3)}")
            parts.append("}")
        parts.append("state Main {")
        parts.append("    entry {")
        for _ in range(rng.randint(1, 10)): parts.append(f"        {rand_expr(3)}")
        parts.append("    }")
        parts.append("}")
        return "\n".join(parts)

    def gen_malformed_program():
        kind = rng.randint(0, 30)
        if kind == 0: return "state Main { entry { " + "{ " * rng.randint(2, 20)
        elif kind == 1: return 'state Main { entry { var x = "' + "".join(rng.choices(string.printable, k=rng.randint(10, 500)))
        elif kind == 2: return "".join(rng.choices(string.printable, k=rng.randint(10, 1000)))
        elif kind == 3:
            depth = rng.randint(50, 500)
            return f"state Main {{ entry {{ var x = {'(' * depth}1{')' * depth} }}"
        elif kind == 4: return f"state Main {{ entry {{ var x = ({'1 + ' * 100}1"
        elif kind == 5: return " ".join(rng.choices(KEYWORDS, k=rng.randint(20, 100)))
        elif kind == 6:
            result = ""
            for i in range(rng.randint(10, 100)): result += f"state S{i} {{ "
            return result
        elif kind == 7: return "state Main { entry { " + "; " * rng.randint(10, 100) + "} }"
        elif kind == 8:
            brackets = rng.choices(["(", ")", "{", "}", "[", "]"], k=rng.randint(20, 100))
            return "state Main { entry { " + "".join(brackets)
        elif kind == 9: return "state Main { entry { var x = " + " + ".join(["1"] * 10000) + " }}"
        elif kind == 10: return "state Main { entry { var x = " + "".join(rng.choices(string.printable, k=rng.randint(100, 300))) + " } }"
        elif kind == 11: return 'state Main { entry { var x = "' + '"'.join(["hello" for _ in range(50)])
        elif kind == 12: return "\n" * rng.randint(100, 10000)
        elif kind == 13: return "".join(rng.choices(string.printable, k=rng.randint(100, 1000)))
        elif kind == 14:
            kw = rng.choice(KEYWORDS)[:rng.randint(1, len(rng.choice(KEYWORDS))-1)]
            return f"state Main {{ entry {{ {kw} }}"
        elif kind == 15:
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
        elif kind == 18: return "state Main { entry { " + "{}{}{}{}{}{}{}{}{}{}" * rng.randint(3, 20) + " } }"
        elif kind == 19: return 'state Main { entry { var x = "' + "\\\\" * rng.randint(10, 500) + '" } }'
        elif kind == 20: return "{" * rng.randint(10, 200) + "}" * rng.randint(10, 200)
        elif kind == 21: return "state Main " + "{ entry { print(1) } } " * rng.randint(5, 30)
        elif kind == 22: return 'import "' + "a" * rng.randint(1, 500)
        elif kind == 23: return "".join(chr(rng.randint(0, 127)) for _ in range(rng.randint(50, 2000)))
        elif kind == 24:
            n = rng.randint(50, 200)
            return "".join(f"struct S{i} {{ x: int }} " for i in range(n))
        elif kind == 25: return "state Main { " + " ".join(f"on {rand_ident()} -> {rand_ident()}" for _ in range(rng.randint(10, 100))) + " }"
        elif kind == 26: return "state Main { entry { " + "print() " * rng.randint(10, 100) + "} }"
        elif kind == 27: return " ".join(str(rng.randint(-999999999, 999999999)) for _ in range(rng.randint(50, 500)))
        elif kind == 28:
            code = gen_random_program()
            pos = rng.randint(0, max(0, len(code) - 1))
            return code[:pos] + code[pos+1:]
        elif kind == 29:
            depth = rng.randint(3, 20)
            inner = '"hello"'
            for _ in range(depth): inner = '"' + inner + '"'
            return f"state Main {{ entry {{ var x = {inner} }} }}"
        else:
            code = gen_random_program()
            pos = rng.randint(0, max(0, len(code) - 1))
            return code[:pos] + "{" + code[pos:]

    malformed_ratio = 0.3
    for test_id in range(max(target_ids) + 1):
        is_malformed = rng.random() < malformed_ratio
        if is_malformed:
            code = gen_malformed_program()
        else:
            code = gen_random_program()

        if test_id in target_ids:
            with tempfile.NamedTemporaryFile(mode='w', suffix='.b+', delete=False, encoding='utf-8') as f:
                f.write(code)
                tmp = f.name
            try:
                r = subprocess.run([BPC, "dll", tmp], capture_output=True, timeout=30, stdin=subprocess.DEVNULL)
                print(f"=== ID {test_id} (malformed={is_malformed}) exit={r.returncode} ===")
                stderr = r.stderr.decode(errors="replace")
                if stderr: print(f"stderr: {stderr[:500]}")
                print(f"CODE ({len(code)} chars):")
                print(code[:2000])
                print()
            finally:
                os.unlink(tmp)
                dll = tmp.rsplit(".", 1)[0] + ".dll"
                if os.path.exists(dll): os.unlink(dll)

if __name__ == "__main__":
    reproduce_seed(42, {7, 144})
