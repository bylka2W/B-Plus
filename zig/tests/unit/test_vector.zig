const std = @import("std");
const gpu_ir = @import("../../src/compiler/gpu/gpu_ir.zig");
const gpu_body_parser = @import("../../src/compiler/gpu/frontend/gpu_body_parser.zig");
const gpu_hlsl = @import("../../src/compiler/gpu/gpu_hlsl.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stdout = std.io.getStdOut().writer();

    // Test 1: int2 * int, swizzle, >=, ||
    {
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
        const result = try gpu_body_parser.parseBody(alloc, &body, &resources, &cbuffer);
        try stdout.print("Test 1 (FSR2 reconstruct_depth): parsed {d} blocks, {d} instrs - PASS\n", .{
            result.blocks.items.len,
            blk: {
                var count: usize = 0;
                for (result.blocks.items) |b| count += b.instrs.items.len;
                break :blk count;
            },
        });
    }

    // Test 2: Simple swizzle
    {
        const body = [_][]const u8{
            "int2 a = int2(1, 2);",
            "int x = a.x;",
            "int y = a.y;",
        };
        const resources = [_]gpu_ir.IrResourceDecl{};
        const cbuffer = [_]gpu_ir.IrCbufferMember{};
        const result = try gpu_body_parser.parseBody(alloc, &body, &resources, &cbuffer);
        try stdout.print("Test 2 (int2 swizzle): parsed {d} blocks, {d} instrs - PASS\n", .{
            result.blocks.items.len,
            blk: {
                var count: usize = 0;
                for (result.blocks.items) |b| count += b.instrs.items.len;
                break :blk count;
            },
        });
    }

    // Test 3: Vector * scalar
    {
        const body = [_][]const u8{
            "int2 a = int2(1, 2);",
            "int2 b = a * 2;",
            "int2 c = 3 * a;",
        };
        const resources = [_]gpu_ir.IrResourceDecl{};
        const cbuffer = [_]gpu_ir.IrCbufferMember{};
        const result = try gpu_body_parser.parseBody(alloc, &body, &resources, &cbuffer);
        try stdout.print("Test 3 (int2 * int): parsed {d} blocks, {d} instrs - PASS\n", .{
            result.blocks.items.len,
            blk: {
                var count: usize = 0;
                for (result.blocks.items) |b| count += b.instrs.items.len;
                break :blk count;
            },
        });
    }

    // Test 4: float2 ops
    {
        const body = [_][]const u8{
            "float2 uv = float2(x, y) * float2(0.5, 0.5);",
            "float u = uv.x;",
            "float v = uv.y;",
        };
        const resources = [_]gpu_ir.IrResourceDecl{};
        const cbuffer = [_]gpu_ir.IrCbufferMember{};
        const result = try gpu_body_parser.parseBody(alloc, &body, &resources, &cbuffer);
        try stdout.print("Test 4 (float2 ops): parsed {d} blocks, {d} instrs - PASS\n", .{
            result.blocks.items.len,
            blk: {
                var count: usize = 0;
                for (result.blocks.items) |b| count += b.instrs.items.len;
                break :blk count;
            },
        });
    }

    // Test 5: >= and || 
    {
        const body = [_][]const u8{
            "int a = 5;",
            "int b = 3;",
            "if (a >= b || a == 0) return;",
        };
        const resources = [_]gpu_ir.IrResourceDecl{};
        const cbuffer = [_]gpu_ir.IrCbufferMember{};
        const result = try gpu_body_parser.parseBody(alloc, &body, &resources, &cbuffer);
        try stdout.print("Test 5 (>= and ||): parsed {d} blocks, {d} instrs - PASS\n", .{
            result.blocks.items.len,
            blk: {
                var count: usize = 0;
                for (result.blocks.items) |b| count += b.instrs.items.len;
                break :blk count;
            },
        });
    }

    try stdout.print("All tests passed!\n", .{});
}
