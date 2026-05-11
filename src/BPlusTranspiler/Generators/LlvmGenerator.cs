using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class LlvmGenerator : ICodeGenerator
{
    private string _prevBlock = "entry";

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
        return files;
    }

    private void EmitKernel(LlvmIrBuilder ll, KernelDecl k)
    {
        _prevBlock = "entry";

        var paramList = new List<string>();
        foreach (var p in k.Parameters)
            paramList.Add($"ptr %{p.Name}");
        if (k.OutputParam != null)
            paramList.Add($"ptr %{k.OutputParam.Name}");

        ll.Line($"; Kernel: {k.Name}");
        ll.Line($"; Pipeline: {DescribePipeline(k.Body)}");
        foreach (var a in k.Annotations)
            ll.Line($"; @{a.Name}({string.Join(", ", a.Args.Select(kv => $"{kv.Key}={kv.Value}"))})");

        ll.Line($"define void @kernel_{k.Name}({string.Join(", ", paramList)}) {{");
        ll.Indent();
        ll.Line("entry:");

        var srcName = k.Parameters.Count > 0 ? k.Parameters[0].Name : "src";
        var dstName = k.OutputParam?.Name ?? "out";
        ll.Line($"  %{srcName}_p = load ptr, ptr %{srcName}");
        ll.Line($"  %{dstName}_p = load ptr, ptr %{dstName}");

        var hVal = GetImageDim(k.Parameters.FirstOrDefault()?.Type, "H", 1080);
        var wVal = GetImageDim(k.Parameters.FirstOrDefault()?.Type, "W", 1920);
        var totalPixels = hVal * wVal * 4;

        ll.Line($"  %buf0 = alloca float, i64 {totalPixels}");
        ll.Line($"  %buf1 = alloca float, i64 {totalPixels}");
        ll.Line($"  call void @llvm.memcpy.p0.p0.i64(ptr %buf0, ptr %{srcName}_p, i64 {totalPixels * 4}, i1 false)");
        ll.Line($"  br label %op_0");
        ll.Line("");

        if (k.Body != null)
        {
            int idx = 0;
            int count = k.Body.Operations.Count;
            bool readBuf0 = true; // data starts in buf0
            string lastOutBuf = "buf0";
            foreach (var op in k.Body.Operations)
            {
                var inBuf = readBuf0 ? "buf0" : "buf1";
                var outBuf = readBuf0 ? "buf1" : "buf0";
                lastOutBuf = outBuf;
                bool isLast = idx == count - 1;
                EmitLoopOp(ll, op, idx, totalPixels, inBuf, outBuf, isLast);
                readBuf0 = !readBuf0;
                idx++;
            }
            ll.Line($"  call void @llvm.memcpy.p0.p0.i64(ptr %{dstName}_p, ptr %{lastOutBuf}, i64 {totalPixels * 4}, i1 false)");
        }

        ll.Line("  ret void");
        ll.Dedent();
        ll.Line("}");
        ll.Line("");
    }

    private void EmitLoopOp(LlvmIrBuilder ll, PipelineOp op, int idx, long totalPixels, string inBuf, string outBuf, bool isLast)
    {
        var loopLabel = $"op_{idx}_loop";
        var bodyLabel = $"op_{idx}_body";
        var doneLabel = $"op_{idx}_done";
        var fromBlock = idx == 0 ? "entry" : $"op_{idx - 1}_done";

        ll.Line($"  ; {op.Name}({string.Join(", ", op.Args)})");
        ll.Line($"{loopLabel}:");
        ll.Line($"  %i{idx} = phi i64 [ 0, %{fromBlock} ], [ %n{idx}, %{bodyLabel} ]");
        ll.Line($"  %c{idx} = icmp slt i64 %i{idx}, {totalPixels}");
        ll.Line($"  br i1 %c{idx}, label %{bodyLabel}, label %{doneLabel}");
        ll.Line("");

        ll.Line($"{bodyLabel}:");
        ll.Line($"  %p{idx} = getelementptr float, ptr %{inBuf}, i64 %i{idx}");
        ll.Line($"  %v{idx} = load float, ptr %p{idx}");

        switch (op.Name)
        {
            case "relu":
                ll.Line($"  %z{idx} = fcmp olt float %v{idx}, 0.0");
                ll.Line($"  %r{idx} = select i1 %z{idx}, float 0.0, float %v{idx}");
                ll.Line($"  %w{idx} = fadd float %r{idx}, 0.0");
                break;
            case "clamp":
                var lo = op.Args.Count > 0 ? op.Args[0] : "0.0";
                var hi = op.Args.Count > 1 ? op.Args[1] : "1.0";
                ll.Line($"  %l{idx} = fcmp olt float %v{idx}, {lo}");
                ll.Line($"  %s{idx} = select i1 %l{idx}, float {lo}, float %v{idx}");
                ll.Line($"  %h{idx} = fcmp ogt float %s{idx}, {hi}");
                ll.Line($"  %w{idx} = select i1 %h{idx}, float {hi}, float %s{idx}");
                break;
            case "convolve":
                ll.Line($"  ; 3x3 box blur: (prev + 2*cur + next) / 4");
                ll.Line($"  %a{idx} = sub i64 %i{idx}, 1");
                ll.Line($"  %b{idx} = add i64 %i{idx}, 1");
                ll.Line($"  %pa{idx} = getelementptr float, ptr %{inBuf}, i64 %a{idx}");
                ll.Line($"  %pb{idx} = getelementptr float, ptr %{inBuf}, i64 %b{idx}");
                ll.Line($"  %va{idx} = load float, ptr %pa{idx}");
                ll.Line($"  %vb{idx} = load float, ptr %pb{idx}");
                ll.Line($"  %s1{idx} = fadd float %va{idx}, %v{idx}");
                ll.Line($"  %s2{idx} = fadd float %s1{idx}, %v{idx}");
                ll.Line($"  %s3{idx} = fadd float %s2{idx}, %vb{idx}");
                ll.Line($"  %w{idx} = fdiv float %s3{idx}, 4.0");
                break;
            case "shuffle":
                ll.Line($"  ; pixel shuffle passthrough");
                ll.Line($"  %w{idx} = fadd float %v{idx}, 0.0");
                break;
            default:
                ll.Line($"  %w{idx} = fadd float %v{idx}, 0.0");
                break;
        }

        ll.Line($"  %o{idx} = getelementptr float, ptr %{outBuf}, i64 %i{idx}");
        ll.Line($"  store float %w{idx}, ptr %o{idx}");
        ll.Line($"  %n{idx} = add i64 %i{idx}, 1");
        ll.Line($"  br label %{loopLabel}");
        ll.Line("");

        ll.Line($"{doneLabel}:");
        if (!isLast)
            ll.Line($"  br label %op_{idx + 1}_loop");
        ll.Line("");
    }

    private void EmitEntry(LlvmIrBuilder ll, EntryDecl e)
    {
        ll.Line("define i32 @main() {");
        ll.Indent();
        ll.Line("entry:");
        ll.Line("  ret i32 0");
        ll.Dedent();
        ll.Line("}");
        ll.Line("");
    }

    private string DescribePipeline(PipelineExpr? body)
    {
        if (body == null) return "none";
        var ops = string.Join(" |> ", body.Operations.Select(o =>
            o.Args.Count > 0 ? $"{o.Name}({string.Join(", ", o.Args)})" : o.Name));
        return $"{body.Source} |> {ops}";
    }

    private static int GetImageDim(BPlusType? type, string dim, int fallback)
    {
        if (type is ImageType img)
            return dim == "H" ? (int.TryParse(img.H, out var h) ? h : fallback)
                               : (int.TryParse(img.W, out var w) ? w : fallback);
        return fallback;
    }
}

internal class LlvmIrBuilder
{
    private readonly List<string> _lines = new();
    private int _indent;

    public void Line(string line) => _lines.Add(new string(' ', _indent * 2) + line);
    public void Indent() => _indent++;
    public void Dedent() => _indent = Math.Max(0, _indent - 1);
    public override string ToString()
    {
        var header = @"; ModuleID = 'bplus_module'
source_filename = ""bplus.bp""
target datalayout = ""e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128""
target triple = ""x86_64-pc-windows-msvc""

declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)

";
        return header + string.Join("\n", _lines);
    }
}
