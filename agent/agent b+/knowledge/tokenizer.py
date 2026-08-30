import os
import sys
import json
import re
from pathlib import Path
from collections import Counter

AGENT_ROOT = Path(__file__).parent.parent
ZIG_ROOT = Path(r"C:\Users\Local\zig")
BPLUS_ROOT = Path(r"C:\B-Plus\zig")
CORPUS_DIR = Path(__file__).parent / "corpus"

EXCLUDED_DIRS = {
    "zig-cache", "zig-out", ".git", "node_modules", "build",
    "build-debug", "build-release", "CMakeFiles",
}

SPACE_TOKEN = "<SP>"
NEWLINE_TOKEN = "<NL>"
TAB_TOKEN = "<TAB>"
EOF_TOKEN = "<EOF>"
UNK_TOKEN = "<UNK>"

SPECIAL_TOKENS = [SPACE_TOKEN, NEWLINE_TOKEN, TAB_TOKEN, EOF_TOKEN, UNK_TOKEN]

ZIG_KEYWORDS = {
    "fn", "pub", "const", "var", "if", "else", "while", "for", "switch",
    "return", "break", "continue", "defer", "errdefer", "try", "catch",
    "struct", "enum", "union", "opaque", "packed", "extern",
    "comptime", "inline", "noinline", "volatile", "allowzero",
    "align", "callconv", "addrspace",
    "u8", "u16", "u32", "u64", "u128", "i8", "i16", "i32", "i64", "i128",
    "usize", "isize", "f16", "f32", "f64", "f80", "f128",
    "bool", "void", "noreturn", "type", "anytype", "anyerror", "anyframe",
    "error", "errorset", "undefined", "null",
    "true", "false",
    "and", "or", "orelse",
    "as", "catch", "test",
    "usingnamespace", "threadlocal",
    "asm", "nosuspend",
}

ZIG_BUILTINS = {
    "@import", "@as", "@intCast", "@floatCast", "@ptrCast", "@alignCast",
    "@truncate", "@bitCast", "@intToFloat", "@floatToInt",
    "@intToPtr", "@ptrToInt", "@intToEnum", "@enumToInt",
    "@intToError", "@errorToInt", "@intToBool",
    "@typeInfo", "@typeName", "@Type", "@sizeOf", "@alignOf",
    "@offsetOf", "@bitSizeOf", "@hasField", "@hasDecl",
    "@field", "@This", "@size", "@maxValue", "@minValue",
    "@compileError", "@compileLog", "@panic", "@breakpoint",
    "@returnAddress", "@src",
    "@tagName", "@enumFromInt", "@errorFromInt",
    "@call", "@memcpy", "@memset", "@volatileLoad", "@volatileStore",
    "@workgroup_size", "@vector",
}

ZIG_OPERATORS = {
    "+", "-", "*", "/", "%", "=", "==", "!=", "<", ">", "<=", ">=",
    "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=",
    "!", "~", "&", "|", "^", "<<", ">>", "++", "--", "**",
    "?", ".", "..", "...", "=>", "->", "::", ":",
    "(", ")", "[", "]", "{", "}", ";", ",",
}


def iter_zig_files(root):
    root = Path(root)
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(
            d for d in dirnames
            if d not in EXCLUDED_DIRS and not d.startswith(".")
        )
        for name in sorted(filenames):
            if name.endswith(".zig"):
                files.append(os.path.join(dirpath, name))
    return files


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except (OSError, IOError):
        return ""


