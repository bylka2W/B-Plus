const std = @import("std");

pub const ResourceType = enum {
    input,
    transient,
    output,
    persistent,
};

pub const Resource = struct {
    name: []const u8,
    resource_type: ResourceType,
    format: []const u8,
    size_hint: []const u8,
};

pub const Pass = struct {
    name: []const u8,
    shader: []const u8,
    reads: [][]const u8,
    writes: [][]const u8,
    group_x: u32,
    group_y: u32,
    group_z: u32,
};

pub const Pipeline = struct {
    name: []const u8,
    resources: []Resource,
    passes: []Pass,
};

pub fn parsePipeline(allocator: std.mem.Allocator, source: []const u8) !Pipeline {
    var resources = std.ArrayList(Resource).init(allocator);
    var passes = std.ArrayList(Pass).init(allocator);

    var lines = std.ArrayList([]const u8).init(allocator);
    var line_iter = std.mem.tokenizeScalar(u8, source, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) continue;
        try lines.append(trimmed);
    }

    var i: usize = 0;
    var pipeline_name: ?[]const u8 = null;

    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];

        if (std.mem.startsWith(u8, line, "pipeline ")) {
            const rest = std.mem.trim(u8, line["pipeline ".len..], " \t");
            if (std.mem.endsWith(u8, rest, "{")) {
                pipeline_name = std.mem.trim(u8, rest[0 .. rest.len - 1], " \t");
            } else {
                pipeline_name = rest;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "resource ")) {
            const rest = std.mem.trim(u8, line["resource ".len..], " \t");
            const name = std.mem.trimRight(u8, rest, " {");
            var res_type: ResourceType = .transient;
            var format: []const u8 = "rgba16f";
            var size_hint: []const u8 = "render";

            i += 1;
            while (i < lines.items.len and !std.mem.eql(u8, lines.items[i], "}")) {
                const prop_line = std.mem.trim(u8, lines.items[i], " \t");
                if (parseProp(prop_line, "type")) |val| {
                    res_type = std.meta.stringToEnum(ResourceType, val) orelse .transient;
                } else if (parseProp(prop_line, "format")) |val| {
                    format = val;
                } else if (parseProp(prop_line, "size")) |val| {
                    size_hint = val;
                }
                i += 1;
            }

            try resources.append(Resource{
                .name = try allocator.dupe(u8, name),
                .resource_type = res_type,
                .format = try allocator.dupe(u8, format),
                .size_hint = try allocator.dupe(u8, size_hint),
            });
            continue;
        }

        if (std.mem.startsWith(u8, line, "pass ")) {
            const rest = std.mem.trim(u8, line["pass ".len..], " \t");
            const pass_name = std.mem.trimRight(u8, rest, " {");

            var shader: ?[]const u8 = null;
            var reads = std.ArrayList([]const u8).init(allocator);
            var writes = std.ArrayList([]const u8).init(allocator);
            var gx: u32 = 8;
            var gy: u32 = 8;
            var gz: u32 = 1;

            i += 1;
            while (i < lines.items.len and !std.mem.eql(u8, lines.items[i], "}")) {
                const prop_line = std.mem.trim(u8, lines.items[i], " \t");
                if (std.mem.startsWith(u8, prop_line, "shader ")) {
                    shader = extractQuoted(prop_line["shader ".len..]);
                } else if (std.mem.startsWith(u8, prop_line, "read ")) {
                    const rest2 = std.mem.trim(u8, prop_line["read ".len..], " \t;");
                    var it2 = std.mem.tokenizeScalar(u8, rest2, ',');
                    while (it2.next()) |token| {
                        const t = std.mem.trim(u8, token, " \t\"");
                        if (t.len > 0) try reads.append(try allocator.dupe(u8, t));
                    }
                } else if (std.mem.startsWith(u8, prop_line, "write ")) {
                    const rest2 = std.mem.trim(u8, prop_line["write ".len..], " \t;");
                    var it2 = std.mem.tokenizeScalar(u8, rest2, ',');
                    while (it2.next()) |token| {
                        const t = std.mem.trim(u8, token, " \t\"");
                        if (t.len > 0) try writes.append(try allocator.dupe(u8, t));
                    }
                } else if (std.mem.startsWith(u8, prop_line, "dispatch(")) {
                    parseDispatch(prop_line, &gx, &gy, &gz);
                }
                i += 1;
            }

            try passes.append(Pass{
                .name = try allocator.dupe(u8, pass_name),
                .shader = try allocator.dupe(u8, shader orelse "unknown"),
                .reads = try reads.toOwnedSlice(),
                .writes = try writes.toOwnedSlice(),
                .group_x = gx,
                .group_y = gy,
                .group_z = gz,
            });
            continue;
        }
    }

    return Pipeline{
        .name = try allocator.dupe(u8, pipeline_name orelse "TSS"),
        .resources = try resources.toOwnedSlice(),
        .passes = try passes.toOwnedSlice(),
    };
}

fn parseProp(line: []const u8, key: []const u8) ?[]const u8 {
    const prefix1 = std.fmt.allocPrint(std.heap.page_allocator, "{s} = ", .{key}) catch return null;
    defer std.heap.page_allocator.free(prefix1);
    if (std.mem.startsWith(u8, line, prefix1)) {
        return std.mem.trim(u8, line[prefix1.len..], " \t;\"");
    }
    const prefix2 = std.fmt.allocPrint(std.heap.page_allocator, "{s}=", .{key}) catch return null;
    defer std.heap.page_allocator.free(prefix2);
    if (std.mem.startsWith(u8, line, prefix2)) {
        return std.mem.trim(u8, line[prefix2.len..], " \t;\"");
    }
    return null;
}

fn extractQuoted(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t;");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn parseDispatch(line: []const u8, gx: *u32, gy: *u32, gz: *u32) void {
    const start = "dispatch(".len;
    const inner = line[start..];
    const end = std.mem.indexOfScalar(u8, inner, ')') orelse return;
    const args_str = std.mem.trim(u8, inner[0..end], " \t");
    var arg_iter = std.mem.tokenizeScalar(u8, args_str, ',');
    const parts = [_]*u32{ gx, gy, gz };
    var pi: usize = 0;
    while (arg_iter.next()) |token| : (pi += 1) {
        const t = std.mem.trim(u8, token, " \t");
        if (pi < parts.len and t.len > 0) {
            parts[pi].* = std.fmt.parseInt(u32, t, 10) catch 8;
        }
    }
}

fn formatToCppEnum(format: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(format, "rgba8") or std.ascii.eqlIgnoreCase(format, "b8g8r8a8")) return "PF_B8G8R8A8";
    if (std.ascii.eqlIgnoreCase(format, "rgba16f") or std.ascii.eqlIgnoreCase(format, "floatrgba")) return "PF_FloatRGBA";
    if (std.ascii.eqlIgnoreCase(format, "r32f") or std.ascii.eqlIgnoreCase(format, "r32_float")) return "PF_R32_FLOAT";
    if (std.ascii.eqlIgnoreCase(format, "rg16f") or std.ascii.eqlIgnoreCase(format, "g16r16f")) return "PF_G16R16F";
    if (std.ascii.eqlIgnoreCase(format, "r16f") or std.ascii.eqlIgnoreCase(format, "r16_float")) return "PF_R16F";
    return "PF_FloatRGBA";
}

fn toPascalCase(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return try allocator.dupe(u8, s);
    var buf = std.ArrayList(u8).init(allocator);
    var segments = std.mem.tokenizeScalar(u8, s, '_');
    while (segments.next()) |seg| {
        if (abbreviation(seg)) |abbr| {
            try buf.appendSlice(abbr);
        } else {
            for (seg, 0..) |c, j| {
                if (j == 0) {
                    try buf.append(std.ascii.toUpper(c));
                } else {
                    try buf.append(std.ascii.toLower(c));
                }
            }
        }
    }
    return try buf.toOwnedSlice();
}

