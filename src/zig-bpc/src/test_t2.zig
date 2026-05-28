const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser_mod = @import("parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const src = " x++; ";
    var p = parser_mod.Parser.init(&.{} , src, allocator);
    const stmts = p.parseBodyStmtsFromSource(src);
    std.debug.print("Parsed {d} stmts\n", .{ stmts.items.len });
    for (stmts.items, 0..) |s, i| {
        std.debug.print("  stmt {d}: kind={s}\n", .{ i, @tagName(s.kind) });
    }
}