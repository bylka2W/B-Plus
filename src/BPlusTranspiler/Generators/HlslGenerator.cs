using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class HlslGenerator : ICodeGenerator
{
    readonly string _arch;
    int _labelId;

    public HlslGenerator(string arch = "auto")
    {
        _arch = arch;
    }

    public string GetLanguageName() => "HLSL";

    public string GetFileExtension() => ".hlsl";

    (int x, int y) LocalSize => _arch switch
    {
        "nvidia" => (16, 16),
        "amd"    => (16, 8),
        "intel"  => (16, 16),
        "apple"  => (8, 8),
        _        => (16, 16)
    };

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var files = new Dictionary<string, string>();
        var sb = new StringBuilder();

        sb.AppendLine("// B+ v2.5.0GH — Auto-generated HLSL (DXIL) compute shaders");
        sb.AppendLine($"// Arch: {_arch}, work group: {LocalSize.x}x{LocalSize.y}x1");
        sb.AppendLine();

        foreach (var k in program.Kernels)
        {
            EmitKernel(sb, k);
            sb.AppendLine();
        }

        files.Add("shaders.hlsl", sb.ToString());

        // Compile batch script for DXIL
        var bat = new StringBuilder();
        bat.AppendLine("@echo off");
        bat.AppendLine("rem B+ v2.5.0GH — Compile HLSL to DXIL");
        bat.AppendLine("rem Requires: dxc.exe (DirectX Shader Compiler)");
        bat.AppendLine();
        foreach (var k in program.Kernels)
        {
            bat.AppendLine($"dxc -T cs_6_6 -E kernel_{k.Name} -Fo kernel_{k.Name}.dxil shaders.hlsl");
        }
        bat.AppendLine("echo Done.");
        files.Add("compile_dxil.bat", bat.ToString());

        return files;
    }

    void EmitKernel(StringBuilder sb, KernelDecl k)
    {
        bool gpu = k.Annotations.Any(a => a.Name == "region" &&
                     a.Args.GetValueOrDefault("_val") is "frame" or "scene");

        if (!gpu) return;

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

        sb.AppendLine($"[numthreads({LocalSize.x}, {LocalSize.y}, 1)]");
        sb.AppendLine($"void kernel_{k.Name}(uint3 id : SV_DispatchThreadID)");
        sb.AppendLine("{");

        int gi = 0;

        sb.AppendLine($"    uint gid = id.x + id.y * {w};");
        sb.AppendLine($"    if (gid >= {total}) return;");
        sb.AppendLine();

        sb.AppendLine($"    float v = {srcParam}[gid];");

        if (k.Body != null)
            foreach (var op in k.Body.Operations)
                gi = EmitOp(sb, op, gi, h, w, total, srcParam, dstParam);

        sb.AppendLine();
        sb.AppendLine($"    {dstParam}[gid] = v;");
        sb.AppendLine("}");
    }

    int EmitOp(StringBuilder sb, PipelineOp op, int gi, int h, int w, int total, string src, string dst)
    {
        switch (op.Name)
        {
            case "relu":
                sb.AppendLine("    v = max(0.0, v);");
                return gi;

            case "clamp":
            {
                string lo = op.Args.Count > 0 ? op.Args[0] : "0.0";
                string hi = op.Args.Count > 1 ? op.Args[1] : "1.0";
                sb.AppendLine($"    v = clamp(v, {lo}, {hi});");
                return gi;
            }

            case "convolve":
                return EmitConvolve(sb, gi, h, w, src);

            case "shuffle":
                return EmitShuffle(sb, gi, h, w, dst);

            case "motion_vectors":
            {
                string refFrame = op.Args.Count > 0 ? op.Args[0] : src;
                sb.AppendLine($"    float ref = {refFrame}[gid];");
                sb.AppendLine("    v = abs(v - ref);");
                return gi;
            }

            case "warp":
            {
                string dx = op.Args.Count > 0 ? op.Args[0] : "0";
                string dy = op.Args.Count > 1 ? op.Args[1] : "0";
                sb.AppendLine($"    int2 pos = int2(gid % {w}, gid / {w}) + int2({dx}, {dy});");
                sb.AppendLine($"    pos = clamp(pos, int2(0, 0), int2({w - 1}, {h - 1}));");
                sb.AppendLine($"    uint warp_gid = pos.y * {w} + pos.x;");
                sb.AppendLine($"    v = {src}[warp_gid];");
                return gi;
            }

            case "atomic_add":
                sb.AppendLine($"    InterlockedAdd({dst}[gid], asuint(v));");
                sb.AppendLine("    v = 0;");
                return gi;

            case "atomic_sub":
                sb.AppendLine($"    InterlockedAdd({dst}[gid], -asuint(v));");
                sb.AppendLine("    v = 0;");
                return gi;

            case "atomic_max":
                sb.AppendLine($"    InterlockedMax({dst}[gid], asuint(v));");
                sb.AppendLine("    v = 0;");
                return gi;

            case "atomic_min":
                sb.AppendLine($"    InterlockedMin({dst}[gid], asuint(v));");
                sb.AppendLine("    v = 0;");
                return gi;

            case "if":
                return EmitIf(sb, op, gi, h, w, total, src, dst);

            case "for":
                return EmitFor(sb, op, gi, h, w, total, src, dst);

            case "while":
                return EmitWhile(sb, op, gi, h, w, total, src, dst);

            default:
                sb.AppendLine($"    // {op.Name}({string.Join(", ", op.Args)}) — stub");
                return gi;
        }
    }

    int EmitConvolve(StringBuilder sb, int gi, int h, int w, string src)
    {
        sb.AppendLine("    // 3x3 convolution");
        sb.AppendLine($"    uint px = gid / 4, ch = gid % 4;");
        sb.AppendLine($"    int x = px % {w}, y = px / {w};");
        sb.AppendLine("    float acc = v * 4.0;");
        sb.AppendLine("    // cardinal neighbors (x2)");
        sb.AppendLine($"    if (x > 0) acc += {src}[max(gid - 4, 0)] * 2.0; else acc += v * 2.0;");
        sb.AppendLine($"    if (x < {w - 1}) acc += {src}[min(gid + 4, {h * w * 4 - 1})] * 2.0; else acc += v * 2.0;");
        sb.AppendLine($"    if (y > 0) acc += {src}[max(gid - {w * 4}, 0)] * 2.0; else acc += v * 2.0;");
        sb.AppendLine($"    if (y < {h - 1}) acc += {src}[min(gid + {w * 4}, {h * w * 4 - 1})] * 2.0; else acc += v * 2.0;");
        sb.AppendLine("    // diagonal neighbors (x1)");
        sb.AppendLine($"    if (x > 0 && y > 0) acc += {src}[max(gid - {w * 4} - 4, 0)];");
        sb.AppendLine($"    if (x < {w - 1} && y > 0) acc += {src}[max(gid - {w * 4} + 4, 0)];");
        sb.AppendLine($"    if (x > 0 && y < {h - 1}) acc += {src}[min(gid + {w * 4} - 4, {h * w * 4 - 1})];");
        sb.AppendLine($"    if (x < {w - 1} && y < {h - 1}) acc += {src}[min(gid + {w * 4} + 4, {h * w * 4 - 1})];");
        sb.AppendLine("    v = acc / 16.0;");
        return gi;
    }

    int EmitShuffle(StringBuilder sb, int gi, int h, int w, string dst)
    {
        int outW = w * 2;
        sb.AppendLine("    // ESPCN pixel shuffle 2x");
        sb.AppendLine($"    uint px = gid / 4, ch = gid % 4;");
        sb.AppendLine($"    int in_x = px % {w}, in_y = px / {w};");
        sb.AppendLine("    int dy = ch / 2, dx = ch % 2;");
        sb.AppendLine($"    int out_x = in_x * 2 + dx, out_y = in_y * 2 + dy;");
        sb.AppendLine($"    uint out_gid = out_y * {outW} + out_x;");
        sb.AppendLine($"    {dst}[out_gid] = v;");
        sb.AppendLine("    // shuffle: value passes through (but is also stored above)");
        sb.AppendLine("    v = v;");
        return gi;
    }

    int EmitIf(StringBuilder sb, PipelineOp op, int gi, int h, int w, int total, string src, string dst)
    {
        string threshold = op.Args.Count > 0 ? op.Args[0] : "0.0";
        int tid = _labelId++;
        sb.AppendLine($"    // if (v > {threshold})");
        sb.AppendLine($"    float saved_{tid} = v;");
        sb.AppendLine($"    if (v > {threshold})");
        sb.AppendLine("    {");
        if (op.NestedBody != null)
            foreach (var sub in op.NestedBody.Operations)
                gi = EmitOp(sb, sub, gi, h, w, total, src, dst);
        else
            sb.AppendLine("        v = saved_{tid};");
        sb.AppendLine("    }");
        sb.AppendLine("    else");
        sb.AppendLine("    {");
        if (op.ElseBody != null)
            foreach (var sub in op.ElseBody.Operations)
                gi = EmitOp(sb, sub, gi, h, w, total, src, dst);
        else
            sb.AppendLine("        v = saved_{tid};");
        sb.AppendLine("    }");
        return gi;
    }

    int EmitFor(StringBuilder sb, PipelineOp op, int gi, int h, int w, int total, string src, string dst)
    {
        string iterations = op.Args.Count > 0 ? op.Args[0] : "1";
        if (!int.TryParse(iterations, out int n)) n = 1;
        sb.AppendLine($"    // for loop: {n} iterations (unrolled)");
        for (int i = 0; i < n; i++)
        {
            sb.AppendLine($"    // iteration {i}");
            if (op.NestedBody != null)
                foreach (var sub in op.NestedBody.Operations)
                    gi = EmitOp(sb, sub, gi, h, w, total, src, dst);
        }
        return gi;
    }

    int EmitWhile(StringBuilder sb, PipelineOp op, int gi, int h, int w, int total, string src, string dst)
    {
        string threshold = op.Args.Count > 0 ? op.Args[0] : "0.0";
        int tid = _labelId++;
        sb.AppendLine($"    // while (v > {threshold})");
        sb.AppendLine($"    [loop]");
        sb.AppendLine($"    while (v > {threshold})");
        sb.AppendLine("    {");
        if (op.NestedBody != null)
            foreach (var sub in op.NestedBody.Operations)
                gi = EmitOp(sb, sub, gi, h, w, total, src, dst);
        sb.AppendLine("    }");
        return gi;
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
