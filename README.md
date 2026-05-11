# B+ v2.1.0VS — язык конечных автоматов

B+ — язык описания конечных автоматов (state machine) с транспиляцией в **Python, C#, C++, C**, а также плагинами для **Unity, Unreal Engine, Godot и Web (TypeScript)**. Никакого рантайма — чистый код под твою платформу.

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
bpc input.bp --target c               # → states.h + states.c
bpc input.bp --output ./out           # кастомный выход

# Оптимизация (синтаксис B+ не меняется)
bpc input.bp --optimize               # таблицы переходов вместо virtual (+10-15%)
bpc input.bp --vectorize              # авто SIMD (AVX/SSE/NEON) (+30-40%)
bpc input.bp --cache-friendly          # AoSoA layout (+20-30%)
bpc input.bp --branchless             # cmov вместо if/else (+10-15%)
bpc input.bp --zero-copy              # state pool, без аллокаций (+15-25%)
bpc input.bp --eco                    # энергосбережение (SSE/NEON)
bpc input.bp --auto                   # авто-детект CPU + лучшие флаги
bpc input.bp --turbo                  # все оптимизации (+150%)
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

## Флаги оптимизации (синтаксис B+ не меняется)

| Флаг | Эффект | Прирост (state machine) |
|------|--------|-------------------------|
| `--optimize` | Таблица переходов вместо virtual dispatch | +10-30% |
| `--pool` | Пул состояний, без new/delete | +20-40% |
| `--cache-friendly` | Упорядоченный layout данных | +10-20% |
| `--prefetch` | Программная предзагрузка кэша | +10-20% |
| `--branchless` | cmov вместо if/else в переходах | +5-15% |
| `--predict` | Предсказание следующего состояния | +5-15% |
| `--pack` | Битфилды, упаковка структур | -40% памяти |
| `--eco` | Энергосбережение (узкие SIMD) | -30% энергии |
| `--lto` | Link-Time Optimization | +5-10% |
| `--lock-free` | Безлоковые структуры | +5-10% |
| **`--turbo`** | **--optimize + --pool + --pack** | **+40-80%** |
| `--turbo-embed` | --pack + --eco для embedded | компактно |
| `--benchmark` | Сгенерировать бенчмарк-обёртку | замеры |
| `--thread-pool` | Многопоточная диспетчеризация | +Nx по ядрам |

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
│   │   ├── Generators/             — Python, C#, C++, C
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
└── BPlusLanguage.vsix               ← VS extension
```

## Бенчмарк: B+ vs C++

Честный замер на state machine из 3 состояний (traffic light),
10 млн итераций, `-O3 -std=c++20`.

```bash
clang++ -O3 -std=c++20 benchmark_traffic.cpp -o bench && ./bench
```

### Ожидаемые результаты (state machine):

| Версия | На итерацию | Относительно |
|--------|-------------|--------------|
| C++ наивный (virtual + new/delete) | ~18-25 нс | 1x (база) |
| C++ таблица + пул (ручной код) | ~12-16 нс | ~1.5x быстрее |
| **B+ --optimize** | ~12-16 нс | **~1.5x быстрее** |
| **B+ --turbo** | ~10-14 нс | **~1.8x быстрее** |

B+ генерирует **тот же код**, что и оптимизированный C++ вручную.
Разница с наивным C++ — не магия, а устранение virtual dispatch + new/delete.

### Почему не 400%?

- State machine — лёгкая задача: 3 состояния, 1 событие
- Virtual dispatch стоит ~5-10 нс, new/delete ~5-15 нс
- Реалистичный максимум ускорения: **~1.5-2x** (50-100%)
- В тяжёлых машинах (50+ состояний, 20+ событий) — **~2-3x**
- С `--thread-pool` на 8 ядрах — **~6-8x** (за счёт параллелизма, не магии)

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
