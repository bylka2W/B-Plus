#!/usr/bin/env python3
"""Generate ALL B+ stress/fuzz/corpus tests for categories 1-13."""
import os, random

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)))

def w(path, content):
    full = os.path.join(OUT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"  wrote {path} ({len(content)} bytes)")

# ============================================================
# CATEGORY 1: Parser Fuzz Tests (malformed input)
# ============================================================
def gen_parser_fuzz():
    d = "fuzz/parser"
    w(f"{d}/01_unclosed_if.b+", "state Main {\n  entry {\n    if (1) {\n      print(1)\n")
    w(f"{d}/02_unclosed_string.b+", 'state Main {\n  entry {\n    var x = "hello\n')
    w(f"{d}/03_garbage_tokens.b+", "!@#$%^&*()_+{}|:\"<>?`~")
    w(f"{d}/04_empty_input.b+", "")
    w(f"{d}/05_only_whitespace.b+", "   \t\t\n   \n\t  \n")
    w(f"{d}/06_only_comments.b+", "// this is a comment\n// another\n")
    w(f"{d}/07_truncated_state.b+", "state Main { entry { print(1) ")
    w(f"{d}/08_truncated_string.b+", 'state Main { entry { var x = "ab')
    w(f"{d}/09_nested_unclosed.b+", "state Main { entry { if (1) { while(1) { print(")
    w(f"{d}/10_binary_only.b+", "\x00\x01\x02\x03\xff\xfe\xfd")
    w(f"{d}/11_missing_rhs.b+", "state Main { entry { var x = 1 + } }")
    w(f"{d}/12_invalid_ops.b+", "state Main { entry { var x = 1 ++ 2 } }")
    w(f"{d}/13_missing_import.b+", 'import\nstate Main { entry {} }')
    w(f"{d}/14_unclosed_bracket.b+", "state Main { entry { var x = (1 + 2 } }")
    w(f"{d}/15_unclosed_paren.b+", "state Main { entry { print(1 + 2 } }")
    w(f"{d}/16_annotations.b+", "state Main @hot { entry @cold {} }")
    w(f"{d}/17_duplicate_states.b+", "state Main { entry { print(1) } }\nstate Main { entry { print(2) } }")
    w(f"{d}/18_duplicate_vars.b+", "state Main { entry { var x = 1\nvar x = 2 } }")
    w(f"{d}/19_double_else.b+", "state Main { entry { if (1) { } else { } else { } } }")
    w(f"{d}/20_keyword_in_ident.b+", "state Main { entry { var state = 1 } }")
    w(f"{d}/21_deeply_nested_braces.b+", "state Main { entry {\n" + "  " * 200 + "print(1)\n" + "}\n" * 201)
    w(f"{d}/22_mixed_quotes.b+", "state Main { entry { var x = \"hello' } }")
    w(f"{d}/23_escape_at_eof.b+", 'state Main { entry { var x = "test\\')
    w(f"{d}/24_null_bytes.b+", "state Main {\x00 entry { print(1) } }")
    w(f"{d}/25_single_brace.b+", "{")
    w(f"{d}/26_only_numbers.b+", "123 456 789\n0 -1 42")
    w(f"{d}/27_random_semicolons.b+", ";;; ; ; ;; ; ;")
    w(f"{d}/28_empty_string.b+", 'state Main { entry { var x = "" } }')
    w(f"{d}/29_huge_number.b+", "state Main { entry { var x = 9" + "9" * 500 + " } }")
    w(f"{d}/30_unicode_idents.b+", "state \u00e9\u00e8\u00ea { entry {} }")

