const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_ir = @import("gpu_ir.zig");

/// Generate C++ UE shader class from GPU IR
pub fn generateCppFromIr(allocator: Allocator, ir: *const gpu_ir.IrModule) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    for (ir.functions.items) |func| {
        const class_name = try std.fmt.allocPrint(allocator, "FTSSShader_{s}", .{func.kernel_name});
        defer allocator.free(class_name);

        // Class declaration
        try w.print("class {s} : public FGlobalShader\n", .{class_name});
        try w.writeAll("{\n");
        try w.writeAll("public:\n");
        try w.print("\tDECLARE_GLOBAL_SHADER({s});\n", .{class_name});
        try w.print("\tSHADER_USE_PARAMETER_STRUCT({s}, FGlobalShader);\n", .{class_name});
        try w.writeAll("\n");

        // FParameters struct
        try w.writeAll("\tBEGIN_SHADER_PARAMETER_STRUCT(FParameters, )\n");

        // Resource declarations
        for (ir.resources.items) |*res| {
            try w.writeAll("\t\t");
            try writeResourceParam(w, res);
        }

        // Cbuffer declarations
        for (ir.cbuffer_members.items) |*mem| {
            try w.writeAll("\t\t");
            try writeCbufferParam(w, mem);
        }

        try w.writeAll("\tEND_SHADER_PARAMETER_STRUCT()\n");
        try w.writeAll("};\n\n");

        // IMPLEMENT_GLOBAL_SHADER macro
        const usf_path = try std.fmt.allocPrint(allocator, "/Plugin/TSS/Private/TSS{s}.usf", .{func.kernel_name});
        defer allocator.free(usf_path);
        const entry_name = try std.fmt.allocPrint(allocator, "{s}Main", .{func.kernel_name});
        defer allocator.free(entry_name);
        try w.print("IMPLEMENT_GLOBAL_SHADER({s}, \"{s}\", \"{s}\", SF_Compute);\n\n", .{ class_name, usf_path, entry_name });
    }

    return buf.toOwnedSlice();
}

fn writeResourceParam(w: anytype, res: *const gpu_ir.IrResourceDecl) !void {
    const param_type = switch (res.type_ref) {
        .texture2d => "SHADER_PARAMETER_RDG_TEXTURE",
        .rw_texture2d => "SHADER_PARAMETER_RDG_TEXTURE_UAV",
        .sampler => "SHADER_PARAMETER_SAMPLER",
        else => "SHADER_PARAMETER_RDG_TEXTURE",
    };

    const hlsl_type = switch (res.type_ref) {
        .texture2d => "Texture2D<float4>",
        .rw_texture2d => "RWTexture2D<float4>",
        .sampler => "SamplerState",
        else => "Texture2D<float4>",
    };

    try w.print("{s}({s}, {s})\n", .{ param_type, hlsl_type, res.name });
}

fn writeCbufferParam(w: anytype, mem: *const gpu_ir.IrCbufferMember) !void {
    const cpp_type = switch (mem.type_ref) {
        .f32 => "float",
        .i32 => "int32",
        .u32 => "uint32",
        .vec2f => "FVector2f",
        .vec3f => "FVector3f",
        .vec4f => "FVector4f",
        .vec2i => "FIntVector2",
        .vec3i => "FIntVector3",
        .vec4i => "FIntVector4",
        .vec2u => "FUintVector2",
        .vec3u => "FUintVector3",
        .vec4u => "FUintVector4",
        else => "float",
    };

    try w.print("SHADER_PARAMETER({s}, {s})\n", .{ cpp_type, mem.name });
}

pub const backend: gpu_ir.BackendApi = .{
    .name = "C++",
    .target = .cpp,
    .file_extension = "cpp",
    .description = "Unreal Engine C++ shader class",
    .compile = compileCppFromIr,
};

fn compileCppFromIr(allocator: Allocator, ir: *const gpu_ir.IrModule, options: gpu_ir.CompileOptions) !gpu_ir.CompileResult {
    _ = options;
    const cpp = try generateCppFromIr(allocator, ir);
    return gpu_ir.CompileResult{
        .bytecode = cpp,
        .allocator = allocator,
    };
}
