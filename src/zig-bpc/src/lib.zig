const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser_mod = @import("parser.zig");
const gen_zig = @import("gen_zig.zig");
const gen_llvm = @import("gen_llvm.zig");
const ast_json = @import("ast_json.zig");

/// Generate Zig code from B+ source text (full parsing)
pub fn generate(source: []const u8, allocator: std.mem.Allocator, mode: u8) ![]const u8 {
    const tokens = try tokenizer.tokenizeFull(source, allocator);
    var parser = parser_mod.Parser.init(tokens, source, allocator);
    const program = try parser.parseProgram();
    if (mode == 1) {
        var gen = gen_llvm.Generator.init(allocator);
        return try gen.generate(program);
    }
    var gen = gen_zig.Generator.init(allocator);
    return try gen.generate(program);
}

/// Generate Zig code from pre-parsed JSON AST (skips top-level parsing and body re-parsing)
pub fn generateFromJson(json: []const u8, allocator: std.mem.Allocator, mode: u8) ![]const u8 {
    var program = try ast_json.parseJson(json, allocator);
    _ = &program;
    // body_stmts and guard_stmts are already populated by ast_json.parseJson
    // No re-parsing of raw text needed
    if (mode == 1) {
        var gen = gen_llvm.Generator.init(allocator);
        return try gen.generate(program);
    }
    var gen = gen_zig.Generator.init(allocator);
    return try gen.generate(program);
}

export fn bpc_generate(
    source: [*]u8,
    src_len: usize,
    output: [*]u8,
    out_len: *usize,
    mode: u8,
) u32 {
    const src = source[0..src_len];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = generate(src, allocator, mode) catch {
        out_len.* = 0;
        return 1;
    };
    const len = @min(result.len, out_len.*);
    @memcpy(output[0..len], result[0..len]);
    out_len.* = len;
    return 0;
}

export fn bpc_generate_json(
    json: [*]u8,
    json_len: usize,
    output: [*]u8,
    out_len: *usize,
    mode: u8,
) u32 {
    const js = json[0..json_len];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = generateFromJson(js, allocator, mode) catch {
        out_len.* = 0;
        return 1;
    };
    const len = @min(result.len, out_len.*);
    @memcpy(output[0..len], result[0..len]);
    out_len.* = len;
    return 0;
}
