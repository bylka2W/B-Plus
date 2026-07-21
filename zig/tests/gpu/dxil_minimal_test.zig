const std = @import("std");
const dxil_bc = @import("../../src/compiler/gpu/dxil_bitcode.zig");

/// Minimal test: just MODULE_BLOCK with VERSION record.
/// This strips everything else to isolate the basic bitstream structure.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var bw = dxil_bc.Writer.init(alloc);
    defer bw.deinit();

    // Minimal module: MODULE_BLOCK, VERSION record, end
    try bw.enterBlock(8, 4); // MODULE_BLOCK, CodeLen=4
    try bw.record(1, &.{2}); // MODULE_CODE_VERSION = 2
    try bw.exitBlock();

    const bytes = try bw.finish();

    // Write with wrapper (offset=5 words)
    var hdr: [20]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 0xDEC04342, .little);
    std.mem.writeInt(u32, hdr[4..8], 0x1435, .little);
    std.mem.writeInt(u32, hdr[8..12], 5, .little);
    @memset(hdr[12..20], 0);
    
    var bc = std.ArrayList(u8).init(alloc);
    try bc.appendSlice(&hdr);
    try bc.appendSlice(bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "minimal_output.bc", .data = bc.items });

    const stdout = std.io.getStdOut().writer();
    try stdout.print("minimal_output.bc: {d} bytes ({d} bitstream)\n", .{ bc.items.len, bytes.len });
    
    // Hex dump for debugging
    for (bc.items, 0..) |b, i| {
        if (i % 16 == 0) try stdout.print("\n  {d:4}: ", .{i});
        try stdout.print("{b:0>8} ", .{b});
    }
    try stdout.print("\n", .{});
}
