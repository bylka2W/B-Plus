const token_kind = @import("token_kind.zig");
const TokenKind = token_kind.TokenKind;

pub const LiteralKind = enum {
    integer,
    float,
    string,
    char,
    byte,
    byte_string,
    boolean,
    null_value,
};

pub const IntBase = enum {
    decimal,
    binary,
    octal,
    hexadecimal,
};

pub const LiteralInfo = struct {
    kind: LiteralKind,
    base: ?IntBase,
    has_suffix: bool,
    suffix: ?u32,

    pub fn fromTokenKind(kind: TokenKind) ?LiteralInfo {
        return switch (kind) {
            .int_literal => .{ .kind = .integer, .base = .decimal, .has_suffix = false, .suffix = null },
            .float_literal => .{ .kind = .float, .base = null, .has_suffix = false, .suffix = null },
            .string_literal => .{ .kind = .string, .base = null, .has_suffix = false, .suffix = null },
            .char_literal => .{ .kind = .char, .base = null, .has_suffix = false, .suffix = null },
            .byte_literal => .{ .kind = .byte, .base = null, .has_suffix = false, .suffix = null },
            .byte_string_literal => .{ .kind = .byte_string, .base = null, .has_suffix = false, .suffix = null },
            .true_literal, .false_literal => .{ .kind = .boolean, .base = null, .has_suffix = false, .suffix = null },
            .null_literal => .{ .kind = .null_value, .base = null, .has_suffix = false, .suffix = null },
            else => null,
        };
    }
};

pub fn detectIntBase(text: []const u8) IntBase {
    if (text.len >= 2 and text[0] == '0') {
        return switch (text[1]) {
            'b', 'B' => .binary,
            'o', 'O' => .octal,
            'x', 'X' => .hexadecimal,
            else => .decimal,
        };
    }
    return .decimal;
}

pub fn isNumericDigit(ch: u8, base: IntBase) bool {
    return switch (base) {
        .decimal => ch >= '0' and ch <= '9',
        .binary => ch == '0' or ch == '1',
        .octal => ch >= '0' and ch <= '7',
        .hexadecimal => (ch >= '0' and ch <= '9') or
            (ch >= 'a' and ch <= 'f') or
            (ch >= 'A' and ch <= 'F'),
    };
}

pub fn charLiteralValue(text: []const u8) ?u32 {
    if (text.len < 3 or text[0] != '\'' or text[text.len - 1] != '\'') return null;
    const inner = text[1 .. text.len - 1];
    if (inner.len == 1) return inner[0];
    if (inner.len > 2 and inner[0] == '\\') {
        switch (inner[1]) {
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            '0' => return 0,
            '\\' => return '\\',
            '\'' => return '\'',
            '"' => return '"',
            'x' => {
                if (inner.len != 4) return null;
                const hi = hexDigit(inner[2]) orelse return null;
                const lo = hexDigit(inner[3]) orelse return null;
                return (hi << 4) | lo;
            },
            'u' => {
                if (inner.len < 4 or inner[2] != '{') return null;
                const end = for (inner[3..], 3..) |ch, i| {
                    if (ch == '}') break i;
                } else return null;
                const hex_str = inner[3..end];
                if (hex_str.len == 0 or hex_str.len > 6) return null;
                var cp: u32 = 0;
                for (hex_str) |ch| {
                    cp = (cp << 4) | (hexDigit(ch) orelse return null);
                }
                if (cp > 0x10FFFF) return null;
                if (cp >= 0xD800 and cp <= 0xDFFF) return null;
                return cp;
            },
            else => return null,
        }
    }
    return null;
}

fn hexDigit(ch: u8) ?u8 {
    return if (ch >= '0' and ch <= '9') ch - '0'
    else if (ch >= 'a' and ch <= 'f') ch - 'a' + 10
    else if (ch >= 'A' and ch <= 'F') ch - 'A' + 10
    else null;
}
