using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class CppKernelGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".cpp";
    public string GetLanguageName() => "C++ (kernel)";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var result = new Dictionary<string, string>
        {
            { "kernels.h", GenHeader(program) },
            { "kernels.cpp", GenImpl(program) }
        };

        // v4.0: ComputeShaderDecl
        if (program.ComputeShaders.Count > 0)
        {
            result["compute_shaders.h"] = GenComputeShadersHeader(program);
            result["compute_shaders.cpp"] = GenComputeShadersImpl(program);
        }

        // v4.0: FragmentShaderDecl
        if (program.FragmentShaders.Count > 0)
        {
            result["fragment_shaders.h"] = GenFragmentShadersHeader(program);
            result["fragment_shaders.cpp"] = GenFragmentShadersImpl(program);
        }

        // v4.0: VertexShaderDecl
        if (program.VertexShaders.Count > 0)
        {
            result["vertex_shaders.h"] = GenVertexShadersHeader(program);
            result["vertex_shaders.cpp"] = GenVertexShadersImpl(program);
        }

        // v4.0: RayTracingShaderDecl
        if (program.RayTracingShaders.Count > 0)
        {
            result["raytracing_shaders.h"] = GenRayTracingShadersHeader(program);
            result["raytracing_shaders.cpp"] = GenRayTracingShadersImpl(program);
        }

        // v4.0: LocalGroupDecl
        if (program.LocalGroups.Count > 0)
        {
            result["local_groups.h"] = GenLocalGroupsHeader(program);
            result["local_groups.cpp"] = GenLocalGroupsImpl(program);
        }

        // v4.0: ScientificKernelDecl
        if (program.ScientificKernels.Count > 0)
        {
            result["scientific_kernels.h"] = GenScientificKernelsHeader(program);
            result["scientific_kernels.cpp"] = GenScientificKernelsImpl(program);
        }

        return result;
    }

    private string GenComputeShadersHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("// B+ v4.0 Compute Shaders");
        sb.AppendLine();
        foreach (var cs in program.ComputeShaders)
            sb.AppendLine($"void {cs.Name}_compute_shader();");
        return sb.ToString();
    }

    private string GenComputeShadersImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"compute_shaders.h\"");
        sb.AppendLine();
        foreach (var cs in program.ComputeShaders)
        {
            sb.AppendLine($"void {cs.Name}_compute_shader() {{");
            sb.AppendLine($"    // Compute shader: {cs.Name}");
            sb.AppendLine("}");
        }
        return sb.ToString();
    }

    private string GenFragmentShadersHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("// B+ v4.0 Fragment Shaders");
        sb.AppendLine();
        foreach (var fs in program.FragmentShaders)
            sb.AppendLine($"void {fs.Name}_fragment_shader();");
        return sb.ToString();
    }

    private string GenFragmentShadersImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"fragment_shaders.h\"");
        sb.AppendLine();
        foreach (var fs in program.FragmentShaders)
        {
            sb.AppendLine($"void {fs.Name}_fragment_shader() {{");
            sb.AppendLine($"    // Fragment shader: {fs.Name}");
            sb.AppendLine("}");
        }
        return sb.ToString();
    }

    private string GenVertexShadersHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("// B+ v4.0 Vertex Shaders");
        sb.AppendLine();
        foreach (var vs in program.VertexShaders)
            sb.AppendLine($"void {vs.Name}_vertex_shader();");
        return sb.ToString();
    }

    private string GenVertexShadersImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"vertex_shaders.h\"");
        sb.AppendLine();
        foreach (var vs in program.VertexShaders)
        {
            sb.AppendLine($"void {vs.Name}_vertex_shader() {{");
            sb.AppendLine($"    // Vertex shader: {vs.Name}");
            sb.AppendLine("}");
        }
        return sb.ToString();
    }

    private string GenRayTracingShadersHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("// B+ v4.0 Ray Tracing Shaders");
        sb.AppendLine();
        foreach (var rt in program.RayTracingShaders)
            sb.AppendLine($"void {rt.Name}_raytracing_shader();");
        return sb.ToString();
    }

    private string GenRayTracingShadersImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"raytracing_shaders.h\"");
        sb.AppendLine();
        foreach (var rt in program.RayTracingShaders)
        {
            sb.AppendLine($"void {rt.Name}_raytracing_shader() {{");
            sb.AppendLine($"    // Ray tracing shader: {rt.Name}");
            sb.AppendLine("}");
        }
        return sb.ToString();
    }

    private string GenLocalGroupsHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("// B+ v4.0 Local Groups");
        sb.AppendLine();
        foreach (var lg in program.LocalGroups)
            sb.AppendLine($"void {lg.Name}_local_group();");
        return sb.ToString();
    }

    private string GenLocalGroupsImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"local_groups.h\"");
        sb.AppendLine();
        foreach (var lg in program.LocalGroups)
        {
            sb.AppendLine($"void {lg.Name}_local_group() {{");
            sb.AppendLine($"    // Local group: {lg.Name}, size: {lg.Width}x{lg.Height}");
            sb.AppendLine("}");
        }
        return sb.ToString();
    }

    private string GenScientificKernelsHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("// B+ v4.0 Scientific Kernels");
        sb.AppendLine();
        foreach (var sk in program.ScientificKernels)
            sb.AppendLine($"void {sk.Name}_scientific_kernel();");
        return sb.ToString();
    }

    private string GenScientificKernelsImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"scientific_kernels.h\"");
        sb.AppendLine();
        foreach (var sk in program.ScientificKernels)
        {
            sb.AppendLine($"void {sk.Name}_scientific_kernel() {{");
            sb.AppendLine($"    // Scientific kernel: {sk.Name}");
            sb.AppendLine("}");
        }
        return sb.ToString();
    }

    private string GenHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("#include <cstdint>");
        sb.AppendLine("#include <cmath>");
        sb.AppendLine("#include <algorithm>");
        sb.AppendLine();

        // C++ interop headers
        foreach (var use in program.UseCxxDecls)
            foreach (var h in use.Headers)
                sb.AppendLine($"#include \"{h}\"");

        if (program.UseCxxDecls.Count > 0) sb.AppendLine();

        // Extern C++ function declarations
        foreach (var ext in program.ExternCppFns)
        {
            var pars = string.Join(", ", ext.Parameters.Select(p =>
            {
                var t = p.Type.ToCppType();
                // Translate Rust-style pointer types to C++
                t = t.Replace("*mut ", "*").Replace("*const ", "const* ");
                return $"{t} {p.Name}";
            }));
            sb.AppendLine($"extern {ext.ReturnType} {ext.Name}({pars});");
        }
        if (program.ExternCppFns.Count > 0) sb.AppendLine();

        // Weight declarations (from @load annotations in global vars)
        sb.AppendLine("// Global weights — loaded from @load(\"...\")");
        sb.AppendLine("extern \"C\" float weights_up[];");
        sb.AppendLine("extern \"C\" float weights_ref[];");
        sb.AppendLine();

        // Kernel function declarations
        foreach (var k in program.Kernels)
        {
            var pars = string.Join(", ", GetKernelCppParams(k).Select(p => $"{p.type} {p.name}"));
            sb.AppendLine($"void {k.Name}_kernel({pars});");
        }
        if (program.Kernels.Count > 0) sb.AppendLine();

        // Pipeline declarations
        foreach (var p in program.Pipelines)
        {
            var pars = string.Join(", ", p.Parameters.Select(pp => $"{pp.Type.ToCppType()} {pp.Name}"));
            var ret = p.ReturnType?.ToCppType() ?? "void";
            sb.AppendLine($"{ret} {p.Name}({pars});");
        }
        sb.AppendLine();

        return sb.ToString();
    }

    private string GenImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"kernels.h\"");
        sb.AppendLine("#include <vector>");
        sb.AppendLine("#include <chrono>");
        sb.AppendLine();

        foreach (var k in program.Kernels)
            EmitKernel(sb, k);

        foreach (var p in program.Pipelines)
            EmitPipeline(sb, p);

        foreach (var e in program.Entries)
            EmitEntry(sb, e);

        return sb.ToString();
    }

    private void EmitKernel(StringBuilder sb, KernelDecl k)
    {
        bool fuse = k.Annotations.Any(a => a.Name == "fuse");
        bool winograd = k.Annotations.Any(a => a.Name == "rewrite" && a.Args.GetValueOrDefault("_val") == "winograd");
        int pipelineDepth = 0;
        var pipeAn = k.Annotations.FirstOrDefault(a => a.Name == "pipeline");
        if (pipeAn != null && pipeAn.Args.TryGetValue("depth", out var pd))
            int.TryParse(pd, out pipelineDepth);

        sb.AppendLine($"// Kernel: {k.Name}");
        if (fuse) sb.AppendLine("// Optimizations: fused");
        if (winograd) sb.AppendLine("// Optimizations: winograd F(2x2, 3x3) — 36 mul вместо 81");
        if (pipelineDepth > 0) sb.AppendLine($"// Pipeline depth: {pipelineDepth}");

        var cppParams = GetKernelCppParams(k);
        var hName = cppParams.FirstOrDefault(p => p.name == "H").name;
        var wName = cppParams.FirstOrDefault(p => p.name == "W").name;
        if (hName == "") hName = "H";
        if (wName == "") wName = "W";

        var pars = string.Join(", ", cppParams.Select(p => $"{p.type} {p.name}"));
        sb.AppendLine($"void {k.Name}_kernel({pars}) {{");

        if (k.Body != null && k.Body.Operations.Count > 0)
        {
            // Fused generation: inline all operations in one loop
            var srcParam = k.Body.Source;
            var lastVar = srcParam;
            string? outputVar = k.Body.OutputTarget;

            if (fuse && k.Body.Operations.Any(o => o.Name is "convolve" or "conv2d"))
            {
                sb.AppendLine($"    // Fused loop: one pass, no intermediate buffers");
                sb.AppendLine($"    // Dimensions: H={hName}, W={wName}");
                sb.AppendLine($"    #pragma omp parallel for collapse(2) if ({hName} * {wName} >= 512*512)");
                sb.AppendLine($"    for (int y = 0; y < {hName}; y++) {{");
                sb.AppendLine($"        for (int x = 0; x < {wName}; x++) {{");

                string currentVar = "v";
                sb.AppendLine($"            float {currentVar} = 0;");

                foreach (var op in k.Body.Operations)
                {
                    switch (op.Name)
                    {
                        case "convolve":
                        case "conv2d":
                        {
                            var wArg = op.Args.Count > 0 ? op.Args[0] : "weights";
                            sb.AppendLine($"            // convolve: {string.Join(", ", op.Args)}");
                            sb.AppendLine($"            {{");
                            sb.AppendLine($"                float acc = 0;");
                            sb.AppendLine($"                for (int ky = -1; ky <= 1; ky++)");
                            sb.AppendLine($"                    for (int kx = -1; kx <= 1; kx++)");
                            sb.AppendLine($"                        for (int c = 0; c < 3; c++)");
                            sb.AppendLine($"                            acc += {currentVar} * {wArg}[ky+1][kx+1][c];");
                            sb.AppendLine($"                {currentVar} = acc;");
                            sb.AppendLine($"            }}");
                            break;
                        }
                        case "relu":
                            sb.AppendLine($"            {currentVar} = std::max(0.0f, {currentVar});");
                            break;
                        case "shuffle":
                        {
                            var raw = op.Args.Count > 0 ? op.Args[0] : "2";
                            var factor = new string(raw.Where(char.IsDigit).ToArray());
                            if (factor == "") factor = "2";
                            sb.AppendLine($"            int ox = x * {factor}, oy = y * {factor};");
                            break;
                        }
                        case "clamp":
                        {
                            var lo = op.Args.Count > 0 ? op.Args[0] : "0.0";
                            var hi = op.Args.Count > 1 ? op.Args[1] : "1.0";
                            sb.AppendLine($"            {currentVar} = std::clamp({currentVar}, {lo}f, {hi}f);");
                            break;
                        }
                        default:
                            sb.AppendLine($"            // op: {op.Name}({string.Join(", ", op.Args)})");
                            break;
                    }
                }

                if (outputVar != null)
                    sb.AppendLine($"            {outputVar}[oy * ({wName} * 2) + ox] = {currentVar};");
                sb.AppendLine($"        }}");
                sb.AppendLine($"    }}");
            }
            else
            {
                // Sequential generation (no fusion)
                foreach (var op in k.Body.Operations)
                {
                    switch (op.Name)
                    {
                        case "convolve":
                        case "conv2d":
                        {
                            var wArg = op.Args.Count > 0 ? op.Args[0] : "weights";
                            sb.AppendLine($"    // convolve({string.Join(", ", op.Args)})");
                            sb.AppendLine($"    auto conv_out = {lastVar}; // placeholder");
                            break;
                        }
                        case "relu":
                            sb.AppendLine($"    // relu: {lastVar} = max(0, {lastVar})");
                            break;
                        case "shuffle":
                            var sf = op.Args.Count > 0 ? op.Args[0] : "2";
                            sb.AppendLine($"    // shuffle(x{sf})");
                            break;
                        case "clamp":
                            sb.AppendLine($"    // clamp({string.Join(", ", op.Args)})");
                            break;
                        default:
                            sb.AppendLine($"    // {op.Name}({string.Join(", ", op.Args)})");
                            break;
                    }
                }

                if (outputVar != null)
                    sb.AppendLine($"    // >> {outputVar}");
            }
        }

        sb.AppendLine("}");
        sb.AppendLine();
    }

    private void EmitPipeline(StringBuilder sb, PipelineDecl p)
    {
        sb.AppendLine($"// Pipeline: {p.Name}");

        var pars = string.Join(", ", p.Parameters.Select(pp => $"{pp.Type.ToCppType()} {pp.Name}"));
        var ret = p.ReturnType?.ToCppType() ?? "void";
        sb.AppendLine($"{ret} {p.Name}({pars}) {{");

        if (p.Telemetry is { Entries.Count: > 0 })
        {
            sb.AppendLine($"    // Telemetry:");
            foreach (var te in p.Telemetry.Entries)
                sb.AppendLine($"    //   log {te.LogSource} -> \"{te.FilePath}\"");
        }

        foreach (var step in p.Steps)
        {
            var args = string.Join(", ", step.Args);
            sb.AppendLine($"    // step {step.Name} = {step.KernelName}({args})");
        }

        sb.AppendLine("}");
        sb.AppendLine();
    }

    private void EmitEntry(StringBuilder sb, EntryDecl e)
    {
        sb.AppendLine($"// Entry: {e.Name}");
        var retType = e.ReturnType ?? "int";
        sb.AppendLine($"int main(int argc, char** argv) {{");
        sb.AppendLine($"    (void)argc; (void)argv;");

        foreach (var line in e.BodyLines)
        {
            // Translate B+ syntax to C++
            var cpp = TranslateBPlusToCpp(line);
            sb.AppendLine($"    {cpp};");
        }

        sb.AppendLine("}");
        sb.AppendLine();
    }

    private static List<(string type, string name)> GetKernelCppParams(KernelDecl k)
    {
        var result = new List<(string type, string name)>();
        foreach (var p in k.Parameters)
        {
            if (p.Type is ImageType)
                result.Add(("float*", p.Name));
            else if (p.Type is ConvWeightsType)
                result.Add(("float*", p.Name));
            else if (p.Type is StreamType)
                result.Add(("void*", p.Name));
            else if (p.Type is MotionVecType)
                result.Add(("float*", p.Name));
            else
                result.Add((p.Type.ToCppType(), p.Name));
        }
        // Add H,W dimension params if any Image type is used
        bool hasH = false, hasW = false;
        foreach (var p in k.Parameters)
        {
            if (p.Type is ImageType img)
            {
                if (!hasH) { hasH = true; result.Add(("int", "H")); }
                if (!hasW) { hasW = true; result.Add(("int", "W")); }
                break; // one pair is enough
            }
        }
        return result;
    }

    private static string TranslateBPlusToCpp(string line)
    {
        if (line.StartsWith("let "))
        {
            // let x = expr  ->  auto x = expr;
            return "auto " + line[4..];
        }
        if (line.StartsWith("run "))
        {
            // run pipeline(args) >> output  ->  pipeline(args);
            return line[4..].Replace(">>", "/*>>*/");
        }
        if (line.Contains("ExitCode::Ok"))
            return "return 0";
        if (line.Contains("ExitCode::Err"))
            return "return 1";
        return line;
    }
}

internal static class BPlusTypeExtensions
{
    public static string ToCppType(this BPlusType type)
    {
        return type switch
        {
            SimpleType s => MapSimpleType(s.Name),
            ImageType i => "float*",  // image as float buffer
            ConvWeightsType c => "float*",  // weights as float buffer
            StreamType s => $"void*",  // stream as opaque pointer
            MotionVecType m => "float*",  // motion vectors as float buffer
            ArrayType a => a.ElementType.ToCppType(),  // array → same C++ type
            _ => "void*"
        };
    }

    private static string MapSimpleType(string name)
    {
        return name.ToLower() switch
        {
            "int" or "i32" => "int32_t",
            "i64" or "long" => "int64_t",
            "f32" or "float" => "float",
            "f64" or "double" => "double",
            "bool" => "bool",
            "u8" or "uint8" or "byte" => "uint8_t",
            "void" => "void",
            "exitcode" => "int",
            _ => name  // pass through (DX12Device, ZeroLagStream, etc.)
        };
    }
}
