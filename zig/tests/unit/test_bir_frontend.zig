const std = @import("std");
const gpu_ast = @import("../../src/compiler/parser/gpu_ast.zig");
const bir = @import("../../src/compiler/backend/bir/bir.zig");
const bir_frontend = @import("../../src/compiler/backend/bir/bir_frontend.zig");
const bir_passes = @import("../../src/compiler/backend/bir/bir_passes.zig");
const bir_unroll = @import("../../src/compiler/backend/bir/bir_unroll.zig");
const bir_cfg = @import("../../src/compiler/backend/bir/bir_cfg.zig");
const bir_dominators = @import("../../src/compiler/backend/bir/bir_dominators.zig");
const bir_hlsl = @import("../../src/compiler/backend/bir/bir_hlsl.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stdout = std.io.getStdOut().writer();

    try testSimple(alloc, stdout);
    try testIfElse(alloc, stdout);
    try testForLoop(alloc, stdout);
    try testTextureOps(alloc, stdout);
    try testPipeline(alloc, stdout);
    try testUnroll(alloc, stdout);
    try testUnrollWithStore(alloc, stdout);
    try testRetNotBr(alloc, stdout);
}

fn testSimple(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testSimple ---\n");

    var mod = try buildTestModule(alloc, &.{
        "float x = 2.0;",
        "float y = x + 1.0;",
        "float z = y * 0.5;",
    }, &.{});

    defer mod.deinit();

    var bir_mod = try bir_frontend.lowerToBir(alloc, &mod);
    defer bir_mod.deinit();

    const func = bir_mod.getFunction(0);
    try stdout.print("  blocks: {d}, values: {d}\n", .{ func.blocks.items.len, func.locals_count });

    const hlsl = try bir_hlsl.generateHlsl(alloc, &bir_mod);
    try stdout.print("  HLSL:\n{s}\n", .{hlsl});

    try stdout.print("  OK\n", .{});
}

fn testIfElse(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testIfElse ---\n");

    var mod = try buildTestModule(alloc, &.{
        "float x = 1.0;",
        "if (x > 0.0) {",
        "    x = x + 1.0;",
        "} else {",
        "    x = x - 1.0;",
        "}",
        "float y = x * 2.0;",
    }, &.{});

    defer mod.deinit();

    var bir_mod = try bir_frontend.lowerToBir(alloc, &mod);
    defer bir_mod.deinit();

    const func = bir_mod.getFunction(0);
    try stdout.print("  blocks: {d}, values: {d}\n", .{ func.blocks.items.len, func.locals_count });

    for (func.blocks.items, 0..) |block, i| {
        try stdout.print("  block {d} '{s}': {d} instrs\n", .{ i, block.label, block.instrs.items.len });
    }

    try stdout.print("  OK\n", .{});
}

fn testForLoop(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testForLoop ---\n");

    var mod = try buildTestModule(alloc, &.{
        "float acc = 0.0;",
        "for (int i = 0; i < 10; i = i + 1) {",
        "    acc = acc + 1.0;",
        "}",
    }, &.{});

    defer mod.deinit();

    var bir_mod = try bir_frontend.lowerToBir(alloc, &mod);
    defer bir_mod.deinit();

    const func = bir_mod.getFunction(0);
    try stdout.print("  blocks: {d}, values: {d}\n", .{ func.blocks.items.len, func.locals_count });

    try stdout.print("  OK\n", .{});
}

