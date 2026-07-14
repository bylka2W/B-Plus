const std = @import("std");
const dxil_bc = @import("dxil_bitcode.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    // Test 1: Just MODULE block with VERSION
    {
        var bw = dxil_bc.Writer.init(alloc);
        defer bw.deinit();
        try bw.enterBlock(8, 3);
        try bw.record(1, &.{2}); // VERSION
        try bw.exitBlock();
        const bytes = try bw.finish();
        var hdr: [12]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], 0xDEC04342, .little);
        std.mem.writeInt(u32, hdr[4..8], 1, .little);
        std.mem.writeInt(u32, hdr[8..12], 12, .little);
        var bc = std.ArrayList(u8).init(alloc);
        try bc.appendSlice(&hdr);
        try bc.appendSlice(bytes);
        try std.fs.cwd().writeFile(.{ .sub_path = "test_v1.bc", .data = bc.items });
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Test 1: MODULE + VERSION only: {d} bytes\n", .{bytes.len});
    }

    // Test 2: MODULE + VERSION + TRIPLE
    {
        var bw = dxil_bc.Writer.init(alloc);
        defer bw.deinit();
        try bw.enterBlock(8, 3);
        try bw.record(1, &.{2}); // VERSION
        try bw.record(2, &.{ 'd', 'x', 'i', 'l', '-', 'm', 's', '-', 'd', 'x' }); // TRIPLE
        try bw.exitBlock();
        const bytes = try bw.finish();
        var hdr: [12]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], 0xDEC04342, .little);
        std.mem.writeInt(u32, hdr[4..8], 1, .little);
        std.mem.writeInt(u32, hdr[8..12], 12, .little);
        var bc = std.ArrayList(u8).init(alloc);
        try bc.appendSlice(&hdr);
        try bc.appendSlice(bytes);
        try std.fs.cwd().writeFile(.{ .sub_path = "test_v2.bc", .data = bc.items });
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Test 2: + TRIPLE: {d} bytes\n", .{bytes.len});
    }

    // Test 3: + DATALAYOUT
    {
        var bw = dxil_bc.Writer.init(alloc);
        defer bw.deinit();
        try bw.enterBlock(8, 3);
        try bw.record(1, &.{2});
        try bw.record(2, &.{ 'd', 'x', 'i', 'l', '-', 'm', 's', '-', 'd', 'x' });
        const dl = "e-m:e-p:32:32-i1:32-i8:32-i16:32-i32:32-i64:64-f16:32-f32:32-f64:64-n8:16:32:64";
        var dl_ops: [100]u32 = undefined;
        for (dl, 0..) |c, i| dl_ops[i] = c;
        try bw.record(3, dl_ops[0..dl.len]);
        try bw.exitBlock();
        const bytes = try bw.finish();
        var hdr: [12]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], 0xDEC04342, .little);
        std.mem.writeInt(u32, hdr[4..8], 1, .little);
        std.mem.writeInt(u32, hdr[8..12], 12, .little);
        var bc = std.ArrayList(u8).init(alloc);
        try bc.appendSlice(&hdr);
        try bc.appendSlice(bytes);
        try std.fs.cwd().writeFile(.{ .sub_path = "test_v3.bc", .data = bc.items });
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Test 3: + DATALAYOUT: {d} bytes\n", .{bytes.len});
    }

    // Test 4: + TYPE_BLOCK
    {
        var bw = dxil_bc.Writer.init(alloc);
        defer bw.deinit();
        try bw.enterBlock(8, 3);
        try bw.record(1, &.{2});
        try bw.record(2, &.{ 'd', 'x', 'i', 'l', '-', 'm', 's', '-', 'd', 'x' });
        const dl = "e-m:e-p:32:32-i1:32-i8:32-i16:32-i32:32-i64:64-f16:32-f32:32-f64:64-n8:16:32:64";
        var dl_ops: [100]u32 = undefined;
        for (dl, 0..) |c, i| dl_ops[i] = c;
        try bw.record(3, dl_ops[0..dl.len]);
        try bw.enterBlock(10, 2); // TYPE_BLOCK
        try bw.record(1, &.{1}); // NUMENTRY: 1 type
        try bw.record(2, &.{}); // TYPE_VOID
        try bw.exitBlock();
        try bw.exitBlock();
        const bytes = try bw.finish();
        var hdr: [12]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], 0xDEC04342, .little);
        std.mem.writeInt(u32, hdr[4..8], 1, .little);
        std.mem.writeInt(u32, hdr[8..12], 12, .little);
        var bc = std.ArrayList(u8).init(alloc);
        try bc.appendSlice(&hdr);
        try bc.appendSlice(bytes);
        try std.fs.cwd().writeFile(.{ .sub_path = "test_v4.bc", .data = bc.items });
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Test 4: + TYPE_BLOCK: {d} bytes\n", .{bytes.len});
    }
}