def extract_zig_tokens(text):
    tokens = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]

        if c == " ":
            j = i
            while j < n and text[j] == " ":
                j += 1
            tokens.append(SPACE_TOKEN)
            i = j
            continue

        if c == "\n":
            tokens.append(NEWLINE_TOKEN)
            i += 1
            continue

        if c == "\t":
            tokens.append(TAB_TOKEN)
            i += 1
            continue

        if c == "\r":
            i += 1
            continue

        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue

        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i < n - 1 and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue

        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    j += 1
                j += 1
            tokens.append(text[i:j + 1])
            i = j + 1
            continue

        if c == "'" and i + 1 < n and text[i + 1] != "'":
            j = i + 1
            while j < n and text[j] != "'":
                if text[j] == "\\":
                    j += 1
                j += 1
            tokens.append(text[i:j + 1])
            i = j + 1
            continue

        if c == "@":
            j = i + 1
            if j < n and (text[j].isalpha() or text[j] == "_"):
                while j < n and (text[j].isalnum() or text[j] == "_"):
                    j += 1
                tokens.append(text[i:j])
                i = j
                continue
            tokens.append(c)
            i += 1
            continue

        if c.isdigit() or (c in "+-" and i + 1 < n and text[i + 1].isdigit()):
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] in "_.xXoObBeE"):
                j += 1
            tokens.append(text[i:j])
            i = j
            continue

        if c.isalpha() or c == "_":
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            run = text[i:j]
            # Cyrillic runs are emitted per-character so Russian maps to the
            # single-char ru_ tokens; Latin identifier runs stay as words (Zig).
            if any(ord(ch) > 127 for ch in run):
                tokens.extend(run)
            else:
                tokens.append(run)
            i = j
            continue

        two = text[i:i + 2]
        if two in ZIG_OPERATORS:
            tokens.append(two)
            i += 2
            continue

        if c in ZIG_OPERATORS:
            tokens.append(c)
            i += 1
            continue

        tokens.append(c)
        i += 1

    return tokens


def build_tokenizer_vocab(zig_roots, max_vocab=32000):
    counter = Counter()
    for root in zig_roots:
        files = iter_zig_files(root)
        for fp in files:
            content = read_file(fp)
            if content:
                tokens = extract_zig_tokens(content)
                counter.update(tokens)

    vocab = {}
    for t in SPECIAL_TOKENS:
        vocab[f"sp_{t}"] = len(vocab)
    for kw in sorted(ZIG_KEYWORDS):
        vocab[f"kw_{kw}"] = len(vocab)
    for bl in sorted(ZIG_BUILTINS):
        vocab[f"bl_{bl}"] = len(vocab)
    for op in sorted(ZIG_OPERATORS):
        vocab[f"op_{op}"] = len(vocab)
    for token, count in counter.most_common(max_vocab - len(vocab)):
        if token in SPECIAL_TOKENS:
            continue
        vocab[f"tok_{token}"] = len(vocab)
    return vocab


class ZigTokenizer:
    def __init__(self, vocab=None):
        self.vocab = vocab or {}
        self.inv_vocab = {v: k for k, v in self.vocab.items()}
        self.token_to_id = {}
        for k, v in self.vocab.items():
            prefix = ""
            if k.startswith("sp_"):
                prefix = "sp_"
            elif k.startswith("kw_"):
                prefix = "kw_"
            elif k.startswith("bl_"):
                prefix = "bl_"
            elif k.startswith("op_"):
                prefix = "op_"
            elif k.startswith("tok_"):
                prefix = "tok_"
            elif k.startswith("ru_"):
                prefix = "ru_"
            raw = k[len(prefix):] if prefix else k
            self.token_to_id[raw] = v

    @classmethod
    def build(cls, zig_roots, max_vocab=32000):
        vocab = build_tokenizer_vocab(zig_roots, max_vocab)
        return cls(vocab)

    @classmethod
    def load(cls, path):
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return cls(data.get("vocab", {}))

    def save(self, path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"vocab": self.vocab, "size": len(self.vocab)}, f, ensure_ascii=False)

    def encode(self, text):
        raw_tokens = extract_zig_tokens(text)
        ids = []
        for t in raw_tokens:
            if t in self.token_to_id:
                ids.append(self.token_to_id[t])
            else:
                ids.append(self.token_to_id.get(UNK_TOKEN, 0))
        return ids

    @classmethod
    def build_ru_zig(cls, zig_roots, ru_texts=None, max_vocab=32000, cyr_room=400):
        """Build a tokenizer that covers ONLY Russian (Cyrillic) + Zig.

        Zig tokens keep their word/operator encoding; every Cyrillic letter is
        added as a single-char token so Russian encodes losslessly (any other
        script maps to UNK, enforcing the Russian+Zig-only constraint).
        """
        import collections as _collections
        vocab = build_tokenizer_vocab(zig_roots, max_vocab - cyr_room)
        cyr = "абвгдежзийклмнопрстуфхцчшщъыьэюяёАБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯЁ"
        for ch in cyr:
            key = f"ru_{ch}"
            if key not in vocab:
                vocab[key] = len(vocab)

        if ru_texts:
            bigrams = _collections.Counter()
            for text in ru_texts:
                runs = []
                cur = ""
                for ch in text:
                    if "а" <= ch.lower() <= "я" or ch in "ёЁ":
                        cur += ch
                    else:
                        if len(cur) >= 2:
                            runs.append(cur)
                        cur = ""
                if len(cur) >= 2:
                    runs.append(cur)
                for run in runs:
                    for i in range(len(run) - 1):
                        bigrams[run[i:i + 2]] += 1
            for bg, _ in bigrams.most_common(cyr_room - len(cyr)):
                key = f"ru_{bg}"
                if key not in vocab:
                    vocab[key] = len(vocab)

        return cls(vocab)

    def decode(self, ids):
        parts = []
        for i in ids:
            if i in self.inv_vocab:
                key = self.inv_vocab[i]
                if key.startswith("sp_"):
                    raw = key[3:]
                    if raw == SPACE_TOKEN:
                        parts.append(" ")
                    elif raw == NEWLINE_TOKEN:
                        parts.append("\n")
                    elif raw == TAB_TOKEN:
                        parts.append("\t")
                    elif raw == EOF_TOKEN:
                        pass
                    elif raw == UNK_TOKEN:
                        parts.append("?")
                    else:
                        parts.append(raw)
                elif key.startswith("kw_"):
                    parts.append(key[3:])
                elif key.startswith("bl_"):
                    parts.append(key[3:])
                elif key.startswith("op_"):
                    parts.append(key[3:])
                elif key.startswith("ru_"):
                    parts.append(key[3:])
                elif key.startswith("tok_"):
                    parts.append(key[4:])
                else:
                    parts.append(key)
            else:
                parts.append("?")
        return "".join(parts)

    def vocab_size(self):
        return len(self.vocab)

    def compression_ratio(self, text):
        tokens = extract_zig_tokens(text)
        return len(text) / max(len(tokens), 1)


