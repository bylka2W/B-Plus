# B+ v4.5.6 — Compiled `.bp` Language (MIR + COFF pipeline)

> [English version ↓](#b-v456--compiled-bp-language-mir--coff-pipeline)


**v4.5.6 (нормальные ошибки + фикс line tracking):**
- **Исправлен `body_line_indices`**: пустые строки и комментарии больше не отфильтровываются при загрузке, поэтому `body_line_indices` правильно указывает на `ctx.source_lines`. Ошибки показывают правильную строку исходника.
- **Column tracking**: `ctx.err_col` добавлен в `CompilerContext`, `reportErr` показывает каретку `^`.
- Все 8 `.bp` тестов проходят (включая `test_error.bp`, `test_implicit2.bp`).

**v4.5.5 (CompilerContext refactor + structs complete):**
- **Structs fully implemented**: `StructDef`/`Field` types, two-pass parser (register names → resolve types/offsets/sizes), field offset layout, `p.x` read/write in expressions and assignments, `&p.x` address-of-field
- **CompilerContext refactor**: global `var struct_table: StructTable = undefined;` eliminated — replaced with `CompilerContext` struct containing `allocator: std.mem.Allocator` and `structs: StructTable`
- **`*CompilerContext` idiom**: all compile/parse functions take `*CompilerContext` instead of separate `allocator` parameter; `Type.fromString`/`Type.size` take `*const StructTable` for struct table access
- Все 8 `.bp` тестов проходят (включая `test_struct.bp`)

**v4.5.4 (Полноценный expression parser + if/while/var + idiv):**
- **Recursive descent expression parser**: 6 уровней приоритета — `||`, `&&`, сравнения (`>= <= == != > <`), `+`/`-`, `*`/`/`. Поддерживает скобки, вложенные вызовы функций с аргументами, целые литералы, переменные.
- **`var` declarations**: `var x: i64 = 42;` — аллокация vreg, инициализация, хранение в var_map.
- **`if`/`else`**: полная поддержка `if (cond) { ... } else { ... }`, включая `} else {` на той же строке.
- **`while` loops**: header-cond-body-exit схема, корректная работа с `if` внутри тела.
- **`break`/`continue`**: `break` → `jmp(exit)`, `continue` → `jmp(header)`.
- **`IDivInst`** в MIR: `idiv` теперь полноценный MIR-инструкция со всеми проходами (dce, peephole, verify, regalloc, x64 codegen).
- **Typed function returns**: парсер разбирает `fn add(a:i64,b:i64) -> i64`, возвращаемый тип учитывается при генерации `ret` (void → `is_void=true`).
- Все `.bp` тесты проходят.

**v4.5.3 (CLI + `.bp` → `.exe` end-to-end):**
- **CLI tool `bplus.zig`**: команды `bplus build <input.bp> [-o <output.exe>]` и `bplus run <input.bp>`. Парсер .bp строит MIR напрямую (fn, extern fn, return, вызовы, целые литералы, `+` выражения, параметры-переменные). Линковка через `zig build-exe` с `bplusrt.obj` и `-lkernel32`.
- **End-to-end `.bp` → `.exe`**: `hello.bp` с `extern fn print_i64(x: i64); fn main() { print_i64(42); }` → stdout `42`, exit code **0**. Утечки устранены (arena allocator). Автоматический `ret 0` при отсутствии явного `return`.
- **Прямой MIR builder**: MIR строится из распарсенных строк `.bp` без промежуточного BIR — vreg аллокация, param→vreg prologue, expression compiler.

**v4.5.2 (BIR→MIR→x64→COFF→.exe pipeline):**
- **COFF object writer** (`coff.zig`): полноценный COFF-формат — IMAGE_FILE_HEADER, .text section, IMAGE_REL_AMD64_REL32 relocations, symbol table (IMAGE_SYM_CLASS_EXTERNAL), string table.
- **Runtime library** (`bplusrt.zig`): `print_i64` через kernel32!GetStdHandle + WriteFile, компилируется в `bplusrt.obj`.
- **Extern calls**: нерезолвленные имена в COFF становятся undefined external symbols, резолвятся линкером.

**v4.5.1 (CPU backend stabilisation):**
- **100 000 / 100 000 MIR fuzz tests passed** — нулевой miscompile на случайных программах.
- **CMP_R64_MEM**, **ADD_R64_MEM**, **SUB_R64_MEM** — новые opcode в `x64enc.zig`.
- **`regalloc.spilledMemOp()`** — хелпер для чтения второго операнда из памяти без перезаписи scratch.

**v4.5.0 (Linear Scan Register Allocator):**
- **Linear Scan Register Allocator** (`regalloc.zig`): live intervals, linear scan с expire/spill, 9 GP-регистров, r11 зарезервирован под spill scratch.
- `mir_x64.zig` полностью переписан: emit-функции для каждой MIR-инструкции, единый `ra: *const RegAllocResult`.

**v4.4.0:**
- Удалён `emitMfunction`. Все CPU-тесты через единый linker `emitModule`.
- `mir_verify.zig` — верификатор MIR перед эмитом.
- `x64enc.disassemble` — дизассемблер (30+ инструкций).

**v4.3.2:**
- Все примеры в README переведены на русский.
- GPU IR: BackendApi, ShaderKey, PipelineKey, CompileOptions/Result.
- DXIL backend (черновик): GPU IR → HLSL → DXC subprocess → DXBC.

**v4.3.1:**
- Исправлено выравнивание стека в прологе entry point (x64gen.zig).
- Добавлены русские псевдонимы ключевых слов.

**B+** транслирует `.b+` / `.bp` файлы напрямую в машинный код x64 и упаковывает в Windows PE (.exe/.dll).
Никаких ассемблеров, линкеров, LLVM — весь кодогенератор написан с нуля на Zig.

---

## Содержание

1. [Быстрый старт](#1-быстрый-старт)
2. [Команды компилятора](#2-команды-компилятора)
3. [Синтаксис языка (.b+)](#3-синтаксис-языка-b)
   - [3.1 Состояния](#31-состояния)
   - [3.2 Переходы (on)](#32-переходы-on)
   - [3.3 Безусловные переходы (always)](#33-безусловные-переходы-always)
   - [3.4 Вход и выход (entry / exit)](#34-вход-и-выход-entry--exit)
   - [3.5 Переменные](#35-переменные)
   - [3.6 Присваивания](#36-присваивания)
   - [3.7 Печать (print)](#37-печать-print)
   - [3.8 Сторожевые условия (guard)](#38-сторожевые-условия-guard)
   - [3.9 Экспортируемый entry (export entry)](#39-экспортируемый-entry-export-entry)
   - [3.10 global entry](#310-global-entry)
   - [3.11 Контекст (context)](#311-контекст-context)
   - [3.12 Аннотации](#312-аннотации)
   - [3.13 Перечисления (enum)](#313-перечисления-enum)
   - [3.14 Параллельные блоки (parallel)](#314-параллельные-блоки-parallel)
   - [3.15 Kernel-функции (GPU)](#315-kernel-функции-gpu)
   - [3.16 Внешние функции (extern)](#316-внешние-функции-extern)
   - [3.17 Комментарии](#317-комментарии)
   - [3.18 Русские ключевые слова](#318-русские-ключевые-слова)
4. [Синтаксис .bp (новый CPU backend)](#4-синтаксис-bp-новый-cpu-backend)
   - [4.1 Типы](#41-типы)
   - [4.2 Функции](#42-функции)
   - [4.3 Внешние функции](#43-внешние-функции)
   - [4.4 Переменные](#44-переменные)
   - [4.5 Структуры](#45-структуры)
   - [4.6 Указатели](#46-указатели)
   - [4.7 If/else](#47-ifelse)
   - [4.8 While](#48-while)
   - [4.9 For](#49-for)
   - [4.10 Составные присваивания](#410-составные-присваивания)
   - [4.11 Операторы](#411-операторы)
   - [4.12 Комментарии](#412-комментарии)
   - [4.13 Сообщения об ошибках](#413-сообщения-об-ошибках)
   - [4.14 CLI](#414-cli)
5. [Типы данных](#5-типы-данных)
6. [Примеры](#6-примеры)
7. [Сборка из исходников](#7-сборка-из-исходников)
8. [Структура проекта](#8-структура-проекта)
9. [Лицензия](#9-лицензия)
10. [Контакты](#10-контакты)

---

## 1. Быстрый старт

```bash
bpc.exe build hello.b+
.\hello.exe
```

Первая команда компилирует `hello.b+` в `hello.exe`.
Вторая — запускает.

Можно совместить:

```bash
bpc.exe run hello.b+
```

---

## 2. Команды компилятора

### Синтаксис

```text
bpc build <входной.b+>              — скомпилировать в <входной>.exe
bpc build <входной.b+> -o <выход.exe> — скомпилировать с указанием имени
bpc dll   <входной.b+>              — скомпилировать в DLL
bpc run   <входной.b+>              — скомпилировать и сразу запустить
bpc hlsl  <входной.b+>              — сгенерировать HLSL шейдер
```

#### `bpc dll <input.b+> [-o <output.dll>] [-exports <name1,name2,...>]`

Компилирует `.b+` файл в DLL с таблицей экспорта. Все `export entry` или
перечисленные в `-exports` становятся экспортируемыми функциями.

| Шаг | Описание |
|-----|----------|
| 1 | Читает файл `.b+` целиком в память |
| 2 | Разбирает (парсит) исходный код в AST |
| 3 | Генерирует машинный код x64 с DllMain (возвращает TRUE) |
| 4 | Создаёт таблицу импорта (kernel32.dll + runtime) |
| 5 | Строит таблицу экспорта (Export Directory Table, EAT, ENPT, EOT) с сортировкой ENPT по алфавиту (требование Windows для `GetProcAddress`) |
| 6 | Упаковывает всё в формат PE (DLL), секция `.text` — RWX (`0xE0000020`) |
| 7 | Записывает результат на диск |

**Примеры:**
```bash
bpc dll test.b+ -o test.dll -exports Init,Update
bpc dll module.b+
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
```bash
bpc build traffic.b+              → traffic.exe
bpc build traffic.b+ -o light.exe → light.exe
bpc build source.b+               → source.exe
```

#### `bpc gpu <input.b+> [-o <output.hlsl>]` / `bpc hlsl <input.b+> [-o <output.hlsl>]`

Генерирует HLSL-код из B+ файла с новым блочным `kernel { ... }` синтаксисом
или старым (legacy `@bind`/`@cbuffer`). `bpc hlsl` автодетектит синтаксис.

| Шаг | Описание (новый pipeline) |
|-----|--------------------------|
| 1 | Читает файл `.b+` целиком в память |
| 2 | Разбирает (парсит) в GPU AST (`gpu_ast.zig`) |
| 3 | Семантический анализ (`gpu_sema.zig`): дубликаты регистров, лимиты, numthreads |
| 4 | Понижение до GPU IR (`gpu_lower.zig`): GPU AST → SSA IR |
| 5 | Генерация HLSL из IR (`gpu_hlsl.zig`) |
| 6 | Записывает результат на диск |

**Аннотации:**

```rust
// Текстуры
g_InputColor: @bind(t, 0, float4)     // Texture2D<float4> : register(t0)
g_OutputColor: @bind(u, 0, float4)    // RWTexture2D<float4> : register(u0)
g_OutputUAV: @bind(u, 1, uint, globallycoherent)  // globallycoherent RWTexture2D<uint>
// Сэмплер
linearClamp: @bind(s, 0)              // SamplerState : register(s0)

// Константный буфер
inputSize: @cbuffer(FSR2Constants, 0, float2)   // cbuffer FSR2Constants : register(b0) { float2 inputSize; ... }

// Shared memory
sharedMem: @groupshared(sharedMem, 256)           // groupshared float sharedMem[256];
```

В теле `entry` цикл `for(x, y, w, h)` транслируется в `uint x = tid.x; if (x >= w) return;`.
HLSL-интринсики (WaveActiveSum, InterlockedAdd, mad, lerp и др.) проходят насквозь.

**Пример:**
```bash
bpc hlsl fsr2_easu.b+ -o fsr2_easu.hlsl
dxc -T cs_6_6 -E main -Fo fsr2_easu.cso fsr2_easu.hlsl
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
```bash
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

```rust
state <Имя> {
    ...
}
```

Состояние — базовый строительный блок. Внутри могут быть переменные, переходы, entry/exit-блоки.

```rust
state Red {
    on timer -> Green
    entry { print("RED\n") }
}
```

### 3.2 Переходы (on)

```rust
on <событие> -> <ЦелевоеСостояние>
```

Когда приходит событие (строка из stdin), автомат переходит в указанное состояние.

```rust
state Green {
    on timer -> Yellow
    on pedestrian -> Red
}
```

### 3.3 Безусловные переходы (always)

```rust
always -> <ЦелевоеСостояние>
```

Переход происходит сразу при входе в состояние, без ожидания события.

```rust
state Init {
    always -> Menu
}
```

### 3.4 Вход и выход (entry / exit)

```rust
state Door {
    entry { print("entered\n") }
    exit  { print("exited\n") }
    on open -> Opened
}
```

- `entry { ... }` — выполняется при входе в состояние.
- `exit { ... }` — выполняется перед выходом из состояния (перед переходом в другое).

### 3.5 Переменные

```rust
var <имя>: <тип> [= <значение>]
```

Объявляются внутри состояния. Типы: int8, int16, int32, int64, u8, u16, u32, u64, byte, bool, short, int, float и т.д.

```rust
state Counter {
    var count: int = 0
    on tick -> Self {
        count += 1
    }
}
```

Можно объявлять несколько переменных через запятую:

```rust
var x: int, y: int, name: int
```

Допускается сокращённая запись — идентификатор без `var` и типа:

```rust
state S {
    x     // эквивалентно var x: i64
}
```

Такие голые идентификаторы автоматически регистрируются как переменные `i64`.

### 3.6 Присваивания

Внутри `entry { }`, `exit { }` или тела перехода:

```rust
var x: int

on event -> Next {
    x = 42
    x += 1
    x -= 5
}
```

Поддерживаются операторы `=`, `+=`, `-=".
В правой части можно использовать числа и имена переменных.

**Запись через указатель** — если левая часть это `*<имя>`, то значение записывается в память
по адресу, хранящемуся в переменной:

```rust
*ctl = new_value    // MOV [RCX], RAX — запись по указателю
result = *ctl       // чтение: RAX = [RCX]
```

Используется для работы с TLS-сохранёнными указателями на persistent-кучу.

### 3.7 Печать (print)

```rust
print("строка")
```

Печатает строку в stdout. Поддерживаются escape-последовательности `\n`, `\r`, `\t`.

```rust
state Hello {
    entry { print("Hello, world!\n") }
}
```

### 3.8 Сторожевые условия (guard)

```rust
on <событие> [<условие>] -> <ЦелевоеСостояние>
```

Переход происходит только если условие истинно. Поддерживаются операторы:
`==`, `!=`, `>`, `<`, `>=`, `<=`

```rust
state Crosswalk {
    var cars_waiting: bool
    on timer [cars_waiting == 0] -> Walk
    on timer [cars_waiting > 0]  -> Wait
}
```

### 3.9 Экспортируемый entry (export entry)

```rust
export entry <Имя> {
    ...
}
```

Экспортируемая точка входа — компилируется как функция, видимая извне DLL.
Используется при сборке DLL (`bpc dll`) вместе с флагом `-exports`.
Тело может быть пустым — достаточно объявления для экспорта.

Все `export entry` в одном файле используют контекст **первого** `state` блока:
переменные состояния доступны из любого экспорта.

ENPT (Export Name Pointer Table) автоматически сортируется по алфавиту —
требование Windows для бинарного поиска в `GetProcAddress`.

```rust
export entry TSS_Init {
    // будет экспортирована из DLL как TSS_Init
}
```

### 3.10 global entry

```rust
entry <Имя> {
    ...
}
```

Глобальная точка входа — выполняется один раз при старте программы. Можно использовать для инициализации.

```rust
entry main {
    print("Starting...\n")
}
```

### 3.11 Контекст (context)

```rust
context {
    var <имя>: <тип>
    ...
}
```

Контекстные переменные — глобальные для всей программы, видимы во всех состояниях.

```rust
context {
    var global_count: int
}
```

### 3.12 Аннотации

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

```rust
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

### 3.13 Перечисления (enum)

```rust
enum <Имя> {
    Член1,
    Член2,
    ...
}
```

Глобальное объявление перечисления.

```rust
enum Color {
    Red,
    Yellow,
    Green
}
```

### 3.14 Параллельные блоки (parallel)

```rust
parallel <Имя> {
    state A { ... }
    state B { ... }
}
```

Группировка состояний в параллельный блок (состояния не влияют друг на друга).

### 3.15 Kernel-функции (GPU)

Два синтаксиса:

1. **Старый** (legacy, аннотации на строках):
```rust
kernel <имя>(<параметр>: <тип>, ...) -> <тип>
```

2. **Новый** (блочный, с `globals`, `@binding`, `@cbuffer`, `@numthreads`):
```rust
kernel <Имя> {
    имя_ресурса : Тип @binding(t#)
    имя_члена  : Тип @cbuffer(#)
    globals {
        float4 HelperFunc(float param) { ... }
    }
    @numthreads(x,y,z)
    entry main(x:u32,y:u32) {
        ... тело шейдера ...
    }
}
```

**Ключевые элементы:**

| Элемент | Описание |
|---------|----------|
| `@binding(t#)` / `@binding(u#)` / `@binding(s#)` | Регистр привязки: `t` = SRV, `u` = UAV, `s` = Sampler |
| `@cbuffer(#)` | Член константного буфера (все в один `cbuffer TSS_Constants : register(b#)`) |
| `globals { ... }` | Функции и константы на глобальном уровне HLSL |
| `@numthreads(x,y,z)` | Размер группы (Thread Group Size) |
| `entry main(x:u32,y:u32)` | Точка входа: `x`, `y` = `SV_DispatchThreadID` |

**Типы ресурсов:** `Texture2D<T>`, `RWTexture2D<T>`, `SamplerState`.  
Типы `T`: `float`, `float2`, `float3`, `float4`, `uint`, `int`, `half`.

**Пример RCAS:**
```rust
kernel RCAS {
    g_InputColor  : Texture2D<float4> @binding(t0)
    g_OutputColor : RWTexture2D<float4> @binding(u0)
    linearClamp   : SamplerState @binding(s0)
    sharpness     : float @cbuffer(0)
    globals {
        float4 RCASPass(float4 col[4][4], float sharp) { ... }
    }
    @numthreads(8,8,1)
    entry main(x:u32,y:u32) {
        uint outW, outH;
        g_OutputColor.GetDimensions(outW, outH);
        int2 ipos = int2(x, y);
        if (ipos.x >= int(outW) || ipos.y >= int(outH)) return;
        ...
        g_OutputColor[ipos] = RCASPass(col, sharpness);
    }
}
```

### 3.16 Внешние функции (extern)

```rust
extern "dllname.dll" fn <имя>(<парам>: <тип>, ...) -> <тип>
```

Объявление внешней функции из DLL.

```rust
extern "user32.dll" fn MessageBoxA(hWnd: int, lpText: int, lpCaption: int, uType: int) -> int
```

### 3.17 Комментарии

```rust
// однострочный комментарий
-- тоже комментарий
```

---

### 3.18 Русские ключевые слова

Все ключевые слова можно писать как по-английски, так и по-русски. Можно мешать в одном файле.

| Русский | English |
|---------|---------|
| `состояние` | `state` |
| `экспорт` | `export` |
| `вход` | `entry` |
| `ядро` | `kernel` |
| `структура` | `struct` |
| `перечисление` | `enum` |
| `параллельно` | `parallel` |
| `на` | `on` |
| `всегда` | `always` |
| `пер` | `var` |
| `контекст` | `context` |
| `внешний` | `extern` |
| `фн` | `fn` |
| `конвейер` | `pipeline` |
| `импорт` | `import` |
| `использовать` | `use` |
| `если` | `if` |
| `иначе` | `else` |
| `вернуть` | `return` |
| `запуск` | `run` |
| `печать` | `print` |
| `освободить` | `free` |
| `тело` | `body` |
| `шаг` | `step` |
| `опубликовать` | `publish` |
| `войти` | `enter` |
| `выйти` | `exit` |
| `истина` | `true` |
| `ложь` | `false` |
| `владение` | `owned` |
| `заимствовано` | `borrowed` |

---

## 4. Синтаксис `.bp` (новый CPU backend)

Новый `.bp` синтаксис работает через прямой MIR pipeline (без BIR, без state-машины).
Поддерживает функции, переменные, структуры, указатели, `if`/`while`/`for`, составные присваивания.

### 4.1 Типы

| Тип | Размер (байт) |
|-----|--------------|
| `i8` / `u8` / `bool` | 1 |
| `i16` / `u16` | 2 |
| `i32` / `u32` | 4 |
| `i64` / `u64` | 8 |
| `int` | алиас `i64` |
| `uint` | алиас `u64` |
| `*T` | 8 (указатель) |
| `void` | 0 |

### 4.2 Функции

```rust
fn add(a: i64, b: i64) -> i64 {
    a + b
}

fn main() {
    print_i64(add(3, 4));
}
```

Последнее выражение — неявный `return`. Можно явно:

```rust
fn max(a: i64, b: i64) -> i64 {
    if a > b {
        return a;
    }
    return b;
}
```

### 4.3 Внешние функции

```rust
extern fn print_i64(x: i64);
extern fn read_i64() i64;
extern fn bplus_malloc(size: i64) i64;
extern fn bplus_free(ptr: i64);
extern fn bplus_exit(code: i64);
```

### 4.4 Переменные

```rust
var x: i64 = 42;
var y;
var z = 10;
x = 10;
```

### 4.5 Структуры

```rust
struct Point {
    x: i64,
    y: i64,
}
```

Можно в строку: `struct Point { x: i64, y: i64 }`

```rust
var p: Point;
p.x = 10;
p.y = 20;
print_i64(p.x);
```

Литералы:

```rust
var p = Point { x: 10, y: 20 };
var q = Point {
    x: 30,
    y: 40,
};
```

### 4.6 Указатели

```rust
var x: i64 = 42;
var p: *i64 = &x;
var y: i64 = *p;
*p = 10;
var addr: *i64 = &p.x;
```

### 4.7 If/else

```rust
if x > 5 {
    print_i64(1);
} else {
    print_i64(0);
}
if (x > 5) {
    print_i64(1);
}
```

### 4.8 While

```rust
while i < 3 {
    print_i64(i);
    i += 1;
}
```

`break` / `continue`:

```rust
while i < 10 {
    if i == 5 { break; }
    if i == 2 { i += 1; continue; }
    print_i64(i);
    i += 1;
}
```

### 4.9 For

```rust
for i in 0..10 {
    print_i64(i);
}
```

### 4.10 Составные присваивания

```rust
x += 1;
y -= 5;
z *= 2;
```

### 4.11 Операторы

| Оператор | Описание |
|----------|----------|
| `*` / `/` | умножение, деление |
| `+` / `-` | сложение, вычитание |
| `==` / `!=` / `>` / `<` / `>=` / `<=` | сравнения |
| `&&` | логическое И |
| `\|\|` | логическое ИЛИ |

### 4.12 Комментарии

```rust
// однострочный комментарий
```

### 4.13 Сообщения об ошибках

```
error[UnknownVariable]: test_error.bp:4:1
   4 |     print_i64(y);
       | ^
```

### 4.14 CLI

```text
bplus build <input.bp> [-o <output.exe>]
bplus run   <input.bp>
```

Pipeline: `.bp → парсер → MIR → DCE → peephole → reg alloc → x64 → COFF .obj → zig build-exe → .exe`

---

## 5. Типы данных

| Тип | Размер (байт) |
|-----|--------------|
| `int8`, `i8`, `u8`, `byte`, `bool` | 1 |
| `int16`, `i16`, `u16`, `short`, `half` | 2 |
| `int32`, `i32`, `u32`, `int`, `uint`, `float` | 4 |
| `int64`, `i64`, `u64` (и всё остальное) | 8 |

---

## 6. Примеры

Все ключевые слова можно писать как по-английски, так и по-русски (см. раздел 3.18).

### Светофор

Английский синтаксис:

```rust
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

Русский синтаксис:

```rust
состояние Зелёный {
    на таймер -> Жёлтый
    вход { печать("ЗЕЛЁНЫЙ\n") }
}

состояние Жёлтый {
    на таймер -> Красный
    вход { печать("ЖЁЛТЫЙ\n") }
}

состояние Красный {
    на таймер -> Зелёный
    вход { печать("КРАСНЫЙ\n") }
}
```

Ввод: `таймер\n` переключает состояния.

### Счётчик

Английский синтаксис:

```rust
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

Русский синтаксис:

```rust
контекст {
    пер всего: int
}

состояние Счёт {
    пер n: int = 0
    на прибавить -> Self { n += 1; всего += 1 }
    на показать -> Показ
}

состояние Показ {
    всегда -> Счёт
    вход { печать("n="); печать("?\n") }
}
```

### Охраняемый переход

Английский синтаксис:

```rust
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

Русский синтаксис:

```rust
состояние Дверь {
    на открыть [ключ == 1] -> Открыто
    вход { печать("заперто\n") }
}

состояние Открыто {
    на закрыть -> Дверь
    вход { печать("открыто\n") }
}

контекст {
    пер ключ: int
}
```

---

## 7. Сборка из исходников

Требуется [Zig](https://ziglang.org/) (master, >= 0.14).

```bash
cd zig
zig build
```

Или напрямую:

```bash
cd zig
zig build-exe src/main.zig -femit-bin=bpc.exe
```

После сборки:

```bash
bpc.exe run example.b+
```

---

## 8. Структура проекта

```text
zig/                    — компилятор (Zig, активная разработка)
  src/
    main.zig            — точка входа, CLI, оркестрация
    runtime.zig          — runtime kernel (handle table, arena, FSM, migration, Snapshot)
    runtime_test.zig     — 40 unit tests: alloc, release, tick, migration, decay, budget, memory layer
    stress_test.zig      — stress test: 100k ops with snapshot-based formal invariant verification
    cpu.zig              — CPU topology detection (Windows kernel32 extern)
    latency.zig          — LatencyProfile, CoreStats, LoadState (adaptive thresholds)
    scheduler.zig        — NUMA-aware worker-pool scheduler
    scheduler_test.zig   — 16 tests: sync/threaded/priority/steal/latency/state-machine
    bench.zig            — A/B benchmark: baseline vs smart scheduler (4 patterns) + smoke tests
    gpu_ir.zig           — GPU IR: BindingKey{reg,space,kind}, BindGroup, PipelineKey, DispatchDesc, ResourceId
    frame_graph.zig      — FrameGraph: Pass, ExecutionNode, ExecutionPlan, GPUPassDesc (unified compute DAG IR)
    frame_graph_executor.zig — compileGraph() → immutable CompiledGraph; per-frame writeFrameDescriptors+executeCompiledGraph
    compiled_graph.zig   — CompiledGraph: CompiledPass, FrameInputs, BindSlot, DescriptorArena. Pre-baked PSOs/barriers/slots
    resource_system.zig  — ResourcePool: GPU resource lifecycle, RS-driven descriptor allocation, state tracking
    root_signature_builder.zig — Per-pass root signature compiler: BindLayout → CompiledRS, cached by hash
    gpu_job.zig          — GPUJob dispatch descriptor
    gpu_scheduler.zig    — Pure GPU dispatch sink (no graph awareness)
    scheduler_config.zig — SchedulerConfig (max_sticky_ns, max_queue_len, imbalance thresholds)
    scheduler_state.zig  — GlobalSchedulerState (SystemLoad, adjustDecision)
    parser.zig          — лексер + парсер .b+
    ast.zig             — типы AST (состояния, переходы и т.д.)
     x64gen.zig          — генератор машинного кода x64 (+ Intrinsic binding к runtime).
                           **Новые возможности:**
                           - Структуры: `struct Name { field: type, ... }` — packed layout
                           - `arr[idx]` — индексация массивов через SIB (scale=3 для *8)
                           - `reinterpret_cast<T>(expr)` — удаление внешнего каста
                           - `obj->method(args)` — COM-вызовы через vtable
                           - `ptr_store(dest, value)` — запись по указателю (depth-aware)
                           - `rcp(x)`, `lerp(a,b,t)`, `med3(a,b,c)` — математические
                             интринсики в парсере выражений
                           - 16 CRT-функций через IAT (msvcrt.dll), XMM0/XMM1 для float
                           - `GetModuleHandleW/A` в IMPORT_FNS
                           - D3D12 COM-методы в COM_METHODS (ID3D12Device,
                             ID3D12GraphicsCommandList, ID3D12DescriptorHeap)
                           - `context { var x: type }` — контекстные переменные (фикс бага)
                           - `forward Name = "dll.dll"` — DLL export forwarding для proxy DLL
     x64enc.zig          — кодировщик инструкций x64
     layout.zig          — StackFrame/SlotKind: типобезопасная абстракция стекового
                           фрейма, используется x64gen.zig для раскладки оффсетов
     symbol.zig          — SymbolTable: реестр символов (code/export/data) для линковки
     pe.zig             — генератор PE (.exe/.dll) — чистый эмиттер, не знает про AST
      hlslgen.zig         — HLSL-кодогенератор (legacy). Аннотации: @bind, @cbuffer, @groupshared.
                            Типы FSR2: FfxFloat32/2/3/4, FfxInt32, FfxUInt32 → float/int/uint.
                            50+ HLSL-интринсиков (wave ops, атомики, math, битовые касты).
                            globallycoherent для RWTexture2D. @numthreads, @unroll, @branch.
      gpu_ast.zig         — GPU AST (GpuKernel, ResourceDecl, CbufferMember, EntryDecl)
      gpu_ir.zig          — GPU SSA IR (IrModule, IrFunction, IrInst с Op, TypeRef, ресурсы)
      gpu_lower.zig       — Понижение GPU AST → GPU IR
      gpu_sema.zig        — Семантический анализатор: дубликаты, лимиты, numthreads
      gpu_hlsl.zig        — HLSL кодогенератор из GPU IR (новый pipeline)

   shaders/fsr2/         — эталонные HLSL-шейдеры FSR2 (8 проходов) + порты:
     fsr2_easu.hlsl       — EASU (Edge Adaptive Spatial Upsampling)
     fsr2_easu_new.b+     — порт на новом kernel-синтаксисе
     fsr2_accumulate.hlsl — Temporal Accumulation (TAAU)
     fsr2_accumulate_new.b+ — порт
     fsr2_depthclip.hlsl  — Depth Clip (анти-гостинг)
     fsr2_depthclip_new.b+ — порт
     fsr2_lock.hlsl       — Lock Status
     fsr2_lock_new.b+     — порт
     fsr2_luminance_pyramid.hlsl — Luminance Pyramid
     fsr2_luminance_pyramid_new.b+ — порт
     fsr2_reconstruct_depth.hlsl — Depth Reconstruction
     fsr2_reconstruct_depth_new.b+ — порт
     fsr2_dilate_velocity.hlsl   — Motion Vector Dilation
     fsr2_dilate_velocity_new.b+ — порт
     fsr2_rcas.hlsl       — RCAS (Robust Contrast Adaptive Sharpening)
     fsr2_rcas_new.b+     — порт на новом kernel-синтаксисе
  shaders/cso/          — скомпилированные .cso файлы (cs_6_6)

  fsr2_proxy.b+         — DXGI proxy DLL: перехватывает CreateSwapChain/Present,
                          создаёт D3D11 device, загружает 8 CSO, управляет текстурами,
                          выполняет полный пайплайн FSR2 на каждом кадре.
                          Написана полностью на B+ (x64 codegen), ~500 строк.

   tss_easu.b+           — CPU-эталон EASU на B+ (программный апскейл)
   tss_easu_faithful.b+  — Точная реализация EASU (12 tap, градиентное направление)

   bitwriter.py          — LLVM 13 bitstream encoder для DXIL-бэкенда.
                           Строит LLVM IR биткод, совместимый с Emscripten LLVM 13 fork
                           (Microsoft.NET.Runtime.Emscripten).
                           Поддерживает: типы, функции, константы (с sign-rotation),
                           SSA value numbering, CFG (basic blocks, terminators),
                           ret/br/add/alloca/load/store.
                           Валидация: llvm-dis exit code 0.
   build.zig            — сборка через zig build
```

---

## 9. Лицензия

MIT License

```text
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

## 10. Контакты

- **GitHub**: [github.com/bylka2W](https://github.com/bylka2W)
- **Репозиторий**: [github.com/bylka2W/B-Plus](https://github.com/bylka2W/B-Plus)
- **Автор**: bylka2W

---

---

# B+ v4.5.6 — Compiled `.bp` Language (MIR + COFF pipeline)

> [Russian version ↑](#b-v456--compiled-bp-language-mir--coff-pipeline)

**v4.5.6 (proper error reporting + line tracking fix):**
- **`body_line_indices` fixed**: empty lines and comments are no longer filtered during loading, so `body_line_indices` correctly indexes into `ctx.source_lines`. Errors now show the correct source line.
- **Column tracking**: `ctx.err_col` added to `CompilerContext`, `reportErr` shows caret `^`.
- All 8 `.bp` tests pass (including `test_error.bp`, `test_implicit2.bp`).

**v4.5.5 (CompilerContext refactor + structs complete):**
- **Structs fully implemented**: `StructDef`/`Field` types, two-pass parser (register names → resolve types/offsets/sizes), field offset layout, `p.x` read/write in expressions and assignments, `&p.x` address-of-field
- **CompilerContext refactor**: global `var struct_table: StructTable = undefined;` eliminated — replaced with `CompilerContext` struct containing `allocator: std.mem.Allocator` and `structs: StructTable`
- **`*CompilerContext` idiom**: all compile/parse functions take `*CompilerContext` instead of separate `allocator` parameter; `Type.fromString`/`Type.size` take `*const StructTable` for struct table access
- All 8 `.bp` tests pass (including `test_struct.bp`)

**v4.5.4 (Full expression parser + if/while/var + idiv):**
- **Recursive descent expression parser**: 6 precedence levels — `||`, `&&`, comparisons (`>= <= == != > <`), `+`/`-`, `*`/`/`. Supports parentheses, nested function calls with arguments, integer literals, variables.
- **`var` declarations**: `var x: i64 = 42;` — vreg allocation, initialization, storage in var_map.
- **`if`/`else`**: full support for `if (cond) { ... } else { ... }`, including `} else {` on the same line.
- **`while` loops**: header-cond-body-exit scheme, correct interaction with `if` inside body.
- **`break`/`continue`**: `break` → `jmp(exit)`, `continue` → `jmp(header)`.
- **`IDivInst`** in MIR: `idiv` is now a full MIR instruction with all passes (dce, peephole, verify, regalloc, x64 codegen).
- **Typed function returns**: parser handles `fn add(a:i64,b:i64) -> i64`, return type is considered when generating `ret` (void → `is_void=true`).
- All `.bp` tests pass.

**v4.5.3 (CLI + `.bp` → `.exe` end-to-end):**
- **CLI tool `bplus.zig`**: commands `bplus build <input.bp> [-o <output.exe>]` and `bplus run <input.bp>`. .bp parser builds MIR directly (fn, extern fn, return, calls, integer literals, `+` expressions, parameter-variables). Linking via `zig build-exe` with `bplusrt.obj` and `-lkernel32`.
- **End-to-end `.bp` → `.exe`**: `hello.bp` with `extern fn print_i64(x: i64); fn main() { print_i64(42); }` → stdout `42`, exit code **0**. Leaks fixed (arena allocator). Automatic `ret 0` when no explicit `return`.
- **Direct MIR builder**: MIR is built from parsed `.bp` lines without intermediate BIR — vreg allocation, param→vreg prologue, expression compiler.

**v4.5.2 (BIR→MIR→x64→COFF→.exe pipeline):**
- **COFF object writer** (`coff.zig`): full COFF format — IMAGE_FILE_HEADER, .text section, IMAGE_REL_AMD64_REL32 relocations, symbol table (IMAGE_SYM_CLASS_EXTERNAL), string table.
- **Runtime library** (`bplusrt.zig`): `print_i64` via kernel32!GetStdHandle + WriteFile, compiled to `bplusrt.obj`.
- **Extern calls**: unresolved names in COFF become undefined external symbols, resolved by linker.

**v4.5.1 (CPU backend stabilisation):**
- **100,000 / 100,000 MIR fuzz tests passed** — zero miscompiles on random programs.
- **CMP_R64_MEM**, **ADD_R64_MEM**, **SUB_R64_MEM** — new opcodes in `x64enc.zig`.
- **`regalloc.spilledMemOp()`** — helper for reading second operand from memory without overwriting scratch.

**v4.5.0 (Linear Scan Register Allocator):**
- **Linear Scan Register Allocator** (`regalloc.zig`): live intervals, linear scan with expire/spill, 9 GP registers, r11 reserved as spill scratch.
- `mir_x64.zig` fully rewritten: emit-functions for each MIR instruction, unified `ra: *const RegAllocResult`.

**v4.4.0:**
- Removed `emitMfunction`. All CPU tests through unified linker `emitModule`.
- `mir_verify.zig` — MIR verifier before emit.
- `x64enc.disassemble` — disassembler (30+ instructions).

**v4.3.2:**
- All examples in README translated to Russian.
- GPU IR: BackendApi, ShaderKey, PipelineKey, CompileOptions/Result.
- DXIL backend (draft): GPU IR → HLSL → DXC subprocess → DXBC.

**v4.3.1:**
- Fixed stack alignment in entry point prologue (x64gen.zig). `stack_frame_size` is now always 8 mod 16, ensuring RSP = 0 mod 16 after saving 6 registers. Resolved `ACCESS_VIOLATION` in `MOVAPS [RSP+0x30]` when calling `MessageBoxW` via ucrtbase.dll.
- Added Russian keyword aliases: `состояние`, `если`, `иначе`, `печать`, `всегда`, `пер`, `вход`, `запуск` etc. Usable alongside English keywords in the same file. Zero performance overhead — `StaticStringMap` (compile-time perfect hash, O(1)).

**B+** compiles `.b+` / `.bp` files directly to x64 machine code and packages them into Windows PE executables (.exe).
No assemblers, linkers, or LLVM — the entire code generator is written from scratch in Zig.

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Compiler Commands](#2-compiler-commands)
3. [Language Syntax](#3-language-syntax)
   - [3.1 States](#31-states)
   - [3.2 Transitions (on)](#32-transitions-on)
   - [3.3 Unconditional Transitions (always)](#33-unconditional-transitions-always)
   - [3.4 Entry and Exit (entry / exit)](#34-entry-and-exit-entry--exit)
   - [3.5 Variables](#35-variables)
   - [3.6 Assignments](#36-assignments)
   - [3.7 Print (print)](#37-print-print)
   - [3.8 Guard Conditions (guard)](#38-guard-conditions-guard)
   - [3.9 global entry](#39-global-entry)
   - [3.10 Context (context)](#310-context-context)
   - [3.11 Annotations](#311-annotations)
   - [3.12 Enums (enum)](#312-enums-enum)
   - [3.13 Parallel Blocks (parallel)](#313-parallel-blocks-parallel)
   - [3.14 Kernel Functions](#314-kernel-functions)
   - [3.15 External Functions (extern)](#315-external-functions-extern)
   - [3.16 Comments](#316-comments)
4. [`.bp` Syntax (New CPU Backend)](#4-bp-syntax-new-cpu-backend)
   - [4.1 Types](#41-types)
   - [4.2 Functions](#42-functions)
   - [4.3 Extern Functions](#43-extern-functions)
   - [4.4 Variables](#44-variables)
   - [4.5 Structs](#45-structs)
   - [4.6 Pointers](#46-pointers)
   - [4.7 If/else](#47-ifelse)
   - [4.8 While](#48-while)
   - [4.9 For](#49-for)
   - [4.10 Compound Assignment](#410-compound-assignment)
   - [4.11 Operators](#411-operators)
   - [4.12 Comments](#412-comments)
   - [4.13 Error Messages](#413-error-messages)
   - [4.14 CLI](#414-cli)
5. [Data Types](#5-data-types)
6. [Examples](#6-examples)
7. [Building from Source](#7-building-from-source)
8. [Project Structure](#8-project-structure)
9. [License](#9-license)
10. [Contact](#10-contact)

---

## 1. Quick Start

```bash
bpc.exe build hello.b+
.\hello.exe
```

The first command compiles `hello.b+` into `hello.exe`.
The second runs it.

Or combine both:

```bash
bpc.exe run hello.b+
```

---

## 2. Compiler Commands

### Syntax

```text
bpc build <input.b+>              — compile to <input>.exe
bpc build <input.b+> -o <out.exe> — compile with custom output name
bpc dll   <input.b+>              — compile to DLL
bpc run   <input.b+>              — compile and run immediately
bpc hlsl  <input.b+>              — generate HLSL shader code
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
```bash
bpc build traffic.b+              → traffic.exe
bpc build traffic.b+ -o light.exe → light.exe
bpc build source.b+               → source.exe
```

#### `bpc hlsl <input.b+> [-o <output.hlsl>]`

Generates HLSL shader code from a B+ file using `@bind`, `@cbuffer`, `@groupshared` annotations.
Designed for authoring GPU compute shaders in B+ and compiling them via DXC or FXC.

| Step | Description |
|------|-------------|
| 1 | Reads the entire `.b+` file |
| 2 | Parses source into AST |
| 3 | Parses `@bind(kind, reg, format)` annotations |
| 4 | Parses `@cbuffer(var, cbName, reg, type)` annotations |
| 5 | Parses `@groupshared(name, size)` annotations |
| 6 | Generates HLSL: cbuffers, resource declarations, `[numthreads]`, shader body |
| 7 | Writes output `.hlsl` file |

**Annotations:**

```rust
// Textures
g_InputColor: @bind(t, 0, float4)     // Texture2D<float4> : register(t0)
g_OutputColor: @bind(u, 0, float4)    // RWTexture2D<float4> : register(u0)
g_OutputUAV: @bind(u, 1, uint, globallycoherent)  // globallycoherent RWTexture2D<uint>
// Sampler
linearClamp: @bind(s, 0)              // SamplerState : register(s0)

// Constant buffer
inputSize: @cbuffer(FSR2Constants, 0, float2)   // cbuffer FSR2Constants : register(b0) { float2 inputSize; ... }

// Groupshared
sharedMem: @groupshared(sharedMem, 256)           // groupshared float sharedMem[256];
```

Inside `entry`, `for(x, y, w, h)` loops translate to `uint x = tid.x; if (x >= w) return;`.
HLSL intrinsics (WaveActiveSum, InterlockedAdd, mad, lerp, etc.) pass through verbatim.

**Example:**
```bash
bpc hlsl fsr2_easu.b+ -o fsr2_easu.hlsl
dxc -T cs_6_6 -E main -Fo fsr2_easu.cso fsr2_easu.hlsl
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
```bash
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

```rust
state <Name> {
    ...
}
```

A state is the basic building block. It can contain variables, transitions, and entry/exit blocks.

```rust
state Red {
    on timer -> Green
    entry { print("RED\n") }
}
```

### 3.2 Transitions (on)

```rust
on <event> -> <TargetState>
```

When an event (a string from stdin) arrives, the machine transitions to the specified state.

```rust
state Green {
    on timer -> Yellow
    on pedestrian -> Red
}
```

### 3.3 Unconditional Transitions (always)

```rust
always -> <TargetState>
```

The transition happens immediately upon entering the state, without waiting for an event.

```rust
state Init {
    always -> Menu
}
```

### 3.4 Entry and Exit (entry / exit)

```rust
state Door {
    entry { print("entered\n") }
    exit  { print("exited\n") }
    on open -> Opened
}
```

- `entry { ... }` — executed when entering the state.
- `exit { ... }` — executed before leaving the state (before transitioning to another state).

### 3.5 Variables

```rust
var <name>: <type> [= <value>]
```

Declared inside a state. Types: int8, int16, int32, int64, u8, u16, u32, u64, byte, bool, short, int, float, etc.

```rust
state Counter {
    var count: int = 0
    on tick -> Self {
        count += 1
    }
}
```

Multiple variables can be declared separated by commas:

```rust
var x: int, y: int, name: int
```

Bare identifiers without `var` and type are also accepted in state bodies:

```rust
state S {
    x     // equivalent to var x: i64
}
```

Such bare identifiers are automatically registered as `i64` variables.

### 3.6 Assignments

Inside `entry { }`, `exit { }` or a transition body:

```rust
var x: int

on event -> Next {
    x = 42
    x += 1
    x -= 5
}
```

Supported operators: `=`, `+=`, `-=`.
The right side can use numbers and variable names.

**Pointer dereference assignment** — when the left side is `*<name>`, the value
is written to the memory address stored in the variable:

```rust
*ctl = new_value    // MOV [RCX], RAX
result = *ctl       // RAX = [RCX]
```

Used for accessing heap memory via TLS-stored pointers.

### 3.7 Print (print)

```rust
print("string")
```

Prints a string to stdout. Supports escape sequences `\n`, `\r`, `\t`.

```rust
state Hello {
    entry { print("Hello, world!\n") }
}
```

### 3.8 Guard Conditions (guard)

```rust
on <event> [<condition>] -> <TargetState>
```

The transition only occurs if the condition is true. Supported operators:
`==`, `!=`, `>`, `<`, `>=`, `<=`

```rust
state Crosswalk {
    var cars_waiting: bool
    on timer [cars_waiting == 0] -> Walk
    on timer [cars_waiting > 0]  -> Wait
}
```

### 3.9 global entry

```rust
entry <Name> {
    ...
}
```

A global entry point — executed once at program startup. Can be used for initialization.

```rust
entry main {
    print("Starting...\n")
}
```

### 3.10 Context (context)

```rust
context {
    var <name>: <type>
    ...
}
```

Context variables are global across the entire program, visible in all states.

```rust
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

```rust
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

```rust
enum <Name> {
    Member1,
    Member2,
    ...
}
```

A global enum declaration.

```rust
enum Color {
    Red,
    Yellow,
    Green
}
```

### 3.13 Parallel Blocks (parallel)

```rust
parallel <Name> {
    state A { ... }
    state B { ... }
}
```

Groups states into a parallel block (states don't affect each other).

### 3.14 Kernel Functions

```rust
kernel <name>(<param>: <type>, ...) -> <type>
```

Declares a kernel function (for GPU/metal code generation).

```rust
kernel matrixMul(a: int, b: int) -> int
```

### 3.15 External Functions (extern)

```rust
extern "dllname.dll" fn <name>(<param>: <type>, ...) -> <type>
```

Declares an external function from a DLL.

```rust
extern "user32.dll" fn MessageBoxA(hWnd: int, lpText: int, lpCaption: int, uType: int) -> int
```

### 3.16 Comments

```rust
// single-line comment
-- also a comment
```

---

## 4. `.bp` Syntax (New CPU Backend)

The new `.bp` syntax uses a direct MIR pipeline (no BIR, no state machine).
Supports functions, variables, structs, pointers, `if`/`while`/`for`, compound assignment.

### 4.1 Types

| Type | Size (bytes) |
|------|-------------|
| `i8` / `u8` / `bool` | 1 |
| `i16` / `u16` | 2 |
| `i32` / `u32` | 4 |
| `i64` / `u64` | 8 |
| `int` | alias for `i64` |
| `uint` | alias for `u64` |
| `*T` | 8 (pointer) |
| `void` | 0 |

### 4.2 Functions

```rust
fn add(a: i64, b: i64) -> i64 {
    a + b
}

fn main() {
    print_i64(add(3, 4));
}
```

Last expression is implicit `return`. Explicit `return` also works:

```rust
fn max(a: i64, b: i64) -> i64 {
    if a > b {
        return a;
    }
    return b;
}
```

### 4.3 Extern Functions

```rust
extern fn print_i64(x: i64);
extern fn read_i64() i64;
extern fn bplus_malloc(size: i64) i64;
extern fn bplus_free(ptr: i64);
extern fn bplus_exit(code: i64);
```

### 4.4 Variables

```rust
var x: i64 = 42;
var y;
var z = 10;
x = 10;
```

### 4.5 Structs

```rust
struct Point {
    x: i64,
    y: i64,
}
```

Single-line: `struct Point { x: i64, y: i64 }`

```rust
var p: Point;
p.x = 10;
p.y = 20;
print_i64(p.x);
```

Literals:

```rust
var p = Point { x: 10, y: 20 };
var q = Point {
    x: 30,
    y: 40,
};
```

### 4.6 Pointers

```rust
var x: i64 = 42;
var p: *i64 = &x;
var y: i64 = *p;
*p = 10;
var addr: *i64 = &p.x;
```

### 4.7 If/else

```rust
if x > 5 {
    print_i64(1);
} else {
    print_i64(0);
}
if (x > 5) {
    print_i64(1);
}
```

### 4.8 While

```rust
while i < 3 {
    print_i64(i);
    i += 1;
}
```

`break` / `continue`:

```rust
while i < 10 {
    if i == 5 { break; }
    if i == 2 { i += 1; continue; }
    print_i64(i);
    i += 1;
}
```

### 4.9 For

```rust
for i in 0..10 {
    print_i64(i);
}
```

### 4.10 Compound Assignment

```rust
x += 1;
y -= 5;
z *= 2;
```

### 4.11 Operators

| Operator | Description |
|----------|-------------|
| `*` / `/` | multiply, divide |
| `+` / `-` | add, subtract |
| `==` / `!=` / `>` / `<` / `>=` / `<=` | comparisons |
| `&&` | logical AND |
| `\|\|` | logical OR |

### 4.12 Comments

```rust
// single-line comment
```

### 4.13 Error Messages

```
error[UnknownVariable]: test_error.bp:4:1
   4 |     print_i64(y);
       | ^
```

### 4.14 CLI

```text
bplus build <input.bp> [-o <output.exe>]
bplus run   <input.bp>
```

Pipeline: `.bp → parser → MIR → DCE → peephole → reg alloc → x64 → COFF .obj → zig build-exe → .exe`

---

## 5. Data Types

| Type | Size (bytes) |
|------|-------------|
| `int8`, `i8`, `u8`, `byte`, `bool` | 1 |
| `int16`, `i16`, `u16`, `short`, `half` | 2 |
| `int32`, `i32`, `u32`, `int`, `uint`, `float` | 4 |
| `int64`, `i64`, `u64` (and anything else) | 8 |

---

## 6. Examples

### Traffic Light

```rust
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

```rust
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

```rust
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

## 7. Building from Source

Requires [Zig](https://ziglang.org/) (master, >= 0.14).

```bash
cd zig
zig build
```

Or directly:

```bash
cd zig
zig build-exe src/main.zig -femit-bin=bpc.exe
```

After building:

```bash
bpc.exe run example.b+
```

---

## 8. Project Structure

```text
zig/                    — compiler (Zig, active development)
  src/
    main.zig            — entry point, CLI, orchestration
    runtime.zig          — runtime kernel (handle table, arena, FSM, migration, Snapshot)
    runtime_test.zig     — 40 unit tests: alloc, release, tick, migration, decay, budget, memory layer
    stress_test.zig      — stress test: 100k ops with snapshot-based formal invariant verification
    cpu.zig              — CPU topology detection (Windows kernel32 extern)
    latency.zig          — LatencyProfile, CoreStats, LoadState (adaptive thresholds)
    scheduler.zig        — NUMA-aware worker-pool scheduler
    scheduler_test.zig   — 16 tests: sync/threaded/priority/steal/latency/state-machine
    bench.zig            — A/B benchmark: baseline vs smart scheduler (4 patterns) + smoke tests
    scheduler_config.zig — SchedulerConfig (max_sticky_ns, max_queue_len, imbalance thresholds)
    scheduler_state.zig  — GlobalSchedulerState (SystemLoad, adjustDecision)
    gpu_ir.zig           — GPU IR: BindingKey{reg,space,kind}, BindGroup, PipelineKey, DispatchDesc, ResourceId
    frame_graph.zig      — FrameGraph: Pass, ExecutionNode, ExecutionPlan, GPUPassDesc (unified compute DAG IR)
    frame_graph_executor.zig — compileGraph() → immutable CompiledGraph; per-frame writeFrameDescriptors+executeCompiledGraph
    compiled_graph.zig   — CompiledGraph: CompiledPass, FrameInputs, BindSlot, DescriptorArena. Pre-baked PSOs/barriers/slots
    resource_system.zig  — ResourcePool: GPU resource lifecycle, RS-driven descriptor allocation, state tracking
    root_signature_builder.zig — Per-pass root signature compiler: BindLayout → CompiledRS, cached by hash
    gpu_job.zig          — GPUJob dispatch descriptor
    gpu_scheduler.zig    — Pure GPU dispatch sink (no graph awareness)
    parser.zig          — lexer + parser for .b+
    ast.zig             — AST types (states, transitions, etc.)
     x64gen.zig          — x64 machine code generator (+ Intrinsic binding to runtime).
                           Features: jump-table dispatch, superblock fusion,
                           compiled event matching (inline CMP imm for ≤4B names),
                           label interning (u32 IDs, zero formatting in hot paths),
                           O(1) state lookup via HashMap.
                           **New features:**
                           - Structs: `struct Name { field: type, ... }` — packed layout
                           - `arr[idx]` — array indexing via SIB (scale=3 for *8)
                           - `reinterpret_cast<T>(expr)` — outer cast stripping
                           - `obj->method(args)` — COM calls via vtable
                           - `ptr_store(dest, value)` — pointer write (depth-aware)
                           - `rcp(x)`, `lerp(a,b,t)`, `med3(a,b,c)` — math intrinsics
                           - 16 CRT functions via IAT (msvcrt.dll), XMM0/XMM1 for float
                           - D3D12 COM methods in COM_METHODS
                           - `context { var x: type }` — context variables (bugfix)
                           - `forward Name = "dll.dll"` — DLL export forwarding
     x64enc.zig          — x64 instruction encoder
     layout.zig          — StackFrame/SlotKind: type-safe stack layout abstraction
                           used by x64gen.zig for frame offset computation
     symbol.zig          — SymbolTable: re-exports table (code/export/data)
     pe.zig             — PE (.exe/.dll) generator
     hlslgen.zig         — HLSL codegen. Annotations: @bind, @cbuffer, @groupshared.
                           FSR2 type mapping, 50+ HLSL intrinsic pass-through,
                           globallycoherent RWTexture2D support.

  shaders/fsr2/         — Reference HLSL shaders (8 FSR2 passes)
    fsr2_easu.hlsl       — EASU upscale
    fsr2_rcas.hlsl       — RCAS sharpen
    fsr2_accumulate.hlsl — Temporal Accumulation
    fsr2_depthclip.hlsl  — Depth Clip
    fsr2_lock.hlsl       — Lock Status
    fsr2_luminance_pyramid.hlsl
    fsr2_reconstruct_depth.hlsl
    fsr2_dilate_velocity.hlsl
  shaders/cso/          — Pre-compiled .cso files (cs_6_6)

  fsr2_proxy.b+         — DXGI proxy DLL (~500 lines, pure B+ x64):
                          hooks CreateSwapChain/Present, initializes D3D11,
                          loads 8 CSOs, runs full FSR2 pipeline per-frame.

  tss_easu.b+           — CPU reference EASU implementation
  tss_easu_faithful.b+  — Faithful 12-tap EASU with gradient direction
  build.zig            — build script (zig build)
```

---

## 9. License

MIT License

```text
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

## 10. Contact

- **GitHub**: [github.com/bylka2W](https://github.com/bylka2W)
- **Repository**: [github.com/bylka2W/B-Plus](https://github.com/bylka2W/B-Plus)
- **Author**: bylka2W
