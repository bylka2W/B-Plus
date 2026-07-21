# B+ v4.6.1-beta — Compiled `.plan` / `.metal` Language (Frontend → HIR → BIR → MIR → Targets)

> [English version ↓](#b-v461-beta--compiled-plan--metal-language-frontend--hir--bir--mir--targets)

**B+** компилирует `.plan` / `.metal` файлы напрямую в машинный код x64 и упаковывает в Windows PE (.exe/.dll).
Никаких ассемблеров, линкеров, LLVM — весь кодогенератор и оптимизатор написаны с нуля на Zig.

### Что нового в v4.6.1-beta

- **Архитектура Frontend → HIR → BIR → MIR → Targets** — полная миграция компилятора на
  многоуровневую архитектуру в стиле LLVM/rustc с однонаправленным потоком зависимостей.
- **Разделение frontend / middle / backend** — исходный код компилятора перемещён из плоской
  структуры `compiler/parser/` и `compiler/backend/bir/` в иерархию `compiler/frontend/`,
  `compiler/middle/bir/`, `compiler/backend/mir/`, `compiler/backend/targets/`.
- **BIR core модуль** — новый `bir/core/` с типизированными `Module`, `Function`, `Block`,
  `Value`, `Instruction` и системой типов (`TypeSystem`).
- **BIR optimizer framework** — `bir/optimizer/` с `PassManager` и `PassResult` для
  построения пайплайнов оптимизаций.
- **BIR analysis** — `bir/analysis/` с `AnalysisManager` и `cfg.zig` (CFG построение).
- **MIR core модуль** — `mir/core/` с типизированными `MFunction`, `MBlock`, `MInst`,
  `MOperand`, `MOpcode`, `PhiInst`, `PhiIncoming`.
- **Targets abstraction** — `targets/common/` (общий target) и `targets/x64/` с
  instruction selection (`isel/`), encoder (`x64enc.zig`), frame manager, register allocator.
- **Critical edge fix** — исправлен hang теста `testCriticalEdgePhi`: эпилог теперь
  генерируется после каждого блока, заканчивающегося `ret`, предотвращая infinite loop
  при critical edge splitting.
- **9/9 E2E тестов BIR → MIR → x64 → execute** проходят (ранее 7/8).

---

## Содержание

1. [Быстрый старт](#1-быстрый-старт)
2. [Команды компилятора](#2-команды-компилятора)
3. [Синтаксис языка (.plan)](#3-синтаксис-языка)
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
4. [Синтаксис .metal (новый CPU backend)](#4-синтаксис-metal-новый-cpu-backend)
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
7. [Оптимизатор BIR — бенчмарки и архитектура](#7-оптимизатор-bir--бенчмарки-и-архитектура)
8. [Сборка из исходников](#8-сборка-из-исходников)
9. [Структура проекта](#9-структура-проекта)
10. [Лицензия](#10-лицензия)
11. [Контакты](#11-контакты)

---

## 1. Быстрый старт

```bash
bpc.exe build hello.plan
.\hello.exe
```

Первая команда компилирует `hello.plan` в `hello.exe`.
Вторая — запускает.

Можно совместить:

```bash
bpc.exe run hello.plan
```

---

## 2. Команды компилятора

### Синтаксис

```text
bpc build <входной.plan>              — скомпилировать в <входной>.exe
bpc build <входной.plan> -o <выход.exe> — скомпилировать с указанием имени
bpc dll   <входной.plan>              — скомпилировать в DLL
bpc run   <входной.plan>              — скомпилировать и сразу запустить
bpc hlsl  <входной.plan>              — сгенерировать HLSL шейдер
```

#### `bpc dll <input.plan> [-o <output.dll>] [-exports <name1,name2,...>]`

Компилирует `.plan` файл в DLL с таблицей экспорта. Все `export entry` или
перечисленные в `-exports` становятся экспортируемыми функциями.

| Шаг | Описание |
|-----|----------|
| 1 | Читает файл `.plan` целиком в память |
| 2 | Разбирает (парсит) исходный код в AST |
| 3 | Генерирует машинный код x64 с DllMain (возвращает TRUE) |
| 4 | Создаёт таблицу импорта (kernel32.dll + runtime) |
| 5 | Строит таблицу экспорта (Export Directory Table, EAT, ENPT, EOT) с сортировкой ENPT по алфавиту (требование Windows для `GetProcAddress`) |
| 6 | Упаковывает всё в формат PE (DLL), секция `.text` — RWX (`0xE0000020`) |
| 7 | Записывает результат на диск |

**Примеры:**
```bash
bpc dll test.plan -o test.dll -exports Init,Update
bpc dll module.plan
```

#### `bpc build <input.plan> [-o <output.exe>]`

Что делает:

| Шаг | Описание |
|-----|----------|
| 1 | Читает файл `.plan` целиком в память |
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
bpc build traffic.plan              → traffic.exe
bpc build traffic.plan -o light.exe → light.exe
bpc build source.plan               → source.exe
```

#### `bpc gpu <input.plan> [-o <output.hlsl>]` / `bpc hlsl <input.plan> [-o <output.hlsl>]`

Генерирует HLSL-код из B+ файла с новым блочным `kernel { ... }` синтаксисом
или старым (legacy `@bind`/`@cbuffer`). `bpc hlsl` автодетектит синтаксис.

| Шаг | Описание (новый pipeline) |
|-----|--------------------------|
| 1 | Читает файл `.plan` целиком в память |
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
bpc hlsl fsr2_easu.plan -o fsr2_easu.hlsl
dxc -T cs_6_6 -E main -Fo fsr2_easu.cso fsr2_easu.hlsl
```

#### `bpc run <input.plan>`

Что делает:

| Шаг | Описание |
|-----|----------|
| 1 | Компилирует `<input>.exe` |
| 2 | Запускает полученный `.exe` |
| 3 | Перехватывает stdout и печатает в консоль |
| 4 | Возвращает код завершения программы |

**Примеры:**
```bash
bpc run traffic.plan    — компилирует и сразу запускает
bpc run hello.plan      — компилирует и сразу запускает
```

### Коды возврата

| Код | Значение |
|-----|----------|
| 0 | Успех |
| 1 | Ошибка: неверные аргументы или файл не найден |
| >0 | Код завершения скомпилированной программы (при использовании `run`) |

### Примечания

- Входной файл **обязан** иметь расширение `.plan`.
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

## 4. Синтаксис `.metal` (новый CPU backend)

Новый `.metal` синтаксис работает через MIR pipeline с полной SSA-архитектурой.
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
error[UnknownVariable]: test_error.metal:4:1
   4 |     print_i64(y);
       | ^
```

### 4.14 CLI

```text
bplus build <input.metal> [-o <output.exe>]
bplus run   <input.metal>
```

Pipeline: `.metal → парсер → BIR (SSA) → mem2reg → cfgsimplify → SCCP → InstCombine → ConstantFolding → GVN → LICM → Unroll → DCE → понижение до MIR → уничтожение SSA → addr_fold → распространение копий → DCE → пеепхол → линейный аллокатор → x64 → COFF .obj → zig build-exe → .exe`

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

## 7. Оптимизатор BIR — бенчмарки и архитектура

### Архитектура backend

Backend компилятора построен по архитектуре, аналогичной LLVM:

```
BIR (SSA)  ──── MIR (Machine IR)  ──── x64 Machine Code
  │                    │                        │
  ├─ mem2reg           ├─ SSA destruction        ├─ Linear Scan RA
  ├─ cfgsimplify        ├─ addr_fold (LEA)        ├─ Frame Manager
  ├─ SCCP               ├─ copy propagation       ├─ Instruction Encoder
  ├─ InstCombine         ├─ DCE                    └─ COFF/PE
  ├─ ConstantFolding     └─ peephole
  ├─ GVN
  ├─ LICM
  ├─ Unroll
  └─ DCE
```

### BIR Optimization Pipeline

| Проход | Описание |
|--------|----------|
| **mem2reg** | Продвижение памяти в SSA-регистры |
| **cfgsimplify** | Упрощение графа потока управления |
| **SCCP** | Распространение условных констант |
| **InstCombine** | Алгебраические тождества, свёртка сравнений |
| **ConstantFolding** | Вычисление константных выражений, max/min |
| **GVN** | Глобальная свёртка значений (CSE для commutative ops) |
| **LICM** | Вынос инвариантов из циклов |
| **Unroll** | Развёртка коротких циклов |
| **DCE** | Удаление мёртвого кода |

### MIR Optimization Pipeline

| Проход | Описание |
|--------|----------|
| **SSA Destruction** | Замена phi на mov через CopyProp |
| **AddrFold** | Синтез LEA из адресной арифметики [base+index*scale+disp] |
| **Copy Propagation** | Распространение копий (3 итерации) |
| **DCE** | Удаление мёртвого кода |
| **Peephole** | Константная свёртка, оптимизация сравнений |

### Бенчмарки оптимизаций

| Тест | Без опт. | С опт. | Экономия |
|------|----------|--------|----------|
| P1: Цепочка арифметики (mul/div pow2, mul -1) | 91 B, 14 инстр. | 51 B, 10 инстр. | **44.0%** |
| P2: Мёртвая ветка (SCCP: if(true) → else) | 74 B, 8 инстр., 4 блока | — 4 инстр., 2 блока | ветка удалена |
| P3: Избыточный CSE (5+3 вычисляется 3 раза) | 74 B, 8 инстр. | 26 B, 2 инстр. | **64.9%** |
| P4: Стресс (200 vregs, цепочка add) | 2026 B, 402 инстр. | 26 B, 2 инстр. | **98.7%** |
| P5: max/min constant folding | 107 B, 8 инстр. | 26 B, 2 инстр. | **75.7%** |

### Тесты

25 E2E тестов кодогенерации (BIR → MIR → x64 → execute):

- Целочисленная арифметика: add, sub, mul, div, neg, not, and/or/xor
- Ветвление: if/else, phi-ноды
- Стресс: 200 и 500 vreg, спилы
- Strength reduction: mul→shl, div→shr, mul -1→neg
- SCCP: мёртвые ветки, свёртка констант
- InstCombine: двойное neg, add/sub cancellation
- Плавающая арифметика: f32/f64 add, mul, sub, div, neg
- Конверсии: int↔float, sext, zext, trunc
- min/max: CMOVcc (branchless)

---

## 8. Сборка из исходников

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
bpc.exe run example.plan
```

---

## 9. Структура проекта

### Архитектура компилятора

```
Frontend (парсер, AST, семантика)
    │
    ▼
HIR (High-Level IR) — BIR SSA
    │  mem2reg → cfgsimplify → SCCP → InstCombine → ConstantFolding
    │  → GVN → Unroll → LICM → ForwardStoreToLoad → DeadStoreElimination → DCE
    ▼
MIR (Machine IR) — target-independent
    │  SSA Destroy → AddrFold → CopyProp → Peephole ×3 → DCE
    ▼
Targets (code generation)
    │  ISEL → RegAlloc → Encoding
    ▼
Object (PE/COFF → .exe)
```

### Дерево исходников

```text
src/
  main.zig                — точка входа, CLI, оркестрация
  bplus.zig               — CLI (bplus build/run)

  compiler/
    frontend/
      ast.zig             — типы AST (TypeId, AST-структуры)
      cppgen.zig          — C++ кодогенератор из AST
      parser/
        ast.zig           — re-export ../ast.zig
        gpu_ast.zig       — re-export ../../gpu/frontend/gpu_ast.zig
        parser.zig        — лексер + парсер .plan
      sema/
        ast.zig           — re-export ../ast.zig
        scope.zig         — re-export resolver/scope.zig
        sema.zig          — семантический анализ
        resolver/
          scope.zig       — разрешение scopes (SymbolKind, scope resolution)
        symbols/
          symbol.zig      — типы символов (SymbolKind: code, ...)

    middle/
      bir/
        bir.zig           — публичный BIR API; re-export core/
        bir_analysis.zig  — re-export analysis/manager.zig
        bir_alias.zig     — анализ псевдонимов (AliasResult: NoAlias, ...)
        bir_backend.zig   — re-export bir, bir_types, bir_cfg, bir_loops, ...
        bir_bplus_frontend.zig — фронтенд B+ → BIR (импортирует frontend/ast)
        bir_cfg.zig       — re-export analysis/cfg/cfg.zig
        bir_cfgsimplify.zig — упрощение CFG
        bir_cpu.zig       — CPU target lowering (BIR → MIR)
        bir_dominators.zig — дерево доминаторов
        bir_frontend.zig  — GPU фронтенд → BIR
        bir_hlsl.zig      — BIR → HLSL
        bir_ivopt.zig     — оптимизация индуктивных переменных
        bir_licm.zig      — LICM (вынос инвариантов из циклов)
        bir_loops.zig     — анализ циклов
        bir_loop_rotate.zig — loop rotation transform
        bir_lower.zig     — понижение BIR (импортирует pipeline_gen)
        bir_mem2reg.zig   — продвижение памяти в регистры (SSA)
        bir_memory_ssa.zig — построение MemorySSA
        bir_passes.zig    — инфраструктура BIR-проходов
        bir_sccp.zig      — SCCP (sparse conditional constant propagation)
        bir_types.zig     — re-export core/types.zig
        bir_unroll.zig    — развёртка циклов
        bir_verify.zig    — верификация BIR
        core/
          block.zig       — базовый блок (BlockId)
          function.zig    — представление функции
          instruction.zig — определения BIR-инструкций
          module.zig      — контейнер модуля
          types.zig       — система типов BIR (TypeId)
          value.zig       — типы значений (ValueId, BlockId, FunctionId)
        optimizer/
          pass_manager.zig — менеджер проходов оптимизации
          pass_types.zig  — идентификаторы проходов/анализов (AnalysisKind bitmask)
        analysis/
          manager.zig     — менеджер анализов (кэш CFG, доминаторов, циклов)
          cfg/
            cfg.zig       — построение графа потока управления

    backend/
      backend.zig          — корневой модуль (re-export bir, mir, targets, object)
      mir/
        mir.zig            — публичный MIR API
        mir_backend.zig    — re-export mir, mir_verify, mir_optimizer, ...
        mir_addr_fold.zig  —.AddrFold (синтез LEA из адресной арифметики)
        mir_copy_prop.zig  — распространение копий
        mir_dce.zig        — удаление мёртвого кода
        mir_optimizer.zig  — пайплайн MIR-оптимизаций (оркестрирует DCE, peephole, SSA destroy)
        mir_peephole.zig   — пеепхол-оптимизации
        mir_ssa_destroy.zig — уничтожение SSA (элиминация phi)
        mir_verify.zig     — верификация MIR
        mir_x64.zig        — legacy wrapper → targets/x64/lowering.zig
        pipeline_gen.zig   — генерация рендер-пайплайна
        sizes.zig          — утилита размеров D3D12 структур
        core/
          mir.zig          — MIR core: target-independent типы
          function.zig     — представление MIR-функции
          opcode.zig       — MIR opcodes (MovInst, и т.д.)
          operand.zig      — типы MIR-операндов (MOperand, PhysReg, CondCode)
          value.zig        — MIR data types (DataType enum: void, i1, i8, ...)

      targets/
        common/
          target.zig       — target-independent типы (RegAllocResult)
        x64/
          x64_backend.zig  — точка входа x64 backend (MIR → x86-64 пайплайн)
          x64enc.zig       — кодировщик инструкций x64
          x64gen.zig       — генератор кода x64
          abi.zig          — ABI-константы (frame_size, shadow_size)
          branches.zig     — хелперы кодирования ветвлений
          codebuffer.zig   — буфер кода с fixup-ами (LabelId)
          debug.zig        — отладочные/трассировочные утилиты x64
          encoder.zig      — re-export x64enc.zig
          frame.zig        — раскладка стекового фрейма (Abi: win64, ...)
          isel.zig         — оркестрация instruction selection
          layout.zig       — раскладка слотов локальных (SlotKind enum)
          lowering.zig     — оркестрация x64 lowering (regalloc → isel → encode)
          memory.zig       — хелперы addressing modes (base + displacement)
          peephole.zig     — x64-specific пеепхол
          regalloc.zig     — аллокация регистров
          registers.zig    — enum регистров x64 (X64Reg)
          ir/
            inst.zig       — типы IR-инструкций x64
          isel/
            context.zig    — общий контекст ISEL-подмодулей
            control.zig    — ISEL контроля потока (branch/call/ret/select)
            conversions.zig — ISEL конверсий типов (sext/zext/trunc/sitofp/...)
            float.zig      — ISEL плавающей арифметики (SSE scalar)
            integer.zig    — ISEL целочисленной арифметики
            memory.zig     — ISEL доступа к памяти (load/store/lea/alloca)

      object/
        pe/
          pe.zig           — генератор PE (.exe/.dll)
        coff/
          coff.zig         — генератор COFF-объектов

    gpu/
      dxil_backend.zig     — DXIL backend
      dxil_bitcode.zig     — LLVM bitstream writer (формат DXIL)
      gpu_cpp.zig          — C++ UE shader class generation из GPU IR
      gpu_dxil.zig         — GPU IR → DXIL кодогенерация
      gpu_hlsl.zig         — GPU IR → HLSL кодогенерация
      gpu_ir.zig           — GPU промежуточное представление (ValueId)
      gpu_lower.zig        — понижение GPU AST → IR
      gpu_types.zig        — GPU runtime типы (ResourceId, DispatchGrid, ...)
      shader_backend.zig   — диспетчер shader backend (IrModule, CompileOptions)
      frontend/
        ast.zig            — re-export gpu_ast.zig
        gpu_ast.zig        — GPU AST (ResourceKind: texture2d, ...)
        gpu_body_parser.zig — парсинг тел GPU shader (1784 строк)
        gpu_sema.zig       — семантический анализ GPU (Severity: error, warning)
        hlslgen.zig        — HLSL генерация из GPU AST

    runtime/
      runtime.zig          — re-export ../../runtime/runtime.zig

  runtime/
    runtime.zig            — основной runtime (Panic Runtime, Windows OS layer)
    bplusrt.zig            — B+ runtime (kernel32, print_i64, ...)
    cpu.zig                — определение/утилиты CPU (Windows API)
    latency.zig            — модель задержек (HT_COST_NS, CORE_COST_NS)
    scheduler.zig          — ядро планировщика задач (CPU/GPU)
    scheduler_config.zig   — конфигурация планировщика
    scheduler_state.zig    — состояние планировщика (DecisionOverride enum)
    cost_scheduler.zig     — cost-based GPU планировщик
    gpu_scheduler.zig      — планировщик GPU-проходов (ResolvedPass)
    gpu_job.zig            — определение GPU-задания (GPUJob)
    frame.zig              — управление фреймами (Stage: upsample, sharpen, temporal)
    bench.zig              — харнесс бенчмарков

  render/
    frame_graph.zig        — FrameGraph (istorical validity per resource)
    compiled_graph.zig     — скомпилированный граф
    frame_graph_executor.zig — исполнитель графа
    frame_runtime.zig      — runtime графа (D3D12 + scheduler)
    resource_system.zig    — управление GPU-ресурсами (текстуры, буферы)
    root_signature_builder.zig — компилятор root signatures D3D12
    render_graph.zig       — high-level render graph
    render_helpers.zig     — утилиты (dispatch2D grid calculation)
    camera_jitter.zig      — Halton sequence camera jitter (TAA)
    d3d12_bindings.zig     — D3D12 API bindings (HRESULT, GUID, ...)
    dx12_compute.zig       — DX12 compute dispatch утилиты
    history_manager.zig    — ring-buffer истории кадров (TAA)
    lifetime_graph.zig     — график жизненного цикла ресурсов
    barrier_optimizer.zig  — оптимизатор ресурс-барьеров
    temporal_history.zig   — temporal scoring confidence кадров
    temporal_pipeline.zig  — temporal upscaling пайплайн
    gpu_execution.zig      — запись GPU-исполнения
    gpu_executor.zig       — оркестрация GPU-исполнения
    fsr3_runtime.zig       — FSR 3 frame generation runtime

  platform/
    linux/                  — (заготовка)
    macos/                  — (заготовка)
    shared/                 — (заготовка)
    windows/                — (заготовка)

  tools/
    test_runner/
      test_runner.zig       — test runner (импортирует parser, x64gen, pe)
```

### E2E тесты

BIR → MIR → x64 → execute: **9/9 PASS** + 25 E2E тестов целочисленной арифметики,
плавающей арифметики, конверсий, min/max (CMOVcc), strength reduction, стресс-тестов (200/500 vreg).

---

## 10. Лицензия

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

## 11. Контакты

- **GitHub**: [github.com/bylka2W](https://github.com/bylka2W)
- **Репозиторий**: [github.com/bylka2W/B-Plus](https://github.com/bylka2W/B-Plus)
- **GitVerse**: [gitverse.ru/bylka2W/B-Plus](https://gitverse.ru/bylka2W/B-Plus)
- **GitFlic**: [gitflic.ru/project/bylka2w/b-plus](https://gitflic.ru/project/bylka2w/b-plus)
- **Автор**: bylka2W

---

---

# B+ v4.6.1-beta — Compiled `.plan` / `.metal` Language (Frontend → HIR → BIR → MIR → Targets)

> [Russian version ↑](#b-v461-beta--compiled-plan--metal-language-frontend--hir--bir--mir--targets)

**B+** compiles `.plan` / `.metal` files directly to x64 machine code and packages them into Windows PE executables (.exe).
No assemblers, linkers, or LLVM — the entire code generator and optimizer are written from scratch in Zig.

### What's new in v4.6.1-beta

- **Frontend → HIR → BIR → MIR → Targets architecture** — full compiler migration to a
  multi-level architecture inspired by LLVM/rustc with strictly one-way dependency flow.
- **frontend / middle / backend split** — compiler source moved from flat `compiler/parser/`
  and `compiler/backend/bir/` into `compiler/frontend/`, `compiler/middle/bir/`,
  `compiler/backend/mir/`, `compiler/backend/targets/`.
- **BIR core module** — new `bir/core/` with typed `Module`, `Function`, `Block`, `Value`,
  `Instruction` and a `TypeSystem`.
- **BIR optimizer framework** — `bir/optimizer/` with `PassManager` and `PassResult` for
  building optimization pipelines.
- **BIR analysis** — `bir/analysis/` with `AnalysisManager` and `cfg.zig` (CFG construction).
- **MIR core module** — `mir/core/` with typed `MFunction`, `MBlock`, `MInst`, `MOperand`,
  `MOpcode`, `PhiInst`, `PhiIncoming`.
- **Targets abstraction** — `targets/common/` (shared target) and `targets/x64/` with
  instruction selection (`isel/`), encoder, frame manager, register allocator.
- **Critical edge fix** — fixed `testCriticalEdgePhi` hang: epilogue now emitted after each
  block ending with `ret`, preventing infinite loop when critical edge splitting places
  blocks after a return block.
- **9/9 BIR → MIR → x64 → execute E2E tests pass** (was 7/8).

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
   - [3.13 Parallel Blocks (parallel)](#313-parallel-blocks)
   - [3.14 Kernel Functions](#314-kernel-functions)
   - [3.15 External Functions (extern)](#315-external-functions-extern)
   - [3.16 Comments](#316-comments)
4. [`.metal` Syntax (New CPU Backend)](#4-metal-syntax-new-cpu-backend)
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
7. [BIR Optimizer — Benchmarks & Architecture](#7-bir-optimizer--benchmarks--architecture)
8. [Building from Source](#8-building-from-source)
9. [Project Structure](#9-project-structure)
10. [License](#10-license)
11. [Contact](#11-contact)

---

## 1. Quick Start

```bash
bpc.exe build hello.plan
.\hello.exe
```

The first command compiles `hello.plan` into `hello.exe`.
The second runs it.

Or combine both:

```bash
bpc.exe run hello.plan
```

---

## 2. Compiler Commands

### Syntax

```text
bpc build <input.plan>              — compile to <input>.exe
bpc build <input.plan> -o <out.exe> — compile with custom output name
bpc dll   <input.plan>              — compile to DLL
bpc run   <input.plan>              — compile and run immediately
bpc hlsl  <input.plan>              — generate HLSL shader code
```

#### `bpc build <input.plan> [-o <output.exe>]`

What it does:

| Step | Description |
|------|-------------|
| 1 | Reads the entire `.plan` file into memory |
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
bpc build traffic.plan              → traffic.exe
bpc build traffic.plan -o light.exe → light.exe
bpc build source.plan               → source.exe
```

#### `bpc hlsl <input.plan> [-o <output.hlsl>]`

Generates HLSL shader code from a B+ file using `@bind`, `@cbuffer`, `@groupshared` annotations.
Designed for authoring GPU compute shaders in B+ and compiling them via DXC or FXC.

| Step | Description |
|------|-------------|
| 1 | Reads the entire `.plan` file |
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
bpc hlsl fsr2_easu.plan -o fsr2_easu.hlsl
dxc -T cs_6_6 -E main -Fo fsr2_easu.cso fsr2_easu.hlsl
```

#### `bpc run <input.plan>`

What it does:

| Step | Description |
|------|-------------|
| 1 | Compiles `<input>.exe` |
| 2 | Runs the resulting `.exe` |
| 3 | Captures stdout and prints to console |
| 4 | Returns the program exit code |

**Examples:**
```bash
bpc run traffic.plan    — compiles and runs immediately
bpc run hello.plan      — compiles and runs immediately
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error: invalid args or file not found |
| >0 | Exit code of the compiled program (when using `run`) |

### Notes

- The input file **must** have a `.plan` extension.
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

## 4. `.metal` Syntax (New CPU Backend)

The new `.metal` syntax uses a direct MIR pipeline (no BIR, no state machine).
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
error[UnknownVariable]: test_error.metal:4:1
   4 |     print_i64(y);
       | ^
```

### 4.14 CLI

```text
bplus build <input.metal> [-o <output.exe>]
bplus run   <input.metal>
```

Pipeline: `.metal → parser → BIR (SSA) → mem2reg → cfgsimplify → SCCP → InstCombine → ConstantFolding → GVN → LICM → Unroll → DCE → lower to MIR → SSA destruction → addr_fold → copy propagation → DCE → peephole → linear scan RA → x64 → COFF .obj → zig build-exe → .exe`

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

## 7. BIR Optimizer — Benchmarks & Architecture

### Backend Architecture

The compiler backend follows an LLVM-like architecture:

```
BIR (SSA)  ──── MIR (Machine IR)  ──── x64 Machine Code
  │                    │                        │
  ├─ mem2reg           ├─ SSA destruction        ├─ Linear Scan RA
  ├─ cfgsimplify        ├─ addr_fold (LEA)        ├─ Frame Manager
  ├─ SCCP               ├─ copy propagation       ├─ Instruction Encoder
  ├─ InstCombine         ├─ DCE                    └─ COFF/PE
  ├─ ConstantFolding     └─ peephole
  ├─ GVN
  ├─ LICM
  ├─ Unroll
  └─ DCE
```

### BIR Optimization Pipeline

| Pass | Description |
|------|-------------|
| **mem2reg** | Promote memory to SSA registers |
| **cfgsimplify** | Control flow graph simplification |
| **SCCP** | Sparse conditional constant propagation |
| **InstCombine** | Algebraic identities, comparison folding |
| **ConstantFolding** | Constant expression evaluation, max/min |
| **GVN** | Global value numbering (CSE for commutative ops) |
| **LICM** | Loop-invariant code motion |
| **Unroll** | Short loop unrolling |
| **DCE** | Dead code elimination |

### MIR Optimization Pipeline

| Pass | Description |
|------|-------------|
| **SSA Destruction** | Replace phi with mov via CopyProp |
| **AddrFold** | LEA synthesis from address arithmetic [base+index*scale+disp] |
| **Copy Propagation** | Copy propagation (3 iterations) |
| **DCE** | Dead code elimination |
| **Peephole** | Constant folding, comparison optimization |

### Optimization Benchmarks

| Test | Without opts | With opts | Savings |
|------|-------------|-----------|---------|
| P1: Arithmetic chain (mul/div pow2, mul -1) | 91 B, 14 instrs | 51 B, 10 instrs | **44.0%** |
| P2: Dead branch (SCCP: if(true) → else) | 74 B, 8 instrs, 4 blocks | — 4 instrs, 2 blocks | branch eliminated |
| P3: Redundant CSE (5+3 computed 3×) | 74 B, 8 instrs | 26 B, 2 instrs | **64.9%** |
| P4: Stress (200 vregs, chain of adds) | 2026 B, 402 instrs | 26 B, 2 instrs | **98.7%** |
| P5: max/min constant folding | 107 B, 8 instrs | 26 B, 2 instrs | **75.7%** |

### E2E Tests

25 codegen E2E tests (BIR → MIR → x64 → execute):

- Integer arithmetic: add, sub, mul, div, neg, not, and/or/xor
- Branching: if/else, phi nodes
- Stress: 200 and 500 vregs, spills
- Strength reduction: mul→shl, div→shr, mul -1→neg
- SCCP: dead branches, constant folding
- InstCombine: double neg, add/sub cancellation
- Floating point: f32/f64 add, mul, sub, div, neg
- Conversions: int↔float, sext, zext, trunc
- min/max: CMOVcc (branchless)

---

## 8. Building from Source

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
bpc.exe run example.plan
```

---

## 9. Project Structure

### Compiler Architecture

```
Frontend (parser, AST, semantic analysis)
    │
    ▼
HIR (High-Level IR) — BIR SSA
    │  mem2reg → cfgsimplify → SCCP → InstCombine → ConstantFolding
    │  → GVN → Unroll → LICM → ForwardStoreToLoad → DeadStoreElimination → DCE
    ▼
MIR (Machine IR) — target-independent
    │  SSA Destroy → AddrFold → CopyProp → Peephole ×3 → DCE
    ▼
Targets (code generation)
    │  ISEL → RegAlloc → Encoding
    ▼
Object (PE/COFF → .exe)
```

### Source Tree

```text
src/
  main.zig                — entry point, CLI, orchestration
  bplus.zig               — CLI tool (bplus build/run)

  compiler/
    frontend/
      ast.zig             — AST node types (TypeId, AST structs)
      cppgen.zig          — C++ code generation from AST
      parser/
        ast.zig           — re-export ../ast.zig
        gpu_ast.zig       — re-export ../../gpu/frontend/gpu_ast.zig
        parser.zig        — lexer + parser for .plan
      sema/
        ast.zig           — re-export ../ast.zig
        scope.zig         — re-export resolver/scope.zig
        sema.zig          — semantic analysis
        resolver/
          scope.zig       — scope resolution (SymbolKind, scope resolution)
        symbols/
          symbol.zig      — symbol types (SymbolKind: code, ...)

    middle/
      bir/
        bir.zig           — public BIR API; re-export core/
        bir_analysis.zig  — re-export analysis/manager.zig
        bir_alias.zig     — alias analysis (AliasResult: NoAlias, ...)
        bir_backend.zig   — re-export bir, bir_types, bir_cfg, bir_loops, ...
        bir_bplus_frontend.zig — B+ language frontend to BIR (imports frontend/ast)
        bir_cfg.zig       — re-export analysis/cfg/cfg.zig
        bir_cfgsimplify.zig — CFG simplification pass
        bir_cpu.zig       — CPU target lowering (BIR → MIR)
        bir_dominators.zig — dominator tree computation
        bir_frontend.zig  — GPU frontend to BIR
        bir_hlsl.zig      — BIR to HLSL
        bir_ivopt.zig     — induction variable optimization
        bir_licm.zig      — loop-invariant code motion
        bir_loops.zig     — loop analysis
        bir_loop_rotate.zig — loop rotation transform
        bir_lower.zig     — BIR lowering (imports pipeline_gen)
        bir_mem2reg.zig   — memory to register promotion (SSA)
        bir_memory_ssa.zig — Memory SSA construction
        bir_passes.zig    — BIR pass infrastructure
        bir_sccp.zig      — SCCP (sparse conditional constant propagation)
        bir_types.zig     — re-export core/types.zig
        bir_unroll.zig    — loop unrolling
        bir_verify.zig    — BIR verification/validation
        core/
          block.zig       — basic block definition (BlockId)
          function.zig    — function representation
          instruction.zig — BIR instruction definitions
          module.zig      — module container
          types.zig       — BIR type system (TypeId)
          value.zig       — value types (ValueId, BlockId, FunctionId)
        optimizer/
          pass_manager.zig — optimization pass manager
          pass_types.zig  — pass/analysis identifiers (AnalysisKind bitmask)
        analysis/
          manager.zig     — analysis manager (caches CFG, dominators, loops)
          cfg/
            cfg.zig       — control-flow graph construction

    backend/
      backend.zig          — backend module root (re-export bir, mir, targets, object)
      mir/
        mir.zig            — public MIR API
        mir_backend.zig    — re-export mir, mir_verify, mir_optimizer, ...
        mir_addr_fold.zig  — AddrFold (LEA synthesis from address arithmetic)
        mir_copy_prop.zig  — copy propagation pass
        mir_dce.zig        — dead code elimination
        mir_optimizer.zig  — MIR optimization pipeline (orchestrates DCE, peephole, SSA destroy)
        mir_peephole.zig   — peephole optimizations
        mir_ssa_destroy.zig — SSA destruction (phi elimination)
        mir_verify.zig     — MIR verification
        mir_x64.zig        — legacy wrapper → targets/x64/lowering.zig
        pipeline_gen.zig   — render pipeline generation
        sizes.zig          — D3D12 struct size utility
        core/
          mir.zig          — MIR core: target-independent types
          function.zig     — MIR function representation
          opcode.zig       — MIR opcodes (MovInst, etc.)
          operand.zig      — MIR operand types (MOperand, PhysReg, CondCode)
          value.zig        — MIR data types (DataType enum: void, i1, i8, ...)

      targets/
        common/
          target.zig       — target-independent types (RegAllocResult)
        x64/
          x64_backend.zig  — x64 backend entry point (MIR → x86-64 pipeline)
          x64enc.zig       — x64 instruction encoding
          x64gen.zig       — x64 code generator
          abi.zig          — ABI constants (frame_size, shadow_size)
          branches.zig     — branch encoding helpers
          codebuffer.zig   — code buffer with label fixups (LabelId)
          debug.zig        — debug/trace utilities for x64
          encoder.zig      — re-export x64enc.zig
          frame.zig        — stack frame layout (Abi: win64, ...)
          isel.zig         — instruction selection orchestration
          layout.zig       — slot layout for locals (SlotKind enum)
          lowering.zig     — x64 lowering orchestrator (regalloc → isel → encode)
          memory.zig       — addressing mode helpers (base + displacement)
          peephole.zig     — x64-specific peephole optimizations
          regalloc.zig     — register allocation
          registers.zig    — x64 register enum (X64Reg)
          ir/
            inst.zig       — x64 IR instruction types
          isel/
            context.zig    — shared context for ISEL sub-modules
            control.zig    — control-flow ISEL (branch/call/ret/select)
            conversions.zig — type conversion ISEL (sext/zext/trunc/sitofp/...)
            float.zig      — floating-point ISEL (SSE scalar)
            integer.zig    — integer arithmetic ISEL
            memory.zig     — memory access ISEL (load/store/lea/alloca)

      object/
        pe/
          pe.zig           — PE (.exe/.dll) generator
        coff/
          coff.zig         — COFF object file writer

    gpu/
      dxil_backend.zig     — DXIL backend
      dxil_bitcode.zig     — LLVM bitstream writer (DXIL format)
      gpu_cpp.zig          — C++ UE shader class generation from GPU IR
      gpu_dxil.zig         — GPU IR → DXIL code generation
      gpu_hlsl.zig         — GPU IR → HLSL code generation
      gpu_ir.zig           — GPU intermediate representation (ValueId)
      gpu_lower.zig        — GPU AST → IR lowering
      gpu_types.zig        — GPU runtime types (ResourceId, DispatchGrid, ...)
      shader_backend.zig   — shader backend dispatcher (IrModule, CompileOptions)
      frontend/
        ast.zig            — re-export gpu_ast.zig
        gpu_ast.zig        — GPU AST (ResourceKind: texture2d, ...)
        gpu_body_parser.zig — GPU shader body parser (1784 lines)
        gpu_sema.zig       — GPU semantic analysis (Severity: error, warning)
        hlslgen.zig        — HLSL code generation from GPU AST

    runtime/
      runtime.zig          — re-export ../../runtime/runtime.zig

  runtime/
    runtime.zig            — main runtime (Panic Runtime, Windows OS layer)
    bplusrt.zig            — B+ runtime (kernel32, print_i64, ...)
    cpu.zig                — CPU detection/utilities (Windows API)
    latency.zig            — latency modeling (HT_COST_NS, CORE_COST_NS)
    scheduler.zig          — core task scheduler (CPU/GPU)
    scheduler_config.zig   — scheduler configuration
    scheduler_state.zig    — scheduler state (DecisionOverride enum)
    cost_scheduler.zig     — cost-based GPU scheduler
    gpu_scheduler.zig      — GPU pass scheduler (ResolvedPass)
    gpu_job.zig            — GPU job definition (GPUJob)
    frame.zig              — frame management (Stage: upsample, sharpen, temporal)
    bench.zig              — benchmarking harness

  render/
    frame_graph.zig        — FrameGraph (per-resource history validity)
    compiled_graph.zig     — compiled render graph
    frame_graph_executor.zig — frame graph execution engine
    frame_runtime.zig      — frame runtime (D3D12 + scheduler)
    resource_system.zig    — GPU resource management (textures, buffers)
    root_signature_builder.zig — D3D12 root signature builder
    render_graph.zig       — high-level render graph
    render_helpers.zig     — utility: dispatch2D grid calculation
    camera_jitter.zig      — Halton sequence camera jitter (TAA)
    d3d12_bindings.zig     — D3D12 API bindings (HRESULT, GUID, ...)
    dx12_compute.zig       — DX12 compute dispatch utilities
    history_manager.zig    — ring-buffer frame history (TAA)
    lifetime_graph.zig     — resource lifetime graph
    barrier_optimizer.zig  — resource barrier optimizer
    temporal_history.zig   — temporal frame confidence scoring
    temporal_pipeline.zig  — temporal upscaling pipeline
    gpu_execution.zig      — GPU execution recording
    gpu_executor.zig       — GPU executor orchestration
    fsr3_runtime.zig       — FSR 3 frame generation runtime

  platform/
    linux/                  — (stub)
    macos/                  — (stub)
    shared/                 — (stub)
    windows/                — (stub)

  tools/
    test_runner/
      test_runner.zig       — test runner (imports parser, x64gen, pe)
```

### E2E Tests

BIR → MIR → x64 → execute: **9/9 PASS** + 25 E2E tests covering integer arithmetic,
floating-point arithmetic, conversions, min/max (CMOVcc), strength reduction, stress tests (200/500 vreg).

---

## 10. License

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

## 11. Contact

- **GitHub**: [github.com/bylka2W](https://github.com/bylka2W)
- **Repository**: [github.com/bylka2W/B-Plus](https://github.com/bylka2W/B-Plus)
- **GitVerse**: [gitverse.ru/bylka2W/B-Plus](https://gitverse.ru/bylka2W/B-Plus)
- **GitFlic**: [gitflic.ru/project/bylka2w/b-plus](https://gitflic.ru/project/bylka2w/b-plus)
- **Author**: bylka2W
