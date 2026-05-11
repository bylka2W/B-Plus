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
        return files;
    }

    private void EmitKernel(LlvmIrBuilder ll, KernelDecl k)
    {
        // Build function type: void(float* src, ..., float* dst)
        var paramList = new List<string>();
        foreach (var p in k.Parameters)
            paramList.Add($"ptr %{p.Name}");
        if (k.OutputParam != null)
            paramList.Add($"ptr %{k.OutputParam.Name}");

        ll.Line($"; Kernel: {k.Name}");
        ll.Line($"define void @kernel_{k.Name}({string.Join(", ", paramList)}) {{");
        ll.Indent();

        var entryName = k.Annotations.Any(a => a.Name == "region")
            ? $"region_{k.Annotations.First(a => a.Name == "region").Args.GetValueOrDefault("_val")}"
            : "entry";

        ll.Line($"{entryName}:");

        // Annotations as metadata
        foreach (var a in k.Annotations)
        {
            var args = string.Join(", ", a.Args.Select(kv => $"\"{kv.Key}\" : \"{kv.Value}\""));
            ll.Line($"  ; @{a.Name}({args})");
        }

        // Pipeline body: for now, simple copy
        if (k.Body != null && k.Parameters.Count > 0 && k.OutputParam != null)
        {
            var srcName = k.Parameters[0].Name;
            var dstName = k.OutputParam.Name;
            ll.Line($"  %{srcName}_ptr = load ptr, ptr %{srcName}");
            ll.Line($"  %{dstName}_ptr = load ptr, ptr %{dstName}");
            ll.Line($"  call void @llvm.memcpy.p0.p0.i64(ptr %{dstName}_ptr, ptr %{srcName}_ptr, i64 4096, i1 false)");
        }

        ll.Line("  ret void");
        ll.Dedent();
        ll.Line("}");
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
