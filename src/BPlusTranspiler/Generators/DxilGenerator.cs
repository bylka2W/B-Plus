using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class DxilGenerator : ICodeGenerator
{
    readonly string _arch;
    int _labelId;

    public DxilGenerator(string arch = "auto")
    {
        _arch = arch;
    }

    public string GetLanguageName() => "DXIL";

    public string GetFileExtension() => ".hlsl";

    (int x, int y) LocalSize => _arch switch
    {
        "nvidia" => (16, 16),
        "amd"    => (16, 8),
        "intel"  => (16, 16),
        "apple"  => (8, 8),
        _        => (16, 16)
    };

    string TensorDeclarations()
    {
        var sb = new StringBuilder();
        if (_arch is "nvidia" or "auto")
        {
            sb.AppendLine("// NVIDIA Tensor Core WMMA (SM 6.6+)");
            sb.AppendLine("// #pragma wave_matrix");
            sb.AppendLine("// WaveMatrix<int4x4> mat_a, mat_b;");
            sb.AppendLine("// WaveMatrix_Multiply(mat_c, mat_a, mat_b);");
            sb.AppendLine("// WaveMatrix_Store(dst, mat_c, stride);");
            sb.AppendLine("#define BPLUS_TENSOR_NVIDIA 1");
        }
        if (_arch is "amd" or "auto")
        {
            sb.AppendLine("// AMD CDNA MFMA — via inline ASM or AGS");
            sb.AppendLine("// asm { ds_mfma_f32_16x16x4f64 acc[0:3], mat_a[0:3], mat_b[0:3], acc[0:3] };");
            sb.AppendLine("#define BPLUS_TENSOR_AMD 1");
        }
        if (_arch is "intel" or "auto")
        {
            sb.AppendLine("// Intel XMX (Xe Matrix Extensions) — via DPC++ or AOT");
            sb.AppendLine("#define BPLUS_TENSOR_INTEL 1");
        }
        return sb.ToString();
    }

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var files = new Dictionary<string, string>();
        var sb = new StringBuilder();

        sb.AppendLine("// B+ v2.5.0GH — Auto-generated HLSL (DXIL) compute shaders");
        sb.AppendLine($"// Arch: {_arch}, work group: {LocalSize.x}x{LocalSize.y}x1");
        sb.AppendLine("// Compile: dxc -T cs_6_6 -E <entry> -Fo output.dxil shaders.hlsl");
        sb.AppendLine();

        // Common macros
        sb.AppendLine("#ifndef BPLUS_DXIL");
        sb.AppendLine("#define BPLUS_DXIL 1");
        sb.AppendLine("#endif");
        sb.AppendLine();

        bool hasTensor = _arch is "nvidia" or "amd" or "intel" or "auto";
        if (hasTensor)
            sb.AppendLine(TensorDeclarations());

        int kernelIdx = 0;
        foreach (var k in program.Kernels)
        {
            bool gpu = k.Annotations.Any(a => a.Name == "region" &&
                         a.Args.GetValueOrDefault("_val") is "frame" or "scene");
            if (!gpu) continue;

            EmitKernel(sb, k, kernelIdx++);
            sb.AppendLine();
        }

        // v4.0: ComputeShaderDecl
        if (program.ComputeShaders.Count > 0)
        {
            foreach (var cs in program.ComputeShaders)
            {
                GenComputeShader(sb, cs);
                sb.AppendLine();
            }
        }

        // v4.0: FragmentShaderDecl
        if (program.FragmentShaders.Count > 0)
        {
            foreach (var fs in program.FragmentShaders)
            {
                GenFragmentShader(sb, fs);
                sb.AppendLine();
            }
        }

        // v4.0: VertexShaderDecl
        if (program.VertexShaders.Count > 0)
        {
            foreach (var vs in program.VertexShaders)
            {
                GenVertexShader(sb, vs);
                sb.AppendLine();
            }
        }

        // v4.0: RayTracingShaderDecl
        if (program.RayTracingShaders.Count > 0)
        {
            foreach (var rt in program.RayTracingShaders)
            {
                GenRayTracingShader(sb, rt);
                sb.AppendLine();
            }
        }

        files.Add("shaders.hlsl", sb.ToString());

        // Compile batch script
        var bat = new StringBuilder();
        bat.AppendLine("@echo off");
        bat.AppendLine("rem B+ v2.5.0GH — Compile HLSL to DXIL");
        bat.AppendLine("rem Requires: dxc.exe (DirectX Shader Compiler) from Windows SDK");
        bat.AppendLine("rem   https://github.com/microsoft/DirectXShaderCompiler");
        bat.AppendLine();
        kernelIdx = 0;
        foreach (var k in program.Kernels)
        {
            bool gpu = k.Annotations.Any(a => a.Name == "region" &&
                         a.Args.GetValueOrDefault("_val") is "frame" or "scene");
            if (!gpu) continue;
            bat.AppendLine($"dxc -T cs_6_6 -E kernel_{k.Name} -Fo kernel_{k.Name}.dxil shaders.hlsl");
            kernelIdx++;
        }
        bat.AppendLine("echo DXIL compilation complete.");
        files.Add("compile_dxil.bat", bat.ToString());

        return files;
    }

    void GenComputeShader(StringBuilder sb, ComputeShaderDecl cs)
    {
        sb.AppendLine($"// ComputeShader: {cs.Name}");
        sb.AppendLine($"// Threads: ({cs.ThreadsX}, {cs.ThreadsY}, {cs.ThreadsZ})");
        sb.AppendLine($"// GroupSize: ({cs.GroupSizeX}, {cs.GroupSizeY}, {cs.GroupSizeZ})");
        if (cs.AutoDiff) sb.AppendLine("// AutoDiff enabled");
        sb.AppendLine();

        foreach (var r in cs.Resources)
            sb.AppendLine($"RWStructuredBuffer<float> {r.Name} : register(u{r.Register});");

        sb.AppendLine();
        sb.AppendLine($"[numthreads({cs.GroupSizeX}, {cs.GroupSizeY}, {cs.GroupSizeZ})]");
        sb.AppendLine($"void cs_{cs.Name}(uint3 id : SV_DispatchThreadID)");
        sb.AppendLine("{");
        sb.AppendLine($"    // Compute shader body for {cs.Name}");
        sb.AppendLine("}");
    }

    void GenFragmentShader(StringBuilder sb, FragmentShaderDecl fs)
    {
        sb.AppendLine($"// FragmentShader: {fs.Name}");
        if (fs.EarlyDepthStencil) sb.AppendLine("// EarlyDepthStencil: true");
        if (fs.AlphaToCoverage) sb.AppendLine("// AlphaToCoverage: true");
        sb.AppendLine();

        foreach (var r in fs.Resources)
            sb.AppendLine($"Texture2D<float4> {r.Name} : register(t{r.Register});");

        sb.AppendLine("struct PS_INPUT { float4 pos : SV_POSITION; };");
        sb.AppendLine($"float4 ps_{fs.Name}(PS_INPUT input) : SV_Target");
        sb.AppendLine("{");
        sb.AppendLine($"    return float4(1,0,1,1); // placeholder for {fs.Name}");
        sb.AppendLine("}");
    }

    void GenVertexShader(StringBuilder sb, VertexShaderDecl vs)
    {
        sb.AppendLine($"// VertexShader: {vs.Name}");
        if (!string.IsNullOrEmpty(vs.InputLayout))
            sb.AppendLine($"// InputLayout: {vs.InputLayout}");
        sb.AppendLine();

        foreach (var r in vs.Resources)
            sb.AppendLine($"cbuffer {r.Name} : register(b{r.Register}) {{ }};");

        sb.AppendLine($"struct VS_OUTPUT {{ float4 pos : SV_POSITION; }};");
        sb.AppendLine($"VS_OUTPUT vs_{vs.Name}(float3 pos : POSITION)");
        sb.AppendLine("{");
        sb.AppendLine("    VS_OUTPUT o;");
        sb.AppendLine("    o.pos = float4(pos, 1.0);");
        sb.AppendLine("    return o;");
        sb.AppendLine("}");
    }

    void GenRayTracingShader(StringBuilder sb, RayTracingShaderDecl rt)
    {
        sb.AppendLine($"// RayTracingShader: {rt.Name}");
        sb.AppendLine($"// MaxRecursionDepth: {rt.MaxRecursionDepth}");
        sb.AppendLine();

        foreach (var r in rt.Resources)
            sb.AppendLine($"RaytracingAccelerationStructure {r.Name} : register(u{r.Register});");

        sb.AppendLine($"void rt_{rt.Name}()");
        sb.AppendLine("{");
        sb.AppendLine($"    // Ray tracing shader for {rt.Name}");
        sb.AppendLine("}");
    }

    void EmitKernel(StringBuilder sb, KernelDecl k, int idx)
    {
        int h = Dim(k.Parameters.FirstOrDefault()?.Type, "H", 1080);
        int w = Dim(k.Parameters.FirstOrDefault()?.Type, "W", 1920);
        int total = h * w * 4;

        var srcParam = k.Parameters.Count > 0 ? k.Parameters[0].Name : "src";
        var dstParam = k.OutputParam?.Name ?? "out";

        bool needsConvolve = k.Body != null && k.Body.Operations.Any(o => o.Name == "convolve");

        sb.AppendLine($"// Kernel: {k.Name}");
        sb.AppendLine($"// Image: {w}x{h}x4 = {total}px");
        sb.AppendLine($"// Pipeline: {Desc(k.Body)}");
        foreach (var a in k.Annotations)
            sb.AppendLine($"// @{a.Name}({string.Join(" ", a.Args.Select(kv => $"{kv.Key}={kv.Value}"))})");
        sb.AppendLine();

        // Buffer declarations — each kernel gets its own binding pair
        int bind = idx * 2;
        sb.AppendLine($"RWStructuredBuffer<float> {srcParam} : register(u{bind});");
        sb.AppendLine($"RWStructuredBuffer<float> {dstParam} : register(u{bind + 1});");
        if (needsConvolve)
        {
            var (ppw, tileStride, tileSize) = TileParams();
            sb.AppendLine($"groupshared float tile_sm[{tileSize}];");
        }
        sb.AppendLine();

        sb.AppendLine($"[numthreads({LocalSize.x}, {LocalSize.y}, 1)]");
        sb.AppendLine($"void kernel_{k.Name}(uint3 id : SV_DispatchThreadID)");
        sb.AppendLine("{");

        sb.AppendLine($"    uint gid = id.x + id.y * {w};");
        sb.AppendLine($"    if (gid >= {total}) return;");
        sb.AppendLine();

        sb.AppendLine($"    float v = {srcParam}[gid];");

        if (k.Body != null)
            foreach (var op in k.Body.Operations)
                EmitOp(sb, op, h, w, total, srcParam, dstParam);

        sb.AppendLine();
        sb.AppendLine($"    {dstParam}[gid] = v;");
        sb.AppendLine("}");
    }

    void EmitOp(StringBuilder sb, PipelineOp op, int h, int w, int total, string src, string dst)
    {
        switch (op.Name)
        {
            case "relu":
                sb.AppendLine("    v = max(0.0, v);");
                break;

            case "clamp":
            {
                string lo = op.Args.Count > 0 ? op.Args[0] : "0.0";
                string hi = op.Args.Count > 1 ? op.Args[1] : "1.0";
                sb.AppendLine($"    v = clamp(v, {lo}, {hi});");
                break;
            }

            case "convolve":
                EmitConvolve(sb, h, w, src);
                break;

            case "shuffle":
                EmitShuffle(sb, h, w, dst);
                break;

            case "motion_vectors":
            {
                string refFrame = op.Args.Count > 0 ? op.Args[0] : src;
                sb.AppendLine($"    float ref = {refFrame}[gid];");
                sb.AppendLine("    v = abs(v - ref);");
                break;
            }

            case "warp":
            {
                string dx = op.Args.Count > 0 ? op.Args[0] : "0";
                string dy = op.Args.Count > 1 ? op.Args[1] : "0";
                sb.AppendLine($"    int2 pos = int2(gid % {w}, gid / {w}) + int2({dx}, {dy});");
                sb.AppendLine($"    pos = clamp(pos, int2(0, 0), int2({w - 1}, {h - 1}));");
                sb.AppendLine($"    uint warp_gid = pos.y * {w} + pos.x;");
                sb.AppendLine($"    v = {src}[warp_gid];");
                break;
            }

            case "atomic_add":
                sb.AppendLine($"    InterlockedAdd({dst}[gid], asuint(v));");
                sb.AppendLine("    v = 0.0;");
                break;

            case "atomic_sub":
                sb.AppendLine($"    InterlockedAdd({dst}[gid], -asuint(v));");
                sb.AppendLine("    v = 0.0;");
                break;

            case "atomic_max":
                sb.AppendLine($"    InterlockedMax({dst}[gid], asuint(v));");
                sb.AppendLine("    v = 0.0;");
                break;

            case "atomic_min":
                sb.AppendLine($"    InterlockedMin({dst}[gid], asuint(v));");
                sb.AppendLine("    v = 0.0;");
                break;

            case "if":
                EmitIf(sb, op, h, w, total, src, dst);
                break;

            case "for":
                EmitFor(sb, op, h, w, total, src, dst);
                break;

            case "while":
                EmitWhile(sb, op, h, w, total, src, dst);
                break;

            default:
                sb.AppendLine($"    // {op.Name}({string.Join(", ", op.Args)}) — stub");
                break;
        }
    }

    void EmitConvolve(StringBuilder sb, int h, int w, string src)
    {
        sb.AppendLine("    // 3x3 box blur (bilateral clamped)");
        sb.AppendLine($"    uint px = gid / 4;");
        sb.AppendLine($"    uint ch = gid % 4;");
        sb.AppendLine($"    int x = px % {w};");
        sb.AppendLine($"    int y = px / {w};");
        sb.AppendLine("    float acc = v * 4.0;");

        // Cardinal neighbors (×2)
        sb.AppendLine($"    if (x > 0)   {{ uint n = gid - 4;            acc += {src}[n] * 2.0; }} else acc += v * 2.0;");
        sb.AppendLine($"    if (x < {w - 1}) {{ uint n = gid + 4;            acc += {src}[n] * 2.0; }} else acc += v * 2.0;");
        sb.AppendLine($"    if (y > 0)   {{ uint n = gid - {w * 4};        acc += {src}[n] * 2.0; }} else acc += v * 2.0;");
        sb.AppendLine($"    if (y < {h - 1}) {{ uint n = gid + {w * 4};        acc += {src}[n] * 2.0; }} else acc += v * 2.0;");

        // Diagonal neighbors (×1)
        sb.AppendLine($"    if (x > 0 && y > 0)     {{ uint n = gid - {w * 4} - 4; acc += {src}[n]; }}");
        sb.AppendLine($"    if (x < {w - 1} && y > 0) {{ uint n = gid - {w * 4} + 4; acc += {src}[n]; }}");
        sb.AppendLine($"    if (x > 0 && y < {h - 1})   {{ uint n = gid + {w * 4} - 4; acc += {src}[n]; }}");
        sb.AppendLine($"    if (x < {w - 1} && y < {h - 1}) {{ uint n = gid + {w * 4} + 4; acc += {src}[n]; }}");

        sb.AppendLine("    v = acc / 16.0;");
    }

    void EmitShuffle(StringBuilder sb, int h, int w, string dst)
    {
        int outW = w * 2;
        sb.AppendLine("    // ESPCN pixel shuffle 2x");
        sb.AppendLine($"    uint px = gid / 4;");
        sb.AppendLine($"    uint ch = gid % 4;");
        sb.AppendLine($"    int in_x = px % {w};");
        sb.AppendLine($"    int in_y = px / {w};");
        sb.AppendLine("    int dy = ch / 2;");
        sb.AppendLine("    int dx = ch % 2;");
        sb.AppendLine($"    int out_x = in_x * 2 + dx;");
        sb.AppendLine($"    int out_y = in_y * 2 + dy;");
        sb.AppendLine($"    uint out_gid = out_y * {outW} + out_x;");
        sb.AppendLine($"    {dst}[out_gid] = v;");
    }

    void EmitIf(StringBuilder sb, PipelineOp op, int h, int w, int total, string src, string dst)
    {
        string threshold = op.Args.Count > 0 ? op.Args[0] : "0.0";
        int tid = _labelId++;
        sb.AppendLine($"    // if (v > {threshold})");
        sb.AppendLine($"    float saved_{tid} = v;");
        sb.AppendLine($"    [branch]");
        sb.AppendLine($"    if (v > {threshold})");
        sb.AppendLine("    {");
        if (op.NestedBody != null)
            foreach (var sub in op.NestedBody.Operations)
                EmitOp(sb, sub, h, w, total, src, dst);
        else
            sb.AppendLine($"        v = saved_{tid};");
        sb.AppendLine("    }");
        sb.AppendLine("    else");
        sb.AppendLine("    {");
        if (op.ElseBody != null)
            foreach (var sub in op.ElseBody.Operations)
                EmitOp(sb, sub, h, w, total, src, dst);
        else
            sb.AppendLine($"        v = saved_{tid};");
        sb.AppendLine("    }");
    }

    void EmitFor(StringBuilder sb, PipelineOp op, int h, int w, int total, string src, string dst)
    {
        string iterations = op.Args.Count > 0 ? op.Args[0] : "1";
        if (!int.TryParse(iterations, out int n)) n = 1;
        sb.AppendLine($"    // for loop: {n} iterations (unrolled)");
        for (int i = 0; i < n; i++)
        {
            sb.AppendLine($"    // iteration {i}");
            if (op.NestedBody != null)
                foreach (var sub in op.NestedBody.Operations)
                    EmitOp(sb, sub, h, w, total, src, dst);
        }
    }

    void EmitWhile(StringBuilder sb, PipelineOp op, int h, int w, int total, string src, string dst)
    {
        string threshold = op.Args.Count > 0 ? op.Args[0] : "0.0";
        sb.AppendLine($"    // while (v > {threshold})");
        sb.AppendLine($"    [loop]");
        sb.AppendLine($"    while (v > {threshold})");
        sb.AppendLine("    {");
        if (op.NestedBody != null)
            foreach (var sub in op.NestedBody.Operations)
                EmitOp(sb, sub, h, w, total, src, dst);
        sb.AppendLine("    }");
    }

    (int ppw, int tileStride, int tileSize) TileParams()
    {
        int ppw = (LocalSize.x * LocalSize.y) / 4;
        int tileStride = ppw + 2;
        int tileSize = 3 * tileStride * 4;
        return (ppw, tileStride, tileSize);
    }

    static string Desc(PipelineExpr? p)
    {
        if (p == null) return "none";
        return string.Join(" |> ", p.Operations.Select(o =>
            o.Args.Count > 0 ? $"{o.Name}({string.Join(",", o.Args)})" : o.Name));
    }

    static int Dim(BPlusType? t, string d, int f) =>
        t is ImageType img && int.TryParse(d == "H" ? img.H : img.W, out var v) ? v : f;
}
