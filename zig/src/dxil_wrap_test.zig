const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    // Read llvm-as generated bitcode
    const bc = try std.fs.cwd().readFileAlloc(alloc, "test_ref.bc", 1024 * 1024);
    defer alloc.free(bc);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Reference BC: {d} bytes\n", .{bc.len});

    // Build DXIL container
    try emitDxilContainer(alloc, bc);
}

fn emitDxilContainer(alloc: std.mem.Allocator, llvm_bc: []const u8) !void {
    const part_sfi0: u32 = 0x30494653;
    const part_isg1: u32 = 0x31475349;
    const part_osg1: u32 = 0x3147534F;
    const part_psv0: u32 = 0x30565350;
    const part_stat: u32 = 0x54415453;
    const part_dxil: u32 = 0x4C495844;

    // PSV0 data
    var psv_buf = try alloc.alloc(u8, 256);
    var psv_pos: u32 = 0;
    {
        const W = struct {
            fn writeLe(buf: []u8, pos: *u32, v: anytype) void {
                const n = @sizeOf(@TypeOf(v));
                std.mem.writeInt(@TypeOf(v), buf[pos.*..][0..n], v, .little);
                pos.* += n;
            }
        };
        W.writeLe(psv_buf, &psv_pos, @as(u32, 0x34));
        W.writeLe(psv_buf, &psv_pos, @as(u32, 0));
        W.writeLe(psv_buf, &psv_pos, @as(u32, 0));
        W.writeLe(psv_buf, &psv_pos, @as(u32, 0));
        psv_buf[psv_pos..][0..4].* = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
        psv_pos += 4;
        W.writeLe(psv_buf, &psv_pos, @as(u32, 5)); // Compute
        for ([_]u32{0} ** 14) |_| W.writeLe(psv_buf, &psv_pos, @as(u32, 0));
        W.writeLe(psv_buf, &psv_pos, @as(u32, 8)); // NumThreadsX
        W.writeLe(psv_buf, &psv_pos, @as(u32, 8)); // NumThreadsY
        W.writeLe(psv_buf, &psv_pos, @as(u32, 1)); // NumThreadsZ
        W.writeLe(psv_buf, &psv_pos, @as(u32, 1));
        for ([_]u32{0} ** 3) |_| W.writeLe(psv_buf, &psv_pos, @as(u32, 0));
        @memcpy(psv_buf[psv_pos..][0..4], "main");
        psv_buf[psv_pos + 4] = 0;
        psv_pos += 5;
        if (psv_pos % 4 != 0) psv_pos += 4 - (psv_pos % 4);
    }
    const psv = psv_buf[0..psv_pos];

    const sfi0: []const u8 = &[_]u8{0} ** 8;
    const isg1: []const u8 = &[_]u8{0} ** 8;
    const osg1: []const u8 = &[_]u8{0} ** 8;
    const stat: []const u8 = &[_]u8{ 0x66, 0, 5, 0, 0, 0, 0, 0 };

    // Build DXIL part
    const bc_wrapper_size: u32 = 12;
    const dxil_part_hdr_size: u32 = 8;
    const bc_offset_from_part: u32 = dxil_part_hdr_size;

    var dxil_part = std.ArrayList(u8).init(alloc);
    defer dxil_part.deinit();
    {
        const dw = dxil_part.writer();
        // DXIL part header: bc_offset, bc_size
        {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, bc_offset_from_part + bc_wrapper_size, .little);
            try dw.writeAll(&tmp);
        }
        {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @as(u32, @intCast(bc_wrapper_size + llvm_bc.len)), .little);
            try dw.writeAll(&tmp);
        }
        // BC wrapper
        try dw.writeAll(&[_]u8{ 0x42, 0x43, 0xC0, 0xDE }); // magic
        {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @as(u32, 0x0C21), .little); // version
            try dw.writeAll(&tmp);
        }
        {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, bc_wrapper_size, .little); // offset from wrapper
            try dw.writeAll(&tmp);
        }
        // Raw bitstream
        try dw.writeAll(llvm_bc);
    }

    const parts = [_]struct { cc: u32, data: []const u8 }{
        .{ .cc = part_sfi0, .data = sfi0 },
        .{ .cc = part_isg1, .data = isg1 },
        .{ .cc = part_osg1, .data = osg1 },
        .{ .cc = part_psv0, .data = psv },
        .{ .cc = part_stat, .data = stat },
        .{ .cc = part_dxil, .data = dxil_part.items },
    };

    const num_parts: u32 = parts.len;

    const base_hdr: u32 = 28;
    const header_size = base_hdr + num_parts * 4;
    var total: u32 = header_size;
    for (parts) |p| total += 8 + @as(u32, @intCast(p.data.len));

    var buf = try alloc.alloc(u8, total);
    @memset(buf, 0);
    var pos: u32 = 0;

    // Magic: "DXBC"
    @memcpy(buf[pos..][0..4], "DXBC");
    pos += 4;
    // Checksum: skip 16 bytes (zeros)
    pos += 16;
    // Version = 1
    std.mem.writeInt(u32, buf[pos..][0..4], @as(u32, 1), .little);
    pos += 4;
    // File size
    std.mem.writeInt(u32, buf[pos..][0..4], total, .little);
    pos += 4;
    // Part count
    std.mem.writeInt(u32, buf[pos..][0..4], num_parts, .little);
    pos += 4;

    // Part offset table
    const off_table_pos = pos;
    pos += num_parts * 4;

    var cur_file_off = header_size;
    for (parts, 0..) |p, i| {
        std.mem.writeInt(u32, buf[off_table_pos + i * 4 ..][0..4], cur_file_off, .little);
        std.mem.writeInt(u32, buf[pos..][0..4], p.cc, .little);
        std.mem.writeInt(u32, buf[pos + 4 ..][0..4], 8 + @as(u32, @intCast(p.data.len)), .little);
        pos += 8;
        @memcpy(buf[pos..][0..p.data.len], p.data);
        pos += @as(u32, @intCast(p.data.len));
        cur_file_off = pos;
    }

    try std.fs.cwd().writeFile(.{ .sub_path = "test_dxil_ref.dxil", .data = buf });
    const stdout = std.io.getStdOut().writer();
    try stdout.print("DXIL container: {d} bytes\n", .{total});
}
