const std = @import("std");
const gpu_ir = @import("../../src/compiler/gpu/gpu_ir.zig");
const gpu_body_parser = @import("../../src/compiler/gpu/frontend/gpu_body_parser.zig");
const gpu_hlsl = @import("../../src/compiler/gpu/gpu_hlsl.zig");
const gpu_dxil = @import("../../src/compiler/gpu/gpu_dxil.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resources = [_]gpu_ir.IrResourceDecl{
        .{ .name = "buf", .type_ref = .rw_texture2d, .binding_prefix = 'u', .binding_reg = 0, .format = .f32 },
    };

    const body_lines = [_][]const u8{
        "buf[uint2(x, y)] = float(x * 2);",
    };

    const func_types = std.StringHashMap(gpu_ir.TypeRef).init(alloc);
    var func = try gpu_body_parser.parseBody(alloc, &body_lines, &resources, &.{}, func_types);
    func.name = "main";
    func.x_param = "x";
    func.y_param = "y";
    func.numthreads = .{ .x = 8, .y = 8, .z = 1 };

    var ir = gpu_ir.IrModule{
        .allocator = alloc,
        .resources = std.ArrayList(gpu_ir.IrResourceDecl).init(alloc),
        .cbuffer_members = std.ArrayList(gpu_ir.IrCbufferMember).init(alloc),
        .functions = std.ArrayList(gpu_ir.IrFunction).init(alloc),
    };

    for (&resources) |*r| try ir.resources.append(r.*);
    try ir.functions.append(func);

    // Native DXIL compilation (no DXC)
    var result = try gpu_dxil.backend.compile(alloc, &ir, .{});
    defer result.deinit();
    std.debug.print("=== DXIL === {} bytes\n", .{result.bytecode.len});

    const magic = std.mem.readInt(u32, result.bytecode[0..4], .little);
    std.debug.print("Magic: 0x{x} ('{c}{c}{c}{c}')\n", .{
        magic, result.bytecode[0], result.bytecode[1],
        result.bytecode[2], result.bytecode[3],
    });

    // Validate with DXC dumpbin
    try std.fs.cwd().writeFile(.{ .sub_path = "test_native.dxil", .data = result.bytecode });
    std.debug.print("Wrote test_native.dxil ({d} bytes)\n", .{result.bytecode.len});
}
