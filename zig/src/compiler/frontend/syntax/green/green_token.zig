const std = @import("std");
const kind_mod = @import("../kind/syntax_kind.zig");

pub const SyntaxKind = kind_mod.SyntaxKind;

pub const GreenToken = struct {
    kind: SyntaxKind,
    text: []const u8,
    span_start: u32,
    span_end: u32,

    pub fn init(kind: SyntaxKind, text: []const u8, start: u32, end: u32) GreenToken {
        return .{ .kind = kind, .text = text, .span_start = start, .span_end = end };
    }

    pub fn len(self: GreenToken) u32 {
        return self.span_end - self.span_start;
    }

    pub fn trivia_len(self: GreenToken) u32 {
        _ = self;
        return 0;
    }

    pub fn is_trivia(self: GreenToken) bool {
        return self.kind.isTrivia();
    }

    pub fn is_error(self: GreenToken) bool {
        return self.kind == .error_token;
    }
};
