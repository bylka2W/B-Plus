# B+ v2.1.3VS — язык конечных автоматов + система памяти

B+ — язык описания конечных автоматов (state machine) с транспиляцией в **Python, C#, C++, C**, а также плагинами для **Unity, Unreal Engine, Godot и Web (TypeScript)**. Никакого рантайма — чистый код под твою платформу.

**v2.1.3VS**: Система памяти — три режима (`smart` / `precise` / `ultra`), аннотации `@live`, `@quant`, `@align`, `@compress`, `@stream`, `@pool`, `@region`, регионы с автоматическим временем жизни.
**v2.1.3VS+**: LLVM backend — `kernel` → **LLVM IR** (`.ll`) → `.obj` напрямую, без C++ посередине. `--target llvm`.

## Установка

**Скопируй это в терминал (CMD / PowerShell):**

```bash
git clone https://github.com/CapGames221/B-Plus.git "B+ v1.0"
cd "B+ v1.0"
dotnet run --project src/BPlusTranspiler -- examples/traffic_light.bp
```

Первая команда скачает B+ в папку `B+ v1.0`, вторая зайдёт туда, третья соберёт и запустит пример. **Всё.**

Нужен [.NET 8 SDK](https://dotnet.microsoft.com/download) — если не стоит, скачай за 1 минуту.

**Для VS2022:** файл `BPlusLanguage.vsix` → клик → Install. Подсветка синтаксиса готова.

## Быстрый старт

```bp
// traffic_light.bp
state Red    { on timer -> Green  enter { stop_traffic() } }
state Green  { on timer -> Yellow enter { allow_traffic() } }
state Yellow { on timer -> Red    enter { warn_traffic() } }
```

```bash
dotnet run --project src/BPlusTranspiler -- examples/traffic_light.bp
```

## CLI Reference (bpc)

```bash
# Транспиляция
bpc input.bp                          # все цели сразу
bpc input.bp --target python          # → generated.py
bpc input.bp --target csharp          # → generated.cs
bpc input.bp --target cpp             # → states.h + states.cpp
bpc input.bp --target llvm            # → kernels.ll (LLVM IR, без C++)
bpc input.bp --target c               # → states.h + states.c
bpc input.bp --output ./out           # кастомный выход

# Оптимизация (синтаксис B+ не меняется)
bpc input.bp --optimize               # таблица переходов вместо virtual
bpc input.bp --pool                   # пул состояний, без new/delete
bpc input.bp --cache-friendly         # упорядоченный layout данных
bpc input.bp --prefetch               # предзагрузка кэша
bpc input.bp --branchless             # cmov вместо if/else
bpc input.bp --predict                # предсказание след. состояния
bpc input.bp --pack                   # упаковка структур
bpc input.bp --turbo                  # --optimize + --pool + --pack
bpc input.bp --eco                    # энергосбережение
bpc input.bp --target cpp --pack --pool --benchmark

# Диагностика (7 категорий ошибок)
bpc input.bp --check                  # анализ + остановка
bpc input.bp                          # анализ информационно + генерация

# Анализ проекта
bpc health                            # мёртвые состояния, память, связи
bpc health src/                       # по директории
bpc health --turbo                    # с учётом оптимизаций

# Семантическое сравнение
bpc diff old.bp new.bp                # что изменилось в AST

# Сборка по конфигу
bpc build                             # читает bp.toml
bpc build --dry-run                   # что будет сделано
bpc build --config ./game/bp.toml     # кастомный путь

# Плагины движков
bpc input.bp --plugin unity           # → MonoBehaviour
bpc input.bp --plugin unreal          # → UCLASS Actor
bpc input.bp --plugin godot           # → Godot Node
bpc input.bp --plugin web             # → TypeScript класс

# Инструменты
bpc --visualize input.bp              # → интерактивный граф (HTML/Mermaid)
bpc format input.bp                   # → автоформатирование
bpc docs input.bp                     # → документация (.md + .html)
bpc debug input.bp                    # → интерактивный дебаггер
bpc profile input.bp 10000            # → профайлинг переходов
bpc watch . --target cpp              # → автоперегенерация при изменениях

# LSP
bpc --lsp                             # → LSP для VS Code/Vim/Emacs
bpc --install-lsp                     # → установка VS Code extension

# Пакетный менеджер (BPM)
bpc bpm init my-package               # → новый пакет
bpc bpm install path                  # → установка
bpc bpm search term                   # → поиск
bpc bpm publish                       # → публикация

# Тестирование
bpc test run input.bp                 # → автотесты переходов
```

## bp.toml — конфиг вместо флагов

```toml
[project]
name    = "my_game"
version = "1.0.0"

[build]
mode        = "turbo"
target      = "cpp"
output      = "./gen"
incremental = true
parallel    = true
cache       = true
flags       = ["--pack", "--pool", "--benchmark"]
plugin      = "unity"

[deps]
fsr  = "4.0"
dx12 = "auto"
```

## Возможности

| Фича | Пример |
|------|--------|
| Состояния | `state Idle { }` |
| Переходы | `on event -> Target { body }` |
| Условия (guard) | `on hit [lives <= 0] -> Dead` |
| Параметры | `on key_press(key: string)` |
| Таймеры | `after 5s -> Timeout` |
| Переменные | `var score: int = 0` |
| Контекст | `context { var max: int }` |
| Перечисления | `enum GameMode { Easy, Normal }` |
| Вложенные состояния | `state Outer { state Inner { } }` |
| Параллельные блоки | `parallel Name { state A state B }` |
| Наследование | `state Boss : Enemy { }` |
| Дженерики | `state Inventory<T> { }` |
| Сигналы | `on signal "error" -> Handler` |
| Async | `async on load -> Done` |
| Auto-переходы | `always -> Next` |

## LLVM Backend — машинный код без C++ (v2.1.3VS+)

B+ теперь умеет генерировать **LLVM IR** (промежуточное представление LLVM) напрямую — минуя C++.

```bash
# Сгенерировать kernels.ll
dotnet run --project src/BPlusTranspiler -- examples/memory_demo.bp --target llvm

# Скомпилировать в .obj (нужен LLVM: https://llvm.org)
llc -filetype=obj gen/kernels.ll -o gen/kernels.obj

# Линковать в исполняемый файл
clang gen/kernels.obj -o gen/kernels.exe
```

Что даёт LLVM backend:
- **Без C++** — не нужен GCC/Clang для компиляции B+-кода
- **Быстрее** — LLVM оптимизирует под конкретное железо (`target triple`)
- **GPU** — LLVM умеет SPIR-V (Vulkan) и будет использован для шейдеров
- **Мосты** — LLVM IR → WASM, AArch64, ARM, RISC-V

Текущий статус: `kernel` → `llvm.memcpy` → `.ll`. Далее: pipeline операторы (convolve, relu, shuffle, clamp), GPU (SPIR-V/DXIL), мосты.

## Система памяти (v2.1.3VS+)

Три режима управления памятью — синтаксис кода не меняется.

| Режим | Описание |
|-------|----------|
| `#memory smart` | Компилятор сам решает где что хранит |
| `#memory precise` | Ты явно указываешь аннотации |
| `#memory ultra` | Максимальное сжатие (int4, BC1) |

```bp
#memory smart
#vram    budget: 8gb
#ram     budget: 16gb
#cache   auto
#defrag  auto
#streaming priority: camera

@live(vram, always)               -- всегда в VRAM
@quant(int8)                      -- сжать до int8
@align(cacheline)                 -- по кеш-линии
weights_precise: ConvWeights[3,3,3,64] = @load("w.bin")

@live(ram, when_visible)          -- RAM, в VRAM только когда видно
@compress(bc7)                    -- сжатие текстур BC7
@stream(priority: high)           -- стриминг с высоким приоритетом
textures_precise: TextureAtlas[1024] = @stream("textures/")

@live(l2_cache, hot)              -- держать в L2 кеше
@align(64)                        -- выровнять по кеш-линии
hot_data: HotBuffer[256]

@stream(
    source:   "assets/textures/",
    resident: 512mb,
    evict:    lru,
    prefetch: 2
)
world_textures: TextureAtlas[4096]

@region(frame)                    -- живёт один кадр
kernel upscale(src: Image[H,W]) -> Image[H*2, W*2]
    body:
        src |> convolve(weights) |> relu |> shuffle(2) |> clamp(0.0, 1.0)
```

Подробнее: `examples/memory_demo.bp`.

## Флаги оптимизации (синтаксис B+ не меняется)

`--optimize` — таблица переходов вместо virtual dispatch (+10-30%)<br>
`--pool` — пул состояний, без new/delete (+20-40%)<br>
`--cache-friendly` — упорядоченный layout данных (+10-20%)<br>
`--prefetch` — программная предзагрузка кэша (+10-20%)<br>
`--branchless` — cmov вместо if/else в переходах (+5-15%)<br>
`--predict` — предсказание следующего состояния (+5-15%)<br>
`--pack` — битфилды, упаковка структур (-40% памяти)<br>
`--eco` — энергосбережение (узкие SIMD)<br>
`--lto` — Link-Time Optimization (+5-10%)<br>
`--lock-free` — безлоковые структуры (+5-10%)<br>
**`--turbo`** — **--optimize + --pool + --pack** (+40-80%)<br>
`--turbo-embed` — --pack + --eco для embedded<br>
`--benchmark` — сгенерировать бенчмарк-обёртку<br>
`--thread-pool <N>` — многопоточная диспетчеризация (+Nx по ядрам)

## Диагностика (bpc --check)

7 категорий ошибок при анализе BP-файла:

| Категория | Тип | Пример |
|-----------|-----|--------|
| **ТИП** | ❌ Ошибка | несуществующее состояние, неизвестный тип |
| **ГРАНИЦА** | ❌ Ошибка | таймер 0, самопетля без guard |
| **ГОНКА ДАННЫХ** | ⚠ Предупреждение | параллельные блоки пишут в одно и то же |
| **ПАМЯТЬ** | ⚠ Предупреждение | много new State() без pool |
| **ТЕМПЕРАТУРА** | ⚠ Предупреждение | AVX-512 без охлаждения |
| **СКОРОСТЬ** | 💡 Подсказка | --optimize не включён, пустые состояния |
| **КОНТРАКТ** | ❌ Ошибка | недостижимое состояние, дубликат имени |

## Пример генерации

```bp
state Game {
    var score: int = 0
    on hit -> Game { score += 10 }
    on die [score > 100] -> Victory
}
```

**→ C++ (обычный):**
```cpp
class Game : public State {
public:
    int score = 0;
    State* on_hit() override { score += 10; return new Game(); }
    State* on_die() override { if (score > 100) return new Victory(); return nullptr; }
};
```

**→ C++ (--turbo):**
```cpp
enum StateId : uint8_t { ST_Game, ST_Victory, ST_COUNT };
enum Event : uint8_t { EV_hit, EV_die, EV_COUNT };

StateId transition_table[ST_COUNT][EV_COUNT] = {
    { ST_Game, (StateId)-1 },  // Game
    { (StateId)-1, (StateId)-1 },  // Victory
};

StateId run_transition(StateId current, Event ev) {
    if (exit_table[current]) exit_table[current]();
    StateId next = transition_table[current][ev];
    StateId guarded = check_transition(current, ev);
    if (guarded != (StateId)-1) next = guarded;
    if (next != (StateId)-1 && enter_table[next]) enter_table[next]();
    return next;
}
```

**→ Python, C#, C** — аналогично, без virtual-диспетчеризации при --optimize.

## Структура проекта

```
B+ v1.0/
├── bp.toml                          ← конфиг сборки
├── src/
│   ├── BPlusTranspiler/             ← Транспилятор (.NET 8)
│   │   ├── Ast/                     — AST-ноды
│   │   ├── Parser/                  — Парсер .bp
│   │   ├── Optimizer/              — AST оптимизатор
│   │   ├── Generators/             — Python, C#, C++, C, LLVM
│   │   │   ├── LlvmGenerator.cs    — AST → LLVM IR (без C++)
│   │   │   └── CppOptimizedGenerator.cs  — оптимизированный C++
│   │   ├── Lsp/                    — LSP сервер
│   │   ├── Visualizer/             — Граф состояний (Mermaid)
│   │   ├── DocGen/                 — Генератор документации
│   │   ├── Debugger/               — Интерактивный дебаггер
│   │   ├── Profiler/               — Профайлинг
│   │   ├── Plugins/                — Unity, Unreal, Godot, Web
│   │   ├── PackageManager/         — BPM
│   │   ├── TestRunner/             — Автотесты
│   │   ├── OptimizationFlags.cs    — Все флаги оптимизации
│   │   ├── BPlusErrorReporter.cs   — 7 категорий диагностики
│   │   ├── BPlusHealth.cs          — bpc health
│   │   ├── BPlusDiff.cs            — bpc diff
│   │   ├── BPlusBuild.cs           — bpc build + bp.toml
│   │   └── Program.cs              — CLI (bpc)
│   └── vs-extension/               ← VS2022 extension (.vsix)
├── examples/                        ← .bp примеры
│   ├── traffic_light.bp             — базовый пример
│   ├── game.bp / game_full.bp       — игровой автомат
│   ├── vending_machine.bp           — торговый автомат
│   ├── dead_state_test.bp           — диагностика dead state
│   ├── memory_demo.bp               — демо системы памяти
│   ├── test_array_type.bp           — тест TypeName[N]
│   ├── test_annotation_values.bp    — тест строковых аргументов
│   ├── test_standalone_region.bp    — тест standalone @region
│   ├── test_memory_modes.bp         — тест трёх режимов памяти
│   ├── test_llvm.bp                 — тест LLVM backend (kernel → .ll)
│   ├── noise_gen.bp                 — генератор шума (в разработке)
│   └── gen_bpm_test/                — тест BPM
├── test_memory.bp                   — интеграционный тест памяти
├── test_memory_full.bp              — полный тест памяти
└── BPlusLanguage.vsix               ← VS extension
```

## Тестирование

Все тесты проходят `--check` без ошибок:

```bash
# Проверка всех примеров
for f in examples/*.bp; do dotnet run --project src/BPlusTranspiler -- $f --check; done

# Полная транспиляция с генерацией
dotnet run --project src/BPlusTranspiler -- examples/memory_demo.bp

# Разные режимы памяти
dotnet run --project src/BPlusTranspiler -- examples/test_memory_modes.bp --check

# ArrayType — TypeName[N]
dotnet run --project src/BPlusTranspiler -- examples/test_array_type.bp --check

# Аннотации со строками
dotnet run --project src/BPlusTranspiler -- examples/test_annotation_values.bp --check

# Standalone @region
dotnet run --project src/BPlusTranspiler -- examples/test_standalone_region.bp --check
```

## Бенчмарк: B+ vs C++

Честный замер на state machine из 3 состояний (traffic light),
10 млн итераций, `-O3 -std=c++20`.

```bash
clang++ -O3 -std=c++20 benchmark_traffic.cpp -o bench && ./bench
```

Ожидаемые результаты (traffic light, 3 стейта, 1 событие, 10M итераций):

```
C++ наивный (virtual + new/delete)        ~30-50 нс/ит    1× (база)
C++ таблица + пул                         ~5-10 нс/ит     ~3-5× быстрее
B+ --optimize                             ~5-10 нс/ит     ~3-5× быстрее
B+ --turbo                                ~4-8 нс/ит      ~4-6× быстрее
```

B+ генерирует **тот же код**, что и оптимизированный C++ вручную. Прирост — не магия, а устранение virtual dispatch (×2-3) и new/delete (×2-3). В сумме на пустом цикле даёт ~3-5×. В реальном приложении, где состояния живут дольше одного перехода, разница будет **~10-30%**, потому что основное время — не диспетчеризация, а логика самих состояний.

### Запустить самому

```bash
# Сгенерировать C++ с бенчмарком
bpc input.bp --target cpp --turbo --benchmark=10000000

# В benchmark_traffic.cpp — готовый файл для сравнения
clang++ -O3 benchmark_traffic.cpp -o bench && ./bench
```

## VS Extension

`BPlusLanguage.vsix` — подсветка синтаксиса и IntelliSense для `.bp` файлов в Visual Studio 2022. Установка: дважды кликнуть.

## Лицензия

MIT
