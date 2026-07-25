# B+ v4.6.2-beta — Compiled `.plan` / `.metal` Language (Frontend → HIR → BIR → MIR → Targets)

> [English version ↓](#b-v461-beta--compiled-plan--metal-language-frontend--hir--bir--mir--targets)

**B+** компилирует `.plan` / `.metal` файлы напрямую в машинный код x64 и упаковывает в Windows PE (.exe/.dll).
Никаких ассемблеров, линкеров, LLVM — весь кодогенератор и оптимизатор написаны с нуля на Zig.

### Что нового в v4.6.2-beta

- Новая архитектура: Frontend → HIR → BIR → MIR → Targets
- Разделение слоёв: frontend / middle(BIR) / backend(MIR) / targets
- Новый BIR Core: типизированные Module, Function, Block, Value, Instruction, TypeSystem
- BIR Optimizer и Analysis: PassManager, CFG, AnalysisManager
- Новый MIR Core: MFunction, MBlock, MInst, Operand, Opcode, Phi
- Target Backend: common + x64 (ISel, encoder, frame manager, regalloc)
- Рефакторинг MIR: CMP/SETCC, 4-operand IDiv, новый Ret, CondCode для FCmp
- Исправлены critical edge, Phi lowering и проблемы vreg
- Полный pipeline: BIR → MIR → x64 → executable
- Парсер теперь syntax-only: убран Dialect из парсера, валидация домена перенесена на этап HIR
- AST реорганизован: `ProgramNode { common, plan, metal }` — общие конструкции, план и метал отдельно
- Единый файл `.b+` для обоих доменов (ранее `.plan` / `.metal` отдельно)
- Слой Frontend: парсер не знает о доменах, принимает весь синтаксис, валидация на HIR
- Слой Middle (BIR): верификатор разбит на 7 модулей (verify/cfg, verify/ssa, verify/phi, verify/function, verify/types, verify/memory, verify/instructions), CFG строится из терминаторов на лету
- Слой Backend (MIR): CMP_FLAGS+SETCC, 4-operand IDiv, Ret как union, CondCode для FCmp
- Слой Targets: common + x64 (ISel, encoder, frame manager, regalloc)
- BIR Verifier: модульная система верификации из 7 модулей (CFG, SSA, phi, функции, типы, память, инструкции)
- Структурированная диагностика: коды ошибок, контекст инструкций, список ошибок для интеграции с тулами
- CFG bounds checking: некорректные адреса переходов ловятся вместо panic
- SSA verification: тесты на use-before-def и нарушение доминантности
- Исправлены E2E тесты верификатора: правильный порядок инструкций (терминатор последний), phi incoming через alloc.dupe
- Исправлен buildCFG: проверка границ перед доступом к блокам по индексу

---

## Что такое B+

**B+** — это язык программирования, который превращает написанный код прямо в готовую программу для Windows (.exe или .dll).
В отличие от многих языков, B+ не использует внешние компиляторы или линкеры — весь процесс сборки выполняет собственный компилятор.

Код B+ хранится в файлах с расширением: `example.b+`

В B+ есть два основных режима программирования:

### PLAN — описание логики состояний

PLAN нужен, когда программа должна работать как набор состояний и переключаться между ними по событиям.

Например:
- меню игры
- состояния персонажа
- игровые режимы
- сетевые протоколы
- обработчики событий

```rust
state Locked {
    on open [key == 1] -> Opened
    entry {
        print("locked\n")
    }
}

state Opened {
    on close -> Locked
    entry {
        print("opened\n")
    }
}
```

Что здесь происходит:
- Программа начинает в состоянии `Locked`
- Если приходит событие `open` и есть ключ (`key == 1`) — переходит в `Opened`
- При входе в состояние выполняется код внутри `entry`

### METAL — обычное программирование

METAL предназначен для создания обычного кода:
- функций
- алгоритмов
- вычислений
- работы с памятью
- низкоуровневых систем

```rust
fn fibonacci(n: i64) -> i64 {
    if n <= 1 {
        return n;
    }

    return fibonacci(n - 1) + fibonacci(n - 2);
}
```

Этот код создаёт функцию вычисления чисел Фибоначчи.

### Один язык — два подхода

PLAN и METAL используют один синтаксис B+, но предназначены для разных задач:

| Режим | Назначение |
|-------|------------|
| PLAN | логика состояний и событий |
| METAL | алгоритмы и системный код |

Компилятор сам определяет, к какому режиму относится код.

B+ объединяет простоту языков высокого уровня с контролем системного программирования, позволяя создавать как игровую логику, так и низкоуровневые программы.

Самый простой способ проверить, что компилятор работает:

1. Создайте или возьмите любой файл B+, например:

```
hello.b+
```

2. Перетащите файл **`hello.b+`** мышкой прямо на **`bpc.bat`**.

3. Компилятор автоматически:
   - скомпилирует программу;
   - создаст рядом файл **`hello.exe`**;
   - сразу запустит его.

Если после перетаскивания появился `hello.exe` и программа выполнилась — значит компилятор установлен и работает правильно.

---

## Содержание

1. [Быстрый старт](#1-быстрый-старт)
2. [Команды компилятора](#2-команды-компилятора)
3. [Синтаксис языка (.b+)](#3-синтаксис-языка)
   - [3.1 Состояния](#31-состояния)
   - [3.2 Переходы (on)](#32-переходы-on)
   - [3.3 Безусловные переходы (always)](#33-безусловные-переходы-always)
   - [3.4 Вход (entry)](#34-вход-entry)
   - [3.5 Переменные](#35-переменные)
   - [3.6 Присваивания](#36-присваивания)
   - [3.7 Печать (print)](#37-печать-print)
   - [3.8 Export entry](#38-export-entry)
   - [3.9 Entry point](#39-entry-point)
   - [3.10 Перечисления (enum)](#310-перечисления-enum)
   - [3.11 Комментарии](#311-комментарии)
4. [Синтаксис METAL](#4-синтаксис-metal)
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

Перетащи файл `.b+` на `bpc.bat` — скомпилирует в `.exe` и запустит.

Или через консоль:
```bash
zig\zig-out\bin\bpc.exe run hello.b+
```

### Самый простой способ проверить, что компилятор работает

1. Создайте файл `hello.b+` в папке `C:\B-Plus`:

```
state Hello {
    entry { print("Hello World!\n") }
}
```

2. Перетащите файл **`hello.b+`** мышкой прямо на **`bpc.bat`**.

3. Компилятор автоматически:
   - скомпилирует программу;
   - создаст рядом файл **`hello.exe`**;
   - сразу запустит его.

Если после перетаскивания появился `hello.exe` и программа выполнилась — значит компилятор установлен и работает правильно.

---

## 2. Команды компилятора

### Синтаксис

```text
bpc run   <входной.b+>              — скомпилировать и сразу запустить
bpc dll   <входной.b+>              — скомпилировать в DLL
bpc build <входной.b+> [-o <каталог>] — сгенерировать C++ UE5 плагин (6 файлов)
bpc hlsl  <входной.b+>              — сгенерировать HLSL шейдер
bpc gpu   <входной.b+>              — сгенерировать DXIL
bpc cpp   <входной.b+>              — сгенерировать C++ код
bpc mir   <входной.b+>              — сгенерировать COFF .obj
bpc bpl   <входной.b+>              — понизить B+ до BIR и вывести
bpc ir    <входной.b+>              — вывести BIR pipeline
bpc cfg   <входной.b+>              — вывести граф потока управления
bpc dom   <входной.b+>              — вывести дерево доминирования
bpc loops <входной.b+>              — вывести иерархию циклов
bpc test  <тест.bpt>                — запустить тест
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

#### `bpc build <input.b+> [-o <output_dir>]`

Генерирует C++ UE5 плагин из B+ файла с описанием pipeline (6 файлов).

| Шаг | Описание |
|-----|----------|
| 1 | Читает файл `.b+` целиком в память |
| 2 | Разбирает описание pipeline |
| 3 | Генерирует TSSShaders.h / TSSShaders.cpp |
| 4 | Генерирует TSSRuntime.h / TSSRuntime.cpp |
| 5 | Генерирует TSSViewExtension.h / TSSViewExtension.cpp |
| 6 | Записывает 6 файлов в выходной каталог |

Если `-o` не указан, файлы записываются в каталог исходного файла.

**Примеры:**
```bash
bpc build pipeline.b+               → 6 C++ файлов рядом с pipeline.b+
bpc build pipeline.b+ -o ./Plugin   → 6 C++ файлов в ./Plugin
```

#### `bpc gpu <input.b+> [-o <output>]` / `bpc hlsl <input.b+> [-o <output.hlsl>]`

Генерирует HLSL-код из B+ файла с блочным `kernel { ... }` синтаксисом
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

- Компилятор **не использует** внешние ассемблеры, линкеры или LLVM — весь машинный код генерируется самостоятельно.
- Команда `bpc run` компилирует в `.exe` и сразу запускает.
- Команда `bpc build` генерирует C++ UE5 плагин (а не .exe).

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

### 3.4 Вход (entry)

```rust
state Door {
    entry { print("entered\n") }
    on open -> Opened
}
```

`entry { ... }` — выполняется при входе в состояние.

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

### 3.9 export entry

```rust
export entry <Имя> {
    ...
}
```

Экспортируемая точка входа — компилируется как функция, видимая извне DLL.
Используется при сборке DLL (`bpc dll`) вместе с флагом `-exports`.

```rust
export entry TSS_Init {
    print("init\n")
}
```

### 3.9 Entry point

```rust
entry <Имя> {
    ...
}
```

Точка входа — выполняется один раз при старте программы.

```rust
entry main {
    print("Starting...\n")
}
```

### 3.11 Перечисления (enum)

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

### 3.11 Комментарии

```rust
// однострочный комментарий
-- тоже комментарий
```

---

## 4. Синтаксис METAL

METAL — это второй домен B+ (наряду с PLAN). Используется для функций, переменных, структур, указателей, `if`/`while`/`for`, составных присваиваний.

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
error[UnknownVariable]: test_error.b+:4:1
   4 |     print_i64(y);
       | ^
```

### 4.14 CLI

```text
bpc run   <input.b+> [-o <output.exe>]
bpc mir   <input.b+> [-o <output.obj>]
```

```
                      B+ Source (.b+)
                              │
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
         PLAN Domain                    METAL Domain
              │                               │
              └───────────────┬───────────────┘
                              ▼
                           Parser
                              │
                              ▼
                             AST
                              │
                              ▼
                             HIR
                              │
                              ▼
                         BIR (SSA)
                              │
        mem2reg → CFG → SCCP → InstCombine
        → Constant Folding → GVN → LICM
        → Loop Unroll → DCE
                              │
                              ▼
                             MIR
                              │
        SSA Destroy → AddrFold → CopyProp
        → Peephole → DCE
                              │
                              ▼
                       x64 Backend
                              │
                 ┌────────────┴────────────┐
                 ▼                         ▼
         PE (.exe / .dll)            COFF (.obj)
```

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

### Светофор

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

Ввод: `timer\n` переключает состояния.

### Счётчик

```rust
state Count {
    var n: int = 0
    on inc -> Self { n += 1 }
    on show -> Show
}

state Show {
    always -> Count
    entry { print("n="); print("?\n") }
}
```

### Охраняемый переход

```rust
state Door {
    on open [key == 1] -> Opened
    entry { print("locked\n") }
}

state Opened {
    on close -> Door
    entry { print("opened\n") }
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
bpc.exe run example.b+
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
- **GitLab**: [gitlab.com/bylka2W/b-plus](https://gitlab.com/bylka2W/b-plus)
- **Автор**: bylka2W

---

---

# B+ v4.6.2-beta — Compiled `.b+` Language (Frontend → HIR → BIR → MIR → Targets)

**B+** compiles `.b+` files directly to x64 machine code and packages them into Windows PE executables (.exe/.dll).
No assemblers, linkers, or LLVM — the entire code generator and optimizer are written from scratch in Zig.

### What's new in v4.6.2-beta

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
- **MIR instruction model refactoring** — CMP_FLAGS + SETCC: `CmpInst` no longer writes a
  destination (FLAGS-only); new `SetCCInst` materializes the comparison result into a vreg.
  `IDivInst` is now 4-operand (dividend, divisor, quotient, remainder). `RetInst` is a
  union (void/value). `FCmpInst` uses `CondCode` enum instead of raw `u8`.
- **Safe defaults for unregistered vregs** — all `orelse unreachable` in x64 ISel replaced
  with safe defaults (`.gpr` / `.i64`), preventing panics when vreg registration is
  missing.
- **9/9 BIR → MIR → x64 → execute E2E tests pass** (was 7/8).
- **BIR Verifier overhaul** — modular verification system with 7 specialized verifier modules
  (CFG correctness, SSA form, phi nodes, function invariants, type checking, memory safety,
  instruction validity).
- **Structured diagnostics** — error codes, per-instruction context, structured error lists
  for tooling integration.
- **CFG bounds checking** — out-of-range branch targets are now caught and reported instead
  of panicking.
- **SSA verification** — tests for use-before-def detection and dominance violation detection.
- **Verifier E2E test fixes** — correct instruction ordering (terminator must be last), phi
  incoming slices use `alloc.dupe`, return values use phi.
- **buildCFG bounds check** — CFG construction validates block indices before access.
- **Parser is now syntax-only** — `Dialect` removed from parser; domain validation moved to HIR lowering stage.
- **AST restructured** — `ProgramNode { common, plan, metal }` separating shared constructs from domain-specific ones.
- **Unified `.b+` extension** for both domains (previously separate `.plan` / `.metal`).
- **Frontend layer** — parser is domain-agnostic, accepts all syntax, validation happens at HIR.
- **Middle layer (BIR)** — verifier split into 7 modules under `verify/` directory (cfg, ssa, phi, function, types, memory, instructions); CFG built on-demand from terminators.
- **Backend layer (MIR)** — CMP_FLAGS+SETCC, 4-operand IDiv, Ret as union, CondCode for FCmp.
- **Targets layer** — common + x64 (ISel, encoder, frame manager, regalloc).

---

## What is B+

**B+** is a programming language that turns written code directly into a ready Windows program (.exe or .dll).
Unlike many languages, B+ doesn't use external compilers or linkers — the entire build process is handled by its own compiler.

B+ code is stored in files with the extension: `example.b+`

B+ has two main programming modes:

### PLAN — state logic description

PLAN is used when a program should work as a set of states and switch between them by events.

For example:
- game menus
- character states
- game modes
- network protocols
- event handlers

```rust
state Locked {
    on open [key == 1] -> Opened
    entry {
        print("locked\n")
    }
}

state Opened {
    on close -> Locked
    entry {
        print("opened\n")
    }
}
```

What happens here:
- The program starts in state `Locked`
- If event `open` arrives and there is a key (`key == 1`) — transitions to `Opened`
- When entering a state, the code inside `entry` is executed

### METAL — regular programming

METAL is designed for writing regular code:
- functions
- algorithms
- computations
- memory management
- low-level systems

```rust
fn fibonacci(n: i64) -> i64 {
    if n <= 1 {
        return n;
    }

    return fibonacci(n - 1) + fibonacci(n - 2);
}
```

This code creates a Fibonacci number calculation function.

### One language — two approaches

PLAN and METAL use the same B+ syntax but are designed for different tasks:

| Mode | Purpose |
|------|---------|
| PLAN | state and event logic |
| METAL | algorithms and systems code |

The compiler determines automatically which mode the code belongs to.

B+ combines the simplicity of high-level languages with the control of systems programming, allowing you to create both game logic and low-level programs.

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Compiler Commands](#2-compiler-commands)
3. [Language Syntax](#3-language-syntax)
   - [3.1 States](#31-states)
   - [3.2 Transitions (on)](#32-transitions-on)
   - [3.3 Unconditional Transitions (always)](#33-unconditional-transitions-always)
   - [3.4 Entry (entry)](#34-entry-entry)
   - [3.5 Variables](#35-variables)
   - [3.6 Assignments](#36-assignments)
   - [3.7 Print (print)](#37-print-print)
   - [3.8 Export entry](#38-export-entry)
   - [3.9 Entry point](#39-entry-point)
   - [3.10 Enums (enum)](#310-enums-enum)
   - [3.11 Comments](#311-comments)
4. [METAL Syntax (New CPU Backend)](#4-metal-syntax-new-cpu-backend)
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

Drag a `.b+` file onto `bpc.bat` — it compiles to `.exe` and runs it.

Or from the command line:
```bash
zig\zig-out\bin\bpc.exe run hello.b+
```

### Quick verification that the compiler works

1. Create a file `hello.b+` in the `C:\B-Plus` folder:

```
state Hello {
    entry { print("Hello World!\n") }
}
```

2. Drag the **`hello.b+`** file onto **`bpc.bat`**.

3. The compiler will automatically:
   - compile the program;
   - create a **`hello.exe`** file next to it;
   - run it immediately.

If `hello.exe` appeared and the program ran — the compiler is installed and working correctly.

---

## 2. Compiler Commands

### Syntax

```text
bpc run   <input.b+>              — compile and run immediately
bpc dll   <input.b+>              — compile to DLL
bpc build <input.b+> [-o <dir>]   — generate C++ UE5 plugin (6 files)
bpc hlsl  <input.b+>              — generate HLSL shader code
bpc gpu   <input.b+>              — generate DXIL
bpc cpp   <input.b+>              — generate C++ code
bpc mir   <input.b+>              — generate COFF .obj
bpc bpl   <input.b+>              — lower B+ to BIR and dump
bpc ir    <input.b+>              — dump BIR pipeline
bpc cfg   <input.b+>              — dump control flow graph
bpc dom   <input.b+>              — dump dominator tree
bpc loops <input.b+>              — dump loop hierarchy
bpc test  <test.bpt>              — run test
```

#### `bpc build <input.b+> [-o <output_dir>]`

Generates a C++ UE5 plugin from a B+ file with pipeline description (6 files).

| Step | Description |
|------|-------------|
| 1 | Reads the entire `.b+` file into memory |
| 2 | Parses pipeline description |
| 3 | Generates TSSShaders.h / TSSShaders.cpp |
| 4 | Generates TSSRuntime.h / TSSRuntime.cpp |
| 5 | Generates TSSViewExtension.h / TSSViewExtension.cpp |
| 6 | Writes 6 files to output directory |

If `-o` is omitted, files are written next to the input file.

**Examples:**
```bash
bpc build pipeline.b+               → 6 C++ files next to pipeline.b+
bpc build pipeline.b+ -o ./Plugin   → 6 C++ files in ./Plugin
```

#### `bpc gpu <input.b+> [-o <output>]` / `bpc hlsl <input.b+> [-o <output.hlsl>]`

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

- The compiler does **not** use external assemblers, linkers, or LLVM — all machine code is self-generated.
- `bpc run` compiles to `.exe` and runs it immediately.
- `bpc build` generates a C++ UE5 plugin (not an .exe).

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

### 3.4 Entry (entry)

```rust
state Door {
    entry { print("entered\n") }
    on open -> Opened
}
```

`entry { ... }` — executed when entering the state.

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

### 3.8 Export entry

```rust
export entry <Name> {
    ...
}
```

An exported entry point — compiled as a function visible from outside the DLL.
Used when building DLLs (`bpc dll`) with the `-exports` flag.

```rust
export entry TSS_Init {
    print("init\n")
}
```

### 3.9 Entry point

```rust
entry <Name> {
    ...
}
```

An entry point — executed once at program startup.

```rust
entry main {
    print("Starting...\n")
}
```

### 3.10 Enums (enum)

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

### 3.11 Comments

```rust
// single-line comment
-- also a comment
```

---

## 4. METAL Syntax

METAL is the second B+ domain (alongside PLAN). Used for functions, variables, structs, pointers, `if`/`while`/`for`, compound assignment.

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
error[UnknownVariable]: test_error.b+:4:1
   4 |     print_i64(y);
       | ^
```

### 4.14 CLI

```text
bpc run   <input.b+> [-o <output.exe>]
bpc mir   <input.b+> [-o <output.obj>]
```

```
                      B+ Source (.b+)
                              │
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
         PLAN Domain                    METAL Domain
              │                               │
              └───────────────┬───────────────┘
                              ▼
                           Parser
                              │
                              ▼
                             AST
                              │
                              ▼
                             HIR
                              │
                              ▼
                         BIR (SSA)
                              │
        mem2reg → CFG → SCCP → InstCombine
        → Constant Folding → GVN → LICM
        → Loop Unroll → DCE
                              │
                              ▼
                             MIR
                              │
        SSA Destroy → AddrFold → CopyProp
        → Peephole → DCE
                              │
                              ▼
                       x64 Backend
                              │
                 ┌────────────┴────────────┐
                 ▼                         ▼
         PE (.exe / .dll)            COFF (.obj)
```

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
state Count {
    var n: int = 0
    on inc -> Self { n += 1 }
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
bpc.exe run example.b+
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

The compiler source is organized into four layers:

- **Frontend** (`compiler/frontend/`) — parser, AST, semantic analysis
- **Middle** (`compiler/middle/bir/`) — BIR core, optimizer, analysis, verification
- **Backend** (`compiler/backend/mir/`, `targets/`) — MIR optimization, x64 code generation
- **GPU** (`compiler/gpu/`) — GPU shader compilation (HLSL, DXIL)

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
- **GitLab**: [gitlab.com/bylka2W/b-plus](https://gitlab.com/bylka2W/b-plus)
- **Author**: bylka2W
