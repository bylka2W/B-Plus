using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class LlvmGenerator : ICodeGenerator
{
    readonly string _platform;

    public LlvmGenerator(string platform = "native")
    {
        _platform = platform;
    }

    public string GetLanguageName() => _platform switch
    {
        "wasm" => "WASM",
        "arm64" or "ios" or "android" => "ARM64",
        _ => "LLVM"
    };

    public string GetFileExtension() => ".ll";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var files = new Dictionary<string, string>();
        var ll = new LlvmIrBuilder(_platform);

        foreach (var k in program.Kernels)
            EmitKernel(ll, k);
        foreach (var e in program.Entries)
            EmitEntry(ll, e);

        files.Add("kernels.ll", ll.ToString());

        if (program.Kernels.Count == 0) return files;

        var names = program.Kernels.Select(k => $"kernel_{k.Name}").ToList();

        files.Add("BPlusBridge.cs", Gen.CSharp(names));
        files.Add("bplus_bridge.py", Gen.Python(names));
        files.Add("bplus_bridge.h", Gen.C(names));
        files.Add("bplus_bridge.rs", Gen.Rust(names));
        files.Add("bplus_bridge_swift.swift", Gen.Swift(names));
        files.Add("bplus_bridge_kt.kt", Gen.Kotlin(names));

        return files;
    }

    void EmitKernel(LlvmIrBuilder ll, KernelDecl k)
    {
        int h = Dim(k.Parameters.FirstOrDefault()?.Type, "H", 1080);
        int w = Dim(k.Parameters.FirstOrDefault()?.Type, "W", 1920);
        int total = h * w * 4;

        bool gpu = k.Annotations.Any(a => a.Name == "region" &&
                     a.Args.GetValueOrDefault("_val") is "frame" or "scene");

        var pars = new List<string>();
        foreach (var p in k.Parameters) pars.Add($"ptr %{p.Name}");
        if (k.OutputParam != null) pars.Add($"ptr %{k.OutputParam.Name}");

        string cc = gpu ? "spir_kernel " : "";
        string attr = gpu ? " [nounwind]" : "";

        ll.Line($"; Kernel: {k.Name}");
        ll.Line($"; Image: {w}x{h}x4 = {total}px");
        ll.Line($"; Pipeline: {Desc(k.Body)}");
        foreach (var a in k.Annotations)
            ll.Line($"; @{a.Name}({string.Join(" ", a.Args.Select(kv => $"{kv.Key}={kv.Value}"))})");

        ll.Line($"define {cc}void @kernel_{k.Name}({string.Join(", ", pars)}){attr} {{");
        ll.Indent();
        ll.Line("entry:");

        var src = k.Parameters.Count > 0 ? k.Parameters[0].Name : "src";
        var dst = k.OutputParam?.Name ?? "out";

        if (gpu)
        {
            ll.GpuMode = true;
            ll.Line($"  %gid = call i64 @__bpc_global_id(i32 0)");
            ll.Line($"  %ok = icmp ult i64 %gid, {total}");
            ll.Line($"  br i1 %ok, label %work, label %exit");
            ll.Line("work:");
            ll.Line($"  %g0 = getelementptr float, ptr addrspace(1) %{src}, i64 %gid");
            ll.Line($"  %g1 = load float, ptr addrspace(1) %g0");
            int gi = 2;
            if (k.Body != null)
                foreach (var op in k.Body.Operations)
                {
                    var (code, next) = GpuOp(op, $"%g{gi - 1}", gi);
                    if (code != null) ll.Line(code);
                    gi = next;
                }
            ll.Line($"  %go = getelementptr float, ptr addrspace(1) %{dst}, i64 %gid");
            ll.Line($"  store float %g{gi - 1}, ptr addrspace(1) %go");
            ll.Line($"  br label %exit");
            ll.Line("exit:");
            ll.Line("  ret void");
            ll.Dedent();
            ll.Line("}");
            ll.Line("declare i64 @__bpc_global_id(i32) nounwind");
            ll.Line("");
            return;
        }

        ll.Line($"  %sp = load ptr, ptr %{src}");
        ll.Line($"  %dp = load ptr, ptr %{dst}");
        ll.Line($"  %b0 = alloca float, i64 {total}");
        ll.Line($"  %b1 = alloca float, i64 {total}");
        ll.Line($"  call void @llvm.memcpy.p0.p0.i64(ptr %b0, ptr %sp, i64 {total * 4}, i1 false)");
        ll.Line("  br label %op0");

        if (k.Body != null)
        {
            int idx = 0, n = k.Body.Operations.Count;
            bool useB0 = true;
            string last = "b0";
            foreach (var op in k.Body.Operations)
            {
                var ib = useB0 ? "b0" : "b1";
                var ob = useB0 ? "b1" : "b0";
                last = ob;
                EmitOp(ll, op, idx++, total, h, w, ib, ob, idx == n);
                useB0 = !useB0;
            }
            ll.Line($"  call void @llvm.memcpy.p0.p0.i64(ptr %dp, ptr %{last}, i64 {total * 4}, i1 false)");
        }

        ll.Line("  ret void");
        ll.Dedent();
        ll.Line("}");
        ll.Line("");
    }

    void EmitOp(LlvmIrBuilder ll, PipelineOp op, int idx, long total,
                int h, int w, string bi, string bo, bool last)
    {
        string L = $"L{idx}", B = $"B{idx}", D = $"D{idx}";
        string from = idx == 0 ? "entry" : $"D{idx - 1}";

        ll.Line($"  ; {op.Name}({string.Join(",", op.Args)})");
        ll.Line($"{L}:");
        ll.Line($"  %i{idx} = phi i64 [ 0, %{from} ], [ %j{idx}, %{B} ]");
        ll.Line($"  %c{idx} = icmp slt i64 %i{idx}, {total}");
        ll.Line($"  br i1 %c{idx}, label %{B}, label %{D}");
        ll.Line($"{B}:");
        ll.Line($"  %p{idx} = getelementptr float, ptr %{bi}, i64 %i{idx}");
        ll.Line($"  %v{idx} = load float, ptr %p{idx}");

        switch (op.Name)
        {
            case "relu":
                ll.Line($"  %z{idx} = fcmp olt float %v{idx}, 0.0");
                ll.Line($"  %w{idx} = select i1 %z{idx}, float 0.0, float %v{idx}");
                break;
            case "clamp":
                string lo = op.Args.Count > 0 ? op.Args[0] : "0.0";
                string hi = op.Args.Count > 1 ? op.Args[1] : "1.0";
                ll.Line($"  %l{idx} = fcmp olt float %v{idx}, {lo}");
                ll.Line($"  %s{idx} = select i1 %l{idx}, float {lo}, float %v{idx}");
                ll.Line($"  %h{idx} = fcmp ogt float %s{idx}, {hi}");
                ll.Line($"  %w{idx} = select i1 %h{idx}, float {hi}, float %s{idx}");
                break;
            case "convolve":
                ll.Line($"  %m{idx} = sub i64 %i{idx}, 1");
                ll.Line($"  %n{idx} = add i64 %i{idx}, 1");
                ll.Line($"  %pa{idx} = getelementptr float, ptr %{bi}, i64 %m{idx}");
                ll.Line($"  %pb{idx} = getelementptr float, ptr %{bi}, i64 %n{idx}");
                ll.Line($"  %va{idx} = load float, ptr %pa{idx}");
                ll.Line($"  %vb{idx} = load float, ptr %pb{idx}");
                ll.Line($"  %s1{idx} = fadd float %va{idx}, %v{idx}");
                ll.Line($"  %s2{idx} = fadd float %s1{idx}, %v{idx}");
                ll.Line($"  %s3{idx} = fadd float %s2{idx}, %vb{idx}");
                ll.Line($"  %w{idx} = fdiv float %s3{idx}, 4.0");
                break;
            case "shuffle":
                // ESPCN pixel shuffle 2×
                int outW = w * 2;
                // v = 1 input pixel channel → output needs 4 positions
                // For now: channel gather (R→top-left, G→top-right, B→bottom-left, A→bottom-right)
                ll.Line($"  %q{idx} = udiv i64 %i{idx}, 4");
                ll.Line($"  %r{idx} = urem i64 %i{idx}, 4");
                ll.Line($"  %y{idx} = udiv i64 %q{idx}, {w}");
                ll.Line($"  %x{idx} = urem i64 %q{idx}, {w}");
                ll.Line($"  %y2{idx} = mul i64 %y{idx}, 2");
                ll.Line($"  %x2{idx} = mul i64 %x{idx}, 2");
                ll.Line($"  %dy{idx} = udiv i64 %r{idx}, 2");
                ll.Line($"  %dx{idx} = urem i64 %r{idx}, 2");
                ll.Line($"  %oy{idx} = add i64 %y2{idx}, %dy{idx}");
                ll.Line($"  %ox{idx} = add i64 %x2{idx}, %dx{idx}");
                ll.Line($"  %oi{idx} = add i64 %oy{idx}, %ox{idx}");
                ll.Line($"  %o{idx} = getelementptr float, ptr %{bo}, i64 %oi{idx}");
                ll.Line($"  store float %v{idx}, ptr %o{idx}");
                ll.Line($"  %j{idx} = add i64 %i{idx}, 1");
                ll.Line($"  br label %{L}");
                ll.Line($"{D}:");
                if (!last) ll.Line($"  br label %L{idx + 1}");
                ll.Line("");
                return; // custom store + loop, skip standard write
            default:
                ll.Line($"  %w{idx} = fadd float %v{idx}, 0.0");
                break;
        }

        ll.Line($"  %o{idx} = getelementptr float, ptr %{bo}, i64 %i{idx}");
        ll.Line($"  store float %w{idx}, ptr %o{idx}");
        ll.Line($"  %j{idx} = add i64 %i{idx}, 1");
        ll.Line($"  br label %{L}");
        ll.Line($"{D}:");
        if (!last) ll.Line($"  br label %L{idx + 1}");
        ll.Line("");
    }

    static (string? code, int next) GpuOp(PipelineOp op, string v, int gi) => op.Name switch
    {
        "relu" => (
            $"  %g{gi} = fcmp olt float {v}, 0.0\n" +
            $"  %g{gi + 1} = select i1 %g{gi}, float 0.0, float {v}",
            gi + 2),
        "clamp" when op.Args.Count > 1 => (
            $"  %g{gi} = fcmp ogt float {v}, {op.Args[1]}\n" +
            $"  %g{gi + 1} = select i1 %g{gi}, float {op.Args[1]}, float {v}\n" +
            $"  %g{gi + 2} = fcmp olt float %g{gi + 1}, {op.Args[0]}\n" +
            $"  %g{gi + 3} = select i1 %g{gi + 2}, float {op.Args[0]}, float %g{gi + 1}",
            gi + 4),
        "clamp" => (
            $"  %g{gi} = fcmp ogt float {v}, 1.0\n" +
            $"  %g{gi + 1} = select i1 %g{gi}, float 1.0, float {v}\n" +
            $"  %g{gi + 2} = fcmp olt float %g{gi + 1}, 0.0\n" +
            $"  %g{gi + 3} = select i1 %g{gi + 2}, float 0.0, float %g{gi + 1}",
            gi + 4),
        "convolve" => (
            $"  ; convolve on GPU needs shared memory (stub)\n" +
            $"  %g{gi} = fadd float {v}, 0.0",
            gi + 1),
        "shuffle" => (
            $"  ; shuffle on GPU needs sub-group ops (stub)\n" +
            $"  %g{gi} = fadd float {v}, 0.0",
            gi + 1),
        _ => (
            $"  ; {op.Name} skipped on GPU\n" +
            $"  %g{gi} = fadd float {v}, 0.0",
            gi + 1)
    };

    void EmitEntry(LlvmIrBuilder ll, EntryDecl e)
    {
        ll.Line($"define i32 @main() {{ entry: ret i32 0 }}");
        ll.Line("");
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

// ─── BRIDGE GENERATORS ──────────────────────────────────────

static class Gen
{
    static string Hdr => "// B+ v2.5.0GH — Auto-generated bridge\n";

    public static string CSharp(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine(Hdr + "// Copy into Assets/ alongside .dll");
        sb.AppendLine("using System.Runtime.InteropServices;");
        sb.AppendLine("public static class BPlusBridge {");
        foreach (var k in kernels)
        {
            sb.AppendLine($"  [DllImport(\"bplus_kernels\", CallingConvention=CallingConvention.Cdecl)]");
            sb.AppendLine($"  static extern void {k}(System.IntPtr i, System.IntPtr o);");
            sb.AppendLine($"  public static unsafe void {k}_safe(float[] i, float[] o) {{");
            sb.AppendLine($"    fixed(float* pi=i, po=o) {k}((IntPtr)pi,(IntPtr)po); }}");
        }
        sb.AppendLine("}");
        return sb.ToString();
    }

    public static string Python(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("# " + Hdr);
        sb.AppendLine("import ctypes,numpy as np,os");
        sb.AppendLine("_dll=None");
        sb.AppendLine("for _n in['bplus_kernels.dll','libbplus_kernels.so','bplus_kernels.dylib']:");
        sb.AppendLine("  _p=os.path.join(os.path.dirname(__file__),_n)");
        sb.AppendLine("  if os.path.exists(_p): _dll=ctypes.CDLL(_p); break");
        foreach (var k in kernels)
        {
            sb.AppendLine($"_{k}=_dll.{k} if _dll else None");
            sb.AppendLine($"if _{k}: _{k}.argtypes=[ctypes.c_void_p,ctypes.c_void_p]; _{k}.restype=None");
            sb.AppendLine($"def {k}(i:np.ndarray,o:np.ndarray): _{k}(i.ctypes.data,o.ctypes.data)");
        }
        return sb.ToString();
    }

    public static string C(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// " + Hdr + "// Include this header and link bplus_kernels.obj");
        sb.AppendLine("#pragma once");
        sb.AppendLine("#include <stdint.h>");
        sb.AppendLine("#ifdef __cplusplus");
        sb.AppendLine("extern \"C\" {");
        sb.AppendLine("#endif");
        foreach (var k in kernels)
            sb.AppendLine($"void {k}(float* input, float* output);");
        sb.AppendLine("#ifdef __cplusplus");
        sb.AppendLine("}");
        sb.AppendLine("#endif");
        return sb.ToString();
    }

    public static string Rust(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// " + Hdr);
        sb.AppendLine("// Add to build.rs: println!(\"cargo:rustc-link-search=.\");");
        sb.AppendLine("//                  println!(\"cargo:rustc-link-lib=bplus_kernels\");");
        sb.AppendLine("#![allow(non_snake_case)]");
        sb.AppendLine("extern \"C\" {");
        foreach (var k in kernels)
            sb.AppendLine($"  fn {k}(input: *const f32, output: *mut f32);");
        sb.AppendLine("}");
        sb.AppendLine("pub struct BPlusKernels;");
        sb.AppendLine("impl BPlusKernels {");
        foreach (var k in kernels)
        {
            var safe = k.Replace("kernel_", "");
            sb.AppendLine($"  pub unsafe fn {safe}(input: &[f32], output: &mut [f32]) {{");
            sb.AppendLine($"    {k}(input.as_ptr(), output.as_mut_ptr()); }}");
        }
        sb.AppendLine("}");
        return sb.ToString();
    }

    public static string Swift(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// " + Hdr + "// Add bplus_kernels.a to Xcode project");
        sb.AppendLine("import Foundation");
        foreach (var k in kernels)
            sb.AppendLine($"@_silgen_name(\"{k}\")");
        sb.AppendLine("func bplus_kernel(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>)");
        sb.AppendLine("");
        sb.AppendLine("class BPlusBridge {");
        foreach (var k in kernels)
        {
            var s = k.Replace("kernel_", "");
            sb.AppendLine($"  class func {s}(input: [Float], output: inout [Float]) {{");
            sb.AppendLine($"    input.withUnsafeBufferPointer {{ i in");
            sb.AppendLine($"      output.withUnsafeMutableBufferPointer {{ o in");
            sb.AppendLine($"        {k}(i.baseAddress!, o.baseAddress!) }} }} }}");
        }
        sb.AppendLine("}");
        return sb.ToString();
    }

    public static string Kotlin(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// " + Hdr + "// Add bplus_kernels.so to jniLibs/");
        sb.AppendLine("object BPlusBridge {");
        sb.AppendLine("  init { System.loadLibrary(\"bplus_kernels\") }");
        foreach (var k in kernels)
        {
            var s = k.Replace("kernel_", "").Replace("_", "");
            sb.AppendLine($"  external fun {s}(input: FloatArray, output: FloatArray)");
            sb.AppendLine($"  fun {s}Safe(input: FloatArray, output: FloatArray) {{");
            sb.AppendLine($"    {s}(input, output) }}");
        }
        sb.AppendLine("}");
        return sb.ToString();
    }
}

// ─── LLVM IR BUILDER ────────────────────────────────────────

internal class LlvmIrBuilder
{
    readonly string _platform;
    readonly List<string> _lines = new();
    int _indent;
    public bool GpuMode;

    public LlvmIrBuilder(string platform = "native") { _platform = platform; }

    public void Line(string l) => _lines.Add(new string(' ', _indent * 2) + l);
    public void Indent() => _indent++;
    public void Dedent() => _indent = Math.Max(0, _indent - 1);

    public override string ToString()
    {
        var (triple, layout) = GpuMode
            ? ("spirv64-unknown-unknown", "e-m:e-p:64:64-i64:64-n32:64-S128")
            : _platform switch
            {
                "wasm" => ("wasm32-unknown-unknown", "e-m:e-p:32:32-i64:64-n32:64-S128"),
                "arm64" or "ios" => ("arm64-apple-ios", "e-m:o-i64:64-i128:128-n32:64-S128"),
                "android" => ("aarch64-linux-android", "e-m:e-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128"),
                _ => ("x86_64-pc-windows-msvc", "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128")
            };

        var h = $@"; ModuleID = 'bplus_module'
source_filename = ""bplus.bp""
target datalayout = ""{layout}""
target triple = ""{triple}""

";
        if (!GpuMode)
            h += "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)\n\n";

        return h + string.Join("\n", _lines);
    }
}