fn testTextureOps(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testTextureOps ---\n");

    var mod = try buildTestModule(alloc, &.{
        "uint w, h;",
        "g_Tex.GetDimensions(w, h);",
        "float2 uv = float2(x, y);",
        "float4 color = g_Tex.SampleLevel(g_Sampler, uv, 0.0);",
        "g_Out[uint2(x, y)] = color;",
    }, &.{
        .{ .name = "g_Tex", .type_ref = .texture2d, .binding_prefix = 't', .binding_reg = 0, .format = .f32, .width = .four },
        .{ .name = "g_Sampler", .type_ref = .sampler_state, .binding_prefix = 's', .binding_reg = 1, .format = .f32, .width = .one },
        .{ .name = "g_Out", .type_ref = .rw_texture2d, .binding_prefix = 'u', .binding_reg = 2, .format = .f32, .width = .four },
    });

    defer mod.deinit();

    var bir_mod = try bir_frontend.lowerToBir(alloc, &mod);
    defer bir_mod.deinit();

    const func = bir_mod.getFunction(0);
    try stdout.print("  blocks: {d}, values: {d}\n", .{ func.blocks.items.len, func.locals_count });

    try stdout.print("  OK\n", .{});
}

fn testPipeline(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testPipeline ---\n");

    var mod = try buildTestModule(alloc, &.{
        "float a = 1.0;",
        "float b = 2.0;",
        "float c = a + b;",
        "float d = a + b;",
        "float e = c * d;",
        "float f = c * d;",
        "float result = e + f;",
    }, &.{});

    defer mod.deinit();

    var bir_mod = try bir_frontend.lowerToBir(alloc, &mod);
    defer bir_mod.deinit();

    var pm = bir.PassManager.init(alloc);
    defer pm.deinit();

    try pm.addPass(bir_passes.ConstantFoldingPass);
    try pm.addPass(bir_passes.GVNPass);
    try pm.addPass(bir_passes.DCEPass);

    try pm.run(&bir_mod);

    const func = bir_mod.getFunction(0);
    try stdout.print("  blocks: {d}, values: {d}\n", .{ func.blocks.items.len, func.locals_count });

    const hlsl = try bir_hlsl.generateHlsl(alloc, &bir_mod);
    try stdout.print("  HLSL:\n{s}\n", .{hlsl});

    try stdout.print("  OK\n", .{});
}

fn testUnroll(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testUnroll ---\n");

    var mod = try buildTestModule(alloc, &.{
        "float acc = 0.0;",
        "for (int i = 0; i < 4; i = i + 1) {",
        "    acc = acc + 1.0;",
        "}",
        "float result = acc;",
    }, &.{});
    defer mod.deinit();

    var bir_mod = try bir_frontend.lowerToBir(alloc, &mod);
    defer bir_mod.deinit();

    const blocks_before = bir_mod.getFunction(0).blocks.items.len;
    try stdout.print("  before: blocks={d}\n", .{blocks_before});
    try stdout.print("  blocks:\n", .{});
    {
        const f = bir_mod.getFunction(0);
        for (f.blocks.items, 0..) |blk, i| {
        try stdout.print("    block {d} '{s}': {d} instrs\n", .{ i, blk.label, blk.instrs.items.len });
        for (blk.instrs.items) |inst| {
            try stdout.print("      [{d}] op={s}", .{ inst.result, @tagName(inst.op) });
            if (inst.op == .phi) {
                try stdout.print(" inc={any}", .{inst.data.phi_incoming});
            }
            if (inst.op == .cond_br) {
                try stdout.print(" then={d} else={d}", .{ inst.data.cond_branch.then_block, inst.data.cond_branch.else_block });
            }
            if (inst.op == .br) {
                try stdout.print(" target={d}", .{inst.data.block_target});
            }
            if (inst.op == .@"const") {
                try stdout.print(" data={any}", .{inst.data.const_data});
            }
            try stdout.print("\n", .{});
        }
    }
    }

    var pm = bir_passes.StandardPasses.init(alloc);
    defer pm.deinit();
    try pm.run(&bir_mod);

    const func = bir_mod.getFunction(0);
    try stdout.print("  after:  blocks={d}, values={d}\n", .{ func.blocks.items.len, func.locals_count });
    try stdout.print("  blocks:\n", .{});
    for (func.blocks.items, 0..) |blk, i| {
        try stdout.print("    block {d} '{s}': {d} instrs\n", .{ i, blk.label, blk.instrs.items.len });
        for (blk.instrs.items) |inst| {
            try stdout.print("      [{d}] op={s}", .{ inst.result, @tagName(inst.op) });
            if (inst.op == .@"const") {
                try stdout.print(" data={any}", .{inst.data.const_data});
            }
            if (inst.op == .br) {
                try stdout.print(" target={d}", .{inst.data.block_target});
            }
            if (inst.op == .cond_br) {
                try stdout.print(" then={d} else={d}", .{ inst.data.cond_branch.then_block, inst.data.cond_branch.else_block });
            }
            if (inst.op == .phi) {
                try stdout.print(" inc={any}", .{inst.data.phi_incoming});
            }
            try stdout.print(" ops=[", .{});
            for (inst.operands, 0..) |op, oi| {
                if (oi > 0) try stdout.print(",", .{});
                try stdout.print("{d}", .{op});
            }
            try stdout.print("]\n", .{});
        }
    }

    if (func.blocks.items.len <= blocks_before) {
        std.debug.print("FAIL: unroll did not increase block count\n", .{});
        return error.TestFailed;
    }

    const hlsl = try bir_hlsl.generateHlsl(alloc, &bir_mod);
    try stdout.print("  HLSL:\n{s}\n", .{hlsl});

    try stdout.print("  OK\n", .{});
}

