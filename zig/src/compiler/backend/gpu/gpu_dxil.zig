const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_ir = @import("gpu_ir.zig");
const bc = @import("dxil_bitcode.zig");

pub const backend: gpu_ir.BackendApi = .{
    .name = "DXIL",
    .target = .dxil,
    .file_extension = "dxil",
    .description = "Direct3D DXIL shader bytecode (native LLVM bitcode)",
    .compile = compileDxilFromIr,
};

fn compileDxilFromIr(allocator: Allocator, ir: *const gpu_ir.IrModule, _: gpu_ir.CompileOptions) !gpu_ir.CompileResult {
    const dxil_bytes = try emitDxilContainer(allocator, ir);
    return gpu_ir.CompileResult{
        .bytecode = dxil_bytes,
        .allocator = allocator,
    };
}

fn emitDxilContainer(allocator: Allocator, ir: *const gpu_ir.IrModule) ![]u8 {
    // 1. Generate LLVM bitcode
    var bw = bc.Writer.init(allocator);
    defer bw.deinit();
    try emitLlvmModule(&bw, ir);
    const llvm_bc = try bw.finish();

    // 2. Build parts
    const func = &ir.functions.items[0];
    const psv = try buildPsv(allocator, func);
    const dxil_payload = try buildDxilPayload(allocator, llvm_bc);

    // 3. Write container: DXBC header + part offset table + parts with 8-byte gaps
    const gap: u32 = 8;
    const num_parts: u32 = 2;
    const header_size: u32 = 32 + num_parts * 4;
    const total: u32 = header_size +
        (8 + @as(u32, @intCast(psv.len)) + gap) +
        (8 + @as(u32, @intCast(dxil_payload.len)) + gap);

    var buf = try allocator.alloc(u8, total);
    @memset(buf, 0);
    var pos: u32 = 0;

    @memcpy(buf[pos..][0..4], "DXBC");
    pos += 20;
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], total, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], num_parts, .little);
    pos += 4;

    const off_table = pos;
    pos += num_parts * 4;

    var cur_off: u32 = header_size;

    std.mem.writeInt(u32, buf[off_table..][0..4], cur_off, .little);
    std.mem.writeInt(u32, buf[cur_off..][0..4], 0x30565350, .little);
    std.mem.writeInt(u32, buf[cur_off + 4 ..][0..4], 8 + @as(u32, @intCast(psv.len)), .little);
    @memcpy(buf[cur_off + 8 ..][0..psv.len], psv);
    cur_off += 8 + @as(u32, @intCast(psv.len)) + gap;

    std.mem.writeInt(u32, buf[off_table + 4 ..][0..4], cur_off, .little);
    std.mem.writeInt(u32, buf[cur_off..][0..4], 0x4C495844, .little);
    std.mem.writeInt(u32, buf[cur_off + 4 ..][0..4], 8 + @as(u32, @intCast(dxil_payload.len)), .little);
    @memcpy(buf[cur_off + 8 ..][0..dxil_payload.len], dxil_payload);

    return buf;
}

fn buildPsv(allocator: Allocator, func: *const gpu_ir.IrFunction) ![]u8 {
    const psv_len: usize = 70;
    const psv = try allocator.alloc(u8, psv_len);
    @memset(psv, 0);
    std.mem.writeInt(u32, psv[0..4], 0x34, .little);
    std.mem.writeInt(u32, psv[24..28], 0xFFFFFFFF, .little);
    std.mem.writeInt(u32, psv[28..32], 5, .little);
    std.mem.writeInt(u32, psv[40..44], func.numthreads.x, .little);
    std.mem.writeInt(u32, psv[44..48], func.numthreads.y, .little);
    std.mem.writeInt(u32, psv[48..52], func.numthreads.z, .little);
    std.mem.writeInt(u32, psv[52..56], 1, .little);
    std.mem.writeInt(u32, psv[60..64], 8, .little);
    if (func.name.len >= 4) {
        @memcpy(psv[65..69], func.name[0..4]);
    } else {
        psv[65] = 'm';
        psv[66] = 'a';
        psv[67] = 'i';
        psv[68] = 'n';
    }
    return psv;
}

