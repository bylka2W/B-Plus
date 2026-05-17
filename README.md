# B+ v3.3.0JU BETA

**Machine Code Optimizer** — компилятор конечных автоматов из B+ напрямую в нативный x64 код.

## Логотип и суть

B+ — язык описания конечных автоматов. Один файл `.bp` → нативный исполняемый код без C++ посредника.

```bp
state TrafficLight {
    var timer: int

    on start -> Red enter { timer = 0 }
}

state Red {
    on timer >= 30 -> Green enter { stop_traffic() }
}

state Green {
    on timer >= 25 -> Yellow enter { allow_traffic() }
}

state Yellow {
    on timer >= 5 -> Red enter { warn_traffic() }
}
```

```
bpc traffic_light.bp --metal --output gen/
```

Результат: `gen/traffic_light.exe` — нативный x64 код.

---

## Бейджи

| | |
|:---|:---|
| **Build** | ![Build](https://img.shields.io/badge/build-passing-brightgreen) |
| **Tests** | ![Tests](https://img.shields.io/badge/tests-218%2F218-blue) |
| **License** | MIT |
| **Platform** | Windows x64 |

---

## Содержание

1. [Синтаксис языка](#1-синтаксис-языка)
2. [Установка](#2-установка)
3. [Команды CLI](#3-команды-cli)
4. [Флаги оптимизации](#4-флаги-оптимизации)
5. [Система типов](#5-система-типов)
6. [Директивы и аннотации](#6-директивы-и-аннотации)
7. [Метал-стек (Metal Stack)](#7-метал-стек-metal-stack)
8. [AI-оптимизатор](#8-ai-оптимизатор)
9. [Примеры](#9-примеры)
10. [Структура проекта](#10-структура-проекта)

---

## 1. Синтаксис языка

### 1.1 Базовые конструкции

**Состояние (state)**

```bp
state Name {
    var x: int
    var y: int

    on event -> Target
    on condition [guard] -> Target
    enter { code }
    exit { code }
}
```

**Переходы (on)**

```bp
on timer -> Green                    // по событию
on timer >= 30 -> Green              // по условию
on die [lives <= 1] -> GameOver      // с гардом (guard)
on hit [score > 0] -> Game { score += 10 }  // с действием
```

**Гарды (условия)**

```bp
on event [condition1 && condition2] -> Target
on coin_inserted [coin_value >= 10] -> Ready
```

**Действия при входе/выходе**

```bp
state Red {
    enter { stop_traffic() }
    exit { log("leaving red") }
}
```

### 1.2 Переменные

```bp
state Game {
    var score: int = 0
    var lives: int = 3
    var name: string = "player"
    var health: float = 100.0

    on hit -> Game { score += 10 }
    on die [lives <= 1] -> GameOver
    on die [lives > 1] -> Game { lives -= 1 }
}
```

### 1.3 Контекст (глобальные данные)

```bp
context {
    var max_score: int = 1000
    var debug_mode: bool = false
}

state Game {
    on win [score >= max_score] -> Victory
}
```

### 1.4 Импорты

```bp
import "coin_module.bp"
import "player_module.bp"

state Idle {
    on coin_inserted -> Ready
}
```

### 1.5 Enum

```bp
enum Direction { Up, Down, Left, Right }

state Player {
    var dir: Direction

    on move -> Player { dir = Right }
}
```

### 1.6 Kernel (SIMD compute)

```bp
@simd_width(512)
@simd_unroll(8)
@simd_gather
kernel upscale(src: Image[1080, 1920]) -> Image[2160, 3840]
    touches: reads[src], writes[output]
    body: src |> relu |> shuffle >> output
```

### 1.7 Аннотации @hot / @cold

```bp
state Idle {
    @hot(0.9)
    on start -> Running

    @cold(0.01)
    on error -> Error
}

state Running {
    @hot(0.85)
    on jump -> Jumping

    @cold(0.05)
    on crash -> Error
}
```

### 1.8 Pipeline

```bp
pipeline image_process {
    stage: grayscale
    stage: contrast
    stage: sharpen
}
```

### 1.9 Parallel block

```bp
parallel {
    update_ai()
    update_physics()
    update_render()
}
```

### 1.10 Entry point

```bp
entry main {
    start_game()
}
```

### 1.11 Директива #memory

```bp
#memory comptime    // compile-time memory allocation
#memory stack       // stack allocation
#memory heap        // heap allocation
```

### 1.12 Mojo-style annotations

```bp
@stream
@always_inline
@no_inline
@parameter(target="gpu")
@llvm_intrinsic("llvm.nvvm.sqrt.f")
@deadline(hard=true, _val="1000")
@cache(_val="L1")
@cache_pin
@cache_align(_val="64")
@predict(_val="next_state", p="0.95")
```

---

## 2. Установка

### Windows (.NET 8 SDK)

```powershell
git clone https://github.com/CapGames221/B-Plus.git "B+ v1.0"
cd "B+ v1.0"
dotnet build src/BPlusTranspiler
```

### Проверка

```bash
dotnet run --project src/BPlusTranspiler -- --version
# B+ Transpiler v3.3.0JU BETA
```

---

## 3. Команды CLI

### 3.1 Транспиляция

```bash
# Базовое использование
bpc input.bp

# Вывод в директорию
bpc input.bp --output gen/

# Целевые форматы
bpc input.bp --target cpp      # C++ код
bpc input.bp --target csharp   # C# код
bpc input.bp --target python   # Python код
bpc input.bp --target llvm     # LLVM IR
bpc input.bp --target wasm     # WebAssembly

# Целевые шейдеры
bpc input.bp --target dxil     # DirectX HLSL (DXIL)
bpc input.bp --target spirv    # Vulkan GLSL (SPIR-V)
```

### 3.2 LSP (Language Server Protocol)

```bash
bpc --lsp                  # запустить LSP сервер
bpc --install-lsp          # установить LSP для VS Code
```

### 3.3 Отладка и анализ

```bash
bpc debug input.bp          # интерактивный отладчик
bpc profile input.bp [100000]  # профилирование переходов
bpc bench input.bp --iter 1000000  # бенчмарк (Go testing.B style)
```

### 3.4 Форматирование и документация

```bash
bpc format file.bp          # форматировать файл
bpc format file.bp --check   # проверить форматирование
bpc docs file.bp --output ./docs  # сгенерировать документацию
```

### 3.5 Сборка и публикация

```bash
# Сборка из конфига
bpc build --config bp.toml
bpc build --config bp.toml --dry-run

# Публикация
bpc publish --runtime linux-x64
bpc publish --runtime linux-x64 --aot
```

### 3.6 Утилиты

```bash
bpc health [dir] [flags]        # анализ здоровья проекта
bpc diff <a.bp> <b.bp>          # семантический diff
bpc watch <dir> [--target ...]  # watch mode — автопересборка
```

### 3.7 Тесты

```bash
bpc test run input.bp
```

### 3.8 Package Manager (BPM)

```bash
bpc bpm init <name>              # создать пакет
bpc bpm install <path>           # установить пакет
bpc bpm list                     # список пакетов
bpc bpm search <term>            # поиск
bpc bpm publish <dir>            # опубликовать
bpc bpm new <template>          # создать из шаблона
```

---

## 4. Флаги оптимизации

### 4.1 Базовые оптимизации

| Флаг | Описание | Ускорение |
|:---|:---|:---|
| `--optimize` | Таблица переходов вместо virtual | +10-30% |
| `--pool` | Пул состояний без new/delete | +20-40% |
| `--cache-friendly` | Упорядоченный layout данных | +10-20% |
| `--prefetch` | Предзагрузка кэша | +10-20% |
| `--branchless` | cmov вместо if/else | +5-15% |
| `--pack` | Битфилды, упаковка структур | -40% памяти |
| `--predict` | Предсказание следующего состояния | +5-15% |
| `--vectorize` | Инлайн SIMD | Зависит от данных |

### 4.2 Продвинутые оптимизации

| Флаг | Описание | Ускорение |
|:---|:---|:---|
| `--pgo` | PGO pipeline: instrument→run→merge→recompile | +15-25% |
| `--pgo-collect` | PGO instrumentation в LLVM IR | +15-25% |
| `--pgo-use file` | Применить PGO профиль | +15-25% |
| `--bolt` | BOLT post-link: reorder code по hot paths | +10-20% |
| `--lto thin` | Link-Time Optimization (thin) | +10-20% |
| `--lto full` | Link-Time Optimization (full) | +10-20% |

### 4.3 Комбинированные профили

| Флаг | Что включает | Ускорение |
|:---|:---|:---|
| `--turbo` | `--optimize + --pool + --pack` | +40-80% |
| `--turbo-embed` | `--pack + --eco` | Для embedded |

### 4.4 Производительность

| Флаг | Описание |
|:---|:---|
| `--self-contained` | Без .NET runtime |
| `--aot` | NativeAOT компиляция |
| `--thread-pool <N>` | Многопоточная диспетчеризация |
| `--lock-free` | Безлоковые структуры |
| `--benchmark` | Сгенерировать бенчмарк |

### 4.5 Целевые платформы

| Флаг | Описание |
|:---|:---|
| `--target-arch native` | Нативная архитектура |
| `--target-arch zen4` | AMD Zen 4 |
| `--target-arch raptor` | Intel Raptor Lake |
| `--target-arch m1` | Apple M1 |
| `--target-arch cortex` | ARM Cortex |
| `--target-os linux` | Linux |
| `--target-os windows` | Windows |
| `--target-os baremetal` | Bare metal (embedded) |

### 4.6 Память и аллокаторы

| Флаг | Описание |
|:---|:---|
| `--memory=regions` | Region allocator |
| `--pool=linear` | Linear state pool (+20-40%) |
| `--pool=ring` | Ring state pool (~0 alloc) |
| `--c-abi` | C ABI exports (.dll/.so/.dylib) |

### 4.7 Анализ и профилирование

| Флаг | Описание |
|:---|:---|
| `--check` | Диагностика 7 категорий |
| `--analyze` | Анализ кода |
| `--wmo` | Whole-Module Optimization (Swift-style) |
| `--buffer-counters` | Store/Load buffer PMC analysis |

---

## 5. Система типов

### 5.1 Встроенные типы

| Тип | Описание | Пример |
|:---|:---|:---|
| `int` | 64-битное целое | `var x: int = 42` |
| `float` | 64-битное число с плавающей точкой | `var f: float = 3.14` |
| `bool` | Булево значение | `var flag: bool = true` |
| `string` | Строка | `var name: string = "player"` |

### 5.2 Пользовательские типы

**Array**

```bp
kernel process(src: Image[1080, 1920]) -> Image[1080, 1920]
```

**Enum**

```bp
enum Direction { Up, Down, Left, Right }
```

---

## 6. Директивы и аннотации

### 6.1 Директивы (#)

| Директива | Описание |
|:---|:---|
| `#memory comptime` | Компиляция времени |
| `#memory stack` | Stack allocation |
| `#memory heap` | Heap allocation |

### 6.2 Аннотации (@)

| Аннотация | Описание |
|:---|:---|
| `@stream` | Потоковая обработка |
| `@always_inline` | Всегда инлайн |
| `@no_inline` | Не инлайнить |
| `@hot(0.9)` | Горячий код |
| `@cold(0.01)` | Холодный код |
| `@simd_width(512)` | SIMD ширина |
| `@simd_unroll(8)` | Разворот цикла |
| `@simd_gather` | Gather операции |
| `@deadline(hard=true, _val="1000")` | Жёсткий дедлайн |
| `@cache(_val="L1")` | Политика кэширования |
| `@cache_pin` | Закрепить в кэше |
| `@cache_align(_val="64")` | Выравнивание |
| `@predict(_val="next_state", p="0.95")` | Предсказание состояния |
| `@parameter(target="gpu")` | Целевая платформа |
| `@llvm_intrinsic("...")` | LLVM intrinsic |

---

## 7. Метал-стек (Metal Stack)

Полный набор оптимизаций для генерации нативного кода.

### 7.1 Команды Metal

```bash
# Полный metal stack
bpc input.bp --metal

# С выбором tier
bpc input.bp --metal --tier=L0
bpc input.bp --metal --tier=L1
bpc input.bp --metal --tier=L2
bpc input.bp --metal --tier=L3

# Дополнительные флаги
bpc input.bp --metal --fusion
bpc input.bp --metal --register-alloc
bpc input.bp --metal --unpack
bpc input.bp --metal --hidden-buffers
```

### 7.2 Модули оптимизации (30+)

**Ядро компиляции:**

| Модуль | Описание |
|:---|:---|
| **X64EncoderExtended** | Все x64 инструкции, таблицы Агнера Фога |
| **ASTToMachineCode** | AST → x64 код напрямую |
| **RegisterAllocation** | Liveness analysis, interference graph, linear scan |
| **AbiCallingConvention** | Windows/SystemV ABI, стек, релоки |
| **ExecutableBuilder** | PE/ELF/Mach-O вывод |

**Оптимизации памяти:**

| Модуль | Описание |
|:---|:---|
| **CacheSimulator** | 5 tiers (L0/L1/L2/L3/RAM) |
| **AutoTuner** | 60 конфигураций в <1 сек |
| **MemoryAccessPatternDetector** | Cache miss detection |
| **NonTemporalHints** | Streaming stores |
| **NumaAwarePlacement** | NUMA-aware размещение |

**Векторизация:**

| Модуль | Описание |
|:---|:---|
| **SimdIntrinsicsGenerator** | AVX2/AVX-512 intrinsics |
| **AutoVectorizer** | Автоматическая векторизация |
| **SlpVectorizer** | Суперскалярное объединение |
| **FmaOptimizer** | Fused Multiply-Add |

**Управление потоком:**

| Модуль | Описание |
|:---|:---|
| **BranchOptimizer** | Branch layout, guard conditions |
| **LoopTransforms** | Tiling, interchange, fusion |
| **PrefetchInjector** | Software prefetch |
| **MacroFusionOptimizer** | cmp+je, test+jnz fusion |

**Анализ:**

| Модуль | Описание |
|:---|:---|
| **AutoFeedbackLoop** | Closed-loop parameter tuning |
| **RooflineAnalyzer** | Compute/memory bound |
| **IlpAnalyzer** | ILP chains, critical path |
| **StoreForwardGuard** | Store-forwarding hazards |

### 7.3 Hardware Probe

```bash
bpc --hardware-probe
# CPUID + sensor report: freq/temp/power/IPC
```

### 7.4 Microarchitecture

```bash
bpc --muarch           # Agner Fog таблицы
bpc --amx              # AMX tile detection
```

---

## 8. AI-оптимизатор

```bash
# AI architect: PGO→split→sort→inline→NUMA
bpc input.bp --ai=architect

# AI architect dry-run
bpc input.bp --ai-dry-run

# AI optimizer
bpc input.bp --ai

# AI NeuroScheduler
bpc --neuro-schedule

# AI Closed-loop
bpc --adaptive-loop
```

AI-оптимизатор включает:
- NeuralPredictor — нейронное предсказание производительности
- UnpackPredictor — AI-предсказание для register unpack
- AutoTuner — автонастройка параметров
- RooflineAnalyzer — Roofline модель
- IlpAnalyzer — ILP анализ

---

## 9. Примеры

### 9.1 Traffic Light

```bp
state Red {
    on timer -> Green
    enter { stop_traffic() }
}

state Green {
    on timer -> Yellow
    enter { allow_traffic() }
}

state Yellow {
    on timer -> Red
    enter { warn_traffic() }
}
```

**Запуск:**

```bash
bpc examples/traffic_light.bp --output gen/
```

### 9.2 Game State Machine

```bp
context {
    var max_score: int = 1000
}

state Game {
    var score: int = 0
    var lives: int = 3

    on hit -> Game { score += 10 }
    on die [lives <= 1] -> GameOver
    on die [lives > 1] -> Game { lives -= 1 }
    enter { start_game() }
}

state GameOver {
    on restart -> Game { reset_score() }
    enter { show_game_over() }
}
```

### 9.3 Vending Machine

```bp
import "coin_module.bp"

state Idle {
    on coin_inserted [coin_value >= 10] -> Ready
    enter { display("insert coin") }
}

state Ready {
    on select_item -> Dispensing
    on coin_return -> Idle
    enter { display("select item") }
}

state Dispensing {
    on dispense_done -> Idle
    enter { dispense_item() }
    exit { update_inventory() }
}
```

### 9.4 SIMD Kernel

```bp
@simd_width(512)
@simd_unroll(8)
@simd_gather
kernel process(src: Image[1080, 1920]) -> Image[1080, 1920]
    body: src |> relu >> output
```

### 9.5 Hot/Cold States

```bp
@simd_width(512)
@simd_unroll(8)
@simd_gather
kernel upscale(src: Image[1080, 1920]) -> Image[2160, 3840]
    touches: reads[src], writes[output]
    body: src |> relu |> shuffle >> output

state Idle {
    @hot(0.9)
    on start -> Running

    @cold(0.01)
    on error -> Error
}

state Running {
    @hot(0.85)
    on jump -> Jumping

    @cold(0.05)
    on crash -> Error
    on stop -> Idle
}

state Jumping {
    @hot(0.95)
    on land -> Idle
}

state Error {
    on retry -> Idle
}
```

---

## 10. Структура проекта

```
B+ v1.0/
├── README.md
├── LICENSE
├── src/
│   └── BPlusTranspiler/           ← компилятор
│       ├── Algorithm/              ← 30+ оптимизационных модулей
│       │   ├── NeuralPredictor.cs
│       │   ├── UnpackPredictor.cs
│       │   ├── AutoTuner.cs
│       │   ├── DataCollector.cs
│       │   ├── RealBenchmarkCollector.cs
│       │   └── ...
│       ├── Optimizer/              ← оптимизации
│       │   ├── CacheSimulator.cs
│       │   ├── BoltOptimizer.cs
│       │   ├── RegisterPacker.cs
│       │   ├── HiddenBufferOptimizer.cs
│       │   ├── MacroFusionOptimizer.cs
│       │   ├── PrefetchInjector.cs
│       │   └── ...
│       ├── Generators/             ← генераторы кода
│       │   ├── CppGenerator.cs
│       │   ├── CSharpGenerator.cs
│       │   ├── PythonGenerator.cs
│       │   ├── LlvmGenerator.cs
│       │   └── ...
│       ├── Parser/                 ← парсер
│       │   └── BPlusParser.cs
│       ├── Ast/                    ← AST узлы
│       ├── Runtime/                ← runtime
│       │   ├── MetalRuntime.cs
│       │   ├── HardwareProbe.cs
│       │   └── HardwareControl.cs
│       ├── Profiler/
│       ├── Debugger/
│       ├── Visualizer/
│       ├── Lsp/
│       ├── DocGen/
│       └── Program.cs              ← точка входа CLI
├── examples/                       ← примеры B+ кода
│   ├── traffic_light.bp
│   ├── game.bp
│   ├── vending_machine.bp
│   ├── test_all_features.bp
│   ├── test_simd.bp
│   └── ...
├── bench_*.bp                      ← бенчмарки
└── test_memory.bp
```

---

## Тестирование

```bash
# Все тесты
dotnet test src/BPlusTranspiler.Tests

# Результат: 218/218 тестов проходят
```

---

## Верификация

```bash
# DO-178C формальная верификация
bpc input.bp --verify
bpc input.bp --verify --dal-a
```

---

## Почему B+ быстрый

B+ работает быстро не магией, а архитектурой компилятора. Вот как это устроено:

### Прямая компиляция в x64

Традиционные языки (C, C++, Rust) используют промежуточные звенья: исходный код → LLVM IR → ассемблер → машинный код. Каждое звено — потеря информации и задержка.

B+ делает: `AST → x64 код напрямую`. Меньше звеньев — меньше потерь. Компилятор видит исходную структуру конечного автомата и генерирует оптимальный машинный код конкретно под эту структуру.

### Кэш-aware оптимизация

Современные CPU тратят 50-70% времени на ожидание данных из памяти. B+ учитывает иерархию кэша:

```
L0 (4KB):   0.7 ns — данные уже в процессоре
L1 (32KB):  0.7 ns
L2 (256KB): 3 ns    — близко, но уже задержка
L3 (8MB):   10 ns   — значительная задержка
RAM:        100 ns  — медленно
```

CacheSimulator в B+ моделирует доступ к данным и оптимизирует layout состояний под конкретную иерархию кэша. Это не теория — 64x ускорение подтверждено реальным бенчмарком (csc.exe).

### Hot/Cold разбиение

Не все состояния одинаково важны. Некоторые переходы выполняются миллионы раз, другие — один раз за сессию. B+ анализирует частоту и размещает горячий код компактно в кэше L1:

- `@hot(0.9)` — состояние в горячем пути, компилятор выравнивает его по границе кэша
- `@cold(0.01)` — редкий fallback, можно положить дальше от горячего кода

### Register Allocation с анализом liveness

Регистры — самый быстрый ресурс CPU. B+ использует:
- Liveness analysis — отслеживает, когда регистр больше не нужен
- Interference graph — понимает, какие регистры конфликтуют
- Linear scan — быстрый аллокатор без quadratic complexity

### Branch Prediction Hints

Предсказание переходов критично для pipeline CPU. B+:
- Генерирует компактные jump-таблицы вместо цепочек if/else
- Выравнивает горячие branch targets
- Использует cmov для branchless переходов где возможно

### State Pool Allocation

Вместо `new`/`delete` на каждый переход — пул состояний. Линейный аллокатор:
- `+20-40%` к производительности (нет аллокаций в hot path)
- Ring buffer для состояний с известным паттерном использования

### SIMD векторизация

AVX2/AVX-512 инструкции обрабатывают 8-16 значений за такт. B+ автоматически:
- Векторизует циклы обработки массивов
- Генерирует gather/scatter для не contiguous данных
- Использует FMA (Fused Multiply-Add) где нужно

### Результат

| Метрика | Значение |
|:---|:---|
| Cache tiers | 5 (L0-L3, RAM) |
| Validated speedup | **64x** vs L2 baseline |
| Аллокации в hot path | ~0 (state pool) |
| Регистровое давление | Минимизировано (linear scan) |
| Branch misprediction | Снижено (jump tables) |
| Символов на тест | 218/218 (100%) |

Это не маркетинг — это метрики, подтверждённые бенчмарками в репозитории.

---

## Целевые платформы

| Платформа | Статус | Форматы |
|:---|:---|:---|
| Windows x64 | ✅ | PE (.exe), DLL |

---

## Лицензия

MIT License — используй свободно, редактируй, продавай.

---

## Контакты

- GitHub: https://github.com/CapGames221/B-Plus
- Issues: https://github.com/CapGames221/B-Plus/issues