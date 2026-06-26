const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_ast = @import("gpu_ast.zig");
const gpu_ir = @import("gpu_ir.zig");
const gpu_body_parser = @import("gpu_body_parser.zig");

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
            var globals_copy = std.ArrayList([]const u8).init(allocator);
            for (kernel.globals_lines.items) |line| {
                try globals_copy.append(try allocator.dupe(u8, line));
            }

            var filtered_body = std.ArrayList([]const u8).init(allocator);
            defer filtered_body.deinit();
            for (entry.body_lines.items) |line| {
                const trimmed = std.mem.trim(u8, line, " \t");
                if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "numthreads")) {
                    try filtered_body.append(trimmed);
                }
            }

            const body_func = try gpu_body_parser.parseBody(
                allocator,
                filtered_body.items,
                ir.resources.items,
                ir.cbuffer_members.items,
            );
            try ir.functions.append(.{
                .name = try allocator.dupe(u8, entry.name),
                .blocks = body_func.blocks,
                .next_block_id = body_func.next_block_id,
                .numthreads = .{ .x = entry.numthreads.x, .y = entry.numthreads.y, .z = entry.numthreads.z },
                .x_param = try allocator.dupe(u8, entry.x_param),
                .y_param = try allocator.dupe(u8, entry.y_param),
                .passthrough_body = std.ArrayList([]const u8).init(allocator),
                .globals_lines = globals_copy,
                .locals = body_func.locals,
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
