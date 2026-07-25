const std = @import("std");
const cursor_mod = @import("cursor.zig");
const token_mod = @import("../token/token.zig");
const literal_scanner = @import("literal_scanner.zig");
const keyword_mod = @import("../token/keyword.zig");
const span_mod = @import("../../source/location/span.zig");

const Cursor = cursor_mod.Cursor;
const Token = token_mod.Token;
const TokenKind = token_mod.TokenKind;
const SourceSpan = span_mod.SourceSpan;

pub const Lexer = struct {
    cursor: Cursor,
    file_id: u32,
    buffer: std.ArrayList(Token),

    pub fn init(source: []const u8, file_id: u32, allocator: std.mem.Allocator) Lexer {
        return .{
            .cursor = Cursor.init(source),
            .file_id = file_id,
            .buffer = std.ArrayList(Token).init(allocator),
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.buffer.deinit();
    }

    pub fn lex(self: *Lexer) !std.ArrayList(Token) {
        while (!self.cursor.isEof()) {
            self.cursor.skipWhitespace();
            if (self.cursor.isEof()) break;

            const tok = self.nextToken();
            try self.buffer.append(tok);
            if (tok.kind == .eof) break;
        }
        if (self.buffer.items.len == 0 or self.buffer.items[self.buffer.items.len - 1].kind != .eof) {
            try self.buffer.append(Token.eof(self.file_id));
        }
        return self.buffer;
    }

    pub fn nextToken(self: *Lexer) Token {
        self.cursor.skipWhitespace();
        if (self.cursor.isEof()) return Token.eof(self.file_id);

        const start: u32 = @intCast(self.cursor.pos);
        const ch = self.cursor.peek() orelse return Token.eof(self.file_id);

        if (ch == '/' and self.cursor.peekAhead(1) == '/') {
            self.cursor.skipLineComment();
            return self.makeToken(.line_comment, start);
        }
        if (ch == '/' and self.cursor.peekAhead(1) == '*') {
            self.cursor.skipBlockComment();
            return self.makeToken(.block_comment, start);
        }
        if (ch == '@' and self.cursor.peekAhead(1) == '/') {
            self.cursor.pos += 2;
            self.cursor.skipLineComment();
            return self.makeToken(.doc_comment_single, start);
        }
        if (ch == '@' and self.cursor.peekAhead(1) == '*') {
            self.cursor.pos += 2;
            self.cursor.skipBlockComment();
            return self.makeToken(.doc_comment_multi, start);
        }

        if (ch == '"') {
            if (self.cursor.peekAhead(1) == '"') {
                return self.scanMultilineString(start);
            }
            if (literal_scanner.scanStringLiteral(&self.cursor)) |lit| {
                return self.makeToken(lit.kind, start);
            }
        }
        if (ch == 'b' and self.cursor.peekAhead(1) == '"') {
            if (literal_scanner.scanByteStringLiteral(&self.cursor)) |lit| {
                return self.makeToken(lit.kind, start);
            }
        }
        if (ch == '\'') {
            if (literal_scanner.scanCharLiteral(&self.cursor)) |lit| {
                return self.makeToken(lit.kind, start);
            }
        }
        if (ch == 'b' and self.cursor.peekAhead(1) == '\'') {
            if (literal_scanner.scanByteLiteral(&self.cursor)) |lit| {
                return self.makeToken(lit.kind, start);
            }
        }

        if (ch >= '0' and ch <= '9') {
            if (literal_scanner.scanNumber(&self.cursor)) |lit| {
                return self.makeToken(lit.kind, start);
            }
        }

        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_') {
            return self.scanIdentOrKeyword(start);
        }

        return self.scanPunctuation(start);
    }

    fn scanIdentOrKeyword(self: *Lexer, start: u32) Token {
        while (self.cursor.isAlphaNum()) {
            self.cursor.pos += 1;
        }
        const text = self.cursor.source[start..self.cursor.pos];
        if (keyword_mod.lookupKeyword(text)) |kw| {
            return self.makeToken(kw, start);
        }
        return self.makeToken(.identifier, start);
    }

    fn scanPunctuation(self: *Lexer, start: u32) Token {
        const ch = self.cursor.advance() orelse return Token.eof(self.file_id);

        return switch (ch) {
            '(' => self.makeToken(.lparen, start),
            ')' => self.makeToken(.rparen, start),
            '{' => self.makeToken(.lbrace, start),
            '}' => self.makeToken(.rbrace, start),
            '[' => self.makeToken(.lbracket, start),
            ']' => self.makeToken(.rbracket, start),
            ';' => self.makeToken(.semicolon, start),
            ',' => self.makeToken(.comma, start),
            '.' => {
                if (self.cursor.peek() == '.') {
                    self.cursor.pos += 1;
                    if (self.cursor.peek() == '.') {
                        self.cursor.pos += 1;
                        return self.makeToken(.dot_dot_dot, start);
                    }
                    if (self.cursor.peek() == '=') {
                        self.cursor.pos += 1;
                        return self.makeToken(.dot_dot_eq, start);
                    }
                    return self.makeToken(.dot_dot, start);
                }
                if (self.cursor.isDigit()) {
                    while (self.cursor.isDigit()) self.cursor.pos += 1;
                    return self.makeToken(.float_literal, start);
                }
                return self.makeToken(.dot, start);
            },
            ':' => {
                if (self.cursor.peek() == ':') {
                    self.cursor.pos += 1;
                    return self.makeToken(.colon_colon, start);
                }
                return self.makeToken(.colon, start);
            },
            '=' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.eq_eq, start);
                }
                return self.makeToken(.eq, start);
            },
            '!' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.bang_eq, start);
                }
                return self.makeToken(.bang, start);
            },
            '<' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.less_eq, start);
                }
                if (self.cursor.peek() == '<') {
                    self.cursor.pos += 1;
                    if (self.cursor.peek() == '=') {
                        self.cursor.pos += 1;
                        return self.makeToken(.shl_eq, start);
                    }
                    return self.makeToken(.shl, start);
                }
                return self.makeToken(.less, start);
            },
            '>' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.greater_eq, start);
                }
                if (self.cursor.peek() == '>') {
                    self.cursor.pos += 1;
                    if (self.cursor.peek() == '=') {
                        self.cursor.pos += 1;
                        return self.makeToken(.shr_eq, start);
                    }
                    return self.makeToken(.shr, start);
                }
                return self.makeToken(.greater, start);
            },
            '+' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.plus_eq, start);
                }
                return self.makeToken(.plus, start);
            },
            '-' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.minus_eq, start);
                }
                if (self.cursor.peek() == '>') {
                    self.cursor.pos += 1;
                    return self.makeToken(.arrow, start);
                }
                return self.makeToken(.minus, start);
            },
            '*' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.star_eq, start);
                }
                return self.makeToken(.star, start);
            },
            '/' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.slash_eq, start);
                }
                return self.makeToken(.slash, start);
            },
            '%' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.percent_eq, start);
                }
                return self.makeToken(.percent, start);
            },
            '^' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.caret_eq, start);
                }
                return self.makeToken(.caret, start);
            },
            '&' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.amp_eq, start);
                }
                if (self.cursor.peek() == '&') {
                    self.cursor.pos += 1;
                    return self.makeToken(.amp_amp, start);
                }
                return self.makeToken(.amp, start);
            },
            '|' => {
                if (self.cursor.peek() == '=') {
                    self.cursor.pos += 1;
                    return self.makeToken(.pipe_eq, start);
                }
                if (self.cursor.peek() == '|') {
                    self.cursor.pos += 1;
                    return self.makeToken(.pipe_pipe, start);
                }
                return self.makeToken(.pipe, start);
            },
            '~' => self.makeToken(.tilde, start),
            '#' => self.makeToken(.hash, start),
            '@' => self.makeToken(.at, start),
            '?' => {
                return self.makeToken(.question, start);
            },
            '\n', '\r' => self.makeToken(.newline, start),
            else => self.makeToken(.error_token, start),
        };
    }

    fn scanMultilineString(self: *Lexer, start: u32) Token {
        self.cursor.pos += 2;
        while (!self.cursor.isEof()) {
            if (self.cursor.peek() == '"' and self.cursor.peekAhead(1) == '"') {
                self.cursor.pos += 2;
                if (self.cursor.peek() == '"') {
                    self.cursor.pos += 1;
                    return self.makeToken(.string_literal, start);
                }
            }
            self.cursor.pos += 1;
        }
        return self.makeToken(.error_token, start);
    }

    fn makeToken(self: *const Lexer, kind: TokenKind, start: u32) Token {
        const text = self.cursor.source[start..self.cursor.pos];
        return Token.init(kind, .{ .file_id = self.file_id, .start = start, .end = @intCast(self.cursor.pos) }, 0, text);
    }
};
