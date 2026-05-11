using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class LlvmGenerator : ICodeGenerator
{
    public string GetLanguageName() => "LLVM";
    public string GetFileExtension() => ".ll";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var files = new Dictionary<string, string>();
        var ll = new LlvmIrBuilder();

        foreach (var k in program.Kernels)
            EmitKernel(ll, k);

        foreach (var e in program.Entries)
            EmitEntry(ll, e);

        files.Add("kernels.ll", ll.ToString());

        if (program.Kernels.Count > 0)
        {
            var names = program.Kernels.Select(k => $"kernel_{k.Name}").ToList();
            files.Add("BPlusBridge.cs", BridgeGenerator.GenCSharp(names));
            files.Add("bplus_bridge.py", BridgeGenerator.GenPython(names));
        }

        return files;
    }

    private void EmitKernel(LlvmIrBuilder ll, KernelDecl k)
    {
        int h = GetImageDim(k.Parameters.FirstOrDefault()?.Type, "H", 1080);
        int w = GetImageDim(k.Parameters.FirstOrDefault()?.Type, "W", 1920);
        int totalPixels = h * w * 4;

        var pars = new List<string>();
        foreach (var p in k.Parameters) pars.Add($"ptr %{p.Name}");
        if (k.OutputParam != null) pars.Add($"ptr %{k.OutputParam.Name}");

        ll.Line($"; Kernel: {k.Name}");
        ll.Line($"; Image: {w}x{h}x4 = {totalPixels} pixels");
        ll.Line($"; Pipeline: {Describe(k.Body)}");
        foreach (var a in k.Annotations)
            ll.Line($"; @{a.Name}({string.Join(" ", a.Args.Select(kv => $"{kv.Key}={kv.Value}"))})");

        ll.Line($"define void @kernel_{k.Name}({string.Join(", ", pars)}) {{");
        ll.Indent();
        ll.Line("entry:");

        var src = k.Parameters.Count > 0 ? k.Parameters[0].Name : "src";
        var dst = k.OutputParam?.Name ?? "out";
        ll.Line($"  %sp = load ptr, ptr %{src}");
        ll.Line($"  %dp = load ptr, ptr %{dst}");
        ll.Line($"  %b0 = alloca float, i64 {totalPixels}");
        ll.Line($"  %b1 = alloca float, i64 {totalPixels}");
        ll.Line($"  call void @llvm.memcpy.p0.p0.i64(ptr %b0, ptr %sp, i64 {totalPixels * 4}, i1 false)");

        if (k.Body != null)
            EmitPipeline(ll, k.Body, totalPixels, h, w, k.OutputParam != null ? dst : null);
        else
            ll.Line($"  call void @llvm.memcpy.p0.p0.i64(ptr %dp, ptr %b0, i64 {totalPixels * 4}, i1 false)");

        ll.Line("  ret void");
        ll.Dedent();
        ll.Line("}");
        ll.Line("");
    }

    private void EmitPipeline(LlvmIrBuilder ll, PipelineExpr pipe, long total, int h, int w, string? dst)
    {
        bool readB0 = true;
        int idx = 0;
        int n = pipe.Operations.Count;
        string lastBuf = "b0";

        ll.Line("  br label %op0");

        foreach (var op in pipe.Operations)
        {
            var inBuf = readB0 ? "b0" : "b1";
            var outBuf = readB0 ? "b1" : "b0";
            lastBuf = outBuf;
            bool last = idx == n - 1;
            EmitOp(ll, op, idx, total, h, w, inBuf, outBuf, last);
            readB0 = !readB0;
            idx++;
        }

        if (dst != null)
            ll.Line($"  call void @llvm.memcpy.p0.p0.i64(ptr %dp, ptr %{lastBuf}, i64 {total * 4}, i1 false)");
    }

    private void EmitOp(LlvmIrBuilder ll, PipelineOp op, int idx, long total,
                        int h, int w, string inBuf, string outBuf, bool last)
    {
        string loop = $"lop{idx}", body = $"lbd{idx}", done = $"ldn{idx}";
        string from = idx == 0 ? "entry" : $"ldn{idx - 1}";

        ll.Line($"  ; {op.Name}({string.Join(", ", op.Args)})");
        ll.Line($"{loop}:");
        ll.Line($"  %i{idx} = phi i64 [ 0, %{from} ], [ %j{idx}, %{body} ]");
        ll.Line($"  %cx{idx} = icmp slt i64 %i{idx}, {total}");
        ll.Line($"  br i1 %cx{idx}, label %{body}, label %{done}");
        ll.Line($"{body}:");
        ll.Line($"  %a{idx} = getelementptr float, ptr %{inBuf}, i64 %i{idx}");
        ll.Line($"  %v{idx} = load float, ptr %a{idx}");

        // Operation body
        switch (op.Name)
        {
            case "relu":
                ll.Line($"  %t{idx} = fcmp olt float %v{idx}, 0.0");
                ll.Line($"  %w{idx} = select i1 %t{idx}, float 0.0, float %v{idx}");
                break;
            case "clamp":
                string lo = op.Args.Count > 0 ? op.Args[0] : "0.0";
                string hi = op.Args.Count > 1 ? op.Args[1] : "1.0";
                ll.Line($"  %l{idx} = fcmp olt float %v{idx}, {lo}");
                ll.Line($"  %s{idx} = select i1 %l{idx}, float {lo}, float %v{idx}");
                ll.Line($"  %x{idx} = fcmp ogt float %s{idx}, {hi}");
                ll.Line($"  %w{idx} = select i1 %x{idx}, float {hi}, float %s{idx}");
                break;
            case "convolve":
                ll.Line($"  %m{idx} = sub i64 %i{idx}, 1");
                ll.Line($"  %p{idx} = add i64 %i{idx}, 1");
                ll.Line($"  %q{idx} = getelementptr float, ptr %{inBuf}, i64 %m{idx}");
                ll.Line($"  %r{idx} = getelementptr float, ptr %{inBuf}, i64 %p{idx}");
                ll.Line($"  %u{idx} = load float, ptr %q{idx}");
                ll.Line($"  %z{idx} = load float, ptr %r{idx}");
                ll.Line($"  %sa{idx} = fadd float %u{idx}, %v{idx}");
                ll.Line($"  %sb{idx} = fadd float %sa{idx}, %v{idx}");
                ll.Line($"  %sc{idx} = fadd float %sb{idx}, %z{idx}");
                ll.Line($"  %w{idx} = fdiv float %sc{idx}, 4.0");
                break;
            case "shuffle":
                // Passthrough (real spatial shuffle needs multiple output pixels per input)
                ll.Line($"  %w{idx} = fadd float %v{idx}, 0.0");
                break;
            default:
                ll.Line($"  %w{idx} = fadd float %v{idx}, 0.0");
                break;
        }

        ll.Line($"  %b{idx} = getelementptr float, ptr %{outBuf}, i64 %i{idx}");
        ll.Line($"  store float %w{idx}, ptr %b{idx}");
        ll.Line($"  %j{idx} = add i64 %i{idx}, 1");
        ll.Line($"  br label %{loop}");
        ll.Line($"{done}:");
        if (!last)
            ll.Line($"  br label %lop{idx + 1}");
        ll.Line("");
    }

    private void EmitEntry(LlvmIrBuilder ll, EntryDecl e)
    {
        ll.Line("define i32 @main() { entry: ret i32 0 }");
        ll.Line("");
    }

    private static string Describe(PipelineExpr? p)
    {
        if (p == null) return "none";
        return string.Join(" |> ", p.Operations.Select(o =>
            o.Args.Count > 0 ? $"{o.Name}({string.Join(",", o.Args)})" : o.Name));
    }

    private static int GetImageDim(BPlusType? t, string d, int f)
    {
        if (t is ImageType img)
            return d == "H" ? (int.TryParse(img.H, out var h) ? h : f)
                            : (int.TryParse(img.W, out var w) ? w : f);
        return f;
    }
}

