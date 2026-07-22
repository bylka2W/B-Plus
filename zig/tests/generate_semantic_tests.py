#!/usr/bin/env python3
"""Generate semantic validation tests. Each test is a separate .b+ file.
For each test, we record EXPECTED behavior: should the compiler reject it (exit=1 or crash)?
Or does B+ intentionally allow it (exit=0)?"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "semantic")
os.makedirs(OUT, exist_ok=True)

def w(name, code, expected="reject", note=""):
    path = os.path.join(OUT, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(code)
    print(f"  {name} (expected={expected}) {note}")

# ============================================================
# GROUP 1: Undefined variables → should be errors
# ============================================================
w("01_undefined_var_in_print.b+",
  'state Main {\n  entry {\n    print(totally_nonexistent_var)\n  }\n}',
  expected="reject", note="undefined var in print()")

w("02_undefined_var_arithmetic.b+",
  'state Main {\n  entry {\n    var x = undefined_a + undefined_b\n    print(x)\n  }\n}',
  expected="reject", note="undefined vars in arithmetic")

w("03_undefined_var_as_condition.b+",
  'state Main {\n  entry {\n    if (ghost_variable) {\n      print(1)\n    } else {\n      print(0)\n    }\n  }\n}',
  expected="reject", note="undefined var as if-condition")

w("04_undefined_var_in_assignment.b+",
  'state Main {\n  entry {\n    undefined_target = 42\n  }\n}',
  expected="reject", note="assign to undefined variable")

w("05_undefined_var_in_while.b+",
  'state Main {\n  entry {\n    while (nonexistent) {\n      print(1)\n    }\n  }\n}',
  expected="reject", note="undefined var as while condition")

# ============================================================
# GROUP 2: Type confusion
# ============================================================
w("06_number_as_if_condition.b+",
  'state Main {\n  entry {\n    if (42) {\n      print(1)\n    } else {\n      print(0)\n    }\n  }\n}',
  expected="maybe_ok", note="number as if-condition — B+ might allow this (0=false)")

w("07_string_as_condition.b+",
  'state Main {\n  entry {\n    if ("hello") {\n      print(1)\n    }\n  }\n}',
  expected="reject", note="string as if-condition — should be type error")

w("08_struct_as_condition.b+",
  'struct Point { x: int }\nstate Main {\n  entry {\n    var p: Point\n    if (p) {\n      print(1)\n    }\n  }\n}',
  expected="reject", note="struct as if-condition")

# ============================================================
# GROUP 3: Bare expression statements
# ============================================================
w("09_bare_number.b+",
  'state Main {\n  entry {\n    42\n  }\n}',
  expected="maybe_ok", note="bare number — might be valid no-op")

w("10_bare_string.b+",
  'state Main {\n  entry {\n    "hello"\n  }\n}',
  expected="maybe_ok", note="bare string — might be valid no-op")

# ============================================================
# GROUP 4: Self-referencing initialization
# ============================================================
w("11_self_ref_init.b+",
  'state Main {\n  var x: int = x + 1\n  entry {\n    print(x)\n  }\n}',
  expected="reject", note="variable uses itself in its own initializer")

# ============================================================
# GROUP 5: Function call validation
# ============================================================
w("12_too_many_args.b+",
  'fn adder(x: int) {\n  print(x)\n}\nstate Main {\n  entry {\n    adder(1, 2, 3)\n  }\n}',
  expected="reject", note="too many arguments to function")

w("13_too_few_args.b+",
  'fn adder(x: int, y: int) {\n  print(x)\n  print(y)\n}\nstate Main {\n  entry {\n    adder(1)\n  }\n}',
  expected="reject", note="too few arguments to function")

w("14_call_nonexistent_fn.b+",
  'state Main {\n  entry {\n    nonexistent_function(1, 2)\n  }\n}',
  expected="reject", note="calling completely nonexistent function")

w("15_call_undefined_with_args.b+",
  'state Main {\n  entry {\n    var x = mystery_func(42)\n    print(x)\n  }\n}',
  expected="reject", note="call to undefined function, use result")

# ============================================================
# GROUP 6: Return type confusion
# ============================================================
w("16_return_inconsistency.b+",
  'fn chaos(x: int) {\n  if (x > 0) {\n    return 1\n  } else {\n    return "hello"\n  }\n}\nstate Main {\n  entry {\n    var r = chaos(1)\n    print(r)\n  }\n}',
  expected="reject", note="function returns int in one branch, string in another")

w("17_return_value_vs_no_return.b+",
  'fn weird(x: int) {\n  if (x > 0) {\n    return 42\n  }\n}\nstate Main {\n  entry {\n    var r = weird(1)\n    print(r)\n  }\n}',
  expected="maybe_ok", note="one branch returns, other doesn't — is missing return value 0?")

# ============================================================
# GROUP 7: Scope violations
# ============================================================
w("18_use_local_outside.b+",
  'state Main {\n  entry {\n    var local = 5\n  }\n  on ev -> Other\n}\nstate Other {\n  entry {\n    print(local)\n  }\n}',
  expected="reject", note="using local var from another state")

w("19_entry_var_in_fn.b+",
  'state Main {\n  var counter: int = 10\n  entry {\n    my_fn()\n  }\n}\nfn my_fn() {\n  print(counter)\n}',
  expected="maybe_ok", note="accessing state var from standalone fn — might be valid if fn is in same state")

# ============================================================
# GROUP 8: Breaking language invariants
# ============================================================
w("20_break_outside_loop.b+",
  'state Main {\n  entry {\n    break\n  }\n}',
  expected="reject", note="break outside any loop")

w("21_continue_outside_loop.b+",
  'state Main {\n  entry {\n    continue\n  }\n}',
  expected="reject", note="continue outside any loop")

w("22_return_in_entry.b+",
  'state Main {\n  entry {\n    var x = 5\n    return x\n  }\n}',
  expected="maybe_ok", note="return with value from entry — is entry a function?")

# ============================================================
# GROUP 9: Import errors
# ============================================================
w("23_import_nonexistent.b+",
  'import "this_file_does_not_exist_ever.b+"\nstate Main {\n  entry {\n    print(1)\n  }\n}',
  expected="reject", note="importing nonexistent file")

# ============================================================
# GROUP 10: Edge cases in the language
# ============================================================
w("24_empty_state.b+",
  'state Main {\n}',
  expected="maybe_ok", note="state with no entry — might be valid")

w("25_state_no_entry.b+",
  'state A {\n  on ev -> B\n}\nstate B {\n  entry { print(1) }\n}',
  expected="maybe_ok", note="state A has no entry, only transitions")

w("26_always_to_self.b+",
  'state Main {\n  entry { print(1) }\n  always -> Main\n}',
  expected="reject", note="always transition to self — infinite immediate loop")

w("27_enum_value_as_state_var.b+",
  'enum Color { Red\nGreen\nBlue }\nstate Main {\n  var c: Color\n  entry {\n    print(c)\n  }\n}',
  expected="maybe_ok", note="printing an enum value — valid?")

w("28_struct_field_access.b+",
  'struct Point { x: int\ny: int }\nstate Main {\n  entry {\n    var p: Point\n    print(p.x)\n  }\n}',
  expected="maybe_ok", note="struct field access — is dot syntax supported?")

w("29_nested_struct_init.b+",
  'struct Inner { val: int }\nstruct Outer { inner: Inner\nextra: int }\nstate Main {\n  entry {\n    var o: Outer\n  }\n}',
  expected="maybe_ok", note="nested struct declaration")

w("30_negative_array_index.b+",
  'state Main {\n  var arr: int = 5\n  entry {\n    var x = arr[-1]\n  }\n}',
  expected="reject", note="negative array index")

print(f"\n=== Generated {len(os.listdir(OUT))} semantic validation tests ===")
