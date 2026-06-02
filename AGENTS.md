# Session Summary

## Compile targets (multi-module)
- `dotnet build BPlus.sln` — build all projects
- `dotnet run --project src\BPlus.Cli -- hello.bp` — transpile hello.bp (entry point)
- `compile-metal.bat` — full LLVM→.exe pipeline (llc → lld-link)
- `src\zig-bpc\bpc-zig.exe hello.bp` — Zig transpiler (hello.bp → output.zig)
- `zig build-obj output.zig` — output.zig → output.obj
- `zig build-exe output.zig --name out` — output.zig → out.exe

## Zig transpiler (src/zig-bpc/)
- `zig build-exe src\zig-bpc\src\main.zig --name bpc` — build the transpiler itself
- `bpc.exe hello.bp` → `output.zig`
- Full pipeline: hello.bp → output.zig → zig build-obj → output.obj
- Currently handles: `entry main()` with `print()` and `return` statements
- Tokenizer handles: strings, numbers, identifiers, keywords, all operators, `//` and `--` comments
- Parser: recursive descent, precedence climbing for expressions (Pratt parser)
- Generator outputs: Zig source with `std.io.getStdOut().writer()` for stdout
- Zig 0.14.0 installed at `C:\tools\zig\zig-windows-x86_64-0.14.0\zig.exe`

## Fixed
### `$section` metadata (LLVM 21 compat)
- `src/BPlusTranspiler/LlvmGenMetal.cs` — changed `section"$...$..."` to `!{i32 0, i32 2, i32 0}`
- `LLVMGen/llvm-gen.c` — same fix

### `main()` entry point
- `src/BPlusTranspiler/LlvmGenMetal.cs` — generates `main` with `i32` return, calls `puts` (not `printf`) to avoid CRT
- `legacy_stdio.ll` — implements `puts` via `kernel32!WriteFile`, no MSVCRT dependency

### `compile-metal.bat` — multiple fixes
- URL changed from vovkos (LLVM 18) → official LLVM 21.1.1
- `GEN_DIR` fixed from `gen` → `gen_metal`
- Output artifacts (`.obj`, `.exe`) now go into `%GEN_DIR%\`
- Fixed `Непредвиденное появление` parser crash: `(`/`)` in `echo` text inside `()` blocks must be escaped with `^(`/`^)`
- Fixed `&&` inside `()` blocks (replaced with `if !ERRORLEVEL!`)
- Converted batch file from LF to CRLF line endings

## Pipeline
`hello.bp` → BPlusTranspiler (LlvmGenMetal.cs) → `gen_metal/kernels_metal.ll` → llc → `.obj` → lld-link + legacy_stdio.obj → `gen_metal/bplus_metal_output.exe`

## Profile
- `dotnet run --project src\BPlus.Cli -- profile examples\traffic_light.bp 1000` — transition profiling

## Test commands
```powershell
# Python global fix
dotnet run --project src\BPlusTranspiler -- hello.bp
Select-String "global" gen\generated.py

# Zig DLL full pipeline
Copy-Item bpc_backend.dll src\BPlusTranspiler\bin\Debug\net8.0\ -Force
dotnet run --project src\BPlusTranspiler -- --zig --run hello.bp

# Check += not =
dotnet run --project src\BPlusTranspiler -- --zig hello.bp
Select-String "attempts \+= 1" output.zig