# ============================================================
# CATEGORY 2: Symbol Resolution Tests
# ============================================================
def gen_symbol_tests():
    d = "fuzz/symbols"
    w(f"{d}/01_duplicate_fn.b+", "fn foo() { print(1) }\nfn foo() { print(2) }\nstate Main { entry { foo() } }")
    w(f"{d}/02_undefined_fn.b+", "state Main { entry { nonexistent() } }")
    w(f"{d}/03_undefined_state.b+", "state Main { entry { } on ev -> MissingState }")
    w(f"{d}/04_circular_refs.b+", "state A { entry { } on ev -> B }\nstate B { on ev -> A }")
    w(f"{d}/05_state_var_scope.b+", "state Main { var x: int = 1\nentry { print(x) } }\nstate Other { entry { print(x) } }")
    w(f"{d}/06_fn_param_shadows_var.b+", "var x = 1\nfn foo(x: int) { print(x) }\nstate Main { entry { foo(2) } }")
    w(f"{d}/07_duplicate_entry.b+", "state Main { entry { print(1) }\nentry { print(2) } }")
    w(f"{d}/08_undefined_struct.b+", "state Main { entry { var s: MyStruct } }")
    w(f"{d}/09_struct_field_missing.b+", "struct S { x: int }\nstate Main { entry { var s: S\nprint(s.y) } }")
    w(f"{d}/10_self_transition.b+", "state Main { entry { } on ev -> Main }")

# ============================================================
# CATEGORY 3: Deep Recursion Tests
# ============================================================
def gen_recursion_tests():
    d = "fuzz/recursion"
    w(f"{d}/01_deep_recursion.b+", "fn deep(n: int) {\n  if (n > 0) { deep(n - 1) }\n  else { print(n) }\n}\nstate Main { entry { deep(500) } }")
    w(f"{d}/02_fibonacci_deep.b+", "fn fib(n: int) {\n  if (n <= 1) { return n }\n  return fib(n - 1) + fib(n - 2)\n}\nstate Main { entry { fib(30) } }")
    w(f"{d}/03_mutual_recursion.b+", "fn is_even(n: int) {\n  if (n == 0) { return 1 }\n  return is_odd(n - 1)\n}\nfn is_odd(n: int) {\n  if (n == 0) { return 0 }\n  return is_even(n - 1)\n}\nstate Main { entry { is_even(100) } }")
    w(f"{d}/04_factorial.b+", "fn fact(n: int) {\n  if (n <= 1) { return 1 }\n  return n * fact(n - 1)\n}\nstate Main { entry { fact(20) } }")
    w(f"{d}/05_recursive_struct_init.b+", "fn build(n: int) {\n  if (n > 0) { build(n - 1) }\n}\nstate Main { entry { build(1000) } }")
    w(f"{d}/06_self_recursive_fn.b+", "fn f() { f() }\nstate Main { entry { } }")

# ============================================================
# CATEGORY 4: Import Hell (1000-5000 imports)
# ============================================================
def gen_import_hell():
    d = "stress/generated"
    for n in [100, 500, 1000, 5000]:
        lines = [f'import "nonexistent_{i}.b+"' for i in range(n)]
        lines.append("state Main { entry { print(1) } }")
        w(f"{d}/import_hell_{n}.b+", "\n".join(lines))

# ============================================================
# CATEGORY 5: State Machine Hell (10000 states)
# ============================================================
def gen_state_hell():
    d = "stress/generated"
    for n in [100, 500, 1000, 5000, 10000]:
        lines = []
        for i in range(n):
            lines.append(f"state S{i} {{")
            lines.append(f"  var x{i}: int = {i}")
            lines.append(f"  entry {{ print(x{i}) }}")
            if i > 0:
                lines.append(f"  on ev -> S{i - 1}")
            lines.append("}")
        lines.insert(0, "state Main { entry { } on ev -> S0 }")
        w(f"{d}/state_hell_{n}.b+", "\n".join(lines))

# ============================================================
# CATEGORY 6: Context Variable Hell (10000 vars)
# ============================================================
def gen_context_var_hell():
    d = "stress/generated"
    for n in [100, 500, 1000, 5000, 10000]:
        lines = [f"state Main {{"]
        for i in range(n):
            lines.append(f"  var v{i}: int = {i % 1000}")
        lines.append("  entry {")
        for i in range(min(n, 100)):
            lines.append(f"    print(v{i})")
        lines.append("  }")
        lines.append("}")
        w(f"{d}/ctxvar_hell_{n}.b+", "\n".join(lines))