fn abbreviation(seg: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(seg, "rcas")) return "RCAS";
    if (std.ascii.eqlIgnoreCase(seg, "easu")) return "EASU";
    if (std.ascii.eqlIgnoreCase(seg, "fsr2")) return "FSR2";
    return null;
}

fn toUsfName(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    try buf.appendSlice("TSS");
    var segments = std.mem.tokenizeScalar(u8, s, '_');
    while (segments.next()) |seg| {
        if (abbreviation(seg)) |abbr| {
            try buf.appendSlice(abbr);
        } else {
            for (seg, 0..) |c, j| {
                if (j == 0) {
                    try buf.append(std.ascii.toUpper(c));
                } else {
                    try buf.append(std.ascii.toLower(c));
                }
            }
        }
    }
    return try buf.toOwnedSlice();
}

pub fn generateShadersHeader(allocator: std.mem.Allocator, pipeline: *const Pipeline) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    try w.writeAll(
        "#pragma once\n\n"
        ++ "#include \"CoreMinimal.h\"\n"
        ++ "#include \"DataDrivenShaderPlatformInfo.h\"\n"
        ++ "#include \"RenderGraph.h\"\n"
        ++ "#include \"GlobalShader.h\"\n"
        ++ "#include \"ShaderParameterStruct.h\"\n\n"
        ++ "BEGIN_SHADER_PARAMETER_STRUCT(FBPlusShaderParams, )\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input0)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input1)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input2)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input3)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input4)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input5)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input6)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input7)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input8)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input9)\n"
        ++ "\tSHADER_PARAMETER_SAMPLER(SamplerState, InputSampler)\n"
        ++ "\tSHADER_PARAMETER(FVector4f, PrevVPRow0)\n"
        ++ "\tSHADER_PARAMETER(FVector4f, PrevVPRow1)\n"
        ++ "\tSHADER_PARAMETER(FVector4f, PrevVPRow2)\n"
        ++ "\tSHADER_PARAMETER(FVector4f, PrevVPRow3)\n"
        ++ "\tSHADER_PARAMETER(FVector4f, CurrInvVPRow0)\n"
        ++ "\tSHADER_PARAMETER(FVector4f, CurrInvVPRow1)\n"
        ++ "\tSHADER_PARAMETER(FVector4f, CurrInvVPRow2)\n"
        ++ "\tSHADER_PARAMETER(FVector4f, CurrInvVPRow3)\n"
        ++ "\tSHADER_PARAMETER(uint32, bHasValidPrevFrame)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output0)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output1)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output2)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output3)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output4)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output5)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output6)\n"
        ++ "\tSHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output7)\n"
        ++ "END_SHADER_PARAMETER_STRUCT()\n\n"
        ++ "#define TSS_DECLARE_SHADER(ClassName, VirtualPath, EntryPoint) \\\n"
        ++ "class ClassName : public FGlobalShader \\\n"
        ++ "{ \\\n"
        ++ "public: \\\n"
        ++ "\tDECLARE_GLOBAL_SHADER(ClassName); \\\n"
        ++ "\tSHADER_USE_PARAMETER_STRUCT(ClassName, FGlobalShader); \\\n"
        ++ "\tusing FParameters = FBPlusShaderParams; \\\n"
        ++ "\tstatic bool ShouldCompilePermutation(const FGlobalShaderPermutationParameters& Parameters) \\\n"
        ++ "\t{ \\\n"
        ++ "\t\treturn IsFeatureLevelSupported(Parameters.Platform, ERHIFeatureLevel::SM5); \\\n"
        ++ "\t} \\\n"
        ++ "};\n\n"
    );

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (pipeline.passes) |pass| {
        if (seen.contains(pass.shader)) continue;
        try seen.put(pass.shader, {});

        const cls = try toPascalCase(allocator, pass.shader);
        defer allocator.free(cls);
        const usf_n = try toUsfName(allocator, pass.shader);
        defer allocator.free(usf_n);
        const entry = try toPascalCase(allocator, pass.shader);
        defer allocator.free(entry);

        try w.print(
            "TSS_DECLARE_SHADER(FTSSShader_{s}, \"/Plugin/TSS/Private/{s}.usf\", \"{s}Main\")\n",
            .{ cls, usf_n, entry },
        );
    }

    try w.writeAll(
        "TSS_DECLARE_SHADER(FTSSShader_Copy, \"/Plugin/TSS/Private/TSSCopy.usf\", \"CopyMain\")\n"
        ++ "TSS_DECLARE_SHADER(FTSSShader_EASU, \"/Plugin/TSS/Private/TSSEASU.usf\", \"EASUMain\")\n"
    );

    return try buf.toOwnedSlice();
}

pub fn generateShadersCpp(allocator: std.mem.Allocator, pipeline: *const Pipeline) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();
    try w.writeAll("#include \"TSSShaders.h\"\n\n");

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (pipeline.passes) |pass| {
        if (seen.contains(pass.shader)) continue;
        try seen.put(pass.shader, {});

        const cls = try toPascalCase(allocator, pass.shader);
        defer allocator.free(cls);
        const usf_n = try toUsfName(allocator, pass.shader);
        defer allocator.free(usf_n);
        const entry = try toPascalCase(allocator, pass.shader);
        defer allocator.free(entry);

        try w.print(
            "IMPLEMENT_GLOBAL_SHADER(FTSSShader_{s}, \"/Plugin/TSS/Private/{s}.usf\", \"{s}Main\", SF_Compute);\n",
            .{ cls, usf_n, entry },
        );
    }

    try w.writeAll(
        "IMPLEMENT_GLOBAL_SHADER(FTSSShader_Copy, \"/Plugin/TSS/Private/TSSCopy.usf\", \"CopyMain\", SF_Compute);\n"
        ++ "IMPLEMENT_GLOBAL_SHADER(FTSSShader_EASU, \"/Plugin/TSS/Private/TSSEASU.usf\", \"EASUMain\", SF_Compute);\n"
    );

    return try buf.toOwnedSlice();
}

pub fn generateRuntimeHeader(allocator: std.mem.Allocator, pipeline: *const Pipeline) ![]const u8 {
    _ = pipeline;
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();
    try w.writeAll(
        "#pragma once\n\n"
        ++ "#include \"CoreMinimal.h\"\n"
        ++ "#include \"RenderGraph.h\"\n\n"
        ++ "class FTSSRuntime\n"
        ++ "{\n"
        ++ "public:\n"
        ++ "\tFTSSRuntime();\n\n"
        ++ "\tvoid ExecutePlan(FRDGBuilder& GraphBuilder, FRDGTextureRef SceneColor, FRDGTextureRef ViewFamilyOutput, FRDGTextureRef Velocity, FRDGTextureRef SceneDepth, FIntPoint DisplaySize, float DownscaleFactor = 1.0f, const FVector4f& InPrevVP0 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InPrevVP1 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InPrevVP2 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InPrevVP3 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InCurrInvVP0 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InCurrInvVP1 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InCurrInvVP2 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InCurrInvVP3 = FVector4f(EForceInit::ForceInitToZero), bool bInHasValidPrevFrame = false);\n\n"
        ++ "\tFRDGTextureRef GetLastFinalOutput() const { return LastFinalOutput; }\n\n"
        ++ "private:\n"
        ++ "\tvoid ExecuteComputePass(FRDGBuilder& GraphBuilder, const FString& PassName, const FString& ShaderName, TArray<FRDGTextureRef>& Inputs, TArray<FString>& OutputNames, TArray<FRDGTextureRef>& OutputTexs, TArray<FRDGTextureUAV*>& OutputUAVs, FIntPoint DispatchSize, int32 GroupSizeX, bool bLog);\n\n"
        ++ "\tTRefCountPtr<IPooledRenderTarget> HistoryRT;\n"
        ++ "\tTRefCountPtr<IPooledRenderTarget> LockHistoryRT;\n"
        ++ "\tTRefCountPtr<IPooledRenderTarget> DilatedVelocityRT;\n"
        ++ "\tTRefCountPtr<IPooledRenderTarget> LumaHistoryRT;\n"
        ++ "\tTRefCountPtr<IPooledRenderTarget> AutoExposureRT;\n"
        ++ "\tFRDGTextureRef LastFinalOutput = nullptr;\n"
        ++ "\tFIntPoint PreviousRenderSize = FIntPoint::ZeroValue;\n"
        ++ "\tfloat PreviousDownscale = 1.0f;\n"
        ++ "\tFVector4f PrevVPRow0 = FVector4f(EForceInit::ForceInitToZero);\n"
        ++ "\tFVector4f PrevVPRow1 = FVector4f(EForceInit::ForceInitToZero);\n"
        ++ "\tFVector4f PrevVPRow2 = FVector4f(EForceInit::ForceInitToZero);\n"
        ++ "\tFVector4f PrevVPRow3 = FVector4f(EForceInit::ForceInitToZero);\n"
        ++ "\tFVector4f CurrInvVPRow0 = FVector4f(EForceInit::ForceInitToZero);\n"
        ++ "\tFVector4f CurrInvVPRow1 = FVector4f(EForceInit::ForceInitToZero);\n"
        ++ "\tFVector4f CurrInvVPRow2 = FVector4f(EForceInit::ForceInitToZero);\n"
        ++ "\tFVector4f CurrInvVPRow3 = FVector4f(EForceInit::ForceInitToZero);\n"
        ++ "\tbool bHasValidPrevFrame = false;\n"
        ++ "\tdouble LastLogTime = 0.0;\n"
        ++ "};\n"
    );
    return try buf.toOwnedSlice();
}

