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

| Флаг | Эффект | Ускорение |
|------|--------|-----------|
| `--optimize` | Таблицы переходов вместо virtual | +10-15% |
| `--inline-states` | Инлайнинг маленьких состояний | +5-10% |
| `--dead-elim` | Удаление мёртвых состояний | -размер |
| `--vectorize` | SIMD (AVX-512/AVX2/SSE/NEON) | +30-40% |
| `--cache-friendly` | AoSoA layout данных | +20-30% |
| `--branchless` | cmov вместо if/else | +10-15% |
| `--prefetch` | Программная предзагрузка | +20-40% |
| `--zero-copy` | State pool, без malloc | +15-25% |
| `--pack` | Битфилды, упаковка структур | -50% памяти |
| `--data-oriented` | SoA layout переменных | +30% |
| `--predict` | Предсказание следующего состояния | +15% |
| `--devirt` | Прямые вызовы вместо таблиц | +10% |
| `--dedup` | Дедупликация одинаковых actions | -30% размера |
| `--multi-path` | Скалярный + векторный пути | +15-25% |
| `--pin-regs` | Закрепление переменных в регистрах | +10-20% |
| `--pool` | Memory pool для состояний | +20% |
| `--hot-cold` | Разделение горячего/холодного кода | +10% |
| `--eco` | Энергосбережение (узкие SIMD) | -40-60% энергии |
| `--lto` | Link-Time Optimization | +5-10% |
| `--fast-math` | Быстрая математика | +5-10% |
| `--parallel-dispatch` | Многопоточная обработка событий | +200-400% |
| `--lock-free` | Безлоковые структуры | +5-10% |
| `--auto` | Авто-детект CPU + выбор флагов | +20-40% |
| **`--turbo`** | **Все оптимизации сразу** | **+150%** |
| `--turbo-eco` | Turbo + энергосбережение | баланс |
| `--turbo-embed` | Для embedded (без исключений/RTTI) | компактно |
| `--benchmark` | Генерация бенчмарк-обёртки | замеры |

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

## VS Extension

`BPlusLanguage.vsix` — подсветка синтаксиса и IntelliSense для `.bp` файлов в Visual Studio 2022. Установка: дважды кликнуть.

## Лицензия

MIT
