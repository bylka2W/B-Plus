const std = @import("std");
const token_mod = @import("token.zig");

pub const Token = token_mod.Token;
pub const TokenKind = token_mod.TokenKind;

pub const Mark = struct {
    position: u32,
};

pub const RecoverySet = struct {
    bits: u128,

    pub fn init(kinds: []const TokenKind) RecoverySet {
        var bits: u128 = 0;
        for (kinds) |k| {
            bits |= @as(u128, 1) << @intFromEnum(k);
        }
        return .{ .bits = bits };
    }

    pub fn contains(self: RecoverySet, kind: TokenKind) bool {
        return (self.bits & (@as(u128, 1) << @intFromEnum(kind))) != 0;
    }

    pub fn merge(a: RecoverySet, b: RecoverySet) RecoverySet {
        return .{ .bits = a.bits | b.bits };
    }
};

pub const TokenStream = struct {
    tokens: std.ArrayList(Token),
    position: u32,

    pub fn init(allocator: std.mem.Allocator) TokenStream {
        return .{
            .tokens = std.ArrayList(Token).init(allocator),
            .position = 0,
        };
    }

    pub fn deinit(self: *TokenStream) void {
        self.tokens.deinit();
    }

    pub fn append(self: *TokenStream, token: Token) !void {
        try self.tokens.append(token);
    }

    pub fn current(self: *const TokenStream) Token {
        if (self.position < self.tokens.items.len) return self.tokens.items[self.position];
        if (self.tokens.items.len > 0) return self.tokens.items[self.tokens.items.len - 1];
        return Token.eof(0);
    }

    pub fn peek(self: *const TokenStream, offset: u32) Token {
        const idx = self.position + offset;
        if (idx < self.tokens.items.len) return self.tokens.items[idx];
        if (self.tokens.items.len > 0) return self.tokens.items[self.tokens.items.len - 1];
        return Token.eof(0);
    }

    pub fn advance(self: *TokenStream) Token {
        const tok = self.current();
        if (self.position < self.tokens.items.len) {
            self.position += 1;
        }
        return tok;
    }

    pub fn expect(self: *TokenStream, kind: TokenKind) ?Token {
        const tok = self.current();
        if (tok.kind == kind) {
            _ = self.advance();
            return tok;
        }
        return null;
    }

    pub fn expectAdvance(self: *TokenStream, kind: TokenKind) Token {
        const tok = self.current();
        if (tok.kind == kind) {
            _ = self.advance();
            return tok;
        }
        return tok;
    }

    pub fn mark(self: *const TokenStream) Mark {
        return .{ .position = self.position };
    }

    pub fn restore(self: *TokenStream, m: Mark) void {
        self.position = m.position;
    }

    pub fn expectOrRecover(
        self: *TokenStream,
        expected: TokenKind,
        recovery: RecoverySet,
    ) struct { found: ?Token, recovered: bool } {
        const tok = self.current();
        if (tok.kind == expected) {
            _ = self.advance();
            return .{ .found = tok, .recovered = false };
        }
        while (!self.at(.eof)) {
            if (recovery.contains(self.current().kind)) {
                return .{ .found = null, .recovered = true };
            }
            _ = self.advance();
        }
        return .{ .found = null, .recovered = true };
    }

    pub fn skipToToken(self: *TokenStream, target: TokenKind) void {
        while (!self.at(.eof) and !self.at(target)) {
            _ = self.advance();
        }
        if (self.at(target)) {
            _ = self.advance();
        }
    }

    pub fn skipTrivia(self: *TokenStream) void {
        while (self.current().isTrivia()) {
            _ = self.advance();
        }
    }

    pub fn at(self: *TokenStream, kind: TokenKind) bool {
        return self.current().kind == kind;
    }

    pub fn atOneOf(self: *TokenStream, kinds: []const TokenKind) bool {
        const cur = self.current();
        for (kinds) |k| {
            if (cur.kind == k) return true;
        }
        return false;
    }

    pub fn slice(self: *const TokenStream) []const Token {
        return self.tokens.items;
    }

    pub fn len(self: *const TokenStream) u32 {
        return @intCast(self.tokens.items.len);
    }

    pub fn positionAsU32(self: *const TokenStream) u32 {
        return self.position;
    }

    pub fn setPosition(self: *TokenStream, pos: u32) void {
        self.position = pos;
    }

    pub fn hasProgress(self: *const TokenStream, before: u32) bool {
        return self.positionAsU32() != before;
    }

    pub fn recoverProgress(self: *TokenStream, before: u32) bool {
        if (self.hasProgress(before)) {
            return true;
        }
        if (!self.at(.eof)) {
            _ = self.advance();
        }
        self.skipTrivia();
        return false;
    }

    pub fn tokenAt(self: *const TokenStream, idx: u32) Token {
        if (idx < self.tokens.items.len) return self.tokens.items[idx];
        return Token.eof(0);
    }
};
