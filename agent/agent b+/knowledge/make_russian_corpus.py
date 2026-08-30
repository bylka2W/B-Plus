import os
import sys
import json
import random
from pathlib import Path

AGENT_BPLUS = Path(r"C:\B-Plus\agent\agent b+")
sys.path.insert(0, str(AGENT_BPLUS))

from knowledge.tokenizer import ZIG_KEYWORDS, ZIG_BUILTINS

OUT = AGENT_BPLUS / "knowledge" / "corpus" / "russian_corpus.jsonl"
OUT.parent.mkdir(parents=True, exist_ok=True)

random.seed(42)

CONCEPTS = {
    "fn": ("Как объявить функцию в Zig?",
           'Функция объявляется ключевым словом fn. Пример:\nfn add(a: i32, b: i32) i32 {\n    return a + b;\n}'),
    "pub": ("Что значит pub в Zig?",
            'pub делает объявление видимым за пределами файла или модуля. Пример:\npub fn main() void {}'),
    "const": ("Как объявить константу в Zig?",
              'Константа объявляется через const. Пример:\nconst pi: f32 = 3.14159;'),
    "var": ("Чем отличаются var и const в Zig?",
            'var — это изменяемая переменная, const — нет. Пример:\nvar x: i32 = 0;\nx += 1;'),
    "struct": ("Как создать структуру в Zig?",
               'Структура объявляется через struct. Пример:\npub const Point = struct {\n    x: f32,\n    y: f32,\n};'),
    "enum": ("Как создать перечисление в Zig?",
             'Перечисление объявляется через enum. Пример:\npub const Color = enum {\n    red,\n    green,\n    blue,\n};'),
    "error": ("Как работают ошибки в Zig?",
              'Ошибки объявляются через error. Пример:\npub const MyErr = error{OutOfMemory, NotFound};'),
    "comptime": ("Что такое comptime в Zig?",
                 'comptime выполняет код на этапе компиляции. Пример:\nfn make(comptime T: type) T {\n    return 0;\n}'),
    "try": ("Что делает try в Zig?",
            'try выполняет выражение и при ошибке сразу возвращает её из функции. Пример:\nconst f = try File.open("a.txt");'),
    "catch": ("Что делает catch в Zig?",
              'catch перехватывает ошибку и заменяет значением. Пример:\nconst n = parse() catch 0;'),
    "defer": ("Что делает defer в Zig?",
              'defer откладывает выполнение до выхода из области видимости. Пример:\ndefer file.close();'),
    "alloc": ("Как выделять память в Zig?",
              'Память выделяется через аллокатор. Пример:\nconst buf = try allocator.alloc(u8, 16);'),
    "test": ("Как написать тест в Zig?",
             'Тест объявляется через test. Пример:\ntest "basic" {\n    try std.testing.expect(true);\n}'),
    "return": ("Как вернуть значение в Zig?",
               'Возврат значения делается через return. Пример:\nfn square(x: i32) i32 {\n    return x * x;\n}'),
    "if": ("Как работает if в Zig?",
           'if проверяет условие. Пример:\nif (x > 0) {\n    return 1;\n}'),
    "while": ("Как написать цикл while в Zig?",
              'Цикл пишется через while. Пример:\nvar i: usize = 0;\nwhile (i < 10) : (i += 1) {}'),
    "for": ("Как написать цикл for в Zig?",
            'for перебирает последовательность. Пример:\nfor (items) |it| {\n    _ = it;\n}'),
    "switch": ("Как работает switch в Zig?",
               'switch выбирает ветку по значению. Пример:\nswitch (c) {\n    "a" => return 1,\n    else => return 0,\n}'),
}

CHAT = [
    "Привет. Я помощник по языку программирования Zig. Задавай вопросы на русском.",
    "Zig — это системный язык программирования с ручным управлением памятью и отсутствием скрытого выделения памяти.",
    "В Zig нет исключений. Ошибки возвращаются явно через объединение ошибок.",
    "Компилятор Zig можно использовать как менеджер пакетов и систему сборки.",
    "Я пишу только на русском языке и на языке Zig. Другие языки мне не нужны.",
    "Объясни, пожалуйста, подробнее на русском, как устроен этот код на Zig.",
    "Напиши, пожалуйста, пример кода на Zig и поясни его на русском языке.",
    "Давай разберём этот фрагмент на Zig шаг за шагом на русском языке.",
]

BUILTIN_QA = [
    ("@import", "Что делает встроенная функция @import в Zig?",
     'const std = @import("std");'),
    ("@as", "Что делает @as в Zig?",
     'const x = @as(i32, 5);'),
    ("@intCast", "Что делает @intCast в Zig?",
     'const y: u8 = @intCast(some_usize);'),
    ("@ptrCast", "Что делает @ptrCast в Zig?",
     'const p: *u8 = @ptrCast(raw);'),
    ("@alignCast", "Что делает @alignCast в Zig?",
     'const a: *align(8) u8 = @alignCast(p);'),
]


def make_sample():
    r = random.random()
    if r < 0.45:
        key = random.choice(list(CONCEPTS))
        q, a = CONCEPTS[key]
        return f"Вопрос: {q}\nОтвет: {a}"
    if r < 0.65:
        bl, q, a = random.choice(BUILTIN_QA)
        return f"Вопрос: {q}\nОтвет: {a}"
    if r < 0.85:
        c = random.choice(CHAT)
        return f"Собеседник: {c}"
    # free-form Russian explanation mentioning a real Zig snippet
    key = random.choice(list(CONCEPTS))
    q, a = CONCEPTS[key]
    return f"Объясни на русском: {q}\n\n{a}\n\nЭтот пример показывает, как работает {key} в языке Zig."


def main():
    n = 6000
    with open(OUT, "w", encoding="utf-8") as f:
        for _ in range(n):
            f.write(json.dumps({"text": make_sample()}, ensure_ascii=False) + "\n")
    print(f"Wrote {n} Russian samples -> {OUT}")


if __name__ == "__main__":
    main()
