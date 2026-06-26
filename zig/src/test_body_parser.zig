const std = @import("std");
const gpu_ir = @import("gpu_ir.zig");
const gpu_body_parser = @import("gpu_body_parser.zig");

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
        "float d = mad(a, b, c.x);",
        "float e = abs(d);",
        "float f = min(e, 1.0);",
        "return f;",
    };

    const resources = [_]gpu_ir.IrResourceDecl{
        .{ .name = "Input", .type_ref = .texture2d, .binding_prefix = 't', .binding_reg = 0, .format = .f32 },
        .{ .name = "Output", .type_ref = .rw_texture2d, .binding_prefix = 'u', .binding_reg = 1, .format = .vec4f },
        .{ .name = "LinearSampler", .type_ref = .sampler, .binding_prefix = 's', .binding_reg = 0, .format = .f32 },
    };

    const cbuffer = [_]gpu_ir.IrCbufferMember{
        .{ .name = "params", .type_ref = .vec4f, .slot = 0 },
    };

    const result = gpu_body_parser.parseBody(alloc, &body_lines, &resources, &cbuffer);
    if (result) |func| {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("SUCCESS: parsed {d} blocks, {d} instructions\n", .{ func.blocks.items.len, blk: {
            var count: usize = 0;
            for (func.blocks.items) |b| count += b.instrs.items.len;
            break :blk count;
        } });
    } else |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("FAIL: {}\n", .{err});
        std.process.exit(1);
    }
}
