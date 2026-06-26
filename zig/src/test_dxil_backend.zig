const std = @import("std");
const gpu_ir = @import("gpu_ir.zig");
const gpu_body_parser = @import("gpu_body_parser.zig");
const gpu_hlsl = @import("gpu_hlsl.zig");
const dxil_backend = @import("dxil_backend.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Simple shader: RWBuffer<float> → write tid.x * 2
    const resources = [_]gpu_ir.IrResourceDecl{
        .{ .name = "buf", .type_ref = .rw_texture2d, .binding_prefix = 'u', .binding_reg = 0, .format = .f32 },
    };

    const body_lines = [_][]const u8{
        "buf[uint2(x, y)] = float(x * 2);",
    };

    const func = try gpu_body_parser.parseBody(alloc, &body_lines, &resources, &.{});

    var ir = gpu_ir.IrModule{
        .allocator = alloc,
        .resources = std.ArrayList(gpu_ir.IrResourceDecl).init(alloc),
        .cbuffer_members = std.ArrayList(gpu_ir.IrCbufferMember).init(alloc),
        .functions = std.ArrayList(gpu_ir.IrFunction).init(alloc),
    };

    for (&resources) |*r| try ir.resources.append(r.*);
    var fixed_func = func;
    fixed_func.name = "main";
    fixed_func.x_param = "x";
    fixed_func.y_param = "y";
    try ir.functions.append(fixed_func);

    // Test 1: HLSL generation
    const hlsl = try gpu_hlsl.generateHlslFromIr(alloc, &ir);
    std.debug.print("=== HLSL ===\n{s}\n", .{hlsl});

    // Test 2: DXIL compilation via backend
    var result = try dxil_backend.backend.compile(alloc, &ir, .{});
    defer result.deinit();
    std.debug.print("=== DXIL === {} bytes\n", .{result.bytecode.len});

    // Verify DXBC magic
    if (result.bytecode.len >= 4) {
        const magic = std.mem.readInt(u32, result.bytecode[0..4], .little);
        std.debug.print("Magic: 0x{x} ('{c}{c}{c}{c}')\n", .{
            magic, result.bytecode[0], result.bytecode[1],
            result.bytecode[2], result.bytecode[3],
        });
    }
}
