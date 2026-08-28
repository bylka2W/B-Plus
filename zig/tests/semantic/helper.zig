const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const testing = std.testing;
const sema_mod = @import("../../src/compiler/frontend/sema/sema.zig");
const parser_mod = @import("../../src/compiler/frontend/parser/parser.zig");

/// Reads a .b+ file, parses, runs semantic analysis,
/// and returns the SemaResult.
pub fn analyzeTestFile(alloc: mem.Allocator, path: []const u8) !sema_mod.SemaResult {
    // Read file content
    const file = try fs.cwd().openFile(path, .{ .mode = .read });
    defer file.close();
    const content = try file.readToEndAlloc(alloc, 32 * 1024);

    // Parse into program
    var lexer = parser_mod.Lexer.init(content, 0, alloc);
    defer lexer.deinit();
    const tokens = try lexer.lex();
    defer tokens.deinit();
    var stream = parser_mod.TokenStream.init(alloc);
    defer stream.deinit();
    for (tokens.items) |tok| {
        try stream.append(tok);
    }
    var parser = parser_mod.Parser.init(&stream, alloc);
    defer parser.deinit();
    const program = try parser.parse();
    defer program.deinit();

    // Semantic analysis
    return try sema_mod.analyze(alloc, program, content, path);
}

fn expectDiagnostic(result: sema_mod.SemaResult, tag: any) void {
    // Find diagnostic with given tag; fail if not found
    for (result.diagnostics) |diag| {
        if (mem.eq(u8, diag.tag, @typeName(tag))) {
            return;
        }
    }
    testing.fail("expected diagnostic tag not found: " ++ @typeName(tag));
}

fn expectNoDiagnostics(result: sema_mod.SemaResult) void {
    if (result.diagnostics.len > 0) {
        testing.fail("expected no diagnostics, found " ++ mem.toString(result.diagnostics.len));
    }
}
