const std = @import("std");

pub const TokenType = enum {
    keyword_entry,
    keyword_state,
    keyword_var,
    keyword_on,
    keyword_after,
    keyword_enter,
    keyword_exit,
    keyword_always,
    keyword_return,
    keyword_print,
    keyword_fn,
    keyword_inline,
    keyword_struct,
    keyword_true,
    keyword_false,
    keyword_if,
    keyword_else,
    keyword_while,
    keyword_for,
    keyword_volatile,
    keyword_fixed,
    keyword_compute_kernel,

    ident,
    number,
    string_lit,

    lbrace,
    rbrace,
    lparen,
    rparen,
    lsquare,
    rsquare,
    colon,
    semicolon,
    comma,
    dot,
    arrow,
    increment,
    decrement,
    assign,
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    lshift,
    rshift,
    not,
    eq,
    neq,
    lt,
    gt,
    le,
    ge,
    and_op,
    or_op,
    hash,
    at,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,

    eof,
    invalid,
};

pub const Token = struct {
    ttype: TokenType,
    start: usize,
    len: usize,
    line: usize,
    col: usize,
};

pub const Tokenizer = struct {
    source: []const u8,
    pos: usize,
    line: usize,
    col: usize,
    allocator: std.mem.Allocator,

    pub fn init(source: []const u8, allocator: std.mem.Allocator) Tokenizer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
            .allocator = allocator,
        };
    }

    pub fn next(t: *Tokenizer) Token {
        while (t.pos < t.source.len) {
            const c = t.source[t.pos];
            if (c == ' ' or c == '\t') {
                t.pos += 1;
                t.col += 1;
                continue;
            }
            if (c == '\r') {
                t.pos += 1;
                continue;
            }
            if (c == '\n') {
                t.pos += 1;
                t.line += 1;
                t.col = 1;
                continue;
            }
            const start = t.pos;
            const line = t.line;
            const col = t.col;

            // Comments: // or --
            if (c == '/' and t.pos + 1 < t.source.len and t.source[t.pos + 1] == '/') {
                t.pos += 2;
                t.col += 2;
                while (t.pos < t.source.len and t.source[t.pos] != '\n') {
                    t.pos += 1;
                    t.col += 1;
                }
                continue;
            }
            if (c == '"') return t.readString(start, line, col);
            if (std.ascii.isDigit(c)) return t.readNumber(start, line, col);
            if (std.ascii.isAlphabetic(c) or c == '_') return t.readIdentOrKeyword(start, line, col);

            t.pos += 1;
            t.col += 1;
            const ty: TokenType = switch (c) {
                '{' => .lbrace,
                '}' => .rbrace,
                '(' => .lparen,
                ')' => .rparen,
                '[' => .lsquare,
                ']' => .rsquare,
                ':' => .colon,
                ';' => .semicolon,
                ',' => .comma,
                '.' => .dot,
                '=' => blk: {
                    if (t.pos < t.source.len and t.source[t.pos] == '=') {
                        t.pos += 1;
                        t.col += 1;
                        break :blk .eq;
                    }
                    break :blk .assign;
                },
                '+' => blk: {
                    if (t.pos < t.source.len and t.source[t.pos] == '+') {
                        t.pos += 1;
                        t.col += 1;
                        break :blk .increment;
                    }
                    break :blk .plus;
                },
                '-' => blk: {
                    if (t.pos < t.source.len and t.source[t.pos] == '>') {
                        t.pos += 1;
                        t.col += 1;
                        break :blk .arrow;
                    }
                    if (t.pos < t.source.len and t.source[t.pos] == '-') {
                        t.pos += 1;
                        t.col += 1;
                        break :blk .decrement;
                    }
                    break :blk .minus;
                },
                '*' => .star,
                '/' => .slash,
                '%' => .percent,
                '&' => blk: {
                    if (t.pos < t.source.len and t.source[t.pos] == '&') {
                        t.pos += 1;
                        t.col += 1;
                        break :blk .and_op;
                    }
                    break :blk .amp;
                },
                '|' => blk: {
                    if (t.pos < t.source.len and t.source[t.pos] == '|') {
                        t.pos += 1;
                        t.col += 1;
                        break :blk .or_op;
                    }
                    break :blk .pipe;
                },
                '^' => .caret,
                '~' => .tilde,
                '<' => blk: {
                    if (t.pos < t.source.len and t.source[t.pos] == '<') {
                        t.pos += 1;
                        t.col += 1;
                        break :blk .lshift;
                    }
                    if (t.pos < t.source.len and t.source[t.pos] == '=') {
                        t.pos += 1;
                        t.col += 1;
                        break :blk .le;
                    }
                    break :blk .lt;
                },
                '>' => blk: {
                    if (t.pos < t.source.len and t.source[t.pos] == '>') {
                        t.pos += 1;
                        t.col += 1;
                        break :blk .rshift;
                    }
                    if (t.pos < t.source.len and t.source[t.pos] == '=') {
                        t.pos += 1;
                        t.col += 1;
                        break :blk .ge;
                    }
                    break :blk .gt;
                },
                '!' => blk: {
                    if (t.pos < t.source.len and t.source[t.pos] == '=') {
                        t.pos += 1;
                        t.col += 1;
                        break :blk .neq;
                    }
                    break :blk .not;
                },
                '#' => .hash,
                '@' => .at,
                else => .invalid,
            };
            return .{ .ttype = ty, .start = start, .len = t.pos - start, .line = line, .col = col };
        }
        return .{ .ttype = .eof, .start = t.pos, .len = 0, .line = t.line, .col = t.col };
    }

    fn readString(t: *Tokenizer, start: usize, line: usize, col: usize) Token {
        t.pos += 1;
        t.col += 1;
        while (t.pos < t.source.len and t.source[t.pos] != '"') {
            if (t.source[t.pos] == '\\') {
                t.pos += 1;
                t.col += 1;
            }
            t.pos += 1;
            t.col += 1;
        }
        if (t.pos < t.source.len) {
            t.pos += 1;
            t.col += 1;
        }
        return .{ .ttype = .string_lit, .start = start, .len = t.pos - start, .line = line, .col = col };
    }

    fn readNumber(t: *Tokenizer, start: usize, line: usize, col: usize) Token {
        while (t.pos < t.source.len) {
            const c = t.source[t.pos];
            if (std.ascii.isDigit(c) or c == '.' or c == 'x' or c == 'X' or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
                t.pos += 1;
                t.col += 1;
            } else {
                break;
            }
        }
        return .{ .ttype = .number, .start = start, .len = t.pos - start, .line = line, .col = col };
    }

    fn readIdentOrKeyword(t: *Tokenizer, start: usize, line: usize, col: usize) Token {
        while (t.pos < t.source.len) {
            const c = t.source[t.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                t.pos += 1;
                t.col += 1;
            } else {
                break;
            }
        }
        const word = t.source[start..t.pos];
        const ty = keywordType(word);
        return .{ .ttype = ty, .start = start, .len = t.pos - start, .line = line, .col = col };
    }

    fn keywordType(word: []const u8) TokenType {
        const map = std.StaticStringMap(TokenType).initComptime(.{
            .{ "entry", .keyword_entry },
            .{ "state", .keyword_state },
            .{ "var", .keyword_var },
            .{ "on", .keyword_on },
            .{ "after", .keyword_after },
            .{ "enter", .keyword_enter },
            .{ "exit", .keyword_exit },
            .{ "always", .keyword_always },
            .{ "return", .keyword_return },
            .{ "print", .keyword_print },
            .{ "fn", .keyword_fn },
            .{ "inline", .keyword_inline },
            .{ "struct", .keyword_struct },
            .{ "true", .keyword_true },
            .{ "false", .keyword_false },
            .{ "if", .keyword_if },
            .{ "else", .keyword_else },
            .{ "while", .keyword_while },
            .{ "for", .keyword_for },
            .{ "volatile", .keyword_volatile },
            .{ "fixed", .keyword_fixed },
            .{ "compute_kernel", .keyword_compute_kernel },
        });
        return map.get(word) orelse .ident;
    }

    pub fn tokenText(t: *Tokenizer, tok: Token) []const u8 {
        return t.source[tok.start .. tok.start + tok.len];
    }
};

pub fn tokenizeFull(source: []const u8, allocator: std.mem.Allocator) ![]Token {
    var list = std.ArrayList(Token).init(allocator);
    var t = Tokenizer.init(source, allocator);
    while (true) {
        const tok = t.next();
        try list.append(tok);
        if (tok.ttype == .eof or tok.ttype == .invalid) break;
    }
    return list.items;
}
