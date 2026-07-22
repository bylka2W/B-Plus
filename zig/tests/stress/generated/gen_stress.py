#!/usr/bin/env python3
"""Generate B+ stress tests at various scales."""
import os, sys, time

OUT = os.path.join(os.path.dirname(__file__), "..", "generated")

def gen_states(n, outdir):
    """5. State Machine Hell — N states chained."""
    path = os.path.join(outdir, f"states_{n}.b+")
    lines = []
    for i in range(1, n):
        lines.append(f"state S{i:05d} {{")
        lines.append(f"    on Go -> S{i+1:05d}")
        lines.append("}")
    lines.append(f"state S{n:05d} {{")
    lines.append(f"    entry {{ ExitProcess(42) }}")
    lines.append("}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path

def gen_context_vars(n, outdir):
    """6. Context Variable Hell — N vars in context."""
    path = os.path.join(outdir, f"ctxvars_{n}.b+")
    lines = ["state Main {"]
    lines.append("    entry {")
    for i in range(n):
        lines.append(f"        var a{i}: int = {i}")
    lines.append("        print(1)")
    lines.append("    }")
    lines.append("}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path

def gen_deep_expr(depth, outdir):
    """7. Expression Hell — N levels of nested parens."""
    path = os.path.join(outdir, f"expr_{depth}.b+")
    lines = ["state Main {"]
    lines.append("    entry {")
    lines.append("        var x = " + "(" * depth + "1 + 2" + ")" * depth)
    lines.append("        print(x)")
    lines.append("    }")
    lines.append("}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path

def gen_imports(n, outdir):
    """4. Import Hell — N imports referencing dummy files."""
    # Create dummy import targets
    import_dir = os.path.join(outdir, "imports")
    os.makedirs(import_dir, exist_ok=True)
    for i in range(n):
        with open(os.path.join(import_dir, f"lib{i}.b+"), "w") as f:
            f.write(f"state Lib{i} {{ entry {{ print({i}) }} }}\n")

    # Main file with N imports
    path = os.path.join(outdir, f"imports_{n}.b+")
    lines = []
    for i in range(n):
        lines.append(f'import "generated/imports/lib{i}.b+"')
    lines.append("state Main {")
    lines.append("    entry {")
    lines.append("        print(1)")
    lines.append("    }")
    lines.append("}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path

def gen_codegen_stress(n, outdir):
    """11. Codegen Stress — N print statements."""
    path = os.path.join(outdir, f"codegen_{n}.b+")
    lines = ["state Main {"]
    lines.append("    entry {")
    for i in range(n):
        lines.append(f"        print({i})")
    lines.append("    }")
    lines.append("}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path

def gen_many_fns(n, outdir):
    """Functions stress — N function definitions."""
    path = os.path.join(outdir, f"fns_{n}.b+")
    lines = []
    for i in range(n):
        lines.append(f"fn add{i}(a, b) {{")
        lines.append(f"    return a + b + {i}")
        lines.append("}")
    lines.append("state Main {")
    lines.append("    entry {")
    lines.append("        var x = add0(1, 2)")
    lines.append("        print(x)")
    lines.append("    }")
    lines.append("}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path

def gen_if_else_chain(n, outdir):
    """Deeply nested if/else."""
    path = os.path.join(outdir, f"ifelse_{n}.b+")
    lines = ["state Main {"]
    lines.append("    entry {")
    lines.append("        var x = 1")
    for i in range(n):
        indent = "        " + "    " * i
        lines.append(f"{indent}if (x == {i}) {{")
        lines.append(f"{indent}    x = x + 1")
    indent = "        " + "    " * n
    lines.append(f"{indent}print(x)")
    for i in range(n):
        indent = "        " + "    " * (n - 1 - i)
        lines.append(f"{indent}}}")
    lines.append("    }")
    lines.append("}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)

    scales = {
        "states":      [100, 500, 1000, 5000],
        "ctx_vars":    [100, 500, 1000, 5000],
        "expr_depth":  [100, 500, 1000, 5000],
        "imports":     [100, 500, 1000],
        "codegen":     [1000, 10000, 50000],
        "fns":         [100, 500, 1000],
        "ifelse":      [100, 500],
    }

    total = 0
    generators = {
        "states":     gen_states,
        "ctx_vars":   gen_context_vars,
        "expr_depth": gen_deep_expr,
        "imports":    gen_imports,
        "codegen":    gen_codegen_stress,
        "fns":        gen_many_fns,
        "ifelse":     gen_if_else_chain,
    }

    for category, sizes in scales.items():
        gen = generators[category]
        for n in sizes:
            t0 = time.time()
            path = gen(n, OUT)
            dt = time.time() - t0
            sz = os.path.getsize(path)
            print(f"  {category}/{n}: {sz/1024:.1f}KB ({dt:.2f}s)")
            total += 1

    print(f"\nGenerated {total} stress test files in {OUT}")