# ============================================================
# CATEGORY 7: Expression Hell (1000 nesting levels)
# ============================================================
def gen_expression_hell():
    d = "stress/generated"
    for n in [50, 100, 500, 1000]:
        expr = "(" * n + "1" + ")" * n
        w(f"{d}/expr_nest_{n}.b+", f"state Main {{ entry {{ var x = {expr} }} }}")
    # Long chain
    for n in [100, 500, 1000]:
        chain = " + ".join(["1"] * n)
        w(f"{d}/expr_chain_{n}.b+", f"state Main {{ entry {{ var x = {chain} }} }}")
    # Deep if/else nesting
    for n in [50, 100]:
        code = "state Main {\n  entry {\n"
        indent = "    "
        for i in range(n):
            code += f"{indent}if (1) {{\n"
            indent += "  "
        code += f"{indent}print(1)\n"
        for i in range(n):
            indent = indent[:-2]
            code += f"{indent}}}\n"
        code += "  }\n}"
        w(f"{d}/ifelse_nest_{n}.b+", code)

# ============================================================
# CATEGORY 8: Integer Overflow Tests
# ============================================================
def gen_overflow_tests():
    d = "fuzz/overflow"
    w(f"{d}/01_i64_max.b+", "state Main { entry { var x = 9223372036854775807\nvar y = x + 1 } }")
    w(f"{d}/02_i64_min.b+", "state Main { entry { var x = -9223372036854775808\nvar y = x - 1 } }")
    w(f"{d}/03_zero_underflow.b+", "state Main { entry { var x = 0\nvar y = x - 1 } }")
    w(f"{d}/04_div_zero.b+", "state Main { entry { var x = 1 / 0 } }")
    w(f"{d}/05_huge_number.b+", "state Main { entry { var x = 999999999999999999999999999999 } }")
    w(f"{d}/06_mul_overflow.b+", "state Main { entry { var x = 999999999 * 999999999 } }")
    w(f"{d}/07_shift_huge.b+", "state Main { entry { var x = 1 << 100 } }")
    w(f"{d}/08_neg_huge.b+", "state Main { entry { var x = -999999999999999999999 } }")

# ============================================================
# CATEGORY 9: Memory Corruption Tests
# ============================================================
def gen_memory_tests():
    d = "fuzz/memory"
    w(f"{d}/01_out_of_bounds.b+", "state Main {\n  var arr: int = 5\n  entry {\n    var x = arr[999999]\n  }\n}")
    w(f"{d}/02_negative_index.b+", "state Main {\n  var arr: int = 5\n  entry {\n    var x = arr[-1]\n  }\n}")
    w(f"{d}/03_free_invalid.b+", "state Main {\n  entry {\n    var x = 5\n    free(x)\n  }\n}")
    w(f"{d}/04_double_free.b+", "state Main {\n  entry {\n    var x = 5\n    free(x)\n    free(x)\n  }\n}")
    w(f"{d}/05_use_after_free.b+", "state Main {\n  entry {\n    var x = 5\n    free(x)\n    print(x)\n  }\n}")

# ============================================================
# CATEGORY 10: Struct Layout Tests
# ============================================================
def gen_struct_tests():
    d = "fuzz/struct"
    w(f"{d}/01_layout.b+", "struct Point { x: int\ny: int\nz: int }\nstate Main { entry { var p: Point } }")
    w(f"{d}/02_empty_struct.b+", "struct Empty {}\nstate Main { entry { var e: Empty } }")
    w(f"{d}/03_recursive_struct.b+", "struct Node { val: int\nnext: Node }\nstate Main { entry { var n: Node } }")
    w(f"{d}/04_enum_basic.b+", "enum Color { Red\nGreen\nBlue }\nstate Main { entry { var c: Color } }")
    w(f"{d}/05_enum_empty.b+", "enum Empty {}\nstate Main { entry { } }")
    w(f"{d}/06_enum_dup.b+", "enum Dup { A\nA\nB\nB }\nstate Main { entry { } }")
    w(f"{d}/07_nested_struct.b+", "struct Inner { a: int }\nstruct Outer { inner: Inner\nb: int }\nstate Main { entry { var o: Outer } }")
    w(f"{d}/08_struct_many_fields.b+", "struct Big {\n" + "\n".join([f"  f{i}: int" for i in range(100)]) + "\n}\nstate Main { entry { var b: Big } }")