pub fn generateRuntimeCpp(allocator: std.mem.Allocator, pipeline: *const Pipeline) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    try w.writeAll(
        "#include \"TSSRuntime.h\"\n"
        ++ "#include \"TSSShaders.h\"\n"
        ++ "#include \"Misc/Paths.h\"\n"
        ++ "#include \"RHIStaticStates.h\"\n\n"
        ++ "FTSSRuntime::FTSSRuntime()\n"
        ++ "{\n"
        ++ "}\n\n"
    );

   //получаем формат выходного файла
    try w.writeAll(
        "static EPixelFormat GetOutputFormat(const FString& ResName, EPixelFormat InputFmt)\n"
        ++ "{\n"
    );
    for (pipeline.resources) |res| {
        if (res.resource_type != .input) {
            try w.print("\tif (ResName == TEXT(\"{s}\")) return {s};\n", .{ res.name, formatToCppEnum(res.format) });
        }
    }
    try w.writeAll(
        "\tif (InputFmt == PF_B8G8R8A8) return PF_FloatRGBA;\n"
        ++ "\treturn InputFmt;\n"
        ++ "}\n\n"
    );

    //получаем размер выходных данных по имени
    try w.writeAll(
        "static FIntPoint GetOutputSizeForName(const FString& Name, FIntPoint RenderSize, FIntPoint DisplaySize)\n"
        ++ "{\n"
    );
    for (pipeline.resources) |res| {
        if (res.resource_type == .input) continue;
            if (std.ascii.eqlIgnoreCase(res.size_hint, "display")) {
                try w.print("\tif (Name == TEXT(\"{s}\")) return DisplaySize;\n", .{res.name});
            } else if (std.mem.indexOfScalar(u8, res.size_hint, 'x') != null or std.mem.indexOfScalar(u8, res.size_hint, 'X') != null) {
                var sz = std.ArrayList(u8).init(allocator);
                defer sz.deinit();
                for (res.size_hint) |c| {
                    if (c == 'x' or c == 'X') try sz.append(',') else try sz.append(c);
                }
                try w.print("\tif (Name == TEXT(\"{s}\")) return FIntPoint({s});\n", .{ res.name, sz.items });
            }
    }
    try w.writeAll("\treturn RenderSize;\n}\n\n");

    //выполняем план ыыыыы
    try w.writeAll(
        "void FTSSRuntime::ExecutePlan(FRDGBuilder& GraphBuilder, FRDGTextureRef SceneColor, FRDGTextureRef ViewFamilyOutput, FRDGTextureRef Velocity, FRDGTextureRef SceneDepth, FIntPoint DisplaySize, float DownscaleFactor, const FVector4f& InPrevVP0, const FVector4f& InPrevVP1, const FVector4f& InPrevVP2, const FVector4f& InPrevVP3, const FVector4f& InCurrInvVP0, const FVector4f& InCurrInvVP1, const FVector4f& InCurrInvVP2, const FVector4f& InCurrInvVP3, bool bInHasValidPrevFrame)\n"
        ++ "{\n"
        ++ "\tPrevVPRow0 = InPrevVP0;\n"
        ++ "\tPrevVPRow1 = InPrevVP1;\n"
        ++ "\tPrevVPRow2 = InPrevVP2;\n"
        ++ "\tPrevVPRow3 = InPrevVP3;\n"
        ++ "\tCurrInvVPRow0 = InCurrInvVP0;\n"
        ++ "\tCurrInvVPRow1 = InCurrInvVP1;\n"
        ++ "\tCurrInvVPRow2 = InCurrInvVP2;\n"
        ++ "\tCurrInvVPRow3 = InCurrInvVP3;\n"
        ++ "\tbHasValidPrevFrame = bInHasValidPrevFrame;\n\n"
        ++ "\tbool bIsUpscale = DownscaleFactor > 0.0f && DownscaleFactor < (1.0f - SMALL_NUMBER);\n"
        ++ "\tbool bIsNative = FMath::IsNearlyEqual(DownscaleFactor, 1.0f, 0.005f);\n"
        ++ "\tbool bIsSupersampling = !bIsUpscale && !bIsNative;\n\n"
        ++ "\tFIntPoint RenderSize = DisplaySize;\n"
        ++ "\tif (bIsUpscale)\n"
        ++ "\t{\n"
        ++ "\t\tRenderSize.X = FMath::Max(1, FMath::CeilToInt(DisplaySize.X * DownscaleFactor));\n"
        ++ "\t\tRenderSize.Y = FMath::Max(1, FMath::CeilToInt(DisplaySize.Y * DownscaleFactor));\n\n"
        ++ "\t\tif (RenderSize != SceneColor->Desc.Extent)\n"
        ++ "\t\t{\n"
        ++ "\t\t\tFRDGTextureRef Downscaled = GraphBuilder.CreateTexture(\n"
        ++ "\t\t\t\tFRDGTextureDesc::Create2D(RenderSize, SceneColor->Desc.Format,\n"
        ++ "\t\t\t\t\tFClearValueBinding::None,\n"
        ++ "\t\t\t\t\tTexCreate_UAV | TexCreate_RenderTargetable | TexCreate_ShaderResource),\n"
        ++ "\t\t\t\tTEXT(\"TSS_DownscaledScene\")\n"
        ++ "\t\t\t);\n"
        ++ "\t\t\tFRDGTextureUAVRef DownUAV = GraphBuilder.CreateUAV(Downscaled);\n\n"
        ++ "\t\t\tTShaderMapRef<FTSSShader_Copy> CopyShader(GetGlobalShaderMap(GMaxRHIFeatureLevel));\n"
        ++ "\t\t\tFBPlusShaderParams* CopyParams = GraphBuilder.AllocParameters<FBPlusShaderParams>();\n"
        ++ "\t\t\tCopyParams->Input0 = SceneColor;\n"
        ++ "\t\t\tCopyParams->Output0 = DownUAV;\n"
        ++ "\t\t\tCopyParams->InputSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();\n\n"
        ++ "\t\t\tFIntVector GroupCount = FComputeShaderUtils::GetGroupCount(RenderSize, 8);\n"
        ++ "\t\t\tGraphBuilder.AddPass(\n"
        ++ "\t\t\t\tRDG_EVENT_NAME(\"TSS_Downscale\"),\n"
        ++ "\t\t\t\tCopyParams, ERDGPassFlags::Compute,\n"
        ++ "\t\t\t\t[CopyShader, CopyParams, GroupCount](FRHIComputeCommandList& Cmd)\n"
        ++ "\t\t\t\t{\n"
        ++ "\t\t\t\t\tFComputeShaderUtils::Dispatch(Cmd, CopyShader, *CopyParams, GroupCount);\n"
        ++ "\t\t\t\t});\n\n"
        ++ "\t\t\tSceneColor = Downscaled;\n"
        ++ "\t\t}\n"
        ++ "\t}\n"
        ++ "\telse if (bIsSupersampling)\n"
        ++ "\t{\n"
        ++ "\t\tRenderSize.X = FMath::Max(1, FMath::CeilToInt(DisplaySize.X * DownscaleFactor));\n"
        ++ "\t\tRenderSize.Y = FMath::Max(1, FMath::CeilToInt(DisplaySize.Y * DownscaleFactor));\n"
        ++ "\t}\n\n"
        ++ "\tbool bCacheValid = (PreviousRenderSize == RenderSize && FMath::IsNearlyEqual(PreviousDownscale, DownscaleFactor));\n\n"
        ++ "\tdouble Now = FPlatformTime::Seconds();\n"
        ++ "\tbool bLogThisFrame = (Now - LastLogTime > 1.0);\n"
        ++ "\tif (bLogThisFrame)\n"
        ++ "\t{\n"
        ++ "\t\tLastLogTime = Now;\n"
        ++ "\t\tconst TCHAR* ModeStr = bIsUpscale ? TEXT(\"UPSCALE\") : (bIsSupersampling ? TEXT(\"SUPERSAMPLE\") : TEXT(\"NATIVE\"));\n"
        ++ "\t\tUE_LOG(LogTemp, Warning, TEXT(\"TSS: ===== %s Display=%dx%d -> Render=%dx%d (DF=%.2f) Cache=%d =====\"),\n"
        ++ "\t\t\tModeStr, DisplaySize.X, DisplaySize.Y,\n"
        ++ "\t\t\tRenderSize.X, RenderSize.Y, DownscaleFactor, bCacheValid ? 1 : 0);\n"
        ++ "\t}\n\n"
        ++ "\tTMap<FString, FRDGTextureRef> TextureCache;\n"
        ++ "\tTextureCache.Add(TEXT(\"SceneColor\"), SceneColor);\n"
        ++ "\tTextureCache.Add(TEXT(\"ViewFamilyOutput\"), ViewFamilyOutput);\n"
        ++ "\tTextureCache.Add(TEXT(\"Velocity\"), Velocity);\n"
        ++ "\tTextureCache.Add(TEXT(\"SceneDepth\"), SceneDepth);\n\n"
    );

    //инициализируем постоянные текстуры 
    try writePersistentInit(w, allocator, pipeline, "History", "HistoryRT", "DisplaySize", "PF_FloatRGBA", "TSS_History");
    try writePersistentInit(w, allocator, pipeline, "LockStatus", "LockHistoryRT", "DisplaySize", "PF_FloatRGBA", "TSS_Lock");
    try writePersistentInit(w, allocator, pipeline, "DilatedMotionVectors", "DilatedVelocityRT", "RenderSize", "PF_G16R16F", "TSS_PrevDilatedMV");
    try writePersistentInit(w, allocator, pipeline, "LumaHistory", "LumaHistoryRT", "DisplaySize", "PF_FloatRGBA", "TSS_LumaHistory");
    try writePersistentInit(w, allocator, pipeline, "Exposure", "AutoExposureRT", "FIntPoint(1, 1)", "PF_R32_FLOAT", "TSS_PrevExposure");

    try w.writeAll(
        "\tPreviousRenderSize = RenderSize;\n"
        ++ "\tPreviousDownscale = DownscaleFactor;\n\n"
        ++ "\tif (bIsNative)\n"
        ++ "\t{\n"
        ++ "\t\tFRDGTextureDesc EASUDesc = FRDGTextureDesc::Create2D(\n"
        ++ "\t\t\tDisplaySize, SceneColor->Desc.Format,\n"
        ++ "\t\t\tFClearValueBinding::None,\n"
        ++ "\t\t\tTexCreate_UAV | TexCreate_RenderTargetable | TexCreate_ShaderResource);\n"
        ++ "\t\tFRDGTextureRef EASUOutput = GraphBuilder.CreateTexture(EASUDesc, TEXT(\"TSS_EASU_Output\"));\n\n"
        ++ "\t\tTShaderMapRef<FTSSShader_EASU> EASUShader(GetGlobalShaderMap(GMaxRHIFeatureLevel));\n"
        ++ "\t\tFBPlusShaderParams* EASUParams = GraphBuilder.AllocParameters<FBPlusShaderParams>();\n"
        ++ "\t\tEASUParams->Input0 = SceneColor;\n"
        ++ "\t\tEASUParams->Output0 = GraphBuilder.CreateUAV(EASUOutput);\n"
        ++ "\t\tEASUParams->InputSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();\n\n"
        ++ "\t\tFIntVector EASUGroups = FComputeShaderUtils::GetGroupCount(DisplaySize, 8);\n"
        ++ "\t\tGraphBuilder.AddPass(\n"
        ++ "\t\t\tRDG_EVENT_NAME(\"TSS_EASU_Native\"),\n"
        ++ "\t\t\tEASUParams, ERDGPassFlags::Compute,\n"
        ++ "\t\t\t[EASUShader, EASUParams, EASUGroups](FRHIComputeCommandList& Cmd)\n"
        ++ "\t\t\t{\n"
        ++ "\t\t\t\tFComputeShaderUtils::Dispatch(Cmd, EASUShader, *EASUParams, EASUGroups);\n"
        ++ "\t\t\t});\n\n"
        ++ "\t\tFRDGTextureDesc FinalDesc = FRDGTextureDesc::Create2D(\n"
        ++ "\t\t\tDisplaySize, SceneColor->Desc.Format,\n"
        ++ "\t\t\tFClearValueBinding::None,\n"
        ++ "\t\t\tTexCreate_UAV | TexCreate_RenderTargetable | TexCreate_ShaderResource);\n"
        ++ "\t\tFRDGTextureRef FinalTex = GraphBuilder.CreateTexture(FinalDesc, TEXT(\"TSS_Final_Output\"));\n\n"
        ++ "\t\tTShaderMapRef<FTSSShader_RCAS> RCASShader(GetGlobalShaderMap(GMaxRHIFeatureLevel));\n"
        ++ "\t\tFBPlusShaderParams* RCASParams = GraphBuilder.AllocParameters<FBPlusShaderParams>();\n"
        ++ "\t\tRCASParams->Input0 = EASUOutput;\n"
        ++ "\t\tRCASParams->Output0 = GraphBuilder.CreateUAV(FinalTex);\n"
        ++ "\t\tRCASParams->InputSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();\n\n"
        ++ "\t\tFIntVector RCASGroups = FComputeShaderUtils::GetGroupCount(DisplaySize, 8);\n"
        ++ "\t\tGraphBuilder.AddPass(\n"
        ++ "\t\t\tRDG_EVENT_NAME(\"TSS_RCAS_Native\"),\n"
        ++ "\t\t\tRCASParams, ERDGPassFlags::Compute,\n"
        ++ "\t\t\t[RCASShader, RCASParams, RCASGroups](FRHIComputeCommandList& Cmd)\n"
        ++ "\t\t\t{\n"
        ++ "\t\t\t\tFComputeShaderUtils::Dispatch(Cmd, RCASShader, *RCASParams, RCASGroups);\n"
        ++ "\t\t\t});\n\n"
        ++ "\t\tLastFinalOutput = FinalTex;\n"
        ++ "\t\tPreviousRenderSize = RenderSize;\n"
        ++ "\t\tPreviousDownscale = DownscaleFactor;\n"
        ++ "\t\treturn;\n"
        ++ "\t}\n\n"
    );

    //генерируем проходы
    try w.writeAll("\t// === Plan/Metal Generated passes ===\n");
    for (pipeline.passes) |pass| {
        try w.writeAll("\t{\n\t\tRDG_EVENT_SCOPE(GraphBuilder, \"TSS_");
        try w.writeAll(pass.name);
        try w.writeAll("\");\n");
        try w.writeAll("\t\tTArray<FRDGTextureRef> Inputs;\n");
        for (pass.reads) |read_name| {
            try w.writeAll("\t\t{\n\t\t\tFRDGTextureRef* Found = TextureCache.Find(TEXT(\"");
            try w.writeAll(read_name);
            try w.writeAll("\"));\n\t\t\tif (Found) Inputs.Add(*Found);\n\t\t}\n");
        }
        try w.writeAll(
            "\t\tFRDGTextureRef SrcForSize = Inputs.Num() > 0 ? Inputs[0] : TextureCache.FindRef(TEXT(\"SceneColor\"));\n\n"
            ++ "\t\tTArray<FRDGTextureRef> OutputTexs;\n"
            ++ "\t\tTArray<FRDGTextureUAV*> OutputUAVs;\n"
            ++ "\t\tTArray<FString> OutputNames;\n\n"
        );
        for (pass.writes) |write_name| {
            try w.writeAll("\t\t{\n");
            try w.writeAll("\t\t\tFIntPoint TexSize = GetOutputSizeForName(TEXT(\"");
            try w.writeAll(write_name);
            try w.writeAll("\"), RenderSize, DisplaySize);\n");
            try w.writeAll("\t\t\tEPixelFormat OutFmt = GetOutputFormat(TEXT(\"");
            try w.writeAll(write_name);
            try w.writeAll("\"), SrcForSize->Desc.Format);\n");
            try w.writeAll("\t\t\tFRDGTextureRef NewTex = GraphBuilder.CreateTexture(\n");
            try w.writeAll("\t\t\t\tFRDGTextureDesc::Create2D(TexSize, OutFmt,\n");
            try w.writeAll("\t\t\t\t\tFClearValueBinding::None,\n");
            try w.writeAll("\t\t\t\t\tTexCreate_UAV | TexCreate_RenderTargetable | TexCreate_ShaderResource),\n");
            try w.writeAll("\t\t\t\tTEXT(\"");
            try w.writeAll(write_name);
            try w.writeAll("\"));\n");
            try w.writeAll("\t\t\tOutputTexs.Add(NewTex);\n");
            try w.writeAll("\t\t\tOutputUAVs.Add(GraphBuilder.CreateUAV(NewTex));\n");
            try w.writeAll("\t\t\tOutputNames.Add(TEXT(\"");
            try w.writeAll(write_name);
            try w.writeAll("\"));\n");
            try w.writeAll("\t\t}\n");
        }
        try w.writeAll(
            "\t\tif (OutputUAVs.Num() > 0) {\n"
            ++ "\t\t\tFBPlusShaderParams* Params = GraphBuilder.AllocParameters<FBPlusShaderParams>();\n"
            ++ "\t\t\tauto SetInputSlot = [&](int32 Slot, FRDGTextureRef Tex) {\n"
            ++ "\t\t\t\tswitch (Slot) {\n"
            ++ "\t\t\t\tcase 0: Params->Input0 = Tex; break;\n"
            ++ "\t\t\t\tcase 1: Params->Input1 = Tex; break;\n"
            ++ "\t\t\t\tcase 2: Params->Input2 = Tex; break;\n"
            ++ "\t\t\t\tcase 3: Params->Input3 = Tex; break;\n"
            ++ "\t\t\t\tcase 4: Params->Input4 = Tex; break;\n"
            ++ "\t\t\t\tcase 5: Params->Input5 = Tex; break;\n"
            ++ "\t\t\t\tcase 6: Params->Input6 = Tex; break;\n"
            ++ "\t\t\t\tcase 7: Params->Input7 = Tex; break;\n"
            ++ "\t\t\t\tcase 8: Params->Input8 = Tex; break;\n"
            ++ "\t\t\t\tcase 9: Params->Input9 = Tex; break;\n"
            ++ "\t\t\t\t}\n"
            ++ "\t\t\t};\n"
            ++ "\t\t\tint32 NumSlots = FMath::Min(Inputs.Num(), 10);\n"
            ++ "\t\t\tfor (int32 i = 0; i < NumSlots; i++) SetInputSlot(i, Inputs[i]);\n"
            ++ "\t\t\tauto SetOutputSlot = [&](int32 Slot, FRDGTextureUAV* UAV) {\n"
            ++ "\t\t\t\tswitch (Slot) {\n"
            ++ "\t\t\t\tcase 0: Params->Output0 = UAV; break;\n"
            ++ "\t\t\t\tcase 1: Params->Output1 = UAV; break;\n"
            ++ "\t\t\t\tcase 2: Params->Output2 = UAV; break;\n"
            ++ "\t\t\t\tcase 3: Params->Output3 = UAV; break;\n"
            ++ "\t\t\t\tcase 4: Params->Output4 = UAV; break;\n"
            ++ "\t\t\t\tcase 5: Params->Output5 = UAV; break;\n"
            ++ "\t\t\t\tcase 6: Params->Output6 = UAV; break;\n"
            ++ "\t\t\t\tcase 7: Params->Output7 = UAV; break;\n"
            ++ "\t\t\t\t}\n"
            ++ "\t\t\t};\n"
            ++ "\t\t\tint32 NumOutSlots = FMath::Min(OutputUAVs.Num(), 8);\n"
            ++ "\t\t\tfor (int32 i = 0; i < NumOutSlots; i++) SetOutputSlot(i, OutputUAVs[i]);\n"
            ++ "\t\t\tParams->InputSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();\n"
            ++ "\t\t\tParams->PrevVPRow0 = PrevVPRow0;\n"
            ++ "\t\t\tParams->PrevVPRow1 = PrevVPRow1;\n"
            ++ "\t\t\tParams->PrevVPRow2 = PrevVPRow2;\n"
            ++ "\t\t\tParams->PrevVPRow3 = PrevVPRow3;\n"
            ++ "\t\t\tParams->CurrInvVPRow0 = CurrInvVPRow0;\n"
            ++ "\t\t\tParams->CurrInvVPRow1 = CurrInvVPRow1;\n"
            ++ "\t\t\tParams->CurrInvVPRow2 = CurrInvVPRow2;\n"
            ++ "\t\t\tParams->CurrInvVPRow3 = CurrInvVPRow3;\n"
            ++ "\t\t\tParams->bHasValidPrevFrame = bHasValidPrevFrame ? 1u : 0u;\n\n"
            ++ "\t\t\tFIntPoint DispatchSize = SrcForSize->Desc.Extent;\n"
            ++ "\t\t\tfor (const FRDGTextureRef& Tex : OutputTexs) {\n"
            ++ "\t\t\t\tDispatchSize.X = FMath::Max(DispatchSize.X, Tex->Desc.Extent.X);\n"
            ++ "\t\t\t\tDispatchSize.Y = FMath::Max(DispatchSize.Y, Tex->Desc.Extent.Y);\n"
            ++ "\t\t\t}\n"
        );
        try w.writeAll("\t\t\tFIntVector GroupCount = FComputeShaderUtils::GetGroupCount(DispatchSize, ");
        {
            const group_str = try std.fmt.allocPrint(allocator, "{d}", .{pass.group_x});
            defer allocator.free(group_str);
            try w.writeAll(group_str);
        }
        try w.writeAll(");\n");
        const cls = try toPascalCase(allocator, pass.shader);
        defer allocator.free(cls);
        try w.writeAll("\t\t\tTShaderMapRef<FTSSShader_");
        try w.writeAll(cls);
        try w.writeAll("> Shader_(GetGlobalShaderMap(GMaxRHIFeatureLevel));\n");
        try w.writeAll("\t\t\tGraphBuilder.AddPass(\n");
        try w.writeAll("\t\t\t\tRDG_EVENT_NAME(\"BPlus_");
        try w.writeAll(pass.name);
        try w.writeAll("\"),\n");
        try w.writeAll(
            "\t\t\t\tParams, ERDGPassFlags::Compute,\n"
            ++ "\t\t\t\t[Shader_, Params, GroupCount](FRHIComputeCommandList& Cmd)\n"
            ++ "\t\t\t\t{\n"
            ++ "\t\t\t\t\tFComputeShaderUtils::Dispatch(Cmd, Shader_, *Params, GroupCount);\n"
            ++ "\t\t\t\t});\n\n"
            ++ "\t\t\tfor (int32 i = 0; i < OutputNames.Num(); i++) {\n"
            ++ "\t\t\t\tTextureCache.Add(OutputNames[i], OutputTexs[i]);\n"
            ++ "\t\t\t}\n"
            ++ "\t\t}\n"
            ++ "\t}\n\n"
        );
    }

    //извлекаем постоянные текстуры
    try w.writeAll(
        "\tFRDGTextureRef* FinalTex = TextureCache.Find(TEXT(\"Final_Output\"));\n"
        ++ "\tif (FinalTex && *FinalTex) LastFinalOutput = *FinalTex;\n\n"
        ++ "\tFRDGTextureRef* InternalUpscaled = TextureCache.Find(TEXT(\"InternalUpscaled\"));\n"
        ++ "\tif (InternalUpscaled && *InternalUpscaled) GraphBuilder.QueueTextureExtraction(*InternalUpscaled, &HistoryRT);\n\n"
        ++ "\tFRDGTextureRef* LockStatOut = TextureCache.Find(TEXT(\"LockStatusOut\"));\n"
        ++ "\tif (LockStatOut && *LockStatOut) GraphBuilder.QueueTextureExtraction(*LockStatOut, &LockHistoryRT);\n\n"
        ++ "\tFRDGTextureRef* DilatedMV = TextureCache.Find(TEXT(\"DilatedMotionVectors\"));\n"
        ++ "\tif (DilatedMV && *DilatedMV) GraphBuilder.QueueTextureExtraction(*DilatedMV, &DilatedVelocityRT);\n\n"
        ++ "\tFRDGTextureRef* LumaHistOut = TextureCache.Find(TEXT(\"LumaHistoryOut\"));\n"
        ++ "\tif (LumaHistOut && *LumaHistOut) GraphBuilder.QueueTextureExtraction(*LumaHistOut, &LumaHistoryRT);\n\n"
        ++ "\tFRDGTextureRef* ExposureTex = TextureCache.Find(TEXT(\"Exposure\"));\n"
        ++ "\tif (ExposureTex && *ExposureTex) GraphBuilder.QueueTextureExtraction(*ExposureTex, &AutoExposureRT);\n"
        ++ "}\n\n"
    );

    //фуинкция для выполнения compute pass
    try w.writeAll(
        "void FTSSRuntime::ExecuteComputePass(FRDGBuilder& GraphBuilder, const FString& PassName, const FString& ShaderName, TArray<FRDGTextureRef>& Inputs, TArray<FString>& OutputNames, TArray<FRDGTextureRef>& OutputTexs, TArray<FRDGTextureUAV*>& OutputUAVs, FIntPoint DispatchSize, int32 GroupSizeX, bool bLog)\n"
        ++ "{\n"
        ++ "\tRDG_EVENT_SCOPE(GraphBuilder, \"TSS_BPlus_%s\", *PassName);\n"
        ++ "\tFBPlusShaderParams* Params = GraphBuilder.AllocParameters<FBPlusShaderParams>();\n"
        ++ "\t// ... input/output binding ...\n"
        ++ "\tFIntVector GroupCount = FComputeShaderUtils::GetGroupCount(DispatchSize, GroupSizeX);\n"
        ++ "#define TSS_DISPATCH_CASE(Name, ShaderClass) \\\n"
        ++ "\tif (ShaderName == TEXT(Name)) { \\\n"
        ++ "\t\tTShaderMapRef<ShaderClass> Shader_(GetGlobalShaderMap(GMaxRHIFeatureLevel)); \\\n"
        ++ "\t\tGraphBuilder.AddPass( \\\n"
        ++ "\t\t\tRDG_EVENT_NAME(\"BPlus_%s\", *ShaderName), \\\n"
        ++ "\t\t\tParams, ERDGPassFlags::Compute, \\\n"
        ++ "\t\t\t[Shader_, Params, GroupCount](FRHIComputeCommandList& Cmd) \\\n"
        ++ "\t\t\t{ \\\n"
        ++ "\t\t\t\tFComputeShaderUtils::Dispatch(Cmd, Shader_, *Params, GroupCount); \\\n"
        ++ "\t\t\t}); \\\n"
        ++ "\t} else\n\n"
    );

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (pipeline.passes) |pass| {
        if (seen.contains(pass.shader)) continue;
        try seen.put(pass.shader, {});
        const cls = try toPascalCase(allocator, pass.shader);
        defer allocator.free(cls);
        try w.writeAll("\tTSS_DISPATCH_CASE(\"");
        try w.writeAll(pass.shader);
        try w.writeAll("\", FTSSShader_");
        try w.writeAll(cls);
        try w.writeAll(")\n");
    }
    try w.writeAll(
        "\t{\n"
        ++ "\t\tUE_LOG(LogTemp, Fatal, TEXT(\"TSS: No shader for '%s'\"), *ShaderName);\n"
        ++ "\t}\n"
        ++ "#undef TSS_DISPATCH_CASE\n"
        ++ "}\n"
    );

    return try buf.toOwnedSlice();
}

