const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_ast = @import("gpu_ast.zig");
const gpu_ir = @import("gpu_ir.zig");

/// Generate HLSL directly from GPU AST (legacy path)
pub fn generateHlsl(allocator: Allocator, module: *const gpu_ast.GpuModule) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    for (module.kernels.items) |kernel| {
        for (kernel.resources.items) |res| {
            try emitResourceDecl(w, &res);
        }
        try w.writeAll("\n");

        if (kernel.cbuffer_members.items.len > 0) {
            try emitCbufferDecl(w, kernel.cbuffer_members.items);
            try w.writeAll("\n");
        }

        for (kernel.entries.items) |entry| {
            try w.print("[numthreads({}, {}, {})]\n", .{ entry.numthreads.x, entry.numthreads.y, entry.numthreads.z });
            try w.print("void {s}(uint3 __tid : SV_DispatchThreadID)", .{entry.name});
            try w.writeAll("{\n");
            try w.print("    uint {s} = __tid.x;\n", .{entry.x_param});
            try w.print("    uint {s} = __tid.y;\n", .{entry.y_param});
            for (entry.body_lines.items) |line| {
                try w.print("    {s}\n", .{ line });
            }
            try w.writeAll("}\n");
        }
    }

    return buf.toOwnedSlice();
}

/// Generate HLSL from GPU IR (Phase 4 pipeline)
pub fn generateHlslFromIr(allocator: Allocator, ir: *const gpu_ir.IrModule) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    for (ir.resources.items) |res| {
        try emitIrResourceDecl(w, &res);
    }
    try w.writeAll("\n");

    if (ir.cbuffer_members.items.len > 0) {
        try emitIrCbuffer(w, ir.cbuffer_members.items);
        try w.writeAll("\n");
    }

    var declared_names = std.StringHashMap(void).init(allocator);
    defer {
        var rit = declared_names.keyIterator();
        while (rit.next()) |k| allocator.free(k.*);
        declared_names.deinit();
    }
    for (ir.resources.items) |res| {
        const name = try allocator.dupe(u8, res.name);
        try declared_names.put(name, {});
    }
    for (ir.cbuffer_members.items) |mem| {
        if (!declared_names.contains(mem.name)) {
            const name = try allocator.dupe(u8, mem.name);
            try declared_names.put(name, {});
        }
    }

    for (ir.functions.items) |func| {
        for (func.globals_lines.items) |line| {
            try w.print("{s}\n", .{line});
        }

        try w.print("[numthreads({}, {}, {})]\n", .{ func.numthreads.x, func.numthreads.y, func.numthreads.z });
        try w.print("void {s}(uint3 __tid : SV_DispatchThreadID)", .{func.name});
        try w.writeAll("{\n");
        try w.print("    uint {s} = __tid.x;\n", .{func.x_param});
        try w.print("    uint {s} = __tid.y;\n", .{func.y_param});

        for (func.locals.items) |local| {
            const lt = typeRefToHlslType(local.type_ref);
            try w.print("    {s} {s};\n", .{ lt, local.name });
            const name = try allocator.dupe(u8, local.name);
            try declared_names.put(name, {});
        }

        if (func.passthrough_body.items.len > 0) {
            for (func.passthrough_body.items) |line| {
                try w.print("    {s}\n", .{ line });
            }
        } else {
            try emitIrFunctionBody(w, allocator, &func, &declared_names);
        }

        try w.writeAll("}\n");
    }

    return buf.toOwnedSlice();
}

