const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../bir.zig");
const types = @import("../bir_types.zig");
const pipeline_gen = @import("../../../backend/mir/pipeline_gen.zig");

const Pipeline = pipeline_gen.Pipeline;
const Resource = pipeline_gen.Resource;
const ResourceType = pipeline_gen.ResourceType;

const AddressSpace = types.AddressSpace;

pub const LowerOptions = struct {
    target_shader_model: []const u8 = "cs_6_6",
};

pub fn lowerPipeline(allocator: Allocator, pipeline: *const Pipeline) !bir.Module {
    var module = bir.Module.init(allocator);

    try setupTypes(&module);

    try lowerResources(&module, pipeline.resources);
    try lowerPipelineFunc(&module, pipeline);

    return module;
}

fn setupTypes(module: *bir.Module) !void {
    _ = try module.types.voidType();
    _ = try module.types.scalarType(.i32);
    _ = try module.types.scalarType(.u32);
    _ = try module.types.scalarType(.f32);
    _ = try module.types.scalarType(.f16);
    _ = try module.types.scalarType(.i1);
    _ = try module.types.vectorType(.f32, 2);
    _ = try module.types.vectorType(.f32, 4);
    _ = try module.types.vectorType(.u32, 2);
    _ = try module.types.vectorType(.u32, 4);
    _ = try module.types.textureType(.tex2d);
    _ = try module.types.textureType(.rw_tex2d);
    _ = try module.types.samplerType();
}

fn lowerResources(module: *bir.Module, resources: []const Resource) !void {
    for (resources) |res| {
        const res_name = try module.allocator.dupe(u8, res.name);
        const tex_type: types.Type.TextureKind = switch (res.resource_type) {
            .input => .tex2d,
            .output => .rw_tex2d,
            .transient => .rw_tex2d,
            .persistent => .rw_tex2d,
        };
        const type_id = try module.types.textureType(tex_type);

        try module.resources.append(.{
            .name = res_name,
            .ty = type_id,
            .binding = @as(u32, @intCast(module.resources.items.len)),
            .space = 0,
        });

        if (res.resource_type == .persistent) {
            const mem_name = try module.allocator.dupe(u8, res.name);
            try module.memory_regions.append(.{
                .name = mem_name,
                .ty = type_id,
                .space = .global,
                .size_val = 0,
                .alignment = 16,
            });
        }
    }
}

fn lowerPipelineFunc(module: *bir.Module, pipeline: *const Pipeline) !void {
    const void_ty = 0;
    const u32_ty = 2;
    const f32x4_ty = 7;

    const f_id = try module.addFunction("ExecutePlan", void_ty, .entry);
    const fn0 = module.getFunctionMut(f_id);
    if (pipeline.passes.len > 0) {
        fn0.numthreads = .{
            .x = pipeline.passes[0].group_x,
            .y = pipeline.passes[0].group_y,
            .z = pipeline.passes[0].group_z,
        };
    }
    const entry_block = try module.addBlock(f_id, "entry");
    const final_block = try module.addBlock(f_id, "final");

    var pass_block_ids = try std.ArrayList(bir.BlockId).initCapacity(module.allocator, pipeline.passes.len);
    for (pipeline.passes) |pass| {
        const block_name = try std.fmt.allocPrint(module.allocator, "{s}", .{pass.name});
        const bid = try module.addBlock(f_id, block_name);
        pass_block_ids.appendAssumeCapacity(bid);
    }

    var res_map = std.StringHashMap(u32).init(module.allocator);
    for (module.resources.items, 0..) |_, i| {
        try res_map.put(module.resources.items[i].name, @as(u32, @intCast(i)));
    }

    const tid_x = try module.addInst(f_id, entry_block, .{
        .op = .thread_id, .ty = u32_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .group_info = .{ .dim = 0 } },
    });
    const tid_y = try module.addInst(f_id, entry_block, .{
        .op = .thread_id, .ty = u32_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .{ .group_info = .{ .dim = 1 } },
    });

    if (pipeline.passes.len > 0) {
        const fn_e = module.getFunctionMut(f_id);
        try fn_e.blocks.items[entry_block].instrs.append(.{
            .op = .br, .ty = void_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = pass_block_ids.items[0] },
        });
    }

    for (pipeline.passes, 0..) |pass, pi| {
        const pass_block = pass_block_ids.items[pi];

        var loaded = std.ArrayList(bir.ValueId).init(module.allocator);
        defer loaded.deinit();

        for (pass.reads) |read_name| {
            const res_idx = res_map.get(read_name) orelse continue;
            const res = &module.resources.items[res_idx];
            const rv = try module.addInst(f_id, pass_block, .{
                .op = .resource, .ty = res.ty, .result = bir.NO_VALUE,
                .operands = &.{}, .data = .{ .string = try module.allocator.dupe(u8, read_name) },
            });
            const lv = try module.addInst(f_id, pass_block, .{
                .op = .texture_load, .ty = f32x4_ty, .result = bir.NO_VALUE,
                .operands = try module.allocator.dupe(bir.ValueId, &.{ rv, tid_x, tid_y }), .data = .none,
            });
            try loaded.append(lv);
        }

        const store_val = if (loaded.items.len > 0) loaded.items[0] else @as(bir.ValueId, 0);
        for (pass.writes) |write_name| {
            const res_idx = res_map.get(write_name) orelse continue;
            const res = &module.resources.items[res_idx];
            const rv = try module.addInst(f_id, pass_block, .{
                .op = .resource, .ty = res.ty, .result = bir.NO_VALUE,
                .operands = &.{}, .data = .{ .string = try module.allocator.dupe(u8, write_name) },
            });
            const fn_p = module.getFunctionMut(f_id);
            try fn_p.blocks.items[pass_block].instrs.append(.{
                .op = .texture_store, .ty = void_ty, .result = bir.NO_VALUE,
                .operands = &.{}, .data = .{ .texture_store_info = .{
                    .tex = rv, .coord_x = tid_x, .coord_y = tid_y, .val = store_val,
                }},
            });
        }

        const next_block = if (pi == pipeline.passes.len - 1) final_block else pass_block_ids.items[pi + 1];
        const fn_p = module.getFunctionMut(f_id);
        try fn_p.blocks.items[pass_block].instrs.append(.{
            .op = .br, .ty = void_ty, .result = bir.NO_VALUE,
            .operands = &.{}, .data = .{ .block_target = next_block },
        });
    }

    const fn_f = module.getFunctionMut(f_id);
    try fn_f.blocks.items[final_block].instrs.append(.{
        .op = .ret, .ty = void_ty, .result = bir.NO_VALUE,
        .operands = &.{}, .data = .none,
    });
}

