using System.Text;
using BPlus.Core.Ast;

namespace BPlus.Targets.Generators;

public class GlslGenerator : ICodeGenerator
{
    readonly string _arch;
    int _labelId;

    public GlslGenerator(string arch = "auto")
    {
        _arch = arch;
    }

    public string GetLanguageName() => "GLSL";

    public string GetFileExtension() => ".comp";

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
            sb.AppendLine("#extension GL_NV_cooperative_matrix : enable");
            sb.AppendLine("#extension GL_NV_integral_cooperative_matrix : enable");
            sb.AppendLine("// NVIDIA Tensor Core WMMA (m16n16k16)");
            sb.AppendLine("// coopmat<float, gl_ScopeSubgroup, 16, 16, gl_MatrixUseA> mat_a;");
            sb.AppendLine("// coopmat<float, gl_ScopeSubgroup, 16, 16, gl_MatrixUseB> mat_b;");
            sb.AppendLine("// coopmat<float, gl_ScopeSubgroup, 16, 16, gl_MatrixUseAccumulator> mat_c;");
            sb.AppendLine("// mat_c = coopMatrixMulAddNV(mat_a, mat_b, mat_c);");
            sb.AppendLine("#define BPLUS_TENSOR_NVIDIA 1");
        }
        if (_arch is "amd" or "auto")
        {
            sb.AppendLine("// AMD CDNA MFMA — via SPIR-V extended instructions");
            sb.AppendLine("// Requires: VK_KHR_shader_float_controls");
            sb.AppendLine("// asm (\"v_mfma_f32_16x16x4f64 %0, %1, %2, %3\" : \"=v\"(c) : \"v\"(a), \"v\"(b), \"v\"(c));");
            sb.AppendLine("#define BPLUS_TENSOR_AMD 1");
        }
        if (_arch is "intel" or "auto")
        {
            sb.AppendLine("// Intel XMX (Xe Matrix Extensions) — via VK_INTEL_*");
            sb.AppendLine("// https://github.com/intel/vulkan-samples");
            sb.AppendLine("#define BPLUS_TENSOR_INTEL 1");
        }
        return sb.ToString();
    }

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var files = new Dictionary<string, string>();
        var sb = new StringBuilder();

        sb.AppendLine("#version 460 core");
        sb.AppendLine();
        sb.AppendLine("// B+ v2.5.0GH — Auto-generated GLSL (SPIR-V) compute shaders");
        sb.AppendLine($"// Arch: {_arch}, work group: {LocalSize.x}x{LocalSize.y}x1");
        sb.AppendLine();

        bool hasTensor = _arch is "nvidia" or "amd" or "intel" or "auto";
        if (hasTensor)
        {
            sb.Append(TensorDeclarations());
            sb.AppendLine();
        }

        int binding = 0;
        foreach (var k in program.Kernels)
        {
            bool gpu = k.Annotations.Any(a => a.Name == "region" &&
                         a.Args.GetValueOrDefault("_val") is "frame" or "scene");
            if (!gpu) continue;

            var srcParam = k.Parameters.Count > 0 ? k.Parameters[0].Name : "src";
            var dstParam = k.OutputParam?.Name ?? "out";

            sb.AppendLine($"layout(local_size_x = {LocalSize.x}, local_size_y = {LocalSize.y}, local_size_z = 1) in;");
            sb.AppendLine($"layout(std430, binding = {binding++}) buffer buf_src {{ float {srcParam}[]; }};");
            sb.AppendLine($"layout(std430, binding = {binding++}) buffer buf_dst {{ float {dstParam}[]; }};");
            sb.AppendLine();

            EmitKernel(sb, k);
            sb.AppendLine();
        }

        // v4.0: ComputeShaderDecl
        if (program.ComputeShaders.Count > 0)
        {
            foreach (var cs in program.ComputeShaders)
            {
                GenComputeShaderGlsl(sb, cs);
                sb.AppendLine();
            }
        }

        // v4.0: FragmentShaderDecl
        if (program.FragmentShaders.Count > 0)
        {
            foreach (var fs in program.FragmentShaders)
            {
                GenFragmentShaderGlsl(sb, fs);
                sb.AppendLine();
            }
        }

        // v4.0: VertexShaderDecl
        if (program.VertexShaders.Count > 0)
        {
            foreach (var vs in program.VertexShaders)
            {
                GenVertexShaderGlsl(sb, vs);
                sb.AppendLine();
            }
        }

        // v4.0: RayTracingShaderDecl
        if (program.RayTracingShaders.Count > 0)
        {
            foreach (var rt in program.RayTracingShaders)
            {
                GenRayTracingShaderGlsl(sb, rt);
                sb.AppendLine();
            }
        }

        // v4.0: LocalGroupDecl
        if (program.LocalGroups.Count > 0)
        {
            foreach (var lg in program.LocalGroups)
            {
                GenLocalGroupGlsl(sb, lg);
                sb.AppendLine();
            }
        }

        files.Add("shaders.comp", sb.ToString());

        // Compile script
        var bat = new StringBuilder();
        bat.AppendLine("@echo off");
        bat.AppendLine("rem B+ v2.5.0GH — Compile GLSL to SPIR-V");
        bat.AppendLine("rem Requires: glslangValidator.exe (from Vulkan SDK)");
        bat.AppendLine();
        bat.AppendLine("glslangValidator -V shaders.comp -o shaders.spv");
        bat.AppendLine("echo Done.");
        files.Add("compile_spirv.bat", bat.ToString());

        return files;
    }

    void GenComputeShaderGlsl(StringBuilder sb, ComputeShaderDecl cs)
    {
        sb.AppendLine($"// ComputeShader: {cs.Name}");
        sb.AppendLine($"layout(local_size_x = {cs.GroupSizeX}, local_size_y = {cs.GroupSizeY}, local_size_z = {cs.GroupSizeZ}) in;");
        sb.AppendLine($"void main() {{ // {cs.Name}");
        sb.AppendLine("}");
    }

    void GenFragmentShaderGlsl(StringBuilder sb, FragmentShaderDecl fs)
    {
        sb.AppendLine($"// FragmentShader: {fs.Name}");
        sb.AppendLine("layout(location = 0) out vec4 fragColor;");
        sb.AppendLine($"void main() {{ fragColor = vec4(1,0,1,1); // {fs.Name}");
        sb.AppendLine("}");
    }

    void GenVertexShaderGlsl(StringBuilder sb, VertexShaderDecl vs)
    {
        sb.AppendLine($"// VertexShader: {vs.Name}");
        sb.AppendLine($"void main() {{ gl_Position = vec4(0); // {vs.Name}");
        sb.AppendLine("}");
    }

    void GenRayTracingShaderGlsl(StringBuilder sb, RayTracingShaderDecl rt)
    {
        sb.AppendLine($"// RayTracingShader: {rt.Name}");
        sb.AppendLine($"// MaxRecursionDepth: {rt.MaxRecursionDepth}");
        sb.AppendLine($"void main() {{ // {rt.Name}");
        sb.AppendLine("}");
    }

    void GenLocalGroupGlsl(StringBuilder sb, LocalGroupDecl lg)
    {
        sb.AppendLine($"// LocalGroup: {lg.Name}");
        sb.AppendLine($"// Work group size: {lg.Width}x{lg.Height}");
        foreach (var sv in lg.SharedVariables)
            sb.AppendLine($"// shared {sv.Name}: {sv.SizeBytes} bytes");
    }

    void EmitKernel(StringBuilder sb, KernelDecl k)
    {
        int h = Dim(k.Parameters.FirstOrDefault()?.Type, "H", 1080);
        int w = Dim(k.Parameters.FirstOrDefault()?.Type, "W", 1920);
        int total = h * w * 4;

        var srcParam = k.Parameters.Count > 0 ? k.Parameters[0].Name : "src";
        var dstParam = k.OutputParam?.Name ?? "out";

        sb.AppendLine($"// Kernel: {k.Name}");
        sb.AppendLine($"// Image: {w}x{h}x4 = {total}px");
        sb.AppendLine($"// Pipeline: {Desc(k.Body)}");
        foreach (var a in k.Annotations)
            sb.AppendLine($"// @{a.Name}({string.Join(" ", a.Args.Select(kv => $"{kv.Key}={kv.Value}"))})");
        sb.AppendLine();

        sb.AppendLine("void main()");
        sb.AppendLine("{");
        sb.AppendLine("    uint gid = gl_GlobalInvocationID.x;");
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
                sb.AppendLine("    v = max(v, 0.0);");
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
                sb.AppendLine($"    ivec2 pos = ivec2(int(gid % {w}), int(gid / {w})) + ivec2({dx}, {dy});");
                sb.AppendLine($"    pos = clamp(pos, ivec2(0), ivec2({w - 1}, {h - 1}));");
                sb.AppendLine($"    uint warp_gid = uint(pos.y) * {w} + uint(pos.x);");
                sb.AppendLine($"    v = {src}[warp_gid];");
                break;
            }

            case "atomic_add":
                sb.AppendLine($"    atomicAdd({dst}[gid], v);");
                sb.AppendLine("    v = 0.0;");
                break;

            case "atomic_sub":
                sb.AppendLine($"    atomicAdd({dst}[gid], -v);");
                sb.AppendLine("    v = 0.0;");
                break;

            case "atomic_max":
                sb.AppendLine($"    v = floatBitsToInt(v);");
                sb.AppendLine($"    atomicMax({dst}[gid], v);");
                break;

            case "atomic_min":
                sb.AppendLine($"    v = floatBitsToInt(v);");
                sb.AppendLine($"    atomicMin({dst}[gid], v);");
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
        sb.AppendLine("    // 3x3 box blur");
        sb.AppendLine($"    uint px = gid / 4, ch = gid % 4;");
        sb.AppendLine($"    int x = int(px % {w}), y = int(px / {w});");
        sb.AppendLine("    float acc = v * 4.0;");
        sb.AppendLine($"    if (x > 0) acc += {src}[max(gid, 4) - 4] * 2.0; else acc += v * 2.0;");
        sb.AppendLine($"    if (x < {w - 1}) acc += {src}[min(gid + 4, {h * w * 4 - 1})] * 2.0; else acc += v * 2.0;");
        sb.AppendLine($"    if (y > 0) acc += {src}[max(gid, {w * 4}) - {w * 4}] * 2.0; else acc += v * 2.0;");
        sb.AppendLine($"    if (y < {h - 1}) acc += {src}[min(gid + {w * 4}, {h * w * 4 - 1})] * 2.0; else acc += v * 2.0;");
        sb.AppendLine($"    if (x > 0 && y > 0) acc += {src}[max(gid, {w * 4 + 4}) - {w * 4} - 4];");
        sb.AppendLine($"    if (x < {w - 1} && y > 0) acc += {src}[max(gid, {w * 4 + 4}) - {w * 4} + 4];");
        sb.AppendLine($"    if (x > 0 && y < {h - 1}) acc += {src}[min(gid + {w * 4} - 4, {h * w * 4 - 1})];");
        sb.AppendLine($"    if (x < {w - 1} && y < {h - 1}) acc += {src}[min(gid + {w * 4} + 4, {h * w * 4 - 1})];");
        sb.AppendLine("    v = acc / 16.0;");
    }

    void EmitShuffle(StringBuilder sb, int h, int w, string dst)
    {
        int outW = w * 2;
        sb.AppendLine("    // ESPCN pixel shuffle 2x");
        sb.AppendLine($"    uint px = gid / 4, ch = gid % 4;");
        sb.AppendLine($"    int in_x = int(px % {w}), in_y = int(px / {w});");
        sb.AppendLine("    int dy = int(ch / 2), dx = int(ch % 2);");
        sb.AppendLine($"    int out_x = in_x * 2 + dx, out_y = in_y * 2 + dy;");
        sb.AppendLine($"    uint out_gid = uint(out_y) * {outW} + uint(out_x);");
        sb.AppendLine($"    {dst}[out_gid] = v;");
        sb.AppendLine("    v = v;");
    }

    void EmitIf(StringBuilder sb, PipelineOp op, int h, int w, int total, string src, string dst)
    {
        string threshold = op.Args.Count > 0 ? op.Args[0] : "0.0";
        int tid = _labelId++;
        sb.AppendLine($"    // if (v > {threshold})");
        sb.AppendLine($"    float saved_{tid} = v;");
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
        int tid = _labelId++;
        sb.AppendLine($"    // while (v > {threshold})");
        sb.AppendLine($"    while (v > {threshold})");
        sb.AppendLine("    {");
        if (op.NestedBody != null)
            foreach (var sub in op.NestedBody.Operations)
                EmitOp(sb, sub, h, w, total, src, dst);
        sb.AppendLine("    }");
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
