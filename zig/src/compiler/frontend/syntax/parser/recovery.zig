const std = @import("std");
const token_stream_mod = @import("../token/token_stream.zig");
const token_kind = @import("../token/token_kind.zig");

pub const TokenKind = token_kind.TokenKind;
pub const TokenStream = token_stream_mod.TokenStream;
pub const RecoverySet = token_stream_mod.RecoverySet;

pub const RecoveryPolicy = struct {
    statement_recover: RecoverySet,
    block_recover: RecoverySet,
    expression_recover: RecoverySet,

    pub fn default() RecoveryPolicy {
        return .{
            .statement_recover = RecoverySet.init(&.{
                .semicolon,
                .rbrace,
                .kw_let,
                .kw_var,
                .kw_const,
                .kw_fn,
                .kw_if,
                .kw_while,
                .kw_for,
                .kw_return,
                .kw_struct,
                .kw_enum,
                .kw_trait,
                .kw_impl,
                .eof,
            }),
            .block_recover = RecoverySet.init(&.{
                .rbrace,
                .kw_fn,
                .kw_struct,
                .kw_enum,
                .kw_trait,
                .kw_impl,
                .eof,
            }),
            .expression_recover = RecoverySet.init(&.{
                .semicolon,
                .comma,
                .rparen,
                .rbrace,
                .rbracket,
                .kw_else,
                .kw_do,
                .eof,
            }),
        };
    }
};

pub fn skipToRecovery(stream: *TokenStream, recover_set: RecoverySet) void {
    while (!stream.at(.eof)) {
        if (recover_set.contains(stream.current().kind)) return;
        _ = stream.advance();
    }
}

pub fn expectOrInsert(stream: *TokenStream, kind: TokenKind, diagnostics: ?*DiagnosticSink) TokenKind {
    if (stream.at(kind)) {
        _ = stream.advance();
        return kind;
    }
    if (diagnostics) |diag| {
        diag.pushMissing(stream.current(), kind);
    }
    return kind;
}

pub const DiagnosticSink = struct {
    errors: std.ArrayList(DiagnosticError),

    pub const DiagnosticError = struct {
        message: []const u8,
        span_start: u32,
        span_end: u32,
        severity: Severity,
    };

    pub const Severity = enum { @"error", warning, note };

    pub fn init(allocator: std.mem.Allocator) DiagnosticSink {
        return .{
            .errors = std.ArrayList(DiagnosticError).init(allocator),
        };
    }

    pub fn deinit(self: *DiagnosticSink) void {
        self.errors.deinit();
    }

    pub fn pushMissing(self: *DiagnosticSink, token: anytype, expected: TokenKind) void {
        self.errors.append(.{
            .message = "unexpected token",
            .span_start = token.span.start,
            .span_end = token.span.end,
            .severity = .@"error",
        }) catch return;
        _ = expected;
    }

    pub fn pushMessage(self: *DiagnosticSink, msg: []const u8, start: u32, end: u32, sev: Severity) void {
        self.errors.append(.{
            .message = msg,
            .span_start = start,
            .span_end = end,
            .severity = sev,
        }) catch return;
    }

    pub fn hasErrors(self: *const DiagnosticSink) bool {
        for (self.errors.items) |e| {
            if (e.severity == .@"error") return true;
        }
        return false;
    }

    pub fn errorCount(self: *const DiagnosticSink) u32 {
        var count: u32 = 0;
        for (self.errors.items) |e| {
            if (e.severity == .@"error") count += 1;
        }
        return count;
    }
};
