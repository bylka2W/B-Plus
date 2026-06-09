# B+ — state machine compiler (x64)

**B+** is a compiler for state machines written in `.b+` files. It generates **native x64 machine code** directly and produces Windows PE executables — no assembler, no linker, no LLVM.

---

## What it does

| Feature | Status |
|---------|--------|
| State machine parsing (states, events, transitions, guards) | ✅ |
| x64 machine code generation (no external tools) | ✅ |
| Windows PE executable output | ✅ |
| Entry/exit actions per state | ✅ |
| `@cache(L1)`, `@hot`, `@cold` annotations | ✅ |
| `print()` for console output | ✅ |
| Basic guard conditions on transitions | ✅ |
| LLVM / WASM / SPIR-V / GPU targets | ❌ |
| LSP / IDE support | ❌ |
| "AI optimizer" / "Metal Stack" | ❌ |
| Multi-platform (Windows x64 only) | ⚠️ |

## Quick start

```
bpc input.b+
.\input.exe
```

Compiles `input.b+` to `input.exe` and runs it.

## What a `.b+` file looks like

```
state Green {
    on timer -> Yellow
    entry { print("Green\n") }
}

state Yellow {
    on timer [cars_waiting] -> Green
    on timer -> Red
    entry { print("Yellow\n") }
}

state Red {
    on timer -> Green
    entry { print("Red\n") }
}
```

## Project structure

```
zig/src/       — compiler source (Zig)
  main.zig     — entry point
  parser.zig   — .b+ file parser
  ast.zig      — AST types
  x64gen.zig   — x64 code generation
  x64enc.zig   — x64 instruction encoding
  pe.zig       — PE executable writer
src/           — original C# version (reference)
```

## Building from source

Requires [Zig](https://ziglang.org/) master.

```
cd zig
zig build
```

Or compile directly:

```
cd zig
zig build-exe src/main.zig -femit-bin=bpc.exe
```

## Notes

- Only **Windows x64** target is supported.
- The compiler is **minimal** — just enough to compile simple state machines.
- Error messages are basic.
- The C# version in `src/` is the original implementation; the Zig version in `zig/` is the current active development.
