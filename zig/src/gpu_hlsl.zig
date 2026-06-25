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

    for (ir.functions.items) |func| {
        for (func.globals_lines.items) |line| {
            try w.print("{s}\n", .{line});
        }

        try w.print("[numthreads({}, {}, {})]\n", .{ func.numthreads.x, func.numthreads.y, func.numthreads.z });
        try w.print("void {s}(uint3 __tid : SV_DispatchThreadID)", .{func.name});
        try w.writeAll("{\n");
        try w.print("    uint {s} = __tid.x;\n", .{func.x_param});
        try w.print("    uint {s} = __tid.y;\n", .{func.y_param});
        for (func.passthrough_body.items) |line| {
            try w.print("    {s}\n", .{ line });
        }
        try w.writeAll("}\n");
    }

    return buf.toOwnedSlice();
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
