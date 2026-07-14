const std = @import("std");
const dxil_bc = @import("dxil_bitcode.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var bw = dxil_bc.Writer.init(alloc);
    defer bw.deinit();

    // Emit minimal LLVM module bitcode
    try bw.enterBlock(8, 4); // MODULE_BLOCK (CodeLen=4 matches reference)

    // VERSION = 2 (LLVM 3.7)
    try bw.record(1, &.{2});

    // TRIPLE: {"dxil-ms-dx"}
    try bw.record(2, &.{ 'd', 'x', 'i', 'l', '-', 'm', 's', '-', 'd', 'x' });

    // DATALAYOUT
    const dl = "e-m:e-p:32:32-i1:32-i8:32-i16:32-i32:32-i64:64-f16:32-f32:32-f64:64-n8:16:32:64";
    var dl_ops: [100]u32 = undefined;
    for (dl, 0..) |c, i| dl_ops[i] = c;
    try bw.record(3, dl_ops[0..dl.len]);

    // TYPE_BLOCK
    // Type 0: void, Type 1: void (function ret), Type 2: function(void->void)
    try bw.enterBlock(10, 2);
    try bw.record(1, &.{3}); // NUMENTRY: 3 types
    try bw.record(2, &.{}); // TYPE_VOID
    try bw.record(2, &.{}); // TYPE_VOID (function return type)
    try bw.record(17, &.{0}); // TYPE_FUNCTION: return=type0 void, no params (not [0,0])
    try bw.exitBlock();

    // MODULE_CODE_FUNCTION: declare void @main()
    // LLVM 13: [value_id, type_id, callingconv, isvararg, comdat,
    //           linkage, paramsize, alignment, section, personality,
    //           prefix, unnamed_addr, prologue]
    try bw.record(8, &.{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

    // FUNCTION_BLOCK
    try bw.enterBlock(12, 2);
    try bw.record(1, &.{1}); // DECLARE_BLOCKS: 1 block
    // INST_BLOCK
    try bw.enterBlock(13, 2);
    try bw.record(1, &.{}); // INST_RET void
    try bw.exitBlock(); // INST_BLOCK
    try bw.exitBlock(); // FUNCTION_BLOCK

    // METADATA_BLOCK (minimal)
    try bw.enterBlock(15, 2);
    // Define metadata node 0 (empty/null)
    try bw.record(3, &.{}); // METADATA_NODE: null
    // !dx.version = !{!0}
    try bw.record(4, &.{ 'd', 'x', '.', 'v', 'e', 'r', 's', 'i', 'o', 'n' }); // METADATA_NAME
    try bw.record(5, &.{ 0, 0 }); // METADATA_NAMED_NODE: name[0] -> node[0]
    try bw.exitBlock();

    try bw.exitBlock(); // MODULE_BLOCK

    const bytes = try bw.finish();
    const stdout = std.io.getStdOut().writer();
    try stdout.print("LLVM bitcode: {d} bytes\n", .{bytes.len});

    // Write standalone BC file (matching LLVM 13 wrapper format)
    {
        // Wrapper: magic(4) + version(4) + offset(4) + optional_padding(8) + bitstream
        var hdr: [20]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], 0xDEC04342, .little); // BC magic 'BC\xc0\xde'
        std.mem.writeInt(u32, hdr[4..8], 0x1435, .little);     // Version (matches llvm-as)
        std.mem.writeInt(u32, hdr[8..12], 5, .little);         // Offset in words (5 = 20 bytes)
        @memset(hdr[12..20], 0);                                 // Padding (8 bytes, hash placeholder)
        var bc = std.ArrayList(u8).init(alloc);
        try bc.appendSlice(&hdr);
        try bc.appendSlice(bytes);
        try std.fs.cwd().writeFile(.{ .sub_path = "test_final.bc", .data = bc.items });
    }

    // Build DXIL container
    try emitDxilContainer(alloc, bytes);
}