# ============================================================
# CATEGORY 11: Codegen Stress (100K-1M lines)
# ============================================================
def gen_codegen_stress():
    d = "stress/generated"
    for n in [1000, 5000, 10000]:
        lines = [f"state Main {{"]
        lines.append("  entry {")
        for i in range(n):
            lines.append(f"    var x{i} = {i % 100}")
            if i % 10 == 0:
                lines.append(f"    print(x{i})")
        lines.append("  }")
        lines.append("}")
        w(f"{d}/codegen_stress_{n}.b+", "\n".join(lines))

# ============================================================
# CATEGORY 13: Golden Regression (valid programs that MUST compile)
# ============================================================
def gen_golden_regression():
    d = "regressions"
    # Already have 001-003. Add golden (must-compile) tests.
    w(f"{d}/010_minimal_state.b+", "state Main {\n  entry {\n    print(42)\n  }\n}")
    w(f"{d}/011_two_states.b+", "state A {\n  entry {\n    print(1)\n  }\n  on ev -> B\n}\nstate B {\n  entry {\n    print(2)\n  }\n}")
    w(f"{d}/012_with_vars.b+", "state Main {\n  var counter: int = 0\n  entry {\n    counter = counter + 1\n    print(counter)\n  }\n}")
    w(f"{d}/013_with_fn.b+", "fn add(a: int, b: int) {\n  return a + b\n}\nstate Main {\n  entry {\n    var x = add(1, 2)\n    print(x)\n  }\n}")
    w(f"{d}/014_struct_use.b+", "struct Point {\n  x: int\n  y: int\n}\nstate Main {\n  entry {\n    var p: Point\n  }\n}")
    w(f"{d}/015_enum_use.b+", "enum Dir {\n  North\n  South\n  East\n  West\n}\nstate Main {\n  entry {\n    var d: Dir\n  }\n}")
    w(f"{d}/016_while_loop.b+", "state Main {\n  var i: int = 0\n  entry {\n    while (i < 10) {\n      i = i + 1\n      print(i)\n    }\n  }\n}")
    w(f"{d}/017_if_else.b+", "state Main {\n  var x: int = 5\n  entry {\n    if (x > 3) {\n      print(1)\n    } else {\n      print(0)\n    }\n  }\n}")
    w(f"{d}/018_multiple_fns.b+", "fn double(x: int) { return x + x }\nfn square(x: int) { return x * x }\nstate Main {\n  entry {\n    var a = double(5)\n    var b = square(3)\n    print(a)\n    print(b)\n  }\n}")
    w(f"{d}/019_state_chain.b+", "state A { entry { print(\"A\") } on go -> B }\nstate B { entry { print(\"B\") } on go -> C }\nstate C { entry { print(\"C\") } }")
    w(f"{d}/020_always_transition.b+", "state A { entry { print(1) }\nalways -> B }\nstate B { entry { print(2) }\nalways -> C }\nstate C { entry { print(3) } }")


print("=== Generating ALL test categories ===")
print("\n[1] Parser Fuzz Tests")
gen_parser_fuzz()
print("\n[2] Symbol Resolution Tests")
gen_symbol_tests()
print("\n[3] Deep Recursion Tests")
gen_recursion_tests()
print("\n[4] Import Hell")
gen_import_hell()
print("\n[5] State Machine Hell")
gen_state_hell()
print("\n[6] Context Variable Hell")
gen_context_var_hell()
print("\n[7] Expression Hell")
gen_expression_hell()
print("\n[8] Integer Overflow Tests")
gen_overflow_tests()
print("\n[9] Memory Corruption Tests")
gen_memory_tests()
print("\n[10] Struct Layout Tests")
gen_struct_tests()
print("\n[11] Codegen Stress")
gen_codegen_stress()
print("\n[13] Golden Regression Suite")
gen_golden_regression()

print("\n=== ALL DONE ===")
