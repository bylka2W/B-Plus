# B+ v4.2.0 — детерминированная машина переходов (x64)

**B+** транслирует `.b+` файлы напрямую в машинный код x64 и упаковывает в Windows PE (.exe).
Никаких ассемблеров, линкеров, LLVM — весь кодогенератор написан с нуля на Zig.

Встроенный runtime-уровень (Stage 2) — детерминированная машина состояний с формальной моделью переходов, трёхуровневой иерархией памяти (L1/L2/L3), поколенческими handle и единственной точкой исполнения миграций (`applyMigration`).

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
```bash
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

### 3.9 global entry

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

### 3.10 Контекст (context)

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

### 3.12 Перечисления (enum)

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

### 3.13 Параллельные блоки (parallel)

```rust
parallel <Имя> {
    state A { ... }
    state B { ... }
}
```

Группировка состояний в параллельный блок (состояния не влияют друг на друга).

### 3.14 Kernel-функции

```rust
kernel <имя>(<параметр>: <тип>, ...) -> <тип>
```

Объявление kernel-функции (для генерации кода на стороне GPU/металла).

```rust
kernel matrixMul(a: int, b: int) -> int
```

### 3.15 Внешние функции (extern)

```rust
extern "dllname.dll" fn <имя>(<парам>: <тип>, ...) -> <тип>
```

Объявление внешней функции из DLL.

```rust
extern "user32.dll" fn MessageBoxA(hWnd: int, lpText: int, lpCaption: int, uType: int) -> int
```

### 3.16 Комментарии

```rust
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

## 6. Сборка из исходников

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

## 7. Структура проекта

```text
zig/                    — компилятор (Zig, активная разработка)
  src/
    main.zig            — точка входа, CLI, оркестрация
    runtime.zig          — Stage 2 runtime kernel (handle table, arena, FSM, migration, Snapshot)
    runtime_test.zig     — 40 unit tests: alloc, release, tick, migration, decay, budget, memory layer
    stress_test.zig      — stress test: 100k ops with snapshot-based formal invariant verification
    cpu.zig              — Stage 7.0a CPU topology detection (Windows kernel32 extern)
    latency.zig          — Stage 7.3 LatencyProfile, CoreStats, LoadState (adaptive thresholds)
    scheduler.zig        — Stage 7 NUMA-aware worker-pool scheduler
    scheduler_test.zig   — 16 tests: sync/threaded/priority/steal/latency/state-machine
    parser.zig          — лексер + парсер .b+
    ast.zig             — типы AST (состояния, переходы и т.д.)
    x64gen.zig          — генератор машинного кода x64 (+ Intrinsic binding к runtime)
    x64enc.zig          — кодировщик инструкций x64
    pe.zig             — генератор PE (.exe)
  build.zig            — сборка через zig build
```

---

## 8. Лицензия

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

## 9. Контакты