def test_tokenizer(tokenizer):
    tests = [
        ('const std = @import("std");', "const std = @import"),
        ("pub fn main() !void {", "pub fn main"),
        ("comptime {", "comptime"),
        ("if (x) |val| {", "if"),
        ("return error{OutOfMemory};", "return error"),
        ("std.debug.print", "std.debug.print"),
        ("0x1234_abcd", "0x1234"),
        ("// this is a comment", ""),
    ]

    all_ok = True
    for text, expected_prefix in tests:
        ids = tokenizer.encode(text)
        decoded = tokenizer.decode(ids)
        ok = decoded.strip() != ""
        status = "OK" if ok else "FAIL"
        if not ok:
            all_ok = False
        print(f"  [{status}] '{text[:40]}' -> {len(ids)} tokens -> '{decoded[:50]}'")

    return all_ok


def main():
    print("BUILDING FINAL ZIG TOKENIZER")
    print("=" * 60)

    print(f"\nB+ source: {BPLUS_ROOT}")
    zig_bplus = iter_zig_files(BPLUS_ROOT)
    print(f"  .zig files: {len(zig_bplus)}")

    print(f"Zig compiler: {ZIG_ROOT}")
    zig_compiler = iter_zig_files(ZIG_ROOT)
    print(f"  .zig files: {len(zig_compiler)}")

    tokenizer = ZigTokenizer.build([BPLUS_ROOT, ZIG_ROOT], max_vocab=24000)
    print(f"\nTokenizer vocab size: {tokenizer.vocab_size()}")

    test_code = 'const std = @import("std");\n\npub fn main() !void {\n    const allocator = std.heap.page_allocator;\n    _ = allocator;\n}'
    ids = tokenizer.encode(test_code)
    decoded = tokenizer.decode(ids)
    print(f"\nEncode/decode test:")
    print(f"  input:  '{test_code}'")
    print(f"  ids:    {ids}")
    print(f"  decoded:'{decoded}'")
    print(f"  match:  {test_code == decoded}")
    print(f"  compression: {tokenizer.compression_ratio(test_code):.2f}x")

    print(f"\nDetailed tests:")
    test_tokenizer(tokenizer)

    tok_path = CORPUS_DIR / "zig_tokenizer.json"
    tokenizer.save(tok_path)
    print(f"\nSaved: {tok_path}")
    print(f"  vocab_size: {tokenizer.vocab_size()}")

    sys.exit(0)


if __name__ == "__main__":
    main()
