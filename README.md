# B+ v2.0.1VS — язык конечных автоматов

B+ — язык описания конечных автоматов (state machine) с транспиляцией в **Python, C#, C++, C**, а также плагинами для **Unity, Unreal Engine, Godot и Web (TypeScript)**.

## Быстрый старт

```bp
// traffic_light.bp
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

```bash
dotnet run --project src/BPlusTranspiler -- examples/traffic_light.bp --target all --output ./gen
```

## Возможности (v2.0.1VS)

| Фича | Пример |
|------|--------|
| Состояния | `state Idle { }` |
| Переходы | `on event -> Target { body }` |
| Условия | `on hit [lives <= 0] -> Dead` |
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

## CLI Reference (bpc)

```bash
# Транспиляция
bpc input.bp --target python            # → generated.py
bpc input.bp --target csharp            # → generated.cs
bpc input.bp --target cpp               # → states.h + states.cpp
bpc input.bp --target c                 # → states.h + states.c
bpc input.bp --target all               # → все сразу
bpc input.bp --optimize                 # + C++ optimized (2D table)
bpc input.bp --plugin unity             # → MonoBehaviour
bpc input.bp --plugin unreal            # → UCLASS Actor
bpc input.bp --plugin godot             # → Godot Node
bpc input.bp --plugin web               # → TypeScript class

# Инструменты
bpc --visualize input.bp                # → интерактивный граф (HTML)
bpc format input.bp                     # → автоформатирование
bpc docs input.bp                       # → документация (.md + .html)
bpc debug input.bp                      # → интерактивный дебаггер
bpc profile input.bp 10000              # → профайлинг переходов
bpc watch . --target cpp                # → автоперегенерация

# LSP сервер
bpc --lsp                               # → LSP для VS Code/Vim/Emacs
bpc --install-lsp                       # → установка VS Code extension

# Пакетный менеджер (BPM)
bpc bpm init my-package                 # → новый пакет
bpc bpm install path/to/package         # → установка
bpc bpm list                            # → список пакетов
bpc bpm search term                     # → поиск
bpc bpm publish path                    # → публикация

# Тестирование
bpc test run input.bp                   # → автотесты переходов
```

## Пример генерации

**B+:**
```bp
state Game {
    var score: int = 0
    on hit -> Game { score += 10 }
    on die [score > 100] -> Victory
}
```

**→ Python:**
```python
class Game(State):
    score: int = 0
    def on_hit(self):
        score += 10
        return Game
    def on_die(self):
        if score > 100:
            return Victory
```

**→ C#:**
```csharp
public class Game : State {
    public int score { get; set; } = 0;
    public override State OnHit() { score += 10; return new Game(); }
    public override State OnDie() { if (score > 100) return new Victory(); return null; }
}
```

**→ C++:**
```cpp
class Game : public State {
public:
    int score = 0;
    State* on_hit() override { score += 10; return new Game(); }
    State* on_die() override { if (score > 100) return new Victory(); return nullptr; }
};
```

**→ C:**
```c
State* game_on_hit(void) { score += 10; return &game_state; }
State* game_on_die(void) { if (score > 100) return &victory_state; return NULL; }

State game_state = {
    .score = 0,
    .game_on_hit = game_on_hit,
    .game_on_die = game_on_die,
};
```

## Структура проекта

```
B+ v1.0/
├── src/
│   ├── BPlusTranspiler/        ← Транспилятор (.NET 8)
│   │   ├── Ast/AstNodes.cs      — AST-ноды
│   │   ├── Parser/BPlusParser.cs — Парсер .bp
│   │   ├── Optimizer/           — AST optimizer
│   │   ├── Generators/          — Python, C#, C++, C generators
│   │   ├── Lsp/                 — LSP сервер
│   │   ├── Visualizer/          — Граф состояний (Mermaid)
│   │   ├── DocGen/              — Генератор документации
│   │   ├── Debugger/            — Интерактивный дебаггер
│   │   ├── Profiler/            — Профайлинг
│   │   ├── Plugins/             — Unity, Unreal, Godot, Web
│   │   ├── PackageManager/      — BPM (bpc bpm)
│   │   ├── TestRunner/          — Автотесты
│   │   └── Program.cs           — CLI (bpc)
│   └── vs-extension/           ← VS2022 extension (.vsix)
├── examples/
│   ├── traffic_light.bp
│   ├── vending_machine.bp
│   └── game_full.bp
└── BPlusLanguage.vsix          ← VS extension для .bp файлов
```

## VS Extension

`BPlusLanguage.vsix` — подсветка синтаксиса и IntelliSense для `.bp` файлов в Visual Studio 2022.

Установка: дважды кликнуть `BPlusLanguage.vsix`.

## Лицензия

MIT
