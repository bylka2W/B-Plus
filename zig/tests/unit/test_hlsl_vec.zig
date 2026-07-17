const std = @import("std");
const gpu_ir = @import("../../src/compiler/backend/gpu/gpu_ir.zig");
const gpu_body_parser = @import("../../src/compiler/parser/gpu_body_parser.zig");
const gpu_hlsl = @import("../../src/compiler/backend/gpu/gpu_hlsl.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stdout = std.io.getStdOut().writer();

    const body = [_][]const u8{
        "uint w, h;",
        "g_DepthOutput.GetDimensions(w, h);",
        "int2 ipos = int2(x, y);",
        "if (ipos.x >= int(w) || ipos.y >= int(h)) return;",
        "int2 srcPos = ipos * 2;",
        "float d0 = g_DepthInput[int3(srcPos.x, srcPos.y, 0)];",
        "g_DepthOutput[ipos] = (d0) * 0.25;",
    };
    const resources = [_]gpu_ir.IrResourceDecl{
        .{ .name = "g_DepthInput", .type_ref = .texture2d, .binding_prefix = 't', .binding_reg = 0, .format = .f32 },
        .{ .name = "g_DepthOutput", .type_ref = .rw_texture2d, .binding_prefix = 'u', .binding_reg = 1, .format = .vec4f },
    };
    const cbuffer = [_]gpu_ir.IrCbufferMember{};
    const empty_func_types = std.StringHashMap(gpu_ir.TypeRef).init(alloc);
    const result = try gpu_body_parser.parseBody(alloc, &body, &resources, &cbuffer, empty_func_types);

    var mod = gpu_ir.IrModule{
        .allocator = alloc,
        .resources = std.ArrayList(gpu_ir.IrResourceDecl).init(alloc),
        .cbuffer_members = std.ArrayList(gpu_ir.IrCbufferMember).init(alloc),
        .functions = std.ArrayList(gpu_ir.IrFunction).init(alloc),
    };
    try mod.functions.append(result);

    const hlsl = try gpu_hlsl.generateHlslFromIr(alloc, &mod);
    try stdout.print("--- HLSL output ---\n{s}\n", .{hlsl});
}
