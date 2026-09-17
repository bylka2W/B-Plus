# B+ v4.6.5-alfa — Compiled `.plan` / `.metal` Language (Frontend → HIR → BIR → MIR → Targets)

> [!NOTE]
> Все примеры кода ниже — это **язык B+** (расширение `.b+`), а не Rust.
> Блоки помечены `rust` только для подсветки синтаксиса на GitHub/в редакторах.

> [English version ↓]((#b-v464-beta--compiled-b-language-frontend--hir--bir--mir--targets))

> 📖 [docs.html — наглядная документация](https://htmlpreview.github.io/?https://github.com/bylka2W/B-Plus/blob/main/html/docs.html)

**B+** компилирует файлы `.b+` (принимаются также `.plan` / `.metal`) напрямую в машинный код x64 и упаковывает в Windows PE (.exe/.dll).
Кодогенератор, IR-оптимизаторы и упаковщик PE написаны с нуля на Zig. Для финальной линковки PE используется `lld-link.exe` (из LLVM).
> Лабораторные тесты компилятора: `zig\tests\B+\.b\sources\` — 262 теста, из них ~259 проходят.

---

## Что такое B+

**B+** — это язык программирования, который превращает написанный код прямо в готовую программу для Windows (.exe или .dll).
Компилятор B+ полностью сам генерирует машинный код, оптимизирует IR и собирает PE; на финальном шаге для линковки вызывается `lld-link.exe`.

Код B+ хранится в файлах с расширением: `example.b+`

В B+ есть два домена синтаксиса:

### PLAN — описание логики состояний

PLAN — состояние/событийный домен. **В текущей версии компилятора `state`-блоки, `entry`/`exit`/`on` не исполняются в рантайме**: весь код запускается из `fn main()`. Домен PLAN документируется исторически и будет включён в следующих версиях.

```rust
fn main() {
    print("PLAN-код запускается из fn main()\n")
}
```

### METAL — обычное программирование

METAL предназначен для создания обычного кода:
- функций
- алгоритмов
- вычислений
- работы с памятью
- низкоуровневых систем

```rust
fn fibonacci(n)
{
    if n <= 1
    {
        return n
    }
    return fibonacci(n - 1) + fibonacci(n - 2)
}

fn main()
{
    print(fibonacci(7))  // 13
}
```

Этот код создаёт функцию вычисления чисел Фибоначчи.
> Проверено: рекурсия компилируется без аннотаций типов (`-> i64` на возврате даёт ошибку).

### Один язык — два подхода

| Режим | Назначение | Статус |
|-------|------------|--------|
| PLAN | логика состояний и событий | парсится, не исполняется |
| METAL | алгоритмы и системный код | работает |

Компилятор сам определяет, к какому режиму относится код.

B+ объединяет простоту языков высокого уровня с контролем системного программирования, позволяя создавать как алгоритмы, так и низкоуровневые программы.

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
   - [3.1 Функции и точка входа](#31-функции-и-точка-входа)
   - [3.2 Переменные](#32-переменные)
   - [3.3 Присваивания](#33-присваивания)
   - [3.4 Печать (print)](#34-печать-print)
   - [3.5 If / else](#35-if--else)
   - [3.6 Циклы](#36-циклы)
   - [3.7 Структуры](#37-структуры)
   - [3.8 Перечисления (enum)](#38-перечисления-enum)
   - [3.9 Константы (const)](#39-константы-const)
   - [3.10 Выражения match](#310-выражения-match)
   - [3.11 Import](#311-import)
   - [3.12 Рекурсия](#312-рекурсия)
   - [3.13 Комментарии](#313-комментарии)
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
fn main() {
    print("Hello World!\n")
}
```

> **Важно:** единственная работающая точка входа — `fn main()`. Форма `state Hello { entry { print(...) } }` **не собирается** (ошибка линковки `undefined symbol: main`); `state`-блоки также не исполняются в рантайме текущей версии — весь код запускается из `fn main`.

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
bpc run    <входной.b+>              — скомпилировать и сразу запустить
bpc dll    <входной.b+> [-o <out.dll>] [-exports <имя1,имя2,...>]  — скомпилировать в DLL
bpc check  <входной.b+>              — проверить код без создания exe (PASS/FAIL)
bpc hlsl   <входной.b+> [-o <out.hlsl>] — сгенерировать HLSL шейдер
bpc mir    <входной.b+>              — сгенерировать COFF .obj
bpc bpl    <входной.b+>              — понизить B+ до BIR и вывести
bpc ir     <входной.b+>              — вывести BIR pipeline
bpc cfg    <входной.b+>              — вывести граф потока управления
bpc dom    <входной.b+>              — вывести дерево доминирования
bpc loops  <входной.b+>              — вывести иерархию циклов
bpc link   <входной.obj> -o <out.exe> — слинковать .obj в .exe
bpc test   <тест.bpt>                 — запустить тест
bpc doctor                            — диагностика компилятора (Runtime/Linker/Parser/HIR/THIR/BIR/MIR/x64)
```

> Проверено: `run`, `dll`, `check`, `mir`, `bpl`, `link`, `doctor` работают.
> `ir`/`cfg`/`dom`/`loops`/`hlsl` на обычном файле с `fn main` выдают `VERIFY: block_has_no_terminator` — ждут pipeline/kernel-вход (см. разделы HLSL/IR).

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

#### `bpc hlsl <input.b+> [-o <output.hlsl>]`

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

#### `bpc check <input.b+>`

Проверяет программу через все верифицируемые слои компилятора (Parser → HIR → THIR → BIR → MIR → x64) без кодогенерации. Выводит `PASS` для каждого слоя.

```bash
bpc check hello.b+    — проверить программу, не компилируя
```

Код возврата: `0` — все слои проверены, `1` — ошибка (указывается слой).

#### `bpc doctor`

Health-check компилятора: наличие встроенного рантайма (`minrt.obj`), наличие линкера (`lld-link`), прогон встроенной программы через полный верифицируемый pipeline.

```bash
bpc doctor            — проверка здоровья компилятора
```

### Коды возврата

| Код | Значение |
|-----|----------|
| 0 | Успех |
| 1 | Ошибка: неверные аргументы или файл не найден |
| >0 | Код завершения скомпилированной программы (при использовании `run`) |

### Примечания

- Компилятор **сам** генерирует весь машинный код x64 (без ассемблеров и внешнего кодогенератора); для линковки PE-файла используется `lld-link.exe`.
- Команда `bpc run` компилирует в `.exe` и сразу запускает. Перед пересборкой компилятор сам завершает зависший старый `.exe`, чтобы не было `permission denied`.

---

## 3. Синтаксис языка

> **Проверено на реальном компиляторе:** единственная точка входа — `fn main()`.
> `state`-блоки парсятся, но `entry`/`exit`/`on`-блоки **не исполняются** текущей версией — весь вывод идёт из `fn main`, поэтому в примерах используется только функции.

### 3.1 Функции и точка входа

```rust
fn main() {
    print("Hello\n")
}
```

Функции объявляются через `fn <имя>(<параметры>)`. Можно с типами параметров и возврата:

```rust
fn add(a: i64, b: i64) -> i64 {
    return a + b
}
```

Значением последнего выражения можно не пользоваться — `return` явный.

Рекурсия работает (см. `Control flow`, `Functions` тесты).

### 3.2 Переменные

```rust
var x: i64 = 0
var name: string
y = 5    // без объявления — тоже работает
```

Переменной можно присвоить число, строку или результат выражения.
`var <имя>: <тип>` — для явной типизации; без `var` тип выводится.

### 3.3 Присваивания

```rust
x = 42
x += 1
x -= 5
x *= 2
x /= 3
x %= 4
```

Все `=`, `+=`, `-=`, `*=`, `/=`, `%=` работают (проверено, вывод корректен).

### 3.4 Печать (print)

```rust
print("строка\n")
```

Печатает в stdout. Поддерживаются `\n`, `\r`, `\t`.

### 3.5 if / else

```rust
if x > 5 {
    print("big")
}
else if x > 0 {
    print("small")
}
else {
    print("zero")
}
```

### 3.6 Циклы

```rust
while i < 10 {
    i = i + 1
}

for j = 0; j < 5; j = j + 1 {
    print(j)
}
```

Поддерживаются `break` и `continue`.

### 3.7 Структуры

См. раздел 4.5. Объявляются на верхнем уровне, поля присваиваются по одному.

### 3.8 Перечисления (enum)

```rust
enum <Имя> {
    Член1
    Член2
}
```

Глобальное объявление перечисления (только верхний уровень). Члены нумеруются с 0:
`Color.Red` → 0, `Color.Green` → 1, `Color.Blue` → 2. Запятые между членами необязательны.

```rust
enum Color {
    Red
    Yellow
    Green
}
```

### 3.9 Константы (const)

```rust
fn main() {
    const MAX = 42;
    print(MAX)
}
```

Константы работают, объявляются внутри `fn main`. Переприсваивание — ошибка
`cannot assign to const variable`. Верхнеуровневое объявление `const` — ошибка.

### 3.10 Выражения match

```rust
enum Color { Red, Green, Blue }
fn main() {
    c = Color.Green
    match c {
        Color.Red   { print("red") }
        Color.Green { print("green") }
        Color.Blue  { print("blue") }
    }
}
```

Можно матчить числа:

```rust
x = 2
match x {
    1 { print("one") }
    2 { print("two") }
}
```

### 3.11 import

```rust
import math
```

`import <identifier>` без кавычек (кавычки — ошибка).

### 3.12 Рекурсия

```rust
fn factorial(n) {
    if n <= 1 {
        return 1
    }
    return n * factorial(n - 1)
}

fn main() {
    print(factorial(10))   // 3628800
}
```

Тесты: `zig\tests\B+\.b\sources\Functions\101. Recursive factorial.b+`, `189`, `236`.

### 3.13 Комментарии

```rust
// однострочный комментарий
```

Только `//`. Форма `--` не поддерживается.

---

## 4. Синтаксис METAL

METAL — это второй домен B+ (наряду с PLAN). Используется для функций, переменных, структур, указателей, `if`/`while`/`for`, составных присваиваний.

### 4.1 Типы

| Тип | Размер (байт) |
|-----|--------------|
| `bool` | 1 |
| `i8` / `u8` | 1 |
| `i16` / `u16` | 2 |
| `i32` / `u32` | 4 |
| `i64` / `u64` | 8 |
| `f32` | 4 |
| `f64` | 8 |
| `int` | алиас `i64` |
| `void` | 0 |

> Проверено: объявления работают для всех указанных типов. Работают также `f32`, `string`, `ptr`.
> Алиасов `int8/int16/int32/int64`, `byte`, `float`, `short`, `uint`, `half` в языке **нет** — проверено компилятором.

### 4.2 Функции

```rust
fn add(a: i64, b: i64) -> i64 {
    return a + b
}

fn main() {
    print(add(3, 4));
}
```

Возврат значения — только через явный `return`:

```rust
fn max(a: i64, b: i64) -> i64 {
    if a > b {
        return a;
    }
    return b;
}
```

Точка входа — `fn main()`. Без неё программа не слинкуется. Функции работают до и после объявления, поддерживается рекурсия.

### 4.3 Внешние функции

Не поддерживаются. Единственная точка входа — `fn main()`; системные функции объявляются как обычные.

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
print(p.x);
```

> **Литералы:** `Point{}` (пустой литерал — все поля нули) **работает**. `Point { x: 10, y: 20 }` (с заполнением полей) — **не компилируется**.
> Создавайте переменную через `var p: Point; p.x = 10; p.y = 20;` или `p = Point{}; p.x = 10;` — проверено.

### 4.6 Указатели

Тип `ptr` объявляется и может хранить/передавать адреса (`a: ptr = 0; a = b` — работает).
Адресная арифметика `&x` / разыменование `*p` ещё не реализованы в BIR-понижении.

### 4.7 If/else

```rust
if x > 5 {
    print(1);
} else {
    print(0);
}
if (x > 5) {
    print(1);
}
```

### 4.8 While

```rust
var i: i64 = 0;
while i < 3 {
    print(i);
    i = i + 1;
}
```

`break` / `continue`:

```rust
var i: i64 = 0;
while i < 10 {
    if i == 5 {
        break;
    }
    if i == 2 {
        i = i + 1;
        continue;
    }
    print(i);
    i = i + 1;
}
```

### 4.9 For (C-стиль)

```rust
for i = 0; i < 10; i = i + 1 {
    print(i);
}
```

> Форма `for i in 0..10` не поддерживается.

### 4.10 Составные присваивания

**Поддерживаются** — проверено компилятором:

```rust
x += 5;
x -= 2;
x *= 3;
x /= 2;
x %= 4;
```

Работают с целыми и числами с плавающей точкой. Используйте `a = a + 1`, если нужна форма без составного оператора.

### 4.11 Операторы

| Оператор | Описание |
|----------|----------|
| `*` / `/` / `%` | умножение, деление, остаток |
| `+` / `-` | сложение, вычитание |
| `=` | присваивание |
| `+=` / `-=` / `*=` / `/=` / `%=` | составные присваивания (работают) |
| `==` / `!=` / `>` / `<` / `>=` / `<=` | сравнения |
| `&&` | логическое И |
| `\|\|` | логическое ИЛИ |
| `!` | логическое НЕ |
| `&` | побитовое И |
| `\|` | побитовое ИЛИ |
| `^` | побитовое XOR |
| `~` | побитовое НЕ |
| `<<` / `>>` | сдвиг влево / вправо |
| `-x` | унарный минус |

> Оператор `^` переключает биты (`xorps`), `&` — конъюнкция (`andps`), `~` — инверсия (`andnps`). Проверено компилятором.

### 4.12 Комментарии

```rust
// однострочный комментарий
```

Только `//`. Форма `--` не поддерживается.

### 4.13 Сообщения об ошибках

```
error[UnknownVariable]: test_error.b+:4:1
   4 |     print(y);
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
| `bool` | 1 |
| `i8` / `u8` | 1 |
| `i16` / `u16` | 2 |
| `i32` / `u32` | 4 |
| `i64` / `u64` | 8 |
| `f32` | 4 |
| `f64` | 8 |
| `void` | 0 |
| `int` | алиас `i64` |

> Проверено на тестах `zig\tests\B+\.b\sources\`: все типы из таблицы работают, включая `f32`.
> Алиасов `int8/.../byte/short/uint/float/half` нет. `ptr` объявляется; работа с ним — хранить и передавать в параметры.

---

## 6. Примеры

> Все примеры ниже проверены компилятором (`bpc run` → `exit 0`).
> Полный набор рабочих примеров и тестов: `zig\tests\B+\.b\sources\` (262 файла).

### Hello, World!

```rust
fn main() {
    print("Hello, B+!\n")
}
```

### Цикл for

```rust
fn main() {
    for i = 0; i < 5; i = i + 1 {
        print(i)
    }
}
```

### Цикл while + break / continue

```rust
fn main() {
    i = 0
    while i < 10 {
        i = i + 1
        if i == 2 { continue }
        if i == 5 { break }
        print(i)
    }
}
```

Вывод: `1 3 4`

### Составные присваивания

```rust
fn main() {
    x = 10
    x += 5
    x -= 2
    x *= 3
    x /= 4
    x %= 3
    print(x)
}
```

### Битовые операторы

```rust
fn main() {
    x = 10
    y = 12
    print(x & y)   // 8
    print(x | y)   // 14
    print(x ^ y)   // 6
    print(~x)      // -11
    print(x << 2)  // 40
    print(x >> 1)  // 5
}
```

> Только десятичные литералы: `0b1010` и `0xFF` не компилируются.

### Факториал (рекурсия)

```rust
fn factorial(n)
{
    if n <= 1
    {
        return 1
    }
    return n * factorial(n - 1)
}

fn main()
{
    print(factorial(5))  // 120
}
```

### Структуры

```rust
struct Point {
    x: i64,
    y: i64,
}

fn main() {
    p = Point {}
    p.x = 3
    p.y = 4
    s = p.x + p.y
    print(s)  // 7
}
```

> Литерал `Point { x: 10, y: 20 }` не компилируется; `Point {}` (пустой, все нули) — работает.

### Перечисления (enum)

```rust
enum Color {
    Red
    Green
    Blue
}

fn main() {
    c = Color.Green
    match c {
        Color.Red   { print("red") }
        Color.Green { print("green") }
        Color.Blue  { print("blue") }
    }
}
```

Члены нумеруются с 0: `Color.Red` → 0, `Color.Green` → 1, `Color.Blue` → 2.
Запятые между членами необязательны.

### Константы

```rust
fn main() {
    const MAX = 42
    const MIN = 1
    print(MAX + MIN)  // 43
}
```

> Переприсваивание константе — ошибка: `cannot assign to const variable`.
> Константы объявляются только внутри `fn main` (объявление на верхнем уровне не работает).

### FizzBuzz

```rust
fn main() {
    for i = 1; i <= 15; i = i + 1 {
        if i % 15 == 0 { print("FizzBuzz") }
        else if i % 3 == 0 { print("Fizz") }
        else if i % 5 == 0 { print("Buzz") }
        else { print(i) }
    }
}
```

### Указатели

```rust
fn main() {
    a: ptr = 0
    b: ptr = 0
    a = b
    print("ok")
}
```

> Тип `ptr` объявляется и используется для хранения/передачи адресов.
> Операторы `&` (адрес) и `*` (разыменование) ещё не реализованы.

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

# B+ v4.6.4-beta — Compiled `.b+` Language (Frontend → HIR → BIR → MIR → Targets)

**B+** compiles `.b+` files directly to x64 machine code and packages them into Windows PE executables (.exe/.dll).
No assemblers, linkers, or LLVM — the entire code generator and optimizer are written from scratch in Zig.

### What's new in v4.6.4-beta

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
- **HIR Unification**: removed `middle/hir/` (duplicate tree-based HIR). `StateItem`,
  `KernelItem`, `HirAttr`, `DispatchSize` moved into unified `frontend/hir/item.zig`.
  Pipeline: `AST → Unified HIR → TIR → BIR → MIR → x64`
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
B+ generates all x64 machine code and IR optimizations itself; `lld-link.exe` (from LLVM) is used for the final PE linking step. `bpc run` automatically terminates a lingering old `.exe` before relinking.

B+ code is stored in files with the extension: `example.b+`

B+ is a language that compiles `.b+` files directly to x64 machine code and Windows PE (.exe/.dll).

B+ has two main programming modes:

### PLAN — state logic description

PLAN is the state/event domain. **In the current build `state` blocks and `entry`/`exit`/`on` are parsed but not executed at runtime** — all code runs from `fn main()`. PLAN is documented historically and will be enabled in a future version.

```rust
fn main() {
    print("PLAN code runs from fn main()\n")
}
```

### METAL — regular programming

METAL is designed for writing regular code:
- functions
- algorithms
- computations
- memory management
- low-level systems

```rust
fn fibonacci(n)
{
    if n <= 1
    {
        return n
    }
    return fibonacci(n - 1) + fibonacci(n - 2)
}

fn main()
{
    print(fibonacci(7))  // 13
}
```

This code creates a Fibonacci number calculation function.
> Verified: recursion compiles without type annotations (`-> i64` on the return gives an error).

### One language — two approaches

PLAN and METAL use the same B+ syntax but are designed for different tasks:

| Mode | Purpose | Status |
|------|---------|--------|
| PLAN | state and event logic | parsed, not executed |
| METAL | algorithms and systems code | works |

The compiler determines automatically which mode the code belongs to.

B+ combines the simplicity of high-level languages with the control of systems programming, allowing you to create both algorithms and low-level programs.

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Compiler Commands](#2-compiler-commands)
3. [Language Syntax](#3-language-syntax)
   - [3.1 Functions and entry point](#31-functions-and-entry-point)
   - [3.2 Variables](#32-variables)
   - [3.3 Assignments](#33-assignments)
   - [3.4 Print (print)](#34-print-print)
   - [3.5 if / else](#35-if--else)
   - [3.6 Loops](#36-loops)
   - [3.7 Structs](#37-structs)
   - [3.8 Enums (enum)](#38-enums-enum)
   - [3.9 Constants (const)](#39-constants-const)
   - [3.10 match expressions](#310-match-expressions)
   - [3.11 import](#311-import)
   - [3.12 Recursion](#312-recursion)
   - [3.13 Comments](#313-comments)
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
fn main() {
    print("Hello World!\n")
}
```

> **Important:** the only working entry point is `fn main()`. The `state Hello { entry { print(...) } }` form fails to link (`undefined symbol: main`); in the current runtime state blocks are not executed — all output comes from `fn main`.

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
bpc run    <input.b+>              — compile and run immediately
bpc dll    <input.b+> [-o <out.dll>] [-exports <name1,name2,...>] — compile to DLL
bpc check  <input.b+>              — check code without producing an exe (PASS/FAIL)
bpc hlsl   <input.b+> [-o <out.hlsl>] — generate HLSL shader code
bpc mir    <input.b+>              — generate COFF .obj
bpc bpl    <input.b+>              — lower B+ to BIR and dump
bpc ir     <input.b+>              — dump BIR pipeline
bpc cfg    <input.b+>              — dump control flow graph
bpc dom    <input.b+>              — dump dominator tree
bpc loops  <input.b+>              — dump loop hierarchy
bpc link   <input.obj> -o <out.exe> — link an .obj into an .exe
bpc test   <test.bpt>              — run test
bpc doctor                          — compiler diagnostics (Runtime/Linker/Parser/HIR/THIR/BIR/MIR/x64)
```

> Verified: `run`, `dll`, `check`, `mir`, `bpl`, `link`, `doctor` work.
> `ir`/`cfg`/`dom`/`loops`/`hlsl` on a plain `fn main` file fail with `VERIFY: block_has_no_terminator` — they expect a pipeline/kernel input.

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

- The compiler self-generates all x64 machine code; `lld-link.exe` is used for the final PE linking step.
- `bpc run` compiles to `.exe` and runs it immediately.

---

## 3. Language Syntax

> **Verified against the real compiler:** the only entry point is `fn main()`.
> `state` blocks are parsed, but their `entry`/`exit`/`on` blocks are **not executed** by the current build — all output comes from `fn main`, so the examples below only use functions.

### 3.1 Functions and entry point

```rust
fn main() {
    print("Hello\n")
}
```

Functions are declared with `fn <name>(<params>)`. Params and return type can be typed:

```rust
fn add(a: i64, b: i64) -> i64 {
    return a + b
}
```

`return` is explicit. Recursion works (see `Functions` tests).

### 3.2 Variables

```rust
var x: i64 = 0
var name: string
y = 5    // without declaration also works
```

A variable can hold a number, a string or an expression result.
`var <name>: <type>` for explicit typing; without `var` the type is inferred.

### 3.3 Assignments

```rust
x = 42
x += 1
x -= 5
x *= 2
x /= 3
x %= 4
```

All of `=`, `+=`, `-=`, `*=`, `/=`, `%=` work (verified, output is correct).

### 3.4 Print (print)

```rust
print("string\n")
```

Prints to stdout. Supports `\n`, `\r`, `\t`.

### 3.5 if / else

```rust
if x > 5 {
    print("big")
}
else if x > 0 {
    print("small")
}
else {
    print("zero")
}
```

### 3.6 Loops

```rust
while i < 10 {
    i = i + 1
}

for j = 0; j < 5; j = j + 1 {
    print(j)
}
```

`break` and `continue` are supported.

### 3.7 Structs

See section 4.5. Declared at top level; fields are assigned one by one.

### 3.8 Enums (enum)

```rust
enum <Name> {
    Member1
    Member2
}
```

A global enum declaration (top level only). Members are numbered from 0:
`Color.Red` → 0, `Color.Green` → 1, `Color.Blue` → 2. Commas between members are optional.

```rust
enum Color {
    Red
    Yellow
    Green
}
```

### 3.9 Constants (const)

```rust
fn main() {
    const MAX = 42;
    print(MAX)
}
```

Constants work, declared inside `fn main`. Reassigning is an error
`cannot assign to const variable`. A top-level `const` is an error.

### 3.10 match expressions

```rust
enum Color { Red, Green, Blue }
fn main() {
    c = Color.Green
    match c {
        Color.Red   { print("red") }
        Color.Green { print("green") }
        Color.Blue  { print("blue") }
    }
}
```

Numbers are matched too:

```rust
x = 2
match x {
    1 { print("one") }
    2 { print("two") }
}
```

### 3.11 import

```rust
import math
```

`import <identifier>` without quotes (quotes are an error).

### 3.12 Recursion

```rust
fn factorial(n) {
    if n <= 1 {
        return 1
    }
    return n * factorial(n - 1)
}

fn main() {
    print(factorial(10))   // 3628800
}
```

Tests: `zig\tests\B+\.b\sources\Functions\101. Recursive factorial.b+`, `189`, `236`.

### 3.13 Comments

```rust
// single-line comment
```

Only `//`. The `--` form is not supported.

---

## 4. METAL Syntax

METAL is the second B+ domain (alongside PLAN). Used for functions, variables, structs, pointers, `if`/`while`/`for`, compound assignment.

### 4.1 Types

| Type | Size (bytes) |
|------|-------------|
| `bool` | 1 |
| `i8` / `u8` | 1 |
| `i16` / `u16` | 2 |
| `i32` / `u32` | 4 |
| `i64` / `u64` | 8 |
| `f32` | 4 |
| `f64` | 8 |
| `int` | alias for `i64` |
| `void` | 0 |

> Verified: declarations work for all listed types, including `f32`, `string`, `ptr`.

### 4.2 Functions

```rust
fn add(a: i64, b: i64) -> i64 {
    return a + b
}

fn main() {
    print(add(3, 4));
}
```

Returning a value requires an explicit `return`:

```rust
fn max(a: i64, b: i64) -> i64 {
    if a > b {
        return a;
    }
    return b;
}
```

The entry point is `fn main()`. Without it the program does not link. Functions work above and below their call site; recursion is supported.

### 4.3 Extern Functions

Not supported. The only entry point is `fn main()`; system functions are declared as ordinary ones.

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
print(p.x);
```

> **Literals:** `Point{}` (empty literal, all zero fields) **works**. `Point { x: 10, y: 20 }` (field-initialized) **does not compile**.
> Use `var p: Point; p.x = 10; p.y = 20;` or `p = Point{}; p.x = 10;` — verified.

### 4.6 Pointers

The `ptr` type can be declared and used to store/pass addresses (`a: ptr = 0; a = b` works).
Address arithmetic `&x` / dereference `*p` are not implemented in BIR lowering yet.

### 4.7 If/else

```rust
if x > 5 {
    print(1);
} else {
    print(0);
}
if (x > 5) {
    print(1);
}
```

### 4.8 While

```rust
var i: i64 = 0;
while i < 3 {
    print(i);
    i = i + 1;
}
```

`break` / `continue`:

```rust
var i: i64 = 0;
while i < 10 {
    if i == 5 {
        break;
    }
    if i == 2 {
        i = i + 1;
        continue;
    }
    print(i);
    i = i + 1;
}
```

### 4.9 For (C style)

```rust
for i = 0; i < 10; i = i + 1 {
    print(i);
}
```

> The `for i in 0..10` form is not supported.

### 4.10 Compound Assignment

**Supported** — verified with the compiler:

```rust
x += 5;
x -= 2;
x *= 3;
x /= 2;
x %= 4;
```

Work with integers and floats. Use `a = a + 1` if you prefer the long form.

### 4.11 Operators

| Operator | Description |
|----------|-------------|
| `*` / `/` / `%` | multiply, divide, remainder |
| `+` / `-` | add, subtract |
| `=` | assignment |
| `+=` / `-=` / `*=` / `/=` / `%=` | compound assignment (work) |
| `==` / `!=` / `>` / `<` / `>=` / `<=` | comparisons |
| `&&` | logical AND |
| `\|\|` | logical OR |
| `!` | logical NOT |
| `&` | bitwise AND |
| `\|` | bitwise OR |
| `^` | bitwise XOR |
| `~` | bitwise NOT |
| `<<` / `>>` | shift left / right |
| `-x` | unary minus |

### 4.12 Comments

```rust
// single-line comment
```

Only `//`. The `--` form is not supported.

### 4.13 Error Messages

```
error[UnknownVariable]: test_error.b+:4:1
   4 |     print(y);
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
| `bool` | 1 |
| `i8` / `u8` | 1 |
| `i16` / `u16` | 2 |
| `i32` / `u32` | 4 |
| `i64` / `u64` | 8 |
| `f32` | 4 |
| `f64` | 8 |
| `void` | 0 |
| `int` | alias for `i64` |

> Supported (verified against `zig\tests\B+\.b\sources\`): `i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 bool string ptr void int`.
> The aliases `int8/int16/int32/int64`, `byte`, `short`, `uint`, `float`, `half` do not exist in the language.

---

## 6. Examples

> Every example below is verified with the compiler (`bpc run` → `exit 0`).
> The full set of working examples and tests: `zig\tests\B+\.b\sources\` (262 files).

### Hello, World!

```rust
fn main() {
    print("Hello, B+!\n")
}
```

### for loop

```rust
fn main() {
    for i = 0; i < 5; i = i + 1 {
        print(i)
    }
}
```

### while loop + break / continue

```rust
fn main() {
    i = 0
    while i < 10 {
        i = i + 1
        if i == 2 { continue }
        if i == 5 { break }
        print(i)
    }
}
```

Output: `1 3 4`

### Compound assignment

```rust
fn main() {
    x = 10
    x += 5
    x -= 2
    x *= 3
    x /= 4
    x %= 3
    print(x)
}
```

### Bitwise operators

```rust
fn main() {
    x = 10
    y = 12
    print(x & y)   // 8
    print(x | y)   // 14
    print(x ^ y)   // 6
    print(~x)      // -11
    print(x << 2)  // 40
    print(x >> 1)  // 5
}
```

> Only decimal literals: `0b1010` and `0xFF` do not compile.

### Factorial (recursion)

```rust
fn factorial(n)
{
    if n <= 1
    {
        return 1
    }
    return n * factorial(n - 1)
}

fn main()
{
    print(factorial(5))  // 120
}
```

### Structs

```rust
struct Point {
    x: i64,
    y: i64,
}

fn main() {
    p = Point {}
    p.x = 3
    p.y = 4
    s = p.x + p.y
    print(s)  // 7
}
```

> The `Point { x: 10, y: 20 }` literal does not compile; `Point {}` (empty, all zeros) works.

### Enums

```rust
enum Color {
    Red
    Green
    Blue
}

fn main() {
    c = Color.Green
    match c {
        Color.Red   { print("red") }
        Color.Green { print("green") }
        Color.Blue  { print("blue") }
    }
}
```

Members are numbered from 0: `Color.Red` → 0, `Color.Green` → 1, `Color.Blue` → 2.
Commas between members are optional.

### Constants

```rust
fn main() {
    const MAX = 42
    const MIN = 1
    print(MAX + MIN)  // 43
}
```

> Reassigning a constant is an error: `cannot assign to const variable`.
> Constants are declared only inside `fn main` (a top-level declaration does not work).

### FizzBuzz

```rust
fn main() {
    for i = 1; i <= 15; i = i + 1 {
        if i % 15 == 0 { print("FizzBuzz") }
        else if i % 3 == 0 { print("Fizz") }
        else if i % 5 == 0 { print("Buzz") }
        else { print(i) }
    }
}
```

### Pointers

```rust
fn main() {
    a: ptr = 0
    b: ptr = 0
    a = b
    print("ok")
}
```

> The `ptr` type can be declared and used to store/pass addresses.
> The `&` (address-of) and `*` (dereference) operators are not implemented yet.

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