# Check guard grouping (one if per event)
Select-String "wrong_code" output.zig
```

## Fixed (current session — 2026-05-30)

### Tests S24/S25/S30: ValidateGenerators() emits 7 expected errors
- `src/BPlusTranspiler/BPlusValidator.cs` — `ValidateGenerators()` reports #82, #98, #63, #64, #983, #993, #996
- Previously silent → tests expected these errors, now 218/218 pass
- `dotnet build`: 0 warnings, 0 errors; `dotnet test`: 218/218 passed

### Warnings 0
- `BPlusParser.cs:236` — CS8604: null check on ParseGpuKernel() return
- `Program.cs:1591,1628` — CS8602: null-forgiving `!` on process.StartInfo

### `--metal` auto-compiles to .exe
- `Program.cs` RunMetal(): after LL → `.ll`, runs `clang -c` → `.obj`, then `lld-link` + `legacy_stdio.obj` → `.exe`
- Same pipeline as `--release` mode (clang, not llc — llc missing from LLVM 21.1.1)
- README line 591/1948: "(auto-compiles to .exe)"

### Repo cleanup: 316 MB → 34 MB
- `git filter-branch` purged `bpc.exe` (38 MB), `bpc_backend.dll`, `out.pdb`, zig-global-cache from all 194 commits
- `git gc --aggressive --prune=now` after reflog expiry
- `.gitignore`: added `*.dll`, `bpc.exe`, `zig-global-cache/`
- Pushed to GitVerse (SSH) and GitHub — success, no more HTTP 413

### Example .bp files
- `examples/hello.bp` — minimal `entry main() { print("hello"); }`
- `examples/traffic_light.bp` — state machine with `context { var ... }`
- `examples/tcp_server.bp` — TCP server FSM

### Bugfix: `--pgo` no longer tries to execute Makefile as binary
- `PgoPipeline.cs` `CompileWithPgo()` — when clang not found, instead of returning Makefile path (→ `Process.Start` on Makefile → Win32Exception), now tries `make -f Makefile`; throws `InvalidOperationException` with instructions if make also fails

### Bugfix: `publish` WorkingDirectory corrected (off-by-one `..`)
- `Program.cs:126` — `..\..\..\BPlusTranspiler` → `..\..\..\..\BPlusTranspiler` to reach `src/BPlusTranspiler/` from `bin/Debug/net8.0/`

### Bugfix: `--lsp` responds to Ctrl+C
- `BPlusLspServer.cs:Run()` — added `Console.CancelKeyPress` handler that sets `_shutdown = true`, breaking the read loop instead of hanging forever

### Python: `global` for context vars
- `PythonGenerator.cs` — `IsContextVarAssigned()` detects `=`/`+=`/`-=`/`++`/`--` with context var name in transition body/guard
- Emits `global var1, var2` before assignments in state methods

### ParseVarDecl: keyword-aware termination
- `BPlusParser.cs:546-562` — initializer loop now stops at `;`, `\n`/`\r`, `}` at depth 0, AND at state-body keywords (`var `, `on `, `enter `, `exit `, `state `, `inline `, `fn `, `always`) at depth 0
- Prevents eating subsequent declarations/actions into default value

### Console encoding (UTF-8)
- `Program.cs:1486-1504` — `chcp 65001` + UTF-8 encoding in `Process.Start` before running `out.exe`
- Russian text now displays correctly instead of CP866 krakozyabry

### Zig DLL: `assign_op` field
- `ast.zig` — added `assign_op: []const u8 = "="` to `Stmt.assign`
- `parser.zig` — `+=`/`-=` set `assign_op` to `"+="`/`"-="`
- `gen_zig.zig` — uses `stmt.assign_op` instead of hardcoded `" = "`
- Fixes `ctx.attempts = 1` → `ctx.attempts += 1`

### Zig DLL: guard grouping (like Python/C++)
- `gen_zig.zig` — transitions with same `event_name` grouped into single `if (std.mem.eql(u8, event, ...))`
- Bodies emitted unconditionally (preserving order), guards as separate `if (guard) { target; return; }` chain
- Matches Python/C++ behavioral semantics

### Zig DLL: state-local var prefix (`ctx.StateName_var`)
- `gen_zig.zig` — added `prog` and `current_state` fields to `Generator`
- `isStateLocalVar()` helper checks if a var belongs to current state
- `genExprInState(.ident)` and `genStmtInState(.assign)` use `ctx.StateName_var` for state-local vars, `ctx.var` for context vars
- Fixes `ctx.x` → `ctx.Test_x` for state-local variable references

### ParseVarDecl: keyword-aware break fix
- `BPlusParser.cs:546` — fixed operator precedence: `depth == 0` now applies to ALL keyword checks, not just `var`
- `\n`/`\r` now only break at depth 0 (allows multi-line expressions inside brackets)
- Prevents false positive breaks on `on`/`enter`/`exit` inside bracket expressions

### Zig DLL: `inferred` → `i32` (not `var`)
- `gen_zig.zig:mapType` — changed `"inferred"` from `"var"` to `"i32"`
- Zig struct fields require concrete types; `var` is a keyword, not a type

### BodyJsonParser: infinite loop в Pratt-парсере (`prec == Prec.None`)
- `BodyJsonParser.cs:372` — в `ParseExpr()` цикл while проверял `prec < minPrec`, но когда `minPrec` = `Prec.None` (0) и `GetInfixPrec()` возвращает `Prec.None` (конец ввода), условие `0 < 0` ложно → бесконечный цикл
- Проявлялось на guard text `current_rpm > 1200`: после парсинга Binary(pos был в конце), `GetInfixPrec()` → `Prec.None`, `ParseInfix()` возвращал lhs без изменений → вечный вызов ParseInfix
- Исправлено: добавлен `prec == Prec.None` как ранний выход из while
- `--zig hello.bp` снова работает (`output.zig` 970 байт, корректный StateFn код)

### Zig DLL: LLVM IR генератор (Mode 1 / Release)
- `src/zig-bpc/src/gen_llvm.zig` — новый файл: генерирует LLVM IR с StateFn паттерном
- `@.strN` константы для строковых литералов (hex-escaped UTF-8)
- `%context_t` struct type с полями для context-var, state-local var, function pointer
- State functions `@Parking_enter(ptr %ctx, i64 %event_id)` с event dispatch (`icmp` + `br`)
- Guard-ы через `getelementptr` + `load` + `icmp sgt` → `br` transition/done
- `@main()`: alloca контекста, `store` инициализация, вызов начального стейта
- Исправлен `ast_json.zig`: все ArrayList поля явно инициализируются пустыми списками (предотвращает crash)
- `Program.cs`: Mode 1 пайплайн — `.ll` → `clang -c` → `.obj` → `lld-link` + `legacy_stdio.obj` → `.exe`

### gen_llvm.zig: proper guard expressions, 64-byte alignment, event dispatch fix
- `src/zig-bpc/src/gen_llvm.zig` — полностью переписан:
  - **General guard expression parsing**: `genLlvmExpr()` рекурсивно разбирает JSON AST → LLVM IR (ident → getelementptr + load, binary → icmp, literal → константа)
  - **64-byte alignment**: `alloca %context_t, align 64` — cache line optimization
  - **Event dispatch fix**: enter body теперь `br label %check_guards` вместо `ret void`; после enter-блока проверяются guard-ы для auto-transitions
  - **Guard chaining**: несколько guard-ов chainятся, последний падает в `done` (без пустых basic block)
  - **SSA register counter**: `tmp_counter` для уникальных `%v0`, `%v1`, ...
  - **Variable lookup**: `findContextFieldIdx()` находит индекс переменной в context_t по имени
- `llc.exe` не входит в LLVM 21.1.1 — пайплайн использует `clang -c` (как и diagram, но без `llc`)

## State
- **C# (стабильный)**: парсинг + все старые генераторы (Python, C++, C, Rust, Go, C#, LLVM) — 218/218 тестов, 0 warnings
- **--metal**: clang → .obj → lld-link → .exe (auto-compile)
- **Zig DLL (Phase 2)**: `--zig` флаг, StateFn паттерн, event loop, группировка guard-ов, поддержка `+=`/`-=`, правильный prefix для state-local vars
- **JSON-мост**: C# → JSON → Zig DLL → `output.zig` → `zig build-exe` → `out.exe` — работает
- **Expression AST в JSON**: `BodyJsonParser` Pratt-парсер + JSON Stmt/Expr сериализация — работает. `--zig --run hello.bp` генерирует корректный `output.zig`
- **LLVM IR (Mode 1 / Release)**: `--zig --release --run hello.bp` → `.ll` → `clang` → `.obj` → `lld-link` → `.exe` — работает
  - Guard `current_rpm > 1200` корректно генерируется из JSON (getelementptr + load + icmp sgt)
  - 64-byte alignment на alloca
  - После enter-блока fall-through в check_guards для auto-transition

## Known issues
- `kernel32.lib` path not resolved — lld-link needs explicit path or LIB env var
- If lld-link not found, falls back to MSVC `link.exe` via vcvars64.bat (VS 2019/2022)
- `\n` в строках B+ выводится буквально (как `\\n` в Zig, как `\5Cn` в LLVM IR) вместо реального newline — escape-последовательности не обрабатываются в JSON-мосте
- LLVM target triple override warning — не влияет на работу
- `llc.exe` отсутствует в LLVM 21.1.1 — `clang -c` используется вместо `llc` для .ll → .obj (diagram устарел для современных LLVM)