pub fn dumpModule(module: *const bir.Module, writer: anytype) !void {
    try writer.writeAll("; BIR Module\n\n");

    try writer.writeAll("; Resources:\n");
    for (module.resources.items) |res| {
        try writer.print("  @resource.{s} : ", .{res.name});
        try writer.print("binding={d}\n", .{res.binding});
    }

    try writer.writeAll("\n; Memory Regions:\n");
    for (module.memory_regions.items) |mr| {
        try writer.print("  @mem.{s} : space={s}\n", .{ mr.name, @tagName(mr.space) });
    }

    try writer.writeAll("\n; Functions:\n");
    for (module.functions.items) |func| {
        try writer.writeAll("define @");
        try writer.writeAll(func.name);
        try writer.writeAll("()\n");
        for (func.blocks.items) |block| {
            try writer.writeAll("  ");
            try writer.writeAll(block.label);
            try writer.writeAll(":");
            try writer.print(" ; {d} instrs\n", .{block.instrs.items.len});
            for (block.instrs.items) |inst| {
                if (inst.result != bir.NO_VALUE) {
                    const vi = &func.value_info.items[inst.result - 1];
                    try writer.print("    %{d} = {s}", .{ inst.result, @tagName(inst.op) });
                    if (vi.uses.items.len > 0) {
                        try writer.print("  ; uses: ", .{});
                        for (vi.uses.items, 0..) |user_val, ui| {
                            if (ui > 0) try writer.writeAll(", ");
                            try writer.print("%{d}", .{user_val});
                        }
                        try writer.writeAll("\n");
                    } else {
                        try writer.writeAll("  ; (unused)\n");
                    }
                } else {
                    try writer.print("    {s}", .{@tagName(inst.op)});
                }

                switch (inst.data) {
                    .block_target => |bt| try writer.print(" -> block_{d}", .{bt}),
                    .string => |s| try writer.print(" \"{s}\"", .{s}),
                    .group_info => |gi| try writer.print(" dim={d}", .{gi.dim}),
                    .phi_incoming => |incoming| {
                        try writer.writeAll(" [");
                        for (incoming, 0..) |inc, pi| {
                            if (pi > 0) try writer.writeAll(", ");
                            try writer.print("%{d} from block_{d}", .{ inc.value, inc.block });
                        }
                        try writer.writeAll("]");
                    },
                    .const_data => |cd| {
                        switch (cd) {
                            .int => |v| try writer.print(" {d}", .{v}),
                            .float => |v| try writer.print(" {d}", .{v}),
                            else => {},
                        }
                    },
                    else => {},
                }
                try writer.writeAll("\n");
            }
        }
        try writer.writeAll("\n");
    }
}