fn emitIrFunctionBody(w: anytype, allocator: Allocator, func: *const gpu_ir.IrFunction, resource_names: *const std.StringHashMap(void)) !void {
    var var_names = std.AutoHashMap(gpu_ir.ValueId, []const u8).init(allocator);
    defer var_names.deinit();

    var next_temp: u32 = 0;

    for (func.blocks.items) |*block| {
        for (block.instrs.items) |*inst| {
            var name_buf: [16]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "_t{d}", .{next_temp});
            const name_owned = try allocator.dupe(u8, name);
            next_temp += 1;
            try var_names.put(inst.result, name_owned);

            var emit_semicolon = true;
            const t = typeRefToHlslType(inst.ty);
            switch (inst.op) {
                .ret => {
                    if (inst.data == .block_target) {
                        emit_semicolon = false;
                    } else if (inst.operands.len > 0) {
                        try w.print("    return {s}", .{var_names.get(inst.operands[0]).?});
                    } else {
                        try w.writeAll("    return");
                    }
                },
                .select => {
                    try w.print("    {s} {s} = {s} ? {s} : {s}", .{
                        t, name_owned,
                        var_names.get(inst.operands[0]).?,
                        var_names.get(inst.operands[1]).?,
                        var_names.get(inst.operands[2]).?,
                    });
                },
                .cast => {
                    const to_type = typeRefToHlslType(inst.ty);
                    try w.print("    {s} {s} = ({s}){s}", .{
                        t, name_owned,
                        to_type,
                        var_names.get(inst.operands[0]).?,
                    });
                },
                .@"const" => {
                    try w.print("    {s} {s}", .{ t, name_owned });
                    switch (inst.ty) {
                        .f32, .vec2f, .vec3f, .vec4f, .f16 => {
                            try w.print(" = {d}", .{inst.data.float_val});
                        },
                        else => {
                            try w.print(" = {d}", .{inst.data.int_val});
                        },
                    }
                },
                .load => {
                    if (resource_names.contains(inst.data.string)) {
                        try var_names.put(inst.result, try allocator.dupe(u8, inst.data.string));
                        emit_semicolon = false;
                    } else {
                        try w.print("    {s} {s} = {s}", .{ t, name_owned, inst.data.string });
                    }
                },
                .store => {
                    const base = if (inst.data == .string and inst.data.string.len > 0)
                        inst.data.string
                    else
                        var_names.get(inst.operands[0]).?;
                    try w.print("    {s}[", .{base});
                    for (inst.operands[1..inst.operands.len - 1], 0..) |idx_op, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(var_names.get(idx_op).?);
                    }
                    try w.writeAll("] = ");
                    try w.writeAll(var_names.get(inst.operands[inst.operands.len - 1]).?);
                },
                .add => try w.print("    {s} {s} = {s} + {s}", .{ t, name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
                .sub => try w.print("    {s} {s} = {s} - {s}", .{ t, name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
                .mul => try w.print("    {s} {s} = {s} * {s}", .{ t, name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
                .div => try w.print("    {s} {s} = {s} / {s}", .{ t, name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
                .call => {
                    if (inst.ty == .void) {
                        // Void call: just method(args) without assignment
                        if (isIntrinsicMethod(inst.data.call_info.callee) and inst.data.call_info.args.len >= 1) {
                            try w.print("    {s}.{s}(", .{
                                var_names.get(inst.data.call_info.args[0]).?,
                                inst.data.call_info.callee,
                            });
                            for (inst.data.call_info.args[1..], 0..) |arg, i| {
                                if (i > 0) try w.writeAll(", ");
                                try w.writeAll(var_names.get(arg).?);
                            }
                        } else {
                            try w.print("    {s}(", .{inst.data.call_info.callee});
                            for (inst.data.call_info.args, 0..) |arg, i| {
                                if (i > 0) try w.writeAll(", ");
                                try w.writeAll(var_names.get(arg).?);
                            }
                        }
                        try w.writeAll(")");
                    } else {
                        if (isIntrinsicMethod(inst.data.call_info.callee) and inst.data.call_info.args.len >= 1) {
                            try w.print("    {s} {s} = {s}.{s}(", .{
                                t, name_owned,
                                var_names.get(inst.data.call_info.args[0]).?,
                                inst.data.call_info.callee,
                            });
                            for (inst.data.call_info.args[1..], 0..) |arg, i| {
                                if (i > 0) try w.writeAll(", ");
                                try w.writeAll(var_names.get(arg).?);
                            }
                        } else {
                            try w.print("    {s} {s} = {s}(", .{ t, name_owned, inst.data.call_info.callee });
                            for (inst.data.call_info.args, 0..) |arg, i| {
                                if (i > 0) try w.writeAll(", ");
                                try w.writeAll(var_names.get(arg).?);
                            }
                        }
                        try w.writeAll(")");
                    }
                },
                .extract => {
                    const idx = inst.data.extract_info.index;
                    const swz = "xyzw"[idx];
                    try w.print("    {s} {s} = {s}.{c}", .{ t, name_owned, var_names.get(inst.operands[0]).?, swz });
                },
                .composite => {
                    try w.print("    {s} {s} = {s}(", .{ t, name_owned, t });
                    for (inst.operands, 0..) |op, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(var_names.get(op).?);
                    }
                    try w.writeAll(")");
                },
                .max => try w.print("    {s} {s} = max({s}, {s})", .{ t, name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
                .min => try w.print("    {s} {s} = min({s}, {s})", .{ t, name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
                .abs => try w.print("    {s} {s} = abs({s})", .{ t, name_owned, var_names.get(inst.operands[0]).? }),
                .floor => try w.print("    {s} {s} = floor({s})", .{ t, name_owned, var_names.get(inst.operands[0]).? }),
                .ceil => try w.print("    {s} {s} = ceil({s})", .{ t, name_owned, var_names.get(inst.operands[0]).? }),
                .frac => try w.print("    {s} {s} = frac({s})", .{ t, name_owned, var_names.get(inst.operands[0]).? }),
                .sin => try w.print("    {s} {s} = sin({s})", .{ t, name_owned, var_names.get(inst.operands[0]).? }),
                .cos => try w.print("    {s} {s} = cos({s})", .{ t, name_owned, var_names.get(inst.operands[0]).? }),
                .exp => try w.print("    {s} {s} = exp({s})", .{ t, name_owned, var_names.get(inst.operands[0]).? }),
                .sqrt => try w.print("    {s} {s} = sqrt({s})", .{ t, name_owned, var_names.get(inst.operands[0]).? }),
                .rsqrt => try w.print("    {s} {s} = rsqrt({s})", .{ t, name_owned, var_names.get(inst.operands[0]).? }),
                .saturate => try w.print("    {s} {s} = saturate({s})", .{ t, name_owned, var_names.get(inst.operands[0]).? }),
                .dot => try w.print("    {s} {s} = dot({s}, {s})", .{ t, name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).? }),
                .fma => try w.print("    {s} {s} = mad({s}, {s}, {s})", .{ t, name_owned, var_names.get(inst.operands[0]).?, var_names.get(inst.operands[1]).?, var_names.get(inst.operands[2]).? }),
                .branch, .phi, .loop => {
                    emit_semicolon = false;
                },
                .entry_point, .sample, .atomic, .barrier => {
                    try w.print("    {s} {s} = 0 /* unhandled op {s} */", .{ t, name_owned, @tagName(inst.op) });
                },
            }
            if (emit_semicolon) try w.writeAll(";\n");
        }
    }

    // Free name strings
    var it = var_names.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.value_ptr.*);
    }
}

fn isIntrinsicMethod(name: []const u8) bool {
    return std.mem.eql(u8, name, "SampleLevel") or
        std.mem.eql(u8, name, "Sample") or
        std.mem.eql(u8, name, "Load") or
        std.mem.eql(u8, name, "GetDimensions") or
        std.mem.eql(u8, name, "Gather") or
        std.mem.eql(u8, name, "GatherRed") or
        std.mem.eql(u8, name, "GatherGreen") or
        std.mem.eql(u8, name, "GatherBlue") or
        std.mem.eql(u8, name, "GatherAlpha");
}

fn emitIrResourceDecl(w: anytype, res: *const gpu_ir.IrResourceDecl) !void {
    const type_s = switch (res.type_ref) {
        .texture2d => "Texture2D",
        .rw_texture2d => "RWTexture2D",
        .sampler => "SamplerState",
        else => "Texture2D",
    };
    const fmt_s = typeRefToHlslType(res.format);
    if (res.type_ref == .sampler) {
        try w.print("{s} {s} : register({c}{});\n", .{ type_s, res.name, res.binding_prefix, res.binding_reg });
    } else {
        try w.print("{s}<{s}> {s} : register({c}{});\n", .{ type_s, fmt_s, res.name, res.binding_prefix, res.binding_reg });
    }
}

fn typeRefToHlslType(tr: gpu_ir.TypeRef) []const u8 {
    return switch (tr) {
        .f32 => "float",
        .i32 => "int",
        .u32 => "uint",
        .f16 => "half",
        .vec2f => "float2",
        .vec3f => "float3",
        .vec4f => "float4",
        .vec2i => "int2",
        .vec3i => "int3",
        .vec4i => "int4",
        .vec2u => "uint2",
        .vec3u => "uint3",
        .vec4u => "uint4",
        else => "float",
    };
}

fn emitIrCbuffer(w: anytype, members: []const gpu_ir.IrCbufferMember) !void {
    try w.print("cbuffer TSS_Constants : register(b{}) {{\n", .{ members[0].slot });
    for (members) |mem| {
        try w.print("    {s} {s};\n", .{ typeRefToHlslType(mem.type_ref), mem.name });
    }
    try w.writeAll("};\n");
}

fn emitResourceDecl(w: anytype, res: *const gpu_ast.ResourceDecl) !void {
    switch (res.gpu_type.kind) {
        .resource_typed => |rt| {
            const fmt = switch (rt.format) { .f32 => "float", .i32 => "int", .u32 => "uint", .f16 => "half", .boolean => "bool" };
            const kind_s = switch (rt.kind) { .texture2d => "Texture2D", .rw_texture2d => "RWTexture2D", else => "Texture2D" };
            const reg_prefix: u8 = if (rt.kind == .rw_texture2d) 'u' else 't';
            const wnum = @intFromEnum(rt.width);
            if (wnum > 1) {
                try w.print("{s}<{s}{c}> {s} : register({c}{});\n", .{ kind_s, fmt, @as(u8, '0' + wnum), res.name, reg_prefix, res.binding.reg });
            } else {
                try w.print("{s}<{s}> {s} : register({c}{});\n", .{ kind_s, fmt, res.name, reg_prefix, res.binding.reg });
            }
        },
        .resource => |rk| {
            const reg_prefix: u8 = switch (rk) { .sampler_state => 's', else => 't' };
            const type_s = switch (rk) {
                .sampler_state => "SamplerState",
                .structured_buffer => "StructuredBuffer<float>",
                .constant_buffer => "ConstantBuffer<float4>",
                else => "Texture2D",
            };
            try w.print("{s} {s} : register({c}{});\n", .{ type_s, res.name, reg_prefix, res.binding.reg });
        },
        else => {},
    }
}

fn emitCbufferDecl(w: anytype, members: []const gpu_ast.CbufferMember) !void {
    try w.print("cbuffer TSS_Constants : register(b{}) {{\n", .{ members[0].slot.reg });
    for (members) |mem| {
        const type_str = switch (mem.scalar_type) {
            .f32 => "float",
            .i32 => "int",
            .u32 => "uint",
            .f16 => "half",
            .boolean => "bool",
        };
        try w.print("    {s} {s};\n", .{ type_str, mem.name });
    }
    try w.writeAll("};\n");
}
