const std = @import("std");
const dxil_bc = @import("dxil_bitcode.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var bw = dxil_bc.Writer.init(alloc);
    defer bw.deinit();

    // Test 1: Just MODULE + VERSION + END_BLOCK
    try bw.enterBlock(8, 2);
    try bw.record(1, &.{2}); // VERSION
    try bw.exitBlock();

    const bytes = try bw.finish();
    
    // Write raw BC (magic only)
    var f = std.ArrayList(u8).init(alloc);
    try f.appendSlice("BC\xc0\xde");
    try f.appendSlice(bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "test_t1.bc", .data = f.items });
    try std.io.getStdOut().writer().print("Test 1: {d} bytes\n", .{f.items.len});
}