pub fn generateViewExtensionHeader(allocator: std.mem.Allocator, pipeline: *const Pipeline) ![]const u8 {
    _ = pipeline;
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();
    try w.writeAll(
        "#pragma once\n\n"
        ++ "#include \"CoreMinimal.h\"\n"
        ++ "#include \"SceneViewExtension.h\"\n\n"
        ++ "struct FPostProcessingInputs;\n"
        ++ "class FTSSRuntime;\n\n"
        ++ "class FTSSViewExtension : public FSceneViewExtensionBase\n"
        ++ "{\n"
        ++ "public:\n"
        ++ "\tFTSSViewExtension(const FAutoRegister& AutoRegister);\n"
        ++ "\tvirtual ~FTSSViewExtension();\n\n"
        ++ "\tvirtual void SetupViewFamily(FSceneViewFamily& InViewFamily) override {}\n"
        ++ "\tvirtual void SetupView(FSceneViewFamily& InViewFamily, FSceneView& InView) override {}\n"
        ++ "\tvirtual void BeginRenderViewFamily(FSceneViewFamily& InViewFamily) override {}\n"
        ++ "\tvirtual void PreRenderView_RenderThread(FRDGBuilder& GraphBuilder, FSceneView& InView) override;\n"
        ++ "\tvirtual void PreRenderViewFamily_RenderThread(FRDGBuilder& GraphBuilder, FSceneViewFamily& InViewFamily) override {}\n"
        ++ "\tvirtual void PrePostProcessPass_RenderThread(FRDGBuilder& GraphBuilder, const FSceneView& View, const FPostProcessingInputs& Inputs) override;\n"
        ++ "\tvirtual void PostRenderView_RenderThread(FRDGBuilder& GraphBuilder, FSceneView& View) override;\n"
        ++ "\tvirtual bool IsActiveThisFrame_Internal(const FSceneViewExtensionContext& Context) const override { return true; }\n\n"
        ++ "public:\n"
        ++ "\tfloat GetDownscaleFactor() const;\n"
        ++ "\tvoid SetDownscaleFactor(float Factor);\n\n"
        ++ "private:\n"
        ++ "\tstatic float Halton(int32 Index, int32 Base);\n\n"
        ++ "private:\n"
        ++ "\tFTSSRuntime* Runtime = nullptr;\n"
        ++ "\tfloat DownscaleFactor = 1.0f;\n"
        ++ "\tFMatrix44f PrevFrameWorldToClip = FMatrix44f(EForceInit::ForceInitToZero);\n"
        ++ "\tbool bUsePrevFrame = false;\n"
        ++ "\tint32 JitterFrameIndex = 0;\n"
        ++ "\tFVector2f CurrentJitter = FVector2f(0, 0);\n"
        ++ "\tFVector2f PreviousJitter = FVector2f(0, 0);\n"
        ++ "\tFRDGTextureRef LastViewFamilyOutput = nullptr;\n"
        ++ "};\n"
    );
    return try buf.toOwnedSlice();
}