fn buildDxilPayload(allocator: Allocator, llvm_bc: []const u8) ![]u8 {
    const bc_align_bytes: u32 = 12 * 4; // 48 bytes from BC wrapper start to bitstream
    const bc_wrapper_sz: usize = bc_align_bytes;
    const dxil_data_sz: usize = 24 + bc_wrapper_sz + llvm_bc.len;
    const payload = try allocator.alloc(u8, dxil_data_sz);
    @memset(payload, 0);

    const bitcode_sz: u32 = @as(u32, @intCast(bc_wrapper_sz + llvm_bc.len));
    std.mem.writeInt(u32, payload[0..4], 0x00050060, .little);
    std.mem.writeInt(u32, payload[4..8], (24 + bitcode_sz + 3) / 4, .little);
    @memcpy(payload[8..12], "DXIL");
    std.mem.writeInt(u32, payload[12..16], 0x100, .little);
    std.mem.writeInt(u32, payload[16..20], 24, .little);
    std.mem.writeInt(u32, payload[20..24], bitcode_sz, .little);

    std.mem.writeInt(u32, payload[24..28], 0xDEC04342, .little);
    std.mem.writeInt(u32, payload[28..32], 0x0C21, .little);
    std.mem.writeInt(u32, payload[32..36], 12, .little);

    // padding from byte 36 to byte 71 (36 bytes) is already 0 from @memset

    @memcpy(payload[72..][0..llvm_bc.len], llvm_bc);
    return payload;
}