- **GitHub**: [github.com/bylka2W](https://github.com/bylka2W)
- **Репозиторий**: [github.com/bylka2W/B-Plus](https://github.com/bylka2W/B-Plus)
- **Автор**: bylka2W

---

## Stage 2 — Runtime kernel (chunk-based memory physics)

`src/runtime.zig` — детерминированная машина памяти на chunk-модели (64KB регионы).

```text
Handle → MetaStore → chunk_id → Chunk.tier (O(1), без эвристик)
                                ↓
moveHotter/moveColder → Chunk.tier.moveHotter/?Tier (pure FSM)
                                ↓
cooldown gate → last_migration_tick + 3 тика (Stage 3)
                                ↓
migrateChunk → tier switch + memcpy used bytes (физическое копирование)
    └─ dst_arena.alloc(CHUNK_SIZE)
    └─ @memcpy (src → dst, только chunk.used байт)
    └─ update chunk.arena_base / chunk.arena_offset
    └─ chunk.last_migration_tick = current_tick
    └─ log .MIGRATE
```

### Stage 2: chunk layer

- **Chunk** = 64KB регион, атомарная единица миграции.
- **`ChunkStore`**: управление массивами chunk'ов, поиск по tier + свободному месту.
- **`MetaStore.chunk_ids`** / **`MetaStore.offsets`** заменили `ptrs` — tier = `chunks[chunk_id].tier`, не pointer.
- **`arena_base`** в Chunk: data всегда читается из физической арены, независимо от `chunk.tier`.
- **Физическое копирование**: при миграции — `dst_arena.alloc(CHUNK_SIZE)`, `@memcpy(chunk.used bytes)`, обновление адреса.
- **Heat per-chunk**: аккумулируется на `access()`, тик оперирует chunk'ами (не handle'ами).
- **`Snapshot`**: слепок per-slot (tiers из chunk.tier) + per-chunk (tiers, heats).
- **`MigrationResult`**: `.success` / `.dst_full` / `.invalid_handle` / `.at_boundary` / `.cooldown`.
- **slot_count**: декремент при release — пустые chunk'и не участвуют в миграциях.

### Stage 3: cooldown tracking

- **`Chunk.last_migration_tick`**: тик последней миграции (0 = never migrated).
- **`COOLDOWN_TICKS = 3`**: минимальное число тиков между миграциями одного чанка.
- **Гейт в `migrateChunk`**: `current_tick - last_migration_tick < COOLDOWN_TICKS` → `.cooldown`.
- **Гейт в `tick()`**: чанки в cooldown не тратят бюджет на сбор кандидатов.
- **Cooldown не заменяет heat-логику**: heat решает *нужна ли* миграция, cooldown решает *можно ли сейчас*.
- **30 unit tests**: cooldown fresh chunk, immediate block, window (1–3–4 тика), tick integration.

### Stage 4: priority scheduling (top-K selection)

- **Partial top-K**: O(n) scan, без глобального буфера — поддерживается топ MIGRATION_BUDGET=4 кандидатов через замену слабейшего при проходе.
- **Сортировка**: promote — `heat desc` (самые горячие первыми), demote — `heat asc` (самые холодные первыми).
- **Tie-break**: `chunk_id asc` — строгий детерминизм при равном heat.
- **Top-K**: `MIGRATION_BUDGET=4` применяется *после* ранжирования, а не во время сбора.
- **Cooldown фильтрует до сортировки**: chunk в cooldown не участвует в очереди.
- **Две очереди**: promote (L2→L1, L3→L2) и demote (L1→L2, L2→L3) обрабатываются независимо.
- **32 unit tests**: top-K priority, tie-breaking, budget limit.
- **Fingerprint стабилен** — детерминированная сортировка не меняет конечное состояние при одинаковых входных данных.

### Stage 5: cost-aware scheduling

- **`migrationCost(src, dst)`**: L1↔L2 = 2, L2↔L3 = 1. Симметрично.
- **Promote score**: `heat - cost`. Только если score > 0.
- **Demote score**: `(DEMOTE_THRESH - heat) - cost`. Только если score > 0.
- **Score фильтрует до top-K**: chunk с score ≤ 0 не тратит бюджет.
- **ENABLE_COST_MODEL**: compile-time флаг отката.
- **Эффект**: chunk в L1 с heat 29 не демотится (score = -1), chunk в L2 с heat 5 демотится (score = 24).
- **35 unit tests**: +3 cost-specific (дорогой блок, дешёвый проходит, promote работает).
- **Stress fingerprint стабилен** — cost не меняет top-K порядок для горячих чанков.

### Stage 6: Memory Layer (foundation release)

- **6.1 Free-list**: `ChunkStore.free_list[]` + `free_count`. При `slot_count == 0` chunk_id попадает в free-list. `allocChunk` сначала проверяет free-list, потом линейный аллок.
- **6.2 Compaction**: `runCompaction()` раз в `COMPACT_INTERVAL=1000` тиков. Собирает живые chunk'и, сохраняет данные, сбрасывает арену, переаллоцирует последовательно.
- **6.3 Indirection**: `Handle → chunk_id → chunk.arena_base + arena_offset + slot_offset`. Компакшен обновляет только `chunk.arena_base`/`arena_offset` — handle'ы не трогаются.
- **39 unit tests**: +4 Stage 6 (free-list reuse, multiple freed IDs, compaction single-tier, compaction multi-tier).
- **API**: `setAllocator(allocator)` включает компакшен. Без него — только free-list.
- **Stress stable** — fingerprint обновлён из-за переиспользования chunk_id.

### Stage 7: Architecture-Aware Runtime Scheduler

`src/scheduler.zig` — упреждающий планировщик с NUMA-локали, латентностной защитой и per-core адаптивными порогами.

```text
Job → WorkerPool → worker[N] (per-core LIFO queue)
         ↓
    steal(neighbor) ← cost-benefit → migrate(job)
         ↓
    load_state (NORMAL ↔ MEDIUM ↔ OVERLOAD)
```

#### 7.0a CPU topology detection (`src/cpu.zig`)

- **`CpuTopology`**: logical/physical cores, HT siblings, кеш-иерархия (дедупликация), NUMA nodes, CPU-класс (tiny/pc/workstation/manycore).
- **Windows kernel32 extern**: `GetLogicalProcessorInformationEx` (primary) + `GetLogicalProcessorInformation` (fallback).
- **Cache dedup**: одна запись на уникальный уровень/размер кеша, не per-core.

#### 7.3 Latency Protection layer

**Core model**:
- **`LatencyProfile`**: матрица стоимости миграции, NUMA-пенальти, кеш-дистанция, per-core NUMA.
- **Score**: `load × LOAD_PENALTY + migrationCost + cacheDistance × SCALE + numaPenalty`.
- **Cost heuristics**: HT-sibling=50ns, same-NUMA=200ns, cross-NUMA=1000ns.

**Per-core adaptive steal threshold**:
- Каждое ядро ведёт `CoreStats` (attempts, successes, EMA cost/benefit).
- Порог = `avg_cost + avg_cost × fail_ratio / 2` — ядро само учится, какие steal выгодны.
- `fail_ratio = (attempts − succ) / attempts` (fixed-point, α=1/16).
- Холодный старт: `cost × 2` при attempts < 4.

**Sticky core + hysteresis**:
- `Job.sticky_core` / `stickiness` — задача остаётся на своём ядре при steal-попытке.
- `migration_cooldown_ns=50ms` — запрет ping-pong миграций.

**Load state machine (трёхуровневая с гистерезисом)**:
```
                   smoothed ≥ 4 (MEDIUM_ENTER)
     NORMAL ─────────────────────────────► MEDIUM
         ◄───────────────────────────────
         smoothed ≤ 2 (MEDIUM_EXIT)

                   smoothed ≥ 8 (OVERLOAD_ENTER)
     MEDIUM ─────────────────────────────► OVERLOAD
         ◄───────────────────────────────
         smoothed ≤ 5 (OVERLOAD_EXIT)
```
- **`smoothed_load`**: EMA очереди ядра (α=1/8) — защита от burst noise.
- **NORMAL**: строгий cost-benefit + adaptive threshold + sticky honored + cooldown.
- **MEDIUM**: relaxed (cost-benefit пропущен) + sticky honored + cooldown.
- **OVERLOAD**: bypass всего — steal без условий, sticky отключён, cooldown отключён.

**Overload escape**: при OVERLOAD-состоянии жертвы — все ограничения locality снимаются, предотвращая biased locality trap.

#### Тестирование

```bash
zig test src\scheduler_test.zig   # 16 tests (sync/threaded/priority/steal/latency/state-machine)
zig test src\latency_test.zig     # 5 tests (matrix build, NUMA, migration log, score)
zig test src\cpu_test.zig         # 1 test (topology detection)
```

| Компонент | Описание |
|-----------|----------|
| `Tier` | Enum L1/L2/L3/DISK. FSM: `moveHotter`/`moveColder` → `?Tier` |
| `Chunk` | 64KB регион: tier, arena_base, heat, used, arena_offset, slot_count, last_migration_tick |
| `ChunkStore` | Массив chunk'ов + free-list, alloc/find/release-by-tier |
| `Handle` | Поколенческий идентификатор: slot + generation |
| `HandleTable` | Состояния слотов (Used/Free), free-лист O(1), инвалидация через generation |
| `MetaStore` | SoA: chunk_ids, offsets, sizes, generations, heats, total_heats, states |
| `Arena` | Трёхуровневый bump-аллокатор (L1/L2/L3), fail-fast при OOM |
| `Snapshot` | Слепок: per-slot tiers/heats/states/gens + per-chunk tiers/heats |
| `assertInvariant` | Приватная — только внутри validateHandle/validateChunkOps |

### Тестирование

```bash
zig test src\runtime_test.zig   # 40 unit tests (chunk-модель + cooldown + top-K + cost + memory layer)
zig test src\stress_test.zig    # 100k ops: 3817 миграций, фингерпринт детерминирован
zig test src\scheduler_test.zig # 16 tests: sync/threaded/priority/steal/latency/state-machine
```

### Intrinsic binding

`x64gen.zig` использует `inline for (comptime std.meta.tags(rt.Intrinsic))` для
исчерпывающей генерации всех runtime-функций. Любое добавление варианта `Intrinsic`
вызывает compile error до тех пор, пока `emitOneIntrinsic` не обработает его.

### Scheduler budget guard

Чтобы предотвратить livelock на always-переходах, каждый тик получает бюджет (4 перехода).
- **Scheduler** (`always_entry`): read-only guard — проверяет бюджет > 0
- **FSM** (`changeToState`): consumption — декремент при реальном always-переходе
- Бюджет сбрасывается на 4 при каждом `ReadFile` (начало тика)

### Spill chain

Аренный аллокатор (bump-pointer) каскадирует выделение:
- `arena_l1_alloc` → try L1 → spill L2 → spill L3 → oom
- `arena_l2_alloc` → try L2 → spill L3 → oom
- `arena_l1_reset` сбрасывает все три арены (L1+L2+L3)

Размер арен вычисляется динамически: `max_data_size × (8 + MIGRATION_BUDGET)`,
минимум 256 байт.

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

Built-in runtime layer (Stage 2) — a deterministic state machine with a formal transition model, three-level memory hierarchy (L1/L2/L3), generational handles, and a single migration execution point (`applyMigration`).

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
```bash
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

## 6. Building from Source

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

## 7. Project Structure

```text
zig/                    — compiler (Zig, active development)
  src/
    main.zig            — entry point, CLI, orchestration
    runtime.zig          — Stage 2 runtime kernel (handle table, arena, FSM, migration, Snapshot)
    runtime_test.zig     — 40 unit tests: alloc, release, tick, migration, decay, budget, memory layer
    stress_test.zig      — stress test: 100k ops with snapshot-based formal invariant verification
    cpu.zig              — Stage 7.0a CPU topology detection (Windows kernel32 extern)
    latency.zig          — Stage 7.3 LatencyProfile, CoreStats, LoadState (adaptive thresholds)
    scheduler.zig        — Stage 7 NUMA-aware worker-pool scheduler
    scheduler_test.zig   — 16 tests: sync/threaded/priority/steal/latency/state-machine
    parser.zig          — lexer + parser for .b+
    ast.zig             — AST types (states, transitions, etc.)
    x64gen.zig          — x64 machine code generator (+ Intrinsic binding to runtime).
                          Features: jump-table dispatch, superblock fusion,
                          compiled event matching (inline CMP imm for ≤4B names),
                          label interning (u32 IDs, zero formatting in hot paths),
                          O(1) state lookup via HashMap.
    x64enc.zig          — x64 instruction encoder
    pe.zig             — PE (.exe) generator
  build.zig            — build script (zig build)
```

---

## 8. License

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

## 9. Contact

- **GitHub**: [github.com/bylka2W](https://github.com/bylka2W)
- **Repository**: [github.com/bylka2W/B-Plus](https://github.com/bylka2W/B-Plus)
- **Author**: bylka2W

---

## Stage 2 — Runtime kernel (chunk-based memory physics)

`src/runtime.zig` — deterministic memory machine using chunk-based physics (64KB regions).

```text
Handle → MetaStore → chunk_id → Chunk.tier (O(1), no heuristics)
                                ↓
moveHotter/moveColder → Chunk.tier.moveHotter/?Tier (pure FSM)
                                ↓
cooldown gate → last_migration_tick + 3 ticks (Stage 3)
                                ↓
migrateChunk → tier switch + memcpy used bytes (physical copy)
    └─ dst_arena.alloc(CHUNK_SIZE)
    └─ @memcpy (src → dst, only chunk.used bytes)
    └─ update chunk.arena_base / chunk.arena_offset
    └─ chunk.last_migration_tick = current_tick
    └─ log .MIGRATE
```

### Stage 2: chunk layer

- **Chunk** = 64KB region, atomic migration unit.
- **`ChunkStore`**: chunk array management, find-by-tier + find-with-space.
- **`MetaStore.chunk_ids`** / **`MetaStore.offsets`** replaced `ptrs` — tier = `chunks[chunk_id].tier`, not pointer-based.
- **`arena_base`** in Chunk: data always read from the physical arena regardless of `chunk.tier`.
- **Physical byte copy**: on migration — `dst_arena.alloc(CHUNK_SIZE)`, `@memcpy(chunk.used bytes)`, pointer update.
- **Heat per-chunk**: accumulated on `access()`, tick operates on chunks (not handles).
- **`Snapshot`**: per-slot tiers (from chunk.tier) + per-chunk arrays (tiers, heats).
- **`MigrationResult`**: `.success` / `.dst_full` / `.invalid_handle` / `.at_boundary` / `.cooldown`.
- **slot_count**: decremented on release — empty chunks excluded from migration decisions.

### Stage 3: cooldown tracking

- **`Chunk.last_migration_tick`**: tick of last migration (0 = never migrated).
- **`COOLDOWN_TICKS = 3`**: minimum ticks between migrations for the same chunk.
- **Gate in `migrateChunk`**: `current_tick - last_migration_tick < COOLDOWN_TICKS` → `.cooldown`.
- **Gate in `tick()`**: chunks in cooldown don't consume budget during candidate collection.
- **Cooldown does not replace heat logic**: heat decides *if* migration is needed, cooldown decides *if it's allowed now*.
- **30 unit tests**: fresh chunk bypass, immediate block, window (1–3–4 ticks), tick integration.

### Stage 4: priority scheduling (top-K selection)

- **Partial top-K**: O(n) scan, no global buffer — maintains top MIGRATION_BUDGET=4 candidates via weakest-replacement during pass.
- **Sorting**: promote — `heat desc` (hottest first), demote — `heat asc` (coldest first).
- **Tie-break**: `chunk_id asc` — strict determinism for equal heat.
- **Top-K**: `MIGRATION_BUDGET=4` applied *after* ranking, not during collection.
- **Cooldown filters before sorting**: chunks in cooldown are excluded from queues.
- **Two queues**: promote (L2→L1, L3→L2) and demote (L1→L2, L2→L3) processed independently.
- **32 unit tests**: top-K priority, tie-breaking, budget limit.
- **Stable fingerprint** — deterministic sort preserves final state for identical inputs.

### Stage 5: cost-aware scheduling

- **`migrationCost(src, dst)`**: L1↔L2 = 2, L2↔L3 = 1. Symmetric.
- **Promote score**: `heat - cost`. Only if score > 0.
- **Demote score**: `(DEMOTE_THRESH - heat) - cost`. Only if score > 0.
- **Score filters before top-K**: chunk with score ≤ 0 doesn't consume budget.
- **ENABLE_COST_MODEL**: compile-time rollback flag.
- **Effect**: L1 chunk at heat 29 stays L1 (score = -1), L2 chunk at heat 5 demotes (score = 24).
- **35 unit tests**: +3 cost-specific (expensive blocked, cheap passes, promote works).
- **Stress fingerprint stable** — cost doesn't affect top-K order for hot chunks.

### Stage 6: Memory Layer (foundation release)

- **6.1 Free-list**: `ChunkStore.free_list[]` + `free_count`. When `slot_count == 0` the chunk_id is pushed to the free list. `allocChunk` checks free list first, then linear alloc.
- **6.2 Compaction**: `runCompaction()` every `COMPACT_INTERVAL=1000` ticks. Collects live chunks, saves data, resets arena, re-allocates sequentially.
- **6.3 Indirection**: `Handle → chunk_id → chunk.arena_base + arena_offset + slot_offset`. Compaction updates only `chunk.arena_base`/`arena_offset` — handles are untouched.
- **39 unit tests**: +4 Stage 6 (free-list reuse, multiple freed IDs, compaction single-tier, compaction multi-tier).
- **API**: `setAllocator(allocator)` enables compaction. Without it — free-list only.
- **Stress stable** — fingerprint updated due to chunk_id reuse.

### Stage 7: Architecture-Aware Runtime Scheduler

`src/scheduler.zig` — preemptive scheduler with NUMA locality, latency protection, and per-core adaptive thresholds.

```text
Job → WorkerPool → worker[N] (per-core LIFO queue)
         ↓
    steal(neighbor) ← cost-benefit → migrate(job)
         ↓
    load_state (NORMAL ↔ MEDIUM ↔ OVERLOAD)
```

#### 7.0a CPU topology detection (`src/cpu.zig`)

- **`CpuTopology`**: logical/physical cores, HT siblings, cache hierarchy (deduplicated), NUMA nodes, CPU class (tiny/pc/workstation/manycore).
- **Windows kernel32 extern**: `GetLogicalProcessorInformationEx` (primary) + `GetLogicalProcessorInformation` (fallback).
- **Cache dedup**: one entry per unique cache level/size, not per-core duplicates.

#### 7.3 Latency Protection layer

**Core model**:
- **`LatencyProfile`**: migration cost matrix, NUMA penalty, cache distance, per-core NUMA.
- **Score**: `load × LOAD_PENALTY + migrationCost + cacheDistance × SCALE + numaPenalty`.
- **Cost heuristics**: HT-sibling=50ns, same-NUMA=200ns, cross-NUMA=1000ns.

**Per-core adaptive steal threshold**:
- Each core maintains `CoreStats` (attempts, successes, EMA cost/benefit).
- Threshold = `avg_cost + avg_cost × fail_ratio / 2` — core learns which steals are profitable.
- `fail_ratio = (attempts − succ) / attempts` (fixed-point, α=1/16).
- Cold start: `cost × 2` when attempts < 4.

**Sticky core + hysteresis**:
- `Job.sticky_core` / `stickiness` — job stays on its core when steal is attempted.
- `migration_cooldown_ns=50ms` — prevents ping-pong migrations.

**Load state machine (three-state hysteresis)**:
```
                   smoothed ≥ 4 (MEDIUM_ENTER)
     NORMAL ─────────────────────────────► MEDIUM
         ◄───────────────────────────────
         smoothed ≤ 2 (MEDIUM_EXIT)

                   smoothed ≥ 8 (OVERLOAD_ENTER)
     MEDIUM ─────────────────────────────► OVERLOAD
         ◄───────────────────────────────
         smoothed ≤ 5 (OVERLOAD_EXIT)
```
- **`smoothed_load`**: EMA of queue length (α=1/8) — shields against burst noise.
- **NORMAL**: strict cost-benefit + adaptive threshold + sticky honored + cooldown.
- **MEDIUM**: relaxed (cost-benefit skipped) + sticky honored + cooldown.
- **OVERLOAD**: unconditional steal — sticky bypassed, cooldown bypassed.

**Overload escape**: at OVERLOAD victim state — all locality constraints are removed, preventing biased locality trap.

#### Testing

```bash
zig test src\scheduler_test.zig   # 16 tests (sync/threaded/priority/steal/latency/state-machine)
zig test src\latency_test.zig     # 5 tests (matrix build, NUMA, migration log, score)
zig test src\cpu_test.zig         # 1 test (topology detection)
```

| Component | Description |
|-----------|-------------|
| `Tier` | Enum L1/L2/L3/DISK. FSM: `moveHotter`/`moveColder` → `?Tier` |
| `Chunk` | 64KB region: tier, arena_base, heat, used, arena_offset, slot_count, last_migration_tick |
| `ChunkStore` | Chunk array + free-list, alloc/find/release-by-tier |
| `Handle` | Generational slot identifier: slot + generation |
| `HandleTable` | Slot states (Used/Free), O(1) free-list, invalidation via generation |
| `MetaStore` | SoA: chunk_ids, offsets, sizes, generations, heats, total_heats, states |
| `Arena` | Three-tier bump allocator (L1/L2/L3), fail-fast on OOM |
| `Snapshot` | Snapshot: per-slot tiers/heats/states/gens + per-chunk tiers/heats |
| `assertInvariant` | Private — only inside validateHandle/validateChunkOps |

### Testing

```bash
zig test src\runtime_test.zig   # 40 unit tests (chunk model + cooldown + top-K + cost + memory layer)
zig test src\stress_test.zig    # 100k ops: 3817 migrations, deterministic fingerprint
zig test src\scheduler_test.zig # 16 tests: sync/threaded/priority/steal/latency/state-machine
```

### Intrinsic binding

`x64gen.zig` uses `inline for (comptime std.meta.tags(rt.Intrinsic))` for
exhaustive generation of all runtime functions. Adding an `Intrinsic` variant
causes a compile error until `emitOneIntrinsic` handles it.

### Scheduler budget guard

To prevent always-transition livelock, each tick has a budget (4 transitions).
- **Scheduler** (`always_entry`): read-only guard — checks budget > 0
- **FSM** (`changeToState`): consumption — decrement on real always transition
- Budget resets to 4 on each `ReadFile` (tick start)

### Spill chain

The arena allocator (bump-pointer) cascades allocation:
- `arena_l1_alloc` → try L1 → spill L2 → spill L3 → oom
- `arena_l2_alloc` → try L2 → spill L3 → oom
- `arena_l1_reset` resets all three arenas (L1+L2+L3)

Arena sizes are computed dynamically: `max_data_size × (8 + MIGRATION_BUDGET)`,
minimum 256 bytes.

---

## Code Generation Optimizations

### Jump-table dispatch

State dispatch uses an O(1) jump table instead of a linear CMP/JE chain:

```asm
MOV R12, [RBP + off_cur_state]
CMP R12, N; JAE re_dispatch
LEA R11, [RIP + jmp_table]
MOV EAX, [R11 + R12*4]
ADD RAX, R11
JMP RAX
```

The table stores 32-bit relative offsets filled at link time via `applyFixups`.
Scale = 4 (4-byte entries). Eliminates O(n) dispatch entirely — no structural
degradation regardless of state count.

### Superblock fusion (always-chain fusion)

Greedy linear expansion: states where `transitions.len == 1 && is_always &&
target_idx == si + chain_len` are fused into fallthrough chains. Fused states
skip L1 reset, budget decrement, and JMP back to the scheduler. Only the last
state in a chain does a normal exit.

This transforms:

```text
A → scheduler → dispatch → B → scheduler → dispatch → C
```

into:

```text
A fallthrough B fallthrough C
```

### Compiled event matching

Instead of a byte-by-byte comparison loop at runtime, event names ≤4 bytes are
matched with direct inline `CMP` using immediate values:

```asm
; event "go" (2 bytes)
MOVZX RAX, WORD [RDI]     ; load 2 bytes from input
CMP   RAX, 0x6F67         ; compare with "go"
JNE   next_event           ; not this event
MOVZX RAX, BYTE [RDI+2]   ; check delimiter
CMP   RAX, 0x0A; JE match ; newline?
```

This eliminates:
- Loop pointer increments (INC RDI, INC RSI)
- Null-term check per iteration
- Loop back-edge branch (JMP loop)
- Taken/not-taken branch mispredictions from the comparison loop

Longer event names fall back to the byte loop.

### Label interning

All labels are assigned a single `u32` ID at compile time via `allocLabelId`.
String formatting only occurs once per unique label (memoized via
`label_name_map`). Hot emit loops use pre-computed `dp_id[i]` / `en_id[i]`
arrays — zero formatting, zero allocation in per-state code generation.

`Fixup` stores `label_id: u32` instead of `label: []const u8`. No per-fixup
string duplication.

### O(1) state lookup

`state_index_map` (`StringHashMap(usize)`) replaces all O(n) `findStateIndex`
linear scans. Built once at initialization after parsing.

---

**Limitations:**
- Windows x64 only.
- Minimal error messages.
- Reads input from stdin (one line = one event).
- No LLVM, WASM, GPU, LSP, DISK tier support.
