const std = @import("std");
const gpu_ir = @import("../../src/compiler/gpu/gpu_ir.zig");
const gpu_body_parser = @import("../../src/compiler/gpu/frontend/gpu_body_parser.zig");
const gpu_hlsl = @import("../../src/compiler/gpu/gpu_hlsl.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body_lines = [_][]const u8{
        "float2 uv = float2(x, y) * params.xy;",
        "float4 color = Input.SampleLevel(LinearSampler, uv, 0.0);",
        "float4 prev = LoadPrev(uv);",
        "float4 result = lerp(color, prev, 0.5);",
        "result = saturate(result);",
        "Output[uint2(x, y)] = (float4)(result);",
        "float4 blended = result * 0.5 + prev * 0.5;",
        "float a = saturate(uv.x);",
        "float b = (float)(a);",
        "float4 c = a > 0.5 ? result : prev;",
    };

    const resources = [_]gpu_ir.IrResourceDecl{
        .{ .name = "Input", .type_ref = .texture2d, .binding_prefix = 't', .binding_reg = 0, .format = .f32 },
        .{ .name = "Output", .type_ref = .rw_texture2d, .binding_prefix = 'u', .binding_reg = 1, .format = .vec4f },
        .{ .name = "LinearSampler", .type_ref = .sampler, .binding_prefix = 's', .binding_reg = 0, .format = .f32 },
    };

    const cbuffer = [_]gpu_ir.IrCbufferMember{
        .{ .name = "params", .type_ref = .vec4f, .slot = 0 },
    };

    const func = try gpu_body_parser.parseBody(alloc, &body_lines, &resources, &cbuffer);

    var ir = gpu_ir.IrModule{
        .allocator = alloc,
        .resources = std.ArrayList(gpu_ir.IrResourceDecl).init(alloc),
        .cbuffer_members = std.ArrayList(gpu_ir.IrCbufferMember).init(alloc),
        .functions = std.ArrayList(gpu_ir.IrFunction).init(alloc),
    };

    for (&resources) |*r| try ir.resources.append(r.*);
    for (&cbuffer) |*c| try ir.cbuffer_members.append(c.*);
    try ir.functions.append(func);

    const hlsl = try gpu_hlsl.generateHlslFromIr(alloc, &ir);
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(hlsl);
}
