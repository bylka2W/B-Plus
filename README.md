# B+ — компилятор конечных автоматов (x64)

**B+** транслирует `.b+` файлы напрямую в машинный код x64 и упаковывает в Windows PE (.exe).  
Никаких ассемблеров, линкеров, LLVM — весь кодогенератор написан с нуля на Zig.

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
8. [Лицензия](#8-лицензия--license)
9. [Контакты](#9-контакты--contact)

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

## 2. Команды компилятора / Compiler commands

### Синтаксис / Syntax

**Русский:**
```
bpc build <входной.b+>     — скомпилировать в <входной>.exe
bpc build <входной.b+> -o <выход.exe>  — скомпилировать с указанием имени
bpc run   <входной.b+>     — скомпилировать и сразу запустить
```

**English:**
```
bpc build <input.b+>              — compile to <input>.exe
bpc build <input.b+> -o <out.exe> — compile with custom output name
bpc run   <input.b+>              — compile and run immediately
```

---

### Подробное описание / Detailed description

#### `bpc build <input.b+> [-o <output.exe>]`

Что делает / What it does:

| Шаг | Русский | English |
|-----|---------|---------|
| 1 | Читает файл `.b+` целиком в память | Reads the entire `.b+` file into memory |
| 2 | Разбирает (парсит) исходный код в AST | Parses source code into an AST |
| 3 | Проверяет, что есть хотя бы одно состояние | Verifies at least one state exists |
| 4 | Генерирует машинный код x64 напрямую | Generates raw x64 machine code (no assembler) |
| 5 | Расставляет NOP-выравнивание для кеша | Inserts NOP padding for cache alignment |
| 6 | Встраивает пул строк (для print) | Embeds string pool (for print) |
| 7 | Генерирует таблицу импорта (kernel32.dll) | Generates import table (kernel32.dll) |
| 8 | Применяет все fixup'ы (адреса переходов) | Applies all jump/call fixups |
| 9 | Упаковывает всё в формат PE (.exe) | Wraps everything into a PE (.exe) file |
| 10 | Записывает результат на диск | Writes the result to disk |

Если `-o` не указан, имя выходного файла = имя входного с расширением `.exe`.  
If `-o` is omitted, the output name = input name with `.exe` extension.

**Примеры / Examples:**
```
bpc build traffic.b+              → traffic.exe
bpc build traffic.b+ -o light.exe → light.exe
bpc build source.b+               → source.exe
```

#### `bpc run <input.b+>`

Что делает / What it does:

| Шаг | Русский | English |
|-----|---------|---------|
| 1 | Компилирует `<input>.exe` | Compiles `<input>.exe` |
| 2 | Запускает полученный `.exe` | Runs the resulting `.exe` |
| 3 | Перехватывает stdout и печатает в консоль | Captures stdout and prints to console |
| 4 | Возвращает код завершения программы | Returns the program exit code |

**Примеры / Examples:**
```
bpc run traffic.b+    — компилирует launch.exe и сразу запускает
bpc run hello.b+      — компилирует hello.exe и сразу запускает
```

### Коды возврата / Exit codes

| Код | Русский | English |
|-----|---------|---------|
| 0 | Успех | Success |
| 1 | Ошибка: неверные аргументы или файл не найден | Error: invalid args or file not found |
| >0 | Код завершения скомпилированной программы | Exit code of the compiled program (when using `run`) |

### Примечания / Notes

- Входной файл **обязан** иметь расширение `.b+`.
- Если расширения нет, компилятор всё равно добавит `.exe` к базовому имени.
- Компилятор **не использует** внешние ассемблеры, линкеры или LLVM — весь машинный код генерируется самостоятельно.
- Выходной файл — полноценный Windows PE x64 исполняемый файл.
- The input file **must** have a `.b+` extension.
- The compiler does **not** use external assemblers, linkers, or LLVM — all machine code is self-generated.
- The output is a fully valid Windows PE x64 executable.

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

Поддерживаются операторы `=`, `+=`, `-=`.  
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

## 7. Структура проекта / Project structure

**Русский:**
```
zig/                    — компилятор (Zig, активная разработка)
  src/
    main.zig            — точка входа, CLI, оркестрация
    parser.zig          — лексер + парсер .b+
    ast.zig             — типы AST (состояния, переходы и т.д.)
    x64gen.zig          — генератор машинного кода x64
    x64enc.zig          — кодировщик инструкций x64
    pe.zig             — генератор PE (.exe)
  build.zig            — сборка через zig build
src/                    — оригинальная версия на C# (не развивается)
```

**English:**
```
zig/                    — compiler (Zig, active development)
  src/
    main.zig            — entry point, CLI, orchestration
    parser.zig          — lexer + parser for .b+
    ast.zig             — AST types (states, transitions, etc.)
    x64gen.zig          — x64 machine code generator
    x64enc.zig          — x64 instruction encoder
    pe.zig             — PE (.exe) generator
  build.zig            — build script (zig build)
src/                    — original C# version (no longer developed)
```

---

**Ограничения / Limitations:**
- Только Windows x64 / Windows x64 only.
- Минимальные сообщения об ошибках / Minimal error messages.
- Чтение ввода через stdin (одна строка = одно событие) / Reads input from stdin (one line = one event).
- Нет поддержки LLVM, WASM, GPU, LSP / No LLVM, WASM, GPU, LSP support.

---

## 8. Лицензия / License

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

## 9. Контакты / Contact

- **GitHub**: [github.com/bylka2W](https://github.com/bylka2W)
- **Репозиторий**: [github.com/bylka2W/B-Plus](https://github.com/bylka2W/B-Plus)
- **Автор**: bylka2W
