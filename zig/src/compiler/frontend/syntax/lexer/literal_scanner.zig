const cursor_mod = @import("cursor.zig");
const token_kind = @import("../token/token_kind.zig");

const Cursor = cursor_mod.Cursor;
const TokenKind = token_kind.TokenKind;

pub const LiteralToken = struct {
    kind: TokenKind,
    length: u32,
};

pub fn scanNumber(cursor: *Cursor) ?LiteralToken {
    const start = cursor.mark();
    var is_float = false;
    var has_suffix = false;

    if (cursor.peek() == '0') {
        if (cursor.peekAhead(1)) |next| {
            switch (next) {
                'x', 'X' => {
                    cursor.pos += 2;
                    scanHexDigits(cursor);
                },
                'b', 'B' => {
                    cursor.pos += 2;
                    scanBinaryDigits(cursor);
                },
                'o', 'O' => {
                    cursor.pos += 2;
                    scanOctalDigits(cursor);
                },
                else => {
                    scanDecimalDigits(cursor);
                },
            }
        }
    } else {
        scanDecimalDigits(cursor);
    }

    if (cursor.peek() == '.' and cursor.peekAhead(1) != '.') {
        is_float = true;
        cursor.pos += 1;
        scanDecimalDigits(cursor);
    }

    if (cursor.peek() == 'e' or cursor.peek() == 'E') {
        is_float = true;
        cursor.pos += 1;
        if (cursor.peek() == '+' or cursor.peek() == '-') {
            cursor.pos += 1;
        }
        scanDecimalDigits(cursor);
    }

    if (cursor.isAlpha()) {
        has_suffix = true;
        while (cursor.isAlphaNum()) {
            cursor.pos += 1;
        }
    }

    const length: u32 = @intCast(cursor.pos - start);
    if (length == 0) return null;

    return .{
        .kind = if (is_float) .float_literal else .int_literal,
        .length = length,
    };
}

pub fn scanStringLiteral(cursor: *Cursor) ?LiteralToken {
    if (cursor.peek() != '"') return null;
    const start = cursor.mark();
    cursor.pos += 1;

    while (cursor.pos < cursor.source.len) {
        switch (cursor.source[cursor.pos]) {
            '"' => {
                cursor.pos += 1;
                return .{ .kind = .string_literal, .length = @intCast(cursor.pos - start) };
            },
            '\\' => {
                cursor.pos += 1;
                if (cursor.pos < cursor.source.len) {
                    cursor.pos += 1;
                }
            },
            '\n', '\r' => return null,
            else => cursor.pos += 1,
        }
    }
    return null;
}

pub fn scanByteStringLiteral(cursor: *Cursor) ?LiteralToken {
    if (cursor.peek() != 'b' or cursor.peekAhead(1) != '"') return null;
    const start = cursor.mark();
    cursor.pos += 2;

    while (cursor.pos < cursor.source.len) {
        switch (cursor.source[cursor.pos]) {
            '"' => {
                cursor.pos += 1;
                return .{ .kind = .byte_string_literal, .length = @intCast(cursor.pos - start) };
            },
            '\\' => {
                cursor.pos += 1;
                if (cursor.pos < cursor.source.len) cursor.pos += 1;
            },
            '\n', '\r' => return null,
            else => cursor.pos += 1,
        }
    }
    return null;
}

pub fn scanCharLiteral(cursor: *Cursor) ?LiteralToken {
    if (cursor.peek() != '\'') return null;
    const start = cursor.mark();
    cursor.pos += 1;

    if (cursor.pos >= cursor.source.len) return null;
    if (cursor.source[cursor.pos] == '\\') {
        cursor.pos += 1;
        if (cursor.pos < cursor.source.len) cursor.pos += 1;
    } else if (cursor.source[cursor.pos] == '\'') {
        return null;
    } else {
        cursor.pos += 1;
    }

    if (cursor.peek() != '\'') return null;
    cursor.pos += 1;
    return .{ .kind = .char_literal, .length = @intCast(cursor.pos - start) };
}

pub fn scanByteLiteral(cursor: *Cursor) ?LiteralToken {
    if (cursor.peek() != 'b' or cursor.peekAhead(1) != '\'') return null;
    const start = cursor.mark();
    cursor.pos += 2;

    if (cursor.pos >= cursor.source.len) return null;
    if (cursor.source[cursor.pos] == '\\') {
        cursor.pos += 1;
        if (cursor.pos < cursor.source.len) cursor.pos += 1;
    } else {
        cursor.pos += 1;
    }

    if (cursor.peek() != '\'') return null;
    cursor.pos += 1;
    return .{ .kind = .byte_literal, .length = @intCast(cursor.pos - start) };
}

fn scanDecimalDigits(cursor: *Cursor) void {
    while (cursor.pos < cursor.source.len) {
        const ch = cursor.source[cursor.pos];
        if (ch >= '0' and ch <= '9') {
            cursor.pos += 1;
        } else if (ch == '_') {
            cursor.pos += 1;
        } else {
            break;
        }
    }
}

fn scanHexDigits(cursor: *Cursor) void {
    while (cursor.pos < cursor.source.len) {
        const ch = cursor.source[cursor.pos];
        if ((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F') or ch == '_') {
            cursor.pos += 1;
        } else {
            break;
        }
    }
}

fn scanBinaryDigits(cursor: *Cursor) void {
    while (cursor.pos < cursor.source.len) {
        const ch = cursor.source[cursor.pos];
        if (ch == '0' or ch == '1' or ch == '_') {
            cursor.pos += 1;
        } else {
            break;
        }
    }
}

fn scanOctalDigits(cursor: *Cursor) void {
    while (cursor.pos < cursor.source.len) {
        const ch = cursor.source[cursor.pos];
        if ((ch >= '0' and ch <= '7') or ch == '_') {
            cursor.pos += 1;
        } else {
            break;
        }
    }
}
