# B+ v2.0.0VS BETA — язык конечных автоматов

B+ — язык описания конечных автоматов (state machine) с транспиляцией в **Python, C#, C++ и C**.

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

## Возможности (v2.0.0VS BETA)

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

## Генерация кода

```bash
bpc input.bp --target python  # → generated.py
bpc input.bp --target csharp  # → generated.cs
bpc input.bp --target cpp     # → states.h + states.cpp
bpc input.bp --target c       # → states.h + states.c
bpc input.bp --target all     # → все сразу
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
│   │   ├── Generators/
│   │   │   ├── PythonGenerator.cs
│   │   │   ├── CSharpGenerator.cs
│   │   │   ├── CppGenerator.cs
│   │   │   └── CGenerator.cs
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
