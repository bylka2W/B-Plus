# B+ v4.2.0 — детерминированная машина переходов (x64)

**B+** транслирует `.b+` файлы напрямую в машинный код x64 и упаковывает в Windows PE (.exe).
Никаких ассемблеров, линкеров, LLVM — весь кодогенератор написан с нуля на Zig.

Встроенный runtime-уровень (Stage 1) — детерминированная машина состояний с формальной моделью переходов, трёхуровневой иерархией памяти (L1/L2/L3), поколенческими handle и единственной точкой исполнения миграций (`applyMigration`).

---

## Содержание

1. [Быстрый старт](#1-быстрый-старт)
2. [Команды компилятора](#2-команды-компилятора)
3. [Синтаксис языка](#3-синтаксис-языка)
   - [Состояния](#31-состояния)
   - [Переходы (on)](#32-переходы-on)
   - [Безусловные переходы (always)](#33-безусловные-переходы-always)
   - [Вход и выход (entry / exit)](#34-вход-и-выход-entry--exit)
   - [Переменные](#35-переменные)
   - [Присваивания](#36-присваивания)
   - [Печать (print)](#37-печать-print)
   - [Сторожевые условия (guard)](#38-сторожевые-условия-guard)
   - [global entry](#39-global-entry)
   - [Контекст (context)](#310-контекст-context)
   - [Аннотации](#311-аннотации)
   - [Перечисления (enum)](#312-перечисления-enum)
   - [Параллельные блоки (parallel)](#313-параллельные-блоки-parallel)
   - [Kernel-функции](#314-kernel-функции)
   - [Внешние функции (extern)](#315-внешние-функции-extern)
   - [Комментарии](#316-комментарии)
4. [Типы данных](#4-типы-данных)
5. [Примеры](#5-примеры)
6. [Сборка из исходников](#6-сборка-из-исходников)
7. [Структура проекта](#7-структура-проекта)
8. [Лицензия](#8-лицензия)
9. [Контакты](#9-контакты)

---

## 1. Быстрый старт

```
bpc.exe build hello.b+
.\hello.exe
```

Первая команда компилирует `hello.b+` в `hello.exe`.
Вторая — запускает.

Можно совместить:

```
bpc.exe run hello.b+
```

---

## 2. Команды компилятора

### Синтаксис

```
bpc build <входной.b+>              — скомпилировать в <входной>.exe
bpc build <входной.b+> -o <выход.exe> — скомпилировать с указанием имени
bpc run   <входной.b+>              — скомпилировать и сразу запустить
```

#### `bpc build <input.b+> [-o <output.exe>]`

Что делает:

| Шаг | Описание |
|-----|----------|
| 1 | Читает файл `.b+` целиком в память |
| 2 | Разбирает (парсит) исходный код в AST |
| 3 | Проверяет, что есть хотя бы одно состояние |
| 4 | Генерирует машинный код x64 напрямую (без ассемблера) |
| 5 | Расставляет NOP-выравнивание для кеша |
| 6 | Встраивает пул строк (для print) |
| 7 | Генерирует таблицу импорта (kernel32.dll) |
| 8 | Применяет все fixup'ы (адреса переходов) |
| 9 | Упаковывает всё в формат PE (.exe) |
| 10 | Записывает результат на диск |

Если `-o` не указан, имя выходного файла = имя входного с расширением `.exe`.

**Примеры:**
```
bpc build traffic.b+              → traffic.exe
bpc build traffic.b+ -o light.exe → light.exe
bpc build source.b+               → source.exe
```

#### `bpc run <input.b+>`

Что делает:

| Шаг | Описание |
|-----|----------|
| 1 | Компилирует `<input>.exe` |
| 2 | Запускает полученный `.exe` |
| 3 | Перехватывает stdout и печатает в консоль |
| 4 | Возвращает код завершения программы |

**Примеры:**
```
bpc run traffic.b+    — компилирует и сразу запускает
bpc run hello.b+      — компилирует и сразу запускает
```

### Коды возврата

| Код | Значение |
|-----|----------|
| 0 | Успех |
| 1 | Ошибка: неверные аргументы или файл не найден |
| >0 | Код завершения скомпилированной программы (при использовании `run`) |

### Примечания

- Входной файл **обязан** иметь расширение `.b+`.
- Если расширения нет, компилятор всё равно добавит `.exe` к базовому имени.
- Компилятор **не использует** внешние ассемблеры, линкеры или LLVM — весь машинный код генерируется самостоятельно.
- Выходной файл — полноценный Windows PE x64 исполняемый файл.

---

## 3. Синтаксис языка

### 3.1 Состояния

```
state <Имя> {
    ...
}
```

Состояние — базовый строительный блок. Внутри могут быть переменные, переходы, entry/exit-блоки.

```
state Red {
    on timer -> Green
    entry { print("RED\n") }
}
```

### 3.2 Переходы (on)

```
on <событие> -> <ЦелевоеСостояние>
```

Когда приходит событие (строка из stdin), автомат переходит в указанное состояние.

```
state Green {
    on timer -> Yellow
    on pedestrian -> Red
}
```

### 3.3 Безусловные переходы (always)

```
always -> <ЦелевоеСостояние>
```

Переход происходит сразу при входе в состояние, без ожидания события.

```
state Init {
    always -> Menu
}
```

### 3.4 Вход и выход (entry / exit)

```
state Door {
    entry { print("entered\n") }
    exit  { print("exited\n") }
    on open -> Opened
}
```

- `entry { ... }` — выполняется при входе в состояние.
- `exit { ... }` — выполняется перед выходом из состояния (перед переходом в другое).

### 3.5 Переменные

```
var <имя>: <тип> [= <значение>]
```

Объявляются внутри состояния. Типы: int8, int16, int32, int64, u8, u16, u32, u64, byte, bool, short, int, float и т.д.

```
state Counter {
    var count: int = 0
    on tick -> Self {
        count += 1
    }
}
```

Можно объявлять несколько переменных через запятую:

```
var x: int, y: int, name: int
```

### 3.6 Присваивания

Внутри `entry { }`, `exit { }` или тела перехода:

```
var x: int

on event -> Next {
    x = 42
    x += 1
    x -= 5
}
```

Поддерживаются операторы `=`, `+=`, `-=".
В правой части можно использовать числа и имена переменных.

### 3.7 Печать (print)

```
print("строка")
```

Печатает строку в stdout. Поддерживаются escape-последовательности `\n`, `\r`, `\t`.

```
state Hello {
    entry { print("Hello, world!\n") }
}
```

### 3.8 Сторожевые условия (guard)

```
on <событие> [<условие>] -> <ЦелевоеСостояние>
```

Переход происходит только если условие истинно. Поддерживаются операторы:
`==`, `!=`, `>`, `<`, `>=`, `<=`

```
state Crosswalk {
    var cars_waiting: bool
    on timer [cars_waiting == 0] -> Walk
    on timer [cars_waiting > 0]  -> Wait
}
```

### 3.9 global entry

```
entry <Имя> {
    ...
}
```

Глобальная точка входа — выполняется один раз при старте программы. Можно использовать для инициализации.

```
entry main {
    print("Starting...\n")
}
```

### 3.10 Контекст (context)

```
context {
    var <имя>: <тип>
    ...
}
```

Контекстные переменные — глобальные для всей программы, видимы во всех состояниях.

```
context {
    var global_count: int
}
```

### 3.11 Аннотации

Аннотации ставятся перед состоянием или переходом.

| Аннотация | Описание |
|-----------|----------|
| `@hot` | Горячий код — размещается в L1 кеше |
| `@cold` | Холодный код — не кешируется |
| `@hot(0.9)` | Явный weight горячести |
| `@cache(L1)` | Данные состояния в L1 |
| `@cache(L2)` | Данные состояния в L2 |
| `@cache(L3)` | Данные состояния в L3 |
| `@fast_path` | Быстрый путь исполнения |
| `@always_inline` | Всегда встраивать |
| `@no_inline` | Не встраивать |
| `@owned` / `@borrowed` | Владение памятью |

```
@hot
@cache(L1)
state FastPath {
    ...
}

@cold
state ErrorHandler {
    ...
}

on critical @hot(0.95) -> Shutdown
```

### 3.12 Перечисления (enum)

```
enum <Имя> {
    Член1,
    Член2,
    ...
}
```

Глобальное объявление перечисления.

```
enum Color {
    Red,
    Yellow,
    Green
}
```

### 3.13 Параллельные блоки (parallel)

```
parallel <Имя> {
    state A { ... }
    state B { ... }
}
```

Группировка состояний в параллельный блок (состояния не влияют друг на друга).

### 3.14 Kernel-функции

```
kernel <имя>(<параметр>: <тип>, ...) -> <тип>
```

Объявление kernel-функции (для генерации кода на стороне GPU/металла).

```
kernel matrixMul(a: int, b: int) -> int
```

### 3.15 Внешние функции (extern)

```
extern "dllname.dll" fn <имя>(<парам>: <тип>, ...) -> <тип>
```

Объявление внешней функции из DLL.

```
extern "user32.dll" fn MessageBoxA(hWnd: int, lpText: int, lpCaption: int, uType: int) -> int
```

### 3.16 Комментарии

```
// однострочный комментарий
-- тоже комментарий
```

---

## 4. Типы данных

| Тип | Размер (байт) |
|-----|--------------|
| `int8`, `i8`, `u8`, `byte`, `bool` | 1 |
| `int16`, `i16`, `u16`, `short`, `half` | 2 |
| `int32`, `i32`, `u32`, `int`, `uint`, `float` | 4 |
| `int64`, `i64`, `u64` (и всё остальное) | 8 |

---

## 5. Примеры

### Светофор

```
state Green {
    on timer -> Yellow
    entry { print("GREEN\n") }
}

state Yellow {
    on timer -> Red
    entry { print("YELLOW\n") }
}

state Red {
    on timer -> Green
    entry { print("RED\n") }
}
```

Ввод: `timer\n` переключает состояния.

### Счётчик

```
context {
    var total: int
}

state Count {
    var n: int = 0
    on inc -> Self { n += 1; total += 1 }
    on show -> Show
}

state Show {
    always -> Count
    entry { print("n="); print("?\n") }
}
```

### Охраняемый переход

```
state Door {
    on open [key == 1] -> Opened
    entry { print("locked\n") }
}

state Opened {
    on close -> Door
    entry { print("opened\n") }
}

context {
    var key: int
}
```

---

## 6. Сборка из исходников

Требуется [Zig](https://ziglang.org/) (master, >= 0.14).

```
cd zig
zig build
```

Или напрямую:

```
cd zig
zig build-exe src/main.zig -femit-bin=bpc.exe
```

После сборки:

```
bpc.exe run example.b+
```

---

## 7. Структура проекта

```
zig/                    — компилятор (Zig, активная разработка)
  src/
    main.zig            — точка входа, CLI, оркестрация
    runtime.zig          — Stage 1 runtime kernel (handle table, arena, FSM, migration)
    parser.zig          — лексер + парсер .b+
    ast.zig             — типы AST (состояния, переходы и т.д.)
    x64gen.zig          — генератор машинного кода x64 (+ Intrinsic binding к runtime)
    x64enc.zig          — кодировщик инструкций x64
    pe.zig             — генератор PE (.exe)
  build.zig            — сборка через zig build
src/                    — оригинальная версия на C# (не развивается)
```

---

## 8. Лицензия

MIT License

```
MIT License

Copyright (c) 2025 bylka2W

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 9. Контакты

- **GitHub**: [github.com/bylka2W](https://github.com/bylka2W)
- **Репозиторий**: [github.com/bylka2W/B-Plus](https://github.com/bylka2W/B-Plus)
- **Автор**: bylka2W

---

## Stage 1 — Runtime kernel

`src/runtime.zig` — детерминированная машина памяти, формальная модель переходов.

```
Handle → MetaStore → ptr → address → Tier (single source of truth)
                                ↓
moveHotter/moveColder → Tier.moveHotter/?Tier (pure FSM)
                                ↓
Transition{handle, src_tier, dst_tier} (pure decision record)
                                ↓
applyMigration → migrate (единственный execution boundary)
    └─ validateAccess (safety gate)
    └─ resolve: slot, ptr, size, arena
    └─ alloc → memcpy → ptr swap → log
```

### Компоненты

| Компонент | Описание |
|-----------|----------|
| `Tier` | Enum L1/L2/L3/DISK. FSM: `moveHotter`/`moveColder` → `?Tier` |
| `Handle` | Поколенческий идентификатор: slot + generation |
| `HandleTable` | Состояния слотов (Used/Free), free-лист O(1), инвалидация через generation |
| `MetaStore` | SoA: ptrs, sizes, generations, heats, states |
| `Arena` | Bump-аллокатор (без проверок — prevalidated inputs) |
| `Transition` | Decision record: handle + src_tier + dst_tier |
| `PanicCode` | INVALID_HANDLE и INVALID_TIER — только через validate функции |
| `assertInvariant` | Приватная — только внутри validateHandle/validateAccess/validateTier |

### Intrinsic binding

`x64gen.zig` использует `inline for (comptime std.meta.tags(rt.Intrinsic))` для
исчерпывающей генерации всех runtime-функций. Любое добавление варианта `Intrinsic`
вызывает compile error до тех пор, пока `emitOneIntrinsic` не обработает его.

---

**Ограничения:**
- Только Windows x64.
- Минимальные сообщения об ошибках.
- Чтение ввода через stdin (одна строка = одно событие).
- Нет поддержки LLVM, WASM, GPU, LSP, DISK tier.

---

---

# B+ v4.2.0 — deterministic transition machine (x64)

**B+** compiles `.b+` files directly to x64 machine code and packages them into Windows PE executables (.exe).
No assemblers, linkers, or LLVM — the entire code generator is written from scratch in Zig.

Built-in runtime layer (Stage 1) — a deterministic state machine with a formal transition model, three-level memory hierarchy (L1/L2/L3), generational handles, and a single migration execution point (`applyMigration`).

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Compiler Commands](#2-compiler-commands)
3. [Language Syntax](#3-language-syntax)
   - [States](#31-states)
   - [Transitions (on)](#32-transitions-on)
   - [Unconditional Transitions (always)](#33-unconditional-transitions-always)
   - [Entry and Exit (entry / exit)](#34-entry-and-exit-entry--exit)
   - [Variables](#35-variables)
   - [Assignments](#36-assignments)
   - [Print (print)](#37-print-print)
   - [Guard Conditions (guard)](#38-guard-conditions-guard)
   - [global entry](#39-global-entry)
   - [Context (context)](#310-context-context)
   - [Annotations](#311-annotations)
   - [Enums (enum)](#312-enums-enum)
   - [Parallel Blocks (parallel)](#313-parallel-blocks-parallel)
   - [Kernel Functions](#314-kernel-functions)
   - [External Functions (extern)](#315-external-functions-extern)
   - [Comments](#316-comments)
4. [Data Types](#4-data-types)
5. [Examples](#5-examples)
6. [Building from Source](#6-building-from-source)
7. [Project Structure](#7-project-structure)
8. [License](#8-license)
9. [Contact](#9-contact)

---

## 1. Quick Start

```
bpc.exe build hello.b+
.\hello.exe
```

The first command compiles `hello.b+` into `hello.exe`.
The second runs it.

Or combine both:

```
bpc.exe run hello.b+
```

---

## 2. Compiler Commands

### Syntax

```
bpc build <input.b+>              — compile to <input>.exe
bpc build <input.b+> -o <out.exe> — compile with custom output name
bpc run   <input.b+>              — compile and run immediately
```

#### `bpc build <input.b+> [-o <output.exe>]`

What it does:

| Step | Description |
|------|-------------|
| 1 | Reads the entire `.b+` file into memory |
| 2 | Parses source code into an AST |
| 3 | Verifies at least one state exists |
| 4 | Generates raw x64 machine code (no assembler) |
| 5 | Inserts NOP padding for cache alignment |
| 6 | Embeds string pool (for print) |
| 7 | Generates import table (kernel32.dll) |
| 8 | Applies all jump/call fixups |
| 9 | Wraps everything into a PE (.exe) file |
| 10 | Writes the result to disk |

If `-o` is omitted, the output name = input name with `.exe` extension.

**Examples:**
```
bpc build traffic.b+              → traffic.exe
bpc build traffic.b+ -o light.exe → light.exe
bpc build source.b+               → source.exe
```

#### `bpc run <input.b+>`

What it does:

| Step | Description |
|------|-------------|
| 1 | Compiles `<input>.exe` |
| 2 | Runs the resulting `.exe` |
| 3 | Captures stdout and prints to console |
| 4 | Returns the program exit code |

**Examples:**
```
bpc run traffic.b+    — compiles and runs immediately
bpc run hello.b+      — compiles and runs immediately
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error: invalid args or file not found |
| >0 | Exit code of the compiled program (when using `run`) |

### Notes

- The input file **must** have a `.b+` extension.
- If the extension is missing, the compiler still adds `.exe` to the base name.
- The compiler does **not** use external assemblers, linkers, or LLVM — all machine code is self-generated.
- The output is a fully valid Windows PE x64 executable.

---

## 3. Language Syntax

### 3.1 States

```
state <Name> {
    ...
}
```

A state is the basic building block. It can contain variables, transitions, and entry/exit blocks.

```
state Red {
    on timer -> Green
    entry { print("RED\n") }
}
```

### 3.2 Transitions (on)

```
on <event> -> <TargetState>
```

When an event (a string from stdin) arrives, the machine transitions to the specified state.

```
state Green {
    on timer -> Yellow
    on pedestrian -> Red
}
```

### 3.3 Unconditional Transitions (always)

```
always -> <TargetState>
```

The transition happens immediately upon entering the state, without waiting for an event.

```
state Init {
    always -> Menu
}
```

### 3.4 Entry and Exit (entry / exit)

```
state Door {
    entry { print("entered\n") }
    exit  { print("exited\n") }
    on open -> Opened
}
```

- `entry { ... }` — executed when entering the state.
- `exit { ... }` — executed before leaving the state (before transitioning to another state).

### 3.5 Variables

```
var <name>: <type> [= <value>]
```

Declared inside a state. Types: int8, int16, int32, int64, u8, u16, u32, u64, byte, bool, short, int, float, etc.

```
state Counter {
    var count: int = 0
    on tick -> Self {
        count += 1
    }
}
```

Multiple variables can be declared separated by commas:

```
var x: int, y: int, name: int
```

### 3.6 Assignments

Inside `entry { }`, `exit { }` or a transition body:

```
var x: int

on event -> Next {
    x = 42
    x += 1
    x -= 5
}
```

Supported operators: `=`, `+=`, `-=`.
The right side can use numbers and variable names.

### 3.7 Print (print)

```
print("string")
```

Prints a string to stdout. Supports escape sequences `\n`, `\r`, `\t`.

```
state Hello {
    entry { print("Hello, world!\n") }
}
```

### 3.8 Guard Conditions (guard)

```
on <event> [<condition>] -> <TargetState>
```

The transition only occurs if the condition is true. Supported operators:
`==`, `!=`, `>`, `<`, `>=`, `<=`

```
state Crosswalk {
    var cars_waiting: bool
    on timer [cars_waiting == 0] -> Walk
    on timer [cars_waiting > 0]  -> Wait
}
```

### 3.9 global entry

```
entry <Name> {
    ...
}
```

A global entry point — executed once at program startup. Can be used for initialization.

```
entry main {
    print("Starting...\n")
}
```

### 3.10 Context (context)

```
context {
    var <name>: <type>
    ...
}
```

Context variables are global across the entire program, visible in all states.

```
context {
    var global_count: int
}
```

### 3.11 Annotations

Annotations are placed before a state or transition.

| Annotation | Description |
|-----------|-------------|
| `@hot` | Hot code — placed in L1 cache |
| `@cold` | Cold code — not cached |
| `@hot(0.9)` | Explicit hotness weight |
| `@cache(L1)` | State data in L1 |
| `@cache(L2)` | State data in L2 |
| `@cache(L3)` | State data in L3 |
| `@fast_path` | Fast execution path |
| `@always_inline` | Always inline |
| `@no_inline` | Do not inline |
| `@owned` / `@borrowed` | Memory ownership |

```
@hot
@cache(L1)
state FastPath {
    ...
}

@cold
state ErrorHandler {
    ...
}

on critical @hot(0.95) -> Shutdown
```

### 3.12 Enums (enum)

```
enum <Name> {
    Member1,
    Member2,
    ...
}
```

A global enum declaration.

```
enum Color {
    Red,
    Yellow,
    Green
}
```

### 3.13 Parallel Blocks (parallel)

```
parallel <Name> {
    state A { ... }
    state B { ... }
}
```

Groups states into a parallel block (states don't affect each other).

### 3.14 Kernel Functions

```
kernel <name>(<param>: <type>, ...) -> <type>
```

Declares a kernel function (for GPU/metal code generation).

```
kernel matrixMul(a: int, b: int) -> int
```

### 3.15 External Functions (extern)

```
extern "dllname.dll" fn <name>(<param>: <type>, ...) -> <type>
```

Declares an external function from a DLL.

```
extern "user32.dll" fn MessageBoxA(hWnd: int, lpText: int, lpCaption: int, uType: int) -> int
```

### 3.16 Comments

```
// single-line comment
-- also a comment
```

---

## 4. Data Types

| Type | Size (bytes) |
|------|-------------|
| `int8`, `i8`, `u8`, `byte`, `bool` | 1 |
| `int16`, `i16`, `u16`, `short`, `half` | 2 |
| `int32`, `i32`, `u32`, `int`, `uint`, `float` | 4 |
| `int64`, `i64`, `u64` (and anything else) | 8 |

---

## 5. Examples

### Traffic Light

```
state Green {
    on timer -> Yellow
    entry { print("GREEN\n") }
}

state Yellow {
    on timer -> Red
    entry { print("YELLOW\n") }
}

state Red {
    on timer -> Green
    entry { print("RED\n") }
}
```

Input: `timer\n` cycles through states.

### Counter

```
context {
    var total: int
}

state Count {
    var n: int = 0
    on inc -> Self { n += 1; total += 1 }
    on show -> Show
}

state Show {
    always -> Count
    entry { print("n="); print("?\n") }
}
```

### Guarded Transition

```
state Door {
    on open [key == 1] -> Opened
    entry { print("locked\n") }
}

state Opened {
    on close -> Door
    entry { print("opened\n") }
}

context {
    var key: int
}
```

---

## 6. Building from Source

Requires [Zig](https://ziglang.org/) (master, >= 0.14).

```
cd zig
zig build
```

Or directly:

```
cd zig
zig build-exe src/main.zig -femit-bin=bpc.exe
```

After building:

```
bpc.exe run example.b+
```

---

## 7. Project Structure

```
zig/                    — compiler (Zig, active development)
  src/
    main.zig            — entry point, CLI, orchestration
    runtime.zig          — Stage 1 runtime kernel (handle table, arena, FSM, migration)
    parser.zig          — lexer + parser for .b+
    ast.zig             — AST types (states, transitions, etc.)
    x64gen.zig          — x64 machine code generator (+ Intrinsic binding to runtime)
    x64enc.zig          — x64 instruction encoder
    pe.zig             — PE (.exe) generator
  build.zig            — build script (zig build)
src/                    — original C# version (no longer developed)
```

---

## 8. License

MIT License

```
MIT License

Copyright (c) 2025 bylka2W

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 9. Contact

- **GitHub**: [github.com/bylka2W](https://github.com/bylka2W)
- **Repository**: [github.com/bylka2W/B-Plus](https://github.com/bylka2W/B-Plus)
- **Author**: bylka2W

---

## Stage 1 — Runtime kernel

`src/runtime.zig` — deterministic memory machine with a formal transition model.

```
Handle → MetaStore → ptr → address → Tier (single source of truth)
                                ↓
moveHotter/moveColder → Tier.moveHotter/?Tier (pure FSM)
                                ↓
Transition{handle, src_tier, dst_tier} (pure decision record)
                                ↓
applyMigration → migrate (sole execution boundary)
    └─ validateAccess (safety gate)
    └─ resolve: slot, ptr, size, arena
    └─ alloc → memcpy → ptr swap → log
```

### Components

| Component | Description |
|-----------|-------------|
| `Tier` | Enum L1/L2/L3/DISK. FSM: `moveHotter`/`moveColder` → `?Tier` |
| `Handle` | Generational slot identifier: slot + generation |
| `HandleTable` | Slot states (Used/Free), O(1) free-list, invalidation via generation |
| `MetaStore` | SoA: ptrs, sizes, generations, heats, states |
| `Arena` | Bump allocator (no bounds checks — prevalidated inputs) |
| `Transition` | Decision record: handle + src_tier + dst_tier |
| `PanicCode` | INVALID_HANDLE and INVALID_TIER — only through validate functions |
| `assertInvariant` | Private — only inside validateHandle/validateAccess/validateTier |

### Intrinsic binding

`x64gen.zig` uses `inline for (comptime std.meta.tags(rt.Intrinsic))` for
exhaustive generation of all runtime functions. Adding an `Intrinsic` variant
causes a compile error until `emitOneIntrinsic` handles it.

---

**Limitations:**
- Windows x64 only.
- Minimal error messages.
- Reads input from stdin (one line = one event).
- No LLVM, WASM, GPU, LSP, DISK tier support.




✅ Stage 1A-J — Deterministic Runtime Kernel
   ├─ L1/L2/L3 Arena (alloc + reset)
   ├─ Handle Table (generation-based)
   ├─ Tier FSM (moveHotter/moveColder)
   ├─ Transition Model (pure decision → applyMigration)
   ├─ Panic Runtime (2 кода)
   ├─ 3 validate функции
   ├─ Intrinsic ABI (16 интринсиков)
   └─ x64gen интеграция (exhaustive switch)

🔜 Stage 2 — Heat + Migration Engine
   ├─ Heat system (increment + decay)
   ├─ Chunk migration (64KB blocks)
   ├─ Migration budget
   ├─ Hysteresis (promote > 100, demote < 30)
   ├─ Epoch system
   ├─ Replay logger
   └─ handle_alloc/release/access (оживают!)

🔜 Stage 3 — Compression + Disk + Async
   ├─ L3 Compressed Pool (Zstd)
   ├─ mmap (Disk tier)
   ├─ Async migration
   ├─ Prefetch
   └─ Background worker threads