fn emitLlvmModule(bw: *bc.Writer, ir: *const gpu_ir.IrModule) !void {
    _ = ir;
    try bw.enterBlock(8, 2); // MODULE_BLOCK

    // Version = 2 (LLVM 3.7)
    try bw.record(1, &.{2});

    // Target triple
    try bw.record(2, &.{ 'd', 'x', 'i', 'l', '-', 'm', 's', '-', 'd', 'x' });

    // Data layout
    const dl = "e-m:e-p:32:32-i1:32-i8:32-i16:32-i32:32-i64:64-f16:32-f32:32-f64:64-n8:16:32:64";
    var dl_ops: [100]u32 = undefined;
    for (dl, 0..) |c, i| dl_ops[i] = c;
    try bw.record(3, dl_ops[0..dl.len]);

    // ── TYPE TABLE (LLVM 13 codes) ──
    try bw.enterBlock(10, 2); // TYPE_BLOCK
    try bw.record(1, &.{13}); // NUMENTRY: 13 types
    try bw.record(2, &.{}); // TYPE_VOID → type 0
    try bw.record(3, &.{}); // TYPE_FLOAT → type 1
    try bw.record(7, &.{32}); // TYPE_INTEGER: width=32 → type 2 (i32/u32)
    try bw.record(7, &.{16}); // TYPE_INTEGER: width=16 → type 3 (i16)
    try bw.record(7, &.{1}); // TYPE_INTEGER: width=1 → type 4 (i1/bool)
    try bw.record(8, &.{1}); // TYPE_POINTER: elt=type1(float), addrspace=0 → type 5 (float*)
    try bw.record(12, &.{2, 1}); // TYPE_VECTOR: count=2, elt=float → type 6 (<2 x f32>)
    try bw.record(12, &.{3, 1}); // TYPE_VECTOR: count=3, elt=float → type 7 (<3 x f32>)
    try bw.record(12, &.{4, 1}); // TYPE_VECTOR: count=4, elt=float → type 8 (<4 x f32>)
    try bw.record(12, &.{2, 2}); // TYPE_VECTOR: count=2, elt=i32 → type 9 (<2 x i32>)
    try bw.record(12, &.{3, 2}); // TYPE_VECTOR: count=3, elt=i32 → type 10 (<3 x i32>)
    try bw.record(12, &.{4, 2}); // TYPE_VECTOR: count=4, elt=i32 → type 11 (<4 x i32>)
    try bw.record(21, &.{0, 0}); // TYPE_FUNCTION: vararg=0, retty=void=type0 → type 12
    try bw.exitBlock(); // TYPE_BLOCK

    // ── FUNCTION DECLARATION ──
    // [value_id=0, type=12, callingconv=0, isproto=0, linkage=0, ...]
    try bw.record(8, &.{ 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

    // ── FUNCTION BLOCK ──
    try bw.enterBlock(12, 2); // FUNCTION_BLOCK
    try bw.record(1, &.{1}); // DECLARE_BLOCKS: 1 basic block

    // Constants block: define i32 values used in metadata and instructions
    try bw.enterBlock(11, 2); // CONSTANTS_BLOCK
    // CST_CODE_SETTYPE(1): set current type to i32 (type 2)
    try bw.record(1, &.{2});
    // CST_CODE_INTEGER(4): define integer constants (LLVM 13: INTEGER=4, not 2)
    try bw.record(4, &.{0}); // value 1: i32 0
    try bw.record(4, &.{1}); // value 2: i32 1
    try bw.record(4, &.{6}); // value 3: i32 6
    try bw.record(4, &.{9}); // value 4: i32 9
    try bw.record(4, &.{4}); // value 5: i32 4
    try bw.exitBlock(); // CONSTANTS_BLOCK

    // INST_BLOCK for basic block 0
    try bw.enterBlock(13, 2); // INST_BLOCK
    // ret void: INST_CODE_RET=1, record = [0] (void return)
    try bw.record(1, &.{0});
    try bw.exitBlock(); // INST_BLOCK

    try bw.exitBlock(); // FUNCTION_BLOCK

    // ── METADATA BLOCK ──
    try bw.enterBlock(15, 2); // METADATA_BLOCK

    // Metadata strings
    try emitMdString(bw, "dxcoob 1.9.2602.24 (d355aa836)"); // md #0
    try emitMdString(bw, "cs"); // md #1
    try emitMdString(bw, "main"); // md #2

    // Metadata nodes
    // !0 = !{!"dxcoob..."} → node containing md ref to #0
    try emitMdNode(bw, &.{.{
        .tag = .metadata,
        .val = 0, // md_id 0
    }}); // md #3

    // !1 = !{i32 1, i32 0}
    try emitMdNode(bw, &.{
        .{ .tag = .value, .val = 2 }, // value_id 2 = i32 1
        .{ .tag = .value, .val = 1 }, // value_id 1 = i32 0
    }); // md #4

    // !2 = !{i32 1, i32 9}
    try emitMdNode(bw, &.{
        .{ .tag = .value, .val = 2 }, // value_id 2 = i32 1
        .{ .tag = .value, .val = 4 }, // value_id 4 = i32 9
    }); // md #5

    // !3 = !{!"cs", i32 6, i32 0}
    try emitMdNode(bw, &.{
        .{ .tag = .metadata, .val = 1 }, // md_id 1 = "cs"
        .{ .tag = .value, .val = 3 }, // value_id 3 = i32 6
        .{ .tag = .value, .val = 1 }, // value_id 1 = i32 0
    }); // md #6

    // !6 = !{i32 1, i32 1, i32 1}
    try emitMdNode(bw, &.{
        .{ .tag = .value, .val = 2 },
        .{ .tag = .value, .val = 2 },
        .{ .tag = .value, .val = 2 },
    }); // md #7

    // !5 = !{i32 4, !6}
    try emitMdNode(bw, &.{
        .{ .tag = .value, .val = 5 }, // value_id 5 = i32 4
        .{ .tag = .metadata, .val = 7 }, // md_id 7 = !6
    }); // md #8

    // !4 = !{void ()* @main, !"main", null, null, !5}
    try emitMdNode(bw, &.{
        .{ .tag = .value, .val = 0 }, // value_id 0 = @main
        .{ .tag = .metadata, .val = 2 }, // md_id 2 = "main"
        .{ .tag = .null, .val = 0 },
        .{ .tag = .null, .val = 0 },
        .{ .tag = .metadata, .val = 8 }, // md_id 8 = !5
    }); // md #9

    // Named metadata
    try emitMdNamed(bw, "llvm.ident", 3); // = !{!0}
    try emitMdNamed(bw, "dx.version", 4); // = !{!1}
    try emitMdNamed(bw, "dx.valver", 5); // = !{!2}
    try emitMdNamed(bw, "dx.shaderModel", 6); // = !{!3}
    try emitMdNamed(bw, "dx.entryPoints", 9); // = !{!4}

    try bw.exitBlock(); // METADATA_BLOCK
    try bw.exitBlock(); // MODULE_BLOCK
}

const MdOperand = struct {
    tag: enum { null, value, metadata },
    val: u32,
};

fn emitMdString(bw: *bc.Writer, s: []const u8) !void {
    var ops: [256]u32 = undefined;
    for (s, 0..) |c, i| ops[i] = c;
    try bw.record(1, ops[0..s.len]);
}

fn emitMdNode(bw: *bc.Writer, ops: []const MdOperand) !void {
    // METADATA_NODE (code 3) with old-style encoding:
    // First operand: number of elements
    // Then each element: null=0, value=(id+1)<<1, metadata=(id<<1)|1
    var buf: [32]u32 = undefined;
    buf[0] = @as(u32, @intCast(ops.len));
    for (ops, 0..) |op, i| {
        buf[i + 1] = switch (op.tag) {
            .null => 0,
            .value => (op.val + 1) << 1,
            .metadata => (op.val << 1) | 1,
        };
    }
    try bw.record(3, buf[0 .. ops.len + 1]);
}

fn emitMdNamed(bw: *bc.Writer, name: []const u8, md_id: u32) !void {
    // METADATA_NAME (code 4): name chars
    var nops: [128]u32 = undefined;
    for (name, 0..) |c, i| nops[i] = c;
    try bw.record(4, nops[0..name.len]);
    // METADATA_NAMED_NODE (code 5): metadata ID
    try bw.record(5, &.{md_id});
}
