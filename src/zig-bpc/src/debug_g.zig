const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser_mod = @import("parser.zig");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const src = "x == 5";
    var p = parser_mod.Parser.init(&.{}, src, allocator);
    const stmts = p.parseBodyStmtsFromSource(src);
    std.debug.print("stmts: {d}\n", .{stmts.items.len});
    for (stmts.items, 0..) |s, i| {
        std.debug.print("  [{d}] kind={s}", .{i, @tagName(s.kind)});
        if (s.expr) |e| {
            std.debug.print(" expr_kind={s}", .{@tagName(e.kind)});
            if (e.kind == .binary) {
                if (e.left) |l| std.debug.print(" left_kind={s}", .{@tagName(l.kind)});
                std.debug.print(" op={s}", .{e.op});
                if (e.right) |r| std.debug.print(" right_kind={s}", .{@tagName(r.kind)});
            }
        }
        std.debug.print("\n", .{});
    }
}