const std = @import("std");
const kind_mod = @import("token_kind.zig");
const span_mod = @import("../../source/location/span.zig");

pub const TokenKind = kind_mod.TokenKind;
pub const SourceSpan = span_mod.SourceSpan;

pub const Token = struct {
    kind: TokenKind,
    span: SourceSpan,
    symbol: u32,
    text: []const u8,

    pub fn init(kind: TokenKind, span: SourceSpan, symbol: u32, text: []const u8) Token {
        return .{ .kind = kind, .span = span, .symbol = symbol, .text = text };
    }

    pub fn eof(file_id: u32) Token {
        return .{
            .kind = .eof,
            .span = .{ .file_id = file_id, .start = 0, .end = 0 },
            .symbol = 0,
            .text = "",
        };
    }

    pub fn errorToken(file_id: u32, start: u32, end: u32) Token {
        return .{
            .kind = .error_token,
            .span = .{ .file_id = file_id, .start = start, .end = end },
            .symbol = 0,
            .text = "",
        };
    }

    pub fn withKind(self: Token, kind: TokenKind) Token {
        return .{ .kind = kind, .span = self.span, .symbol = self.symbol, .text = self.text };
    }

    pub fn withSpan(self: Token, span: SourceSpan) Token {
        return .{ .kind = self.kind, .span = span, .symbol = self.symbol, .text = self.text };
    }

    pub fn len(self: Token) u32 {
        return self.span.len();
    }

    pub fn is(self: Token, kind: TokenKind) bool {
        return self.kind == kind;
    }

    pub fn isOneOf(self: Token, kinds: []const TokenKind) bool {
        for (kinds) |k| {
            if (self.kind == k) return true;
        }
        return false;
    }

    pub fn isKeyword(self: Token) bool {
        return self.kind.isKeyword();
    }

    pub fn isLiteral(self: Token) bool {
        return self.kind.isLiteral();
    }

    pub fn isTrivia(self: Token) bool {
        return self.kind.isTrivia();
    }
};
