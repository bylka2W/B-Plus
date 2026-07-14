const std = @import("std");
const Writer = @import("dxil_bitcode.zig").Writer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var w = Writer.init(a);
    defer w.deinit();

    // Minimal bitstream: MODULE_BLOCK with some content
    try w.enterBlock(8, 2); // MODULE_BLOCK
    try w.enterBlock(14, 2); // TYPE_BLOCK
    try w.enterBlock(7, 2); // BLOCKINFO_BLOCK
    try w.exitBlock(); // BLOCKINFO
    try w.exitBlock(); // TYPE_BLOCK
    try w.exitBlock(); // MODULE_BLOCK

    const bc = try w.finish();

    // Write standalone BC
    const out = try std.fs.cwd().createFile("test_writer.bc", .{});
    defer out.close();
    try out.writeAll(bc);
    std.debug.print("Wrote {d} bytes\n", .{bc.len});
}
