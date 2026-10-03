# B+ Language Support for Visual Studio Code

Полный тулчейн B+ в одной коробке: подсветка синтаксиса, диагностика прямо в
редакторе и **встроенный компилятор `bpc.exe`**.

> **v0.3.0 — установка расширения это всё, что нужно.** Компилятор лежит внутри
> расширения (`bin/bpc.exe`). Ничего не скачивать, ни PATH настраивать, ни
> `zig build` запускать: создайте `hello.b+`, нажмите **F8** — программа
> соберётся в `.exe` и запустится в терминале.

## Что работает «из коробки»

| Возможность | Состояние |
|---|---|
| Компиляция и запуск `.b+` → `.exe` | работает |
| Красные подчёркивания ошибок на лету (при сохранении) | работает |
| Команда `B+: Check Current File` | работает |
| `bpc doctor` (здоровье компилятора) | работает |
| Подсветка синтаксиса, snippets, фолдинг, скобки | работает |
| Настройка `bplus.compilerPath` | работает (необязательно) |
| Отладка по точкам останова (breakpoints) | **нет** — только запуск |

## Установка

Скачайте `vscode-bplus-0.3.0.vsix` и:

```powershell
code --install-extension vscode-bplus-0.3.0.vsix
```

Создайте `hello.b+`:

```bplus
fn main()
{
    print("Hello, B+!")
}
```

Нажмите **F8** (или кнопку ▶ в заголовке редактора).

## Как это работает

```
   .b+ файл в VS Code
          |
          |  F8 / F5 / Ctrl+Alt+B / кнопка ▶
          v
   bpc mir  <file> -o <file>.obj      # компиляция, БЕЗ запуска программы
          |
   bpc link <file>.obj -o <file>.exe  # линковка
          |
   терминал "B+ Run":  & '<file>.exe'
          |
   вывод программы
```

Команда `Run` собирает и запускает **ровно один раз**. `Build` только собирает.
Ошибки компилятора показываются и в панели вывода, и как подчёркивания в коде.

## Команды

| Команда | Описание | Горячая клавиша |
|---|---|---|
| `B+: Run Current File` | собрать и запустить | `F8` / `F5` / `Ctrl+Alt+B` |
| `B+: Build Current File` | только собрать `.exe` | `Ctrl+Alt+Shift+B` |
| `B+: Check Current File` | только диагностика, без артефактов | `Ctrl+Alt+K` |
| `B+: Launch .exe in Terminal` | запустить уже собранный `.exe` | — |
| `B+: Clean (delete built .exe)` | удалить `.exe` | — |
| `B+: Compiler Health Check` | `bpc doctor` | — |
| `B+: Select Compiler Path...` | открыть настройку пути | — |
| `B+: Show Output Channel` | показать вывод компилятора | — |

## Настройки

| Настройка | По умолчанию | Смысл |
|---|---|---|
| `bplus.compilerPath` | `""` | Путь к `bpc.exe`. Пусто = встроенный компилятор, затем `PATH`, затем `zig-out`. |
| `bplus.outputDirectory` | `""` | Куда класть `.exe`. Пусто = рядом с исходником. |
| `bplus.checkOnSave` | `true` | Компилировать в фоне при каждом сохранении и показывать ошибки. |
| `bplus.keepObjectFile` | `false` | Не удалять промежуточный `.obj` после сборки. |
| `bplus.runInTerminal` | `true` | Запускать `.exe` в интегрированном терминале. |
| `bplus.clearTerminalBeforeRun` | `true` | Очищать терминал перед запуском. |
| `bplus.showOutputChannel` | `true` | Показывать панель вывода при каждой сборке. |

## Как ищется компилятор

1. настройка `bplus.compilerPath`;
2. переменная окружения `BPC_PATH`;
3. **встроенный `bin/bpc.exe` внутри расширения**;
4. `bpc` в `PATH`;
5. стандартные папки сборки (`C:\B-Plus\zig\zig-out\bin`, `D:\...`).

Если не найден ни один — расширение явно скажет об этом и предложит открыть
настройку. Сборка при этом всегда продолжает работать на том компиляторе,
который был в комплекте.

## Обновление встроенного компилятора

```powershell
cd C:\B-Plus\zig
zig build                      # собрать bpc.exe
cd ..\vscode-bplus
npm run sync-compiler          # скрипт проверит компилятор и скопирует его в bin\
```

`npm run package` делает то же самое и сразу собирает `.vsix`.

## Сборка `.vsix` из исходников

```powershell
cd C:\B-Plus\vscode-bplus
npm install                    # только devDependencies (@types/vscode)
npm run package                # -> vscode-bplus-0.3.0.vsix
code --install-extension vscode-bplus-0.3.0.vsix
```

Скрипт `sync-compiler.ps1` перед упаковкой проверяет, что собранный `bpc.exe`
реально компилирует hello-world, и откажется класть в пакет сломанный компилятор.

## Важно: ставьте только одно расширение B+

В marketplace есть несколько сторонних расширений для `.b+` / `.plan`
(`bplus-syntax`, `bplus-vscode`, старые версии `vscode-bplus`). Если установлено
больше одного, они дерут один и тот же language id `bplus` и одни и те же
команды (`bplus.run`, `bplus.build`, `bplus.clean`) — VS Code активирует
последний, подсветка берётся не из того расширения, а команды падают.

```powershell
code --list-extensions | Select-String bplus     # должно быть ровно одно
code --uninstall-extension bplus-syntax
code --uninstall-extension bplus-vscode
code --install-extension vscode-bplus-0.3.0.vsix
```

## Известные ограничения самого компилятора

Расширение работает корректно, но `bpc.exe` на текущей ревизии ещё не умеет:

- `match` — фронтенд разбирает, но BIR-lowering падает с `UndefinedVReg`.
  Это падение компилятора, а не расширения: файл с `match` не соберётся.
- `for x in 0..10` (range-for) — парсится, но не lowered: `UnknownExpression`.
  Используйте `for i = 0; i < 10; i = i + 1 { }`.
- Пустой `entry { }` без поведения — ошибка `dead_state`.
- Поля `struct` и члены `enum` пишутся **по одному в строке**; запятая допускается,
  но не обязательна.

Всё остальное (`fn`, `state`, `entry`, `on`, `emit`, `start`, `struct`, `enum`,
`if`, `while`, `for`, `import`, арифметика, строки, `print`) собирается и
запускается.

## Тесты расширения

Логика расширения покрыта headless-тестом с мокнутым `vscode`:

```powershell
node C:\B-Plus\vscode-bplus\test-extension.js
```

## Лицензия

MIT