fn testUnrollWithStore(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testUnrollWithStore ---\n");

    var mod = try buildTestModule(alloc, &.{
        "float acc = 0.0;",
        "for (int i = 0; i < 4; i = i + 1) {",
        "    acc = acc + 1.0;",
        "}",
        "g_Out[uint2(x, y)] = acc;",
    }, &.{
        .{ .name = "g_Out", .type_ref = .rw_texture2d, .binding_prefix = 'u', .binding_reg = 0, .format = .f32, .width = .one },
    });
    defer mod.deinit();

    var bir_mod = try bir_frontend.lowerToBir(alloc, &mod);
    defer bir_mod.deinit();

    const blocks_before = bir_mod.getFunction(0).blocks.items.len;
    try stdout.print("  before: blocks={d}\n", .{blocks_before});
    {
        const f = bir_mod.getFunction(0);
        for (f.blocks.items, 0..) |blk, i| {
            try stdout.print("    block {d} '{s}': {d} instrs\n", .{ i, blk.label, blk.instrs.items.len });
            for (blk.instrs.items) |inst| {
                try stdout.print("      [{d}] op={s}", .{ inst.result, @tagName(inst.op) });
                if (inst.op == .phi) {
                    try stdout.print(" inc={any}", .{inst.data.phi_incoming});
                }
                if (inst.op == .cond_br) {
                    try stdout.print(" then={d} else={d}", .{ inst.data.cond_branch.then_block, inst.data.cond_branch.else_block });
                }
                if (inst.op == .br) {
                    try stdout.print(" target={d}", .{inst.data.block_target});
                }
                try stdout.print(" ops=[", .{});
                for (inst.operands, 0..) |op, oi| {
                    if (oi > 0) try stdout.print(",", .{});
                    try stdout.print("{d}", .{op});
                }
                try stdout.print("]\n", .{});
            }
        }
    }

    var pm = bir_passes.StandardPasses.init(alloc);
    defer pm.deinit();

    const func_before = bir_mod.getFunction(0);
    {
        var cfg_d = try bir_cfg.buildCFG(alloc, func_before);
        defer cfg_d.deinit();
        try stdout.print("  CFG before:\n", .{});
        try bir_cfg.dumpCFG(&cfg_d, stdout);
    }

    try pm.run(&bir_mod);

    const func = bir_mod.getFunction(0);
    try stdout.print("  after:  blocks={d}, values={d}\n", .{ func.blocks.items.len, func.locals_count });
    for (func.blocks.items, 0..) |blk, i| {
        try stdout.print("    block {d} '{s}': {d} instrs\n", .{ i, blk.label, blk.instrs.items.len });
        for (blk.instrs.items) |inst| {
            try stdout.print("      [{d}] op={s} ops=[", .{ inst.result, @tagName(inst.op) });
            for (inst.operands, 0..) |op, oi| {
                if (oi > 0) try stdout.print(",", .{});
                try stdout.print("{d}", .{op});
            }
            try stdout.print("]\n", .{});
        }
    }

    if (func.blocks.items.len <= blocks_before) {
        std.debug.print("FAIL: unroll did not increase block count\n", .{});
        return error.TestFailed;
    }

    {
        var cfg_d = try bir_cfg.buildCFG(alloc, func);
        defer cfg_d.deinit();
        try stdout.print("  CFG after:\n", .{});
        try bir_cfg.dumpCFG(&cfg_d, stdout);
    }

    const hlsl = try bir_hlsl.generateHlsl(alloc, &bir_mod);
    try stdout.print("  HLSL:\n{s}\n", .{hlsl});

    try stdout.print("  OK\n", .{});
}