pub fn generateViewExtensionCpp(allocator: std.mem.Allocator, pipeline: *const Pipeline) ![]const u8 {
    _ = pipeline;
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    try w.writeAll(
        "#include \"TSSViewExtension.h\"\n"
        ++ "#include \"PostProcess/PostProcessing.h\"\n"
        ++ "#include \"TSSRuntime.h\"\n"
        ++ "#include \"TSSShaders.h\"\n"
        ++ "#include \"Misc/Paths.h\"\n\n"
        ++ "static TAutoConsoleVariable<float> CVarTSSDownscale(\n"
        ++ "\tTEXT(\"r.TSS.DownscaleFactor\"),\n"
        ++ "\t1.0f,\n"
        ++ "\tTEXT(\"TSS render resolution scale (0.1-1.0). 1.0 = full res, 0.5 = half res.\"),\n"
        ++ "\tECVF_RenderThreadSafe\n"
        ++ ");\n\n"
        ++ "static TAutoConsoleVariable<float> CVarTSSJitter(\n"
        ++ "\tTEXT(\"r.TSS.JitterStrength\"),\n"
        ++ "\t1.0f,\n"
        ++ "\tTEXT(\"TSS jitter amplitude (0.0=no jitter, 1.0=full pixel).\"),\n"
        ++ "\tECVF_RenderThreadSafe\n"
        ++ ");\n\n"
        ++ "FTSSViewExtension::FTSSViewExtension(const FAutoRegister& AutoRegister)\n"
        ++ "\t: FSceneViewExtensionBase(AutoRegister)\n"
        ++ "{\n"
        ++ "\tRuntime = new FTSSRuntime();\n"
        ++ "}\n\n"
        ++ "FTSSViewExtension::~FTSSViewExtension()\n"
        ++ "{\n"
        ++ "\tdelete Runtime;\n"
        ++ "}\n\n"
        ++ "float FTSSViewExtension::Halton(int32 Index, int32 Base)\n"
        ++ "{\n"
        ++ "\tfloat Result = 0.0f;\n"
        ++ "\tfloat InvBase = 1.0f / Base;\n"
        ++ "\tfloat Fraction = InvBase;\n"
        ++ "\twhile (Index > 0)\n"
        ++ "\t{\n"
        ++ "\t\tResult += (float)(Index % Base) * Fraction;\n"
        ++ "\t\tIndex /= Base;\n"
        ++ "\t\tFraction *= InvBase;\n"
        ++ "\t}\n"
        ++ "\treturn Result;\n"
        ++ "}\n\n"
        ++ "void FTSSViewExtension::PreRenderView_RenderThread(FRDGBuilder& GraphBuilder, FSceneView& View)\n"
        ++ "{\n"
        ++ "\tfloat Downscale = CVarTSSDownscale.GetValueOnRenderThread();\n"
        ++ "\tif (Downscale < SMALL_NUMBER) return;\n"
        ++ "\tfloat JitterStrength = CVarTSSJitter.GetValueOnRenderThread();\n"
        ++ "\tif (JitterStrength < SMALL_NUMBER) return;\n"
        ++ "\tFIntPoint ViewSize = View.UnscaledViewRect.Size();\n"
        ++ "\tif (ViewSize.X < 1 || ViewSize.Y < 1) return;\n"
        ++ "\tPreviousJitter = CurrentJitter;\n"
        ++ "\tfloat DisplayJitter = 0.5f * JitterStrength;\n"
        ++ "\tfloat RenderJitter = Downscale >= 1.0f ? DisplayJitter / Downscale : DisplayJitter * Downscale;\n"
        ++ "\tfloat JitterX = (Halton(JitterFrameIndex, 2) - 0.5f) * RenderJitter;\n"
        ++ "\tfloat JitterY = (Halton(JitterFrameIndex, 3) - 0.5f) * RenderJitter;\n"
        ++ "\tCurrentJitter = FVector2f(JitterX, JitterY);\n"
        ++ "\t{\n"
        ++ "\t\tFMatrix& ProjMat = const_cast<FMatrix&>(View.ViewMatrices.GetProjectionMatrix());\n"
        ++ "\t\tfloat InvWidth = 2.0f / ViewSize.X;\n"
        ++ "\t\tfloat InvHeight = 2.0f / ViewSize.Y;\n"
        ++ "\t\tProjMat.M[2][0] += JitterX * InvWidth;\n"
        ++ "\t\tProjMat.M[2][1] += JitterY * InvHeight;\n"
        ++ "\t}\n"
        ++ "\t{\n"
        ++ "\t\tFMatrix& ViewProjMat = const_cast<FMatrix&>(View.ViewMatrices.GetViewProjectionMatrix());\n"
        ++ "\t\tViewProjMat = View.ViewMatrices.GetViewMatrix() * View.ViewMatrices.GetProjectionMatrix();\n"
        ++ "\t}\n"
        ++ "\t{\n"
        ++ "\t\tFMatrix& InvViewProjMat = const_cast<FMatrix&>(View.ViewMatrices.GetInvViewProjectionMatrix());\n"
        ++ "\t\tInvViewProjMat = View.ViewMatrices.GetViewProjectionMatrix().Inverse();\n"
        ++ "\t}\n"
        ++ "\tJitterFrameIndex++;\n"
        ++ "}\n\n"
        ++ "void FTSSViewExtension::PrePostProcessPass_RenderThread(\n"
        ++ "\tFRDGBuilder& GraphBuilder,\n"
        ++ "\tconst FSceneView& View,\n"
        ++ "\tconst FPostProcessingInputs& Inputs)\n"
        ++ "{\n"
        ++ "\tInputs.Validate();\n"
        ++ "\tFRDGTextureRef SceneColor = (*Inputs.SceneTextures)->SceneColorTexture;\n"
        ++ "\tFRDGTextureRef ViewFamilyOutput = Inputs.ViewFamilyTexture;\n"
        ++ "\tif (!SceneColor || !ViewFamilyOutput || !Runtime) return;\n"
        ++ "\tFRDGTextureRef Velocity = (*Inputs.SceneTextures)->GBufferVelocityTexture;\n"
        ++ "\tFRDGTextureRef Depth = (*Inputs.SceneTextures)->SceneDepthTexture;\n"
        ++ "\tFIntPoint DisplaySize = ViewFamilyOutput->Desc.Extent;\n"
        ++ "\tfloat Downscale = CVarTSSDownscale.GetValueOnRenderThread();\n"
        ++ "\tFVector4f PrevVP0(EForceInit::ForceInitToZero), PrevVP1(EForceInit::ForceInitToZero), PrevVP2(EForceInit::ForceInitToZero), PrevVP3(EForceInit::ForceInitToZero);\n"
        ++ "\tFVector4f CurrInvVP0(EForceInit::ForceInitToZero), CurrInvVP1(EForceInit::ForceInitToZero), CurrInvVP2(EForceInit::ForceInitToZero), CurrInvVP3(EForceInit::ForceInitToZero);\n"
        ++ "\tif (bUsePrevFrame)\n"
        ++ "\t{\n"
        ++ "\t\tFMatrix44f CurrInvVP = FMatrix44f(View.ViewMatrices.GetInvViewProjectionMatrix());\n"
        ++ "\t\tCurrInvVP0 = FVector4f(CurrInvVP.M[0][0], CurrInvVP.M[0][1], CurrInvVP.M[0][2], CurrInvVP.M[0][3]);\n"
        ++ "\t\tCurrInvVP1 = FVector4f(CurrInvVP.M[1][0], CurrInvVP.M[1][1], CurrInvVP.M[1][2], CurrInvVP.M[1][3]);\n"
        ++ "\t\tCurrInvVP2 = FVector4f(CurrInvVP.M[2][0], CurrInvVP.M[2][1], CurrInvVP.M[2][2], CurrInvVP.M[2][3]);\n"
        ++ "\t\tCurrInvVP3 = FVector4f(CurrInvVP.M[3][0], CurrInvVP.M[3][1], CurrInvVP.M[3][2], CurrInvVP.M[3][3]);\n"
        ++ "\t\tFMatrix44f PrevVP = PrevFrameWorldToClip;\n"
        ++ "\t\tPrevVP0 = FVector4f(PrevVP.M[0][0], PrevVP.M[0][1], PrevVP.M[0][2], PrevVP.M[0][3]);\n"
        ++ "\t\tPrevVP1 = FVector4f(PrevVP.M[1][0], PrevVP.M[1][1], PrevVP.M[1][2], PrevVP.M[1][3]);\n"
        ++ "\t\tPrevVP2 = FVector4f(PrevVP.M[2][0], PrevVP.M[2][1], PrevVP.M[2][2], PrevVP.M[2][3]);\n"
        ++ "\t\tPrevVP3 = FVector4f(PrevVP.M[3][0], PrevVP.M[3][1], PrevVP.M[3][2], PrevVP.M[3][3]);\n"
        ++ "\t}\n"
        ++ "\tLastViewFamilyOutput = ViewFamilyOutput;\n"
        ++ "\tRuntime->ExecutePlan(GraphBuilder, SceneColor, ViewFamilyOutput, Velocity, Depth, DisplaySize, Downscale, PrevVP0, PrevVP1, PrevVP2, PrevVP3, CurrInvVP0, CurrInvVP1, CurrInvVP2, CurrInvVP3, bUsePrevFrame);\n"
        ++ "\tPrevFrameWorldToClip = FMatrix44f(View.ViewMatrices.GetViewProjectionMatrix());\n"
        ++ "\tbUsePrevFrame = true;\n"
        ++ "}\n\n"
        ++ "float FTSSViewExtension::GetDownscaleFactor() const { return DownscaleFactor; }\n\n"
        ++ "void FTSSViewExtension::SetDownscaleFactor(float Factor) { DownscaleFactor = FMath::Clamp(Factor, 0.25f, 1.0f); }\n\n"
        ++ "void FTSSViewExtension::PostRenderView_RenderThread(\n"
        ++ "\tFRDGBuilder& GraphBuilder,\n"
        ++ "\tFSceneView& View)\n"
        ++ "{\n"
        ++ "\tFRDGTextureRef TSSResult = Runtime->GetLastFinalOutput();\n"
        ++ "\tif (!TSSResult || !LastViewFamilyOutput)\n"
        ++ "\t{\n"
        ++ "\t\tUE_LOG(LogTemp, Warning, TEXT(\"TSS: PostRenderView skipped (no FinalOutput or ViewFamily)\"));\n"
        ++ "\t\treturn;\n"
        ++ "\t}\n"
        ++ "\tif (TSSResult->Desc.Extent == LastViewFamilyOutput->Desc.Extent && TSSResult->Desc.Format == LastViewFamilyOutput->Desc.Format)\n"
        ++ "\t{\n"
        ++ "\t\tAddCopyTexturePass(GraphBuilder, TSSResult, LastViewFamilyOutput);\n"
        ++ "\t}\n"
        ++ "\telse\n"
        ++ "\t{\n"
        ++ "\t\tFRDGTextureRef CopyDst = LastViewFamilyOutput;\n"
        ++ "\t\tbool bHasUAV = EnumHasAnyFlags(LastViewFamilyOutput->Desc.Flags, TexCreate_UAV);\n"
        ++ "\t\tif (!bHasUAV)\n"
        ++ "\t\t{\n"
        ++ "\t\t\tCopyDst = GraphBuilder.CreateTexture(\n"
        ++ "\t\t\t\tFRDGTextureDesc::Create2D(LastViewFamilyOutput->Desc.Extent, LastViewFamilyOutput->Desc.Format,\n"
        ++ "\t\t\t\t\tFClearValueBinding::None,\n"
        ++ "\t\t\t\t\tTexCreate_UAV | TexCreate_ShaderResource),\n"
        ++ "\t\t\t\tTEXT(\"TSS_PostRender_CopyDst\"));\n"
        ++ "\t\t}\n"
        ++ "\t\tTShaderMapRef<FTSSShader_Copy> CopyShader(GetGlobalShaderMap(GMaxRHIFeatureLevel));\n"
        ++ "\t\tFBPlusShaderParams* CParams = GraphBuilder.AllocParameters<FBPlusShaderParams>();\n"
        ++ "\t\tCParams->Input0 = TSSResult;\n"
        ++ "\t\tCParams->Output0 = GraphBuilder.CreateUAV(CopyDst);\n"
        ++ "\t\tCParams->InputSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();\n"
        ++ "\t\tFIntVector GroupCount = FComputeShaderUtils::GetGroupCount(LastViewFamilyOutput->Desc.Extent, 8);\n"
        ++ "\t\tGraphBuilder.AddPass(\n"
        ++ "\t\t\tRDG_EVENT_NAME(\"TSS_PostRenderCopy\"),\n"
        ++ "\t\t\tCParams, ERDGPassFlags::Compute,\n"
        ++ "\t\t\t[CopyShader, CParams, GroupCount](FRHIComputeCommandList& Cmd)\n"
        ++ "\t\t\t{\n"
        ++ "\t\t\t\tFComputeShaderUtils::Dispatch(Cmd, CopyShader, *CParams, GroupCount);\n"
        ++ "\t\t\t});\n"
        ++ "\t\tif (!bHasUAV)\n"
        ++ "\t\t{\n"
        ++ "\t\t\tAddCopyTexturePass(GraphBuilder, CopyDst, LastViewFamilyOutput);\n"
        ++ "\t\t}\n"
        ++ "\t}\n"
        ++ "}\n"
    );

    return try buf.toOwnedSlice();
}

