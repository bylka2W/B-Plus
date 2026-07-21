const std = @import("std");
const dxil_bc = @import("../../src/compiler/gpu/dxil_bitcode.zig");

/// Test with more realistic records (source_filename, triple, datalayout)
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var bw = dxil_bc.Writer.init(alloc);
    defer bw.deinit();

    try bw.enterBlock(8, 4); // MODULE_BLOCK, CodeLen=4

    // VERSION
    try bw.record(1, &.{2});

    // SOURCE_FILENAME (code 7 in LLVM 13)
    const src = "test.ll";
    var src_ops: [20]u32 = undefined;
    for (src, 0..) |c, i| src_ops[i] = c;
    try bw.record(7, src_ops[0..src.len]);

    // TRIPLE: "dxil-ms-dx"
    try bw.record(2, &.{ 'd', 'x', 'i', 'l', '-', 'm', 's', '-', 'd', 'x' });

    // MODULE_CODE_FUNCTION: declare void @main()
    try bw.record(8, &.{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

    try bw.exitBlock();

    const bytes = try bw.finish();

    var hdr: [20]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 0xDEC04342, .little);
    std.mem.writeInt(u32, hdr[4..8], 0x1435, .little);
    std.mem.writeInt(u32, hdr[8..12], 5, .little);
    @memset(hdr[12..20], 0);
    
    var bc = std.ArrayList(u8).init(alloc);
    try bc.appendSlice(&hdr);
    try bc.appendSlice(bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "test_v2.bc", .data = bc.items });

    const stdout = std.io.getStdOut().writer();
    try stdout.print("test_v2.bc: {d} bytes ({d} bitstream)\n", .{ bc.items.len, bytes.len });
}