// ─── BRIDGE GENERATOR ───────────────────────────────────────

internal static class BridgeGenerator
{
    public static string GenCSharp(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// B+ v2.1.3VS — P/Invoke bridge for Unity");
        sb.AppendLine("// Drop this into Assets/ alongside bplus_kernels.dll");
        sb.AppendLine("using System.Runtime.InteropServices;");
        sb.AppendLine("");
        sb.AppendLine("public static class BPlusBridge");
        sb.AppendLine("{");
        foreach (var k in kernels)
        {
            sb.AppendLine($"    [DllImport(\"bplus_kernels\", CallingConvention = CallingConvention.Cdecl)]");
            sb.AppendLine($"    private static extern void {k}(System.IntPtr input, System.IntPtr output);");
            sb.AppendLine($"");
            sb.AppendLine($"    public static unsafe void {k}_safe(float[] input, float[] output)");
            sb.AppendLine($"    {{");
            sb.AppendLine($"        fixed (float* pIn = input, pOut = output)");
            sb.AppendLine($"            {k}((System.IntPtr)pIn, (System.IntPtr)pOut);");
            sb.AppendLine($"    }}");
        }
        sb.AppendLine("}");
        return sb.ToString();
    }

    public static string GenPython(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("# B+ v2.1.3VS — Python bridge (ctypes + numpy)");
        sb.AppendLine("import ctypes, numpy as np, os");
        sb.AppendLine("");
        sb.AppendLine("_dll = None");
        sb.AppendLine("for _name in ['bplus_kernels.dll', 'libbplus_kernels.so', 'bplus_kernels.dylib']:");
        sb.AppendLine("    _p = os.path.join(os.path.dirname(__file__), _name)");
        sb.AppendLine("    if os.path.exists(_p): _dll = ctypes.CDLL(_p); break");
        sb.AppendLine("");
        foreach (var k in kernels)
        {
            sb.AppendLine($"_{k} = _dll.{k} if _dll else None");
            sb.AppendLine($"if _{k}: _{k}.argtypes = [ctypes.c_void_p, ctypes.c_void_p]; _{k}.restype = None");
            sb.AppendLine($"");
            sb.AppendLine($"def {k}(input: np.ndarray, output: np.ndarray):");
            sb.AppendLine($"    _{k}(input.ctypes.data, output.ctypes.data)");
            sb.AppendLine($"");
        }
        return sb.ToString();
    }
}

internal class LlvmIrBuilder
{
    private readonly List<string> _lines = new();
    private int _indent;

    public void Line(string l) => _lines.Add(new string(' ', _indent * 2) + l);
    public void Indent() => _indent++;
    public void Dedent() => _indent = Math.Max(0, _indent - 1);

    public override string ToString()
    {
        var h = @"; ModuleID = 'bplus_module'
source_filename = ""bplus.bp""
target datalayout = ""e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128""
target triple = ""x86_64-pc-windows-msvc""

declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)

";
        return h + string.Join("\n", _lines);
    }
}