fn emitDxilContainer(alloc: std.mem.Allocator, llvm_bc: []const u8) !void {
    const part_psv0: u32 = 0x30565350;
    const part_dxil: u32 = 0x4C495844;
    const gap: u32 = 8;

    // PSV0 data (68 bytes, exactly matching DXC reference format)
    // Fields: Size(0x34=52), ShaderType(5=compute), NumThreads(8,8,1),
    //         entry point name "main\0"
    const psv = &[_]u8{
        0x34, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x05, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0x00, 0x6d, 0x61, 0x69, 0x6e, 0x00,
    };

    // Build DXIL part payload:
    //   DxilProgramHeader (24 bytes): ProgramVersion + SizeInUint32 + Magic + HeaderVersion + BitcodeOffset + BitcodeSize
    //   BC wrapper (12 bytes): BC magic (4) + wrapper version (4) + offset to bitcode (4)
    //   Raw bitstream
    const dxil_data_sz: u32 = @as(u32, @intCast(24 + 12 + llvm_bc.len)); // DxilProgramHeader + wrapper + bitstream
    const dxil_part_sz: u32 = 8 + dxil_data_sz; // part header (8) + data

    var dxil_part: [2048]u8 = undefined;
    @memset(&dxil_part, 0);
    const hdr = dxil_part[0..24];
    std.mem.writeInt(u32, hdr[0..4], 0x00050060, .little); // ProgramVersion (CS_5_0)
    std.mem.writeInt(u32, hdr[4..8], dxil_part_sz / 4, .little); // SizeInUint32
    @memcpy(hdr[8..12], "DXIL");
    std.mem.writeInt(u32, hdr[12..16], 0x100, .little); // HeaderVersion
    std.mem.writeInt(u32, hdr[16..20], 16, .little); // BitcodeOffset
    std.mem.writeInt(u32, hdr[20..24], 20 + @as(u32, @intCast(llvm_bc.len)), .little); // BitcodeSize

    const wrapper = dxil_part[24..36];
    std.mem.writeInt(u32, wrapper[0..4], 0xDEC04342, .little); // BC magic
    std.mem.writeInt(u32, wrapper[4..8], 0x0C21, .little); // wrapper version
    std.mem.writeInt(u32, wrapper[8..12], 12, .little); // offset to bitcode

    // Copy bitcode after wrapper
    @memcpy(dxil_part[36..][0..llvm_bc.len], llvm_bc);

    const dxil_data = dxil_part[0..dxil_data_sz];

    const num_parts: u32 = 2;
    const header_size: u32 = 32 + num_parts * 4;
    const total: u32 = header_size + (8 + @as(u32, @intCast(psv.len)) + gap) + (8 + @as(u32, @intCast(dxil_data.len)) + gap);

    var buf = try alloc.alloc(u8, total);
    @memset(buf, 0);
    var pos: u32 = 0;

    // DXBC header
    @memcpy(buf[pos..][0..4], "DXBC");
    pos += 20; // magic + checksum
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little); // version
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], total, .little); // file_size
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], num_parts, .little); // part_count
    pos += 4;

    const off_table_start = pos;
    pos += num_parts * 4;

    // Write parts with 8-byte gaps
    var cur_off: u32 = header_size;

    // PSV0 part
    std.mem.writeInt(u32, buf[off_table_start..][0..4], cur_off, .little);
    std.mem.writeInt(u32, buf[cur_off..][0..4], part_psv0, .little);
    std.mem.writeInt(u32, buf[cur_off + 4 ..][0..4], 8 + @as(u32, @intCast(psv.len)), .little);
    @memcpy(buf[cur_off + 8 ..][0..psv.len], psv);
    cur_off += 8 + @as(u32, @intCast(psv.len)) + gap;

    // DXIL part
    std.mem.writeInt(u32, buf[off_table_start + 4 ..][0..4], cur_off, .little);
    std.mem.writeInt(u32, buf[cur_off..][0..4], part_dxil, .little);
    std.mem.writeInt(u32, buf[cur_off + 4 ..][0..4], 8 + @as(u32, @intCast(dxil_data.len)), .little);
    @memcpy(buf[cur_off + 8 ..][0..dxil_data.len], dxil_data);
    // trailing gap already zeroed

    try std.fs.cwd().writeFile(.{ .sub_path = "test_dxil_empty.dxil", .data = buf });
    const stdout = std.io.getStdOut().writer();
    try stdout.print("DXIL container: {d} bytes ({d} parts, hdr={d})\n", .{ total, num_parts, header_size });
}
