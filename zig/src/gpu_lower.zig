const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_ast = @import("gpu_ast.zig");
const gpu_ir = @import("gpu_ir.zig");

pub fn lowerModule(allocator: Allocator, module: *const gpu_ast.GpuModule) !gpu_ir.IrModule {
    var ir = gpu_ir.IrModule{
        .allocator = allocator,
        .resources = std.ArrayList(gpu_ir.IrResourceDecl).init(allocator),
        .cbuffer_members = std.ArrayList(gpu_ir.IrCbufferMember).init(allocator),
        .functions = std.ArrayList(gpu_ir.IrFunction).init(allocator),
    };

        for (module.kernels.items) |*kernel| {
            for (kernel.resources.items) |res| {
            const ir_res = gpuResourceToIr(&res);
            try ir.resources.append(.{
                .name = res.name,
                .type_ref = ir_res.@"0",
                .binding_prefix = ir_res.@"1",
                .binding_reg = res.binding.reg,
                .format = gpuResourceFormatToIr(&res),
            });
        }

        for (kernel.cbuffer_members.items) |member| {
            try ir.cbuffer_members.append(.{
                .name = member.name,
                .type_ref = gpu_ir.scalarTypeToTypeRefWithWidth(member.scalar_type, member.vector_width),
                .slot = member.slot.reg,
            });
        }

        for (kernel.entries.items) |entry| {
            var body = std.ArrayList([]const u8).init(allocator);
            for (entry.body_lines.items) |line| {
                try body.append(try allocator.dupe(u8, line));
            }

            var globals_copy = std.ArrayList([]const u8).init(allocator);
            for (kernel.globals_lines.items) |line| {
                try globals_copy.append(try allocator.dupe(u8, line));
            }

            var blocks = std.ArrayList(gpu_ir.IrBasicBlock).init(allocator);
            try blocks.append(gpu_ir.IrBasicBlock{
                .label = "entry",
                .instrs = std.ArrayList(gpu_ir.IrInst).init(allocator),
                .next_value_id = 0,
            });

            try ir.functions.append(.{
                .name = try allocator.dupe(u8, entry.name),
                .blocks = blocks,
                .next_block_id = 1,
                .numthreads = .{ .x = entry.numthreads.x, .y = entry.numthreads.y, .z = entry.numthreads.z },
                .x_param = try allocator.dupe(u8, entry.x_param),
                .y_param = try allocator.dupe(u8, entry.y_param),
                .passthrough_body = body,
                .globals_lines = globals_copy,
            });
        }
    }

    return ir;
}

fn gpuResourceToIr(res: *const gpu_ast.ResourceDecl) struct { gpu_ir.TypeRef, u8 } {
    return switch (res.gpu_type.kind) {
        .resource_typed => |rt| switch (rt.kind) {
            .texture2d => .{ .texture2d, 't' },
            .rw_texture2d => .{ .rw_texture2d, 'u' },
            else => .{ .texture2d, 't' },
        },
        .resource => |rk| switch (rk) {
            .sampler_state => .{ .sampler, 's' },
            else => .{ .texture2d, 't' },
        },
        else => .{ .texture2d, 't' },
    };
}

fn gpuResourceFormatToIr(res: *const gpu_ast.ResourceDecl) gpu_ir.TypeRef {
    return switch (res.gpu_type.kind) {
        .resource_typed => |rt| gpu_ir.scalarTypeToTypeRefWithWidth(rt.format, rt.width),
        else => .f32,
    };
}