fn testRetNotBr(alloc: std.mem.Allocator, stdout: anytype) !void {
    try stdout.writeAll("--- testRetNotBr ---\n");

    var mod = try buildTestModule(alloc, &.{
        "return;",
    }, &.{});
    defer mod.deinit();

    var bir_mod = try bir_frontend.lowerToBir(alloc, &mod);
    defer bir_mod.deinit();

    const hlsl = try bir_hlsl.generateHlsl(alloc, &bir_mod);
    try stdout.print("  HLSL:\n{s}\n", .{hlsl});

    if (std.mem.indexOf(u8, hlsl, "return") == null) {
        std.debug.print("FAIL: HLSL has no 'return'\n", .{});
        return error.TestFailed;
    }

    try stdout.print("  OK\n", .{});
}

const TestResource = struct {
    name: []const u8,
    type_ref: gpu_ast.ResourceKind,
    binding_prefix: u8,
    binding_reg: u32,
    format: gpu_ast.ScalarType,
    width: gpu_ast.VectorWidth,
};

fn buildTestModule(alloc: std.mem.Allocator, body: []const []const u8, resources: []const struct { name: []const u8, type_ref: gpu_ast.ResourceKind, binding_prefix: u8, binding_reg: u32, format: gpu_ast.ScalarType, width: gpu_ast.VectorWidth }) !gpu_ast.GpuModule {
    var mod = gpu_ast.GpuModule{
        .allocator = alloc,
        .kernels = std.ArrayList(gpu_ast.GpuKernel).init(alloc),
    };
    errdefer mod.deinit();

    var kernel = gpu_ast.GpuKernel{
        .name = try alloc.dupe(u8, "test_kernel"),
        .resources = std.ArrayList(gpu_ast.ResourceDecl).init(alloc),
        .cbuffer_members = std.ArrayList(gpu_ast.CbufferMember).init(alloc),
        .entries = std.ArrayList(gpu_ast.EntryDecl).init(alloc),
        .globals_lines = std.ArrayList([]const u8).init(alloc),
    };
    errdefer kernel.entries.deinit();

    for (resources) |res| {
        try kernel.resources.append(.{
            .name = try alloc.dupe(u8, res.name),
            .gpu_type = .{
                .kind = .{ .resource_typed = .{
                    .kind = res.type_ref,
                    .format = res.format,
                    .width = res.width,
                } },
            },
            .binding = .{ .reg = res.binding_reg, .space = 0 },
        });
    }

    var body_lines = std.ArrayList([]const u8).init(alloc);
    errdefer body_lines.deinit();
    for (body) |line| {
        try body_lines.append(try alloc.dupe(u8, line));
    }

    try kernel.entries.append(.{
        .name = try alloc.dupe(u8, "main"),
        .x_param = try alloc.dupe(u8, "x"),
        .y_param = try alloc.dupe(u8, "y"),
        .body_lines = body_lines,
        .numthreads = .{ .x = 8, .y = 8, .z = 1 },
    });

    try mod.kernels.append(kernel);
    return mod;
}