fn writePersistentInit(w: anytype, allocator: std.mem.Allocator, pipeline: *const Pipeline, tex_name: []const u8, rt_field: []const u8, size_expr: []const u8, _: []const u8, debug_name: []const u8) !void {
    _ = allocator;
    _ = pipeline;
    const init_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_Init", .{debug_name});
    defer std.heap.page_allocator.free(init_name);
    try w.writeAll("\tif (");
    try w.writeAll(rt_field);
    try w.writeAll("RT.IsValid() && bCacheValid && !bIsNative)\n");
    try w.writeAll("\t{\n");
    try w.writeAll("\t\tFRDGTextureRef ");
    try w.writeAll(tex_name);
    try w.writeAll("Tex = GraphBuilder.RegisterExternalTexture(");
    try w.writeAll(rt_field);
    try w.writeAll("RT, TEXT(\"");
    try w.writeAll(debug_name);
    try w.writeAll("\"));\n");
    try w.writeAll("\t\tTextureCache.Add(TEXT(\"");
    try w.writeAll(tex_name);
    try w.writeAll("\"), ");
    try w.writeAll(tex_name);
    try w.writeAll("Tex);\n");
    try w.writeAll("\t}\n");
    try w.writeAll("\telse\n");
    try w.writeAll("\t{\n");
    try w.writeAll("\t\tFRDGTextureRef Init");
    try w.writeAll(tex_name);
    try w.writeAll(" = GraphBuilder.CreateTexture(\n");
    try w.writeAll("\t\t\tFRDGTextureDesc::Create2D(");
    try w.writeAll(tex_name);
    try w.writeAll(", ");
    try w.writeAll(size_expr);
    try w.writeAll(",\n");
    try w.writeAll("\t\t\t\tFClearValueBinding::None,\n");
    try w.writeAll("\t\t\t\tTexCreate_UAV | TexCreate_ShaderResource),\n");
    try w.writeAll("\t\t\tTEXT(\"");
    try w.writeAll(init_name);
    try w.writeAll("\"));\n");
    try w.writeAll("\t\tTextureCache.Add(TEXT(\"");
    try w.writeAll(tex_name);
    try w.writeAll("\"), Init");
    try w.writeAll(tex_name);
    try w.writeAll(");\n");
    try w.writeAll("\t}\n\n");
}
