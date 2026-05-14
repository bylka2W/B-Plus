using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

// Fortran/OpenMP: Explicit parallelism hints for GPU code generation
// batch transitions can be marked as data-parallel for GPU warp execution

public class GpuGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".hlsl";
    public string GetLanguageName() => "GPU (HLSL/GLSL)";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var result = new Dictionary<string, string>();

        // HLSL compute shader
        result["parallel_states.hlsl"] = GenHlsl(program);
        // GLSL compute shader
        result["parallel_states.comp"] = GenGlsl(program);
        // OpenMP-style pragma hints
        result["parallel_hints.h"] = GenOpenMPHints(program);

        return result;
    }

    private string GenHlsl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("// B+ GPU Parallel States — HLSL Compute Shader");
        sb.AppendLine("// Fortran-inspired DO CONCURRENT for batch transitions");
        sb.AppendLine();
        sb.AppendLine("RWStructuredBuffer<uint> g_state_buffer : register(u0);");
        sb.AppendLine("RWStructuredBuffer<float> g_data_buffer : register(u1);");
        sb.AppendLine();

        // Find parallelizable states (those with many independent transitions)
        var parallelStates = program.States
            .Where(s => s.Transitions.Count >= 4)
            .ToList();

        foreach (var state in parallelStates)
        {
            sb.AppendLine($"[numthreads(64, 1, 1)]");
            sb.AppendLine($"void cs_{state.Name}(uint3 id : SV_DispatchThreadID) {{");
            sb.AppendLine("    // Fortran DO CONCURRENT: all iterations are independent");
            sb.AppendLine("    [allow_uav_condition]");
            sb.AppendLine("    uint idx = id.x;");
            sb.AppendLine("    uint state_id = g_state_buffer[idx];");
            sb.AppendLine();
            sb.AppendLine("    // OpenMP SIMD: safe to vectorize this loop");
            sb.AppendLine("    switch (state_id) {");

            for (int i = 0; i < state.Transitions.Count; i++)
            {
                var t = state.Transitions[i];
                sb.AppendLine($"        case {i}: /* → {t.Target} */");
                sb.AppendLine($"            g_state_buffer[idx] = {i + 1};");
                sb.AppendLine("            break;");
            }

            sb.AppendLine("        default: break;");
            sb.AppendLine("    }");
            sb.AppendLine("}");
            sb.AppendLine();
        }

        return sb.ToString();
    }

    private string GenGlsl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#version 460");
        sb.AppendLine("// B+ GPU Parallel States — GLSL Compute Shader");
        sb.AppendLine("// OpenMP-style simd directive equivalent");
        sb.AppendLine();
        sb.AppendLine("layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;");
        sb.AppendLine();
        sb.AppendLine("layout(std430, binding = 0) buffer StateBuf { uint states[]; };");
        sb.AppendLine("layout(std430, binding = 1) buffer DataBuf { float data[]; };");
        sb.AppendLine();

        var parallelStates = program.States
            .Where(s => s.Transitions.Count >= 4)
            .ToList();

        foreach (var state in parallelStates)
        {
            sb.AppendLine($"// OpenMP: #pragma omp simd safelen(64)");
            sb.AppendLine($"void dispatch_{state.Name}() {{");
            sb.AppendLine("    uint idx = gl_GlobalInvocationID.x;");
            sb.AppendLine("    uint s = states[idx];");
            sb.AppendLine("    switch (s) {");

            for (int i = 0; i < state.Transitions.Count; i++)
            {
                var t = state.Transitions[i];
                sb.AppendLine($"        case {i}: states[idx] = {i + 1}; break;");
            }

            sb.AppendLine("        default: break;");
            sb.AppendLine("    }");
            sb.AppendLine("}");
            sb.AppendLine();
        }

        return sb.ToString();
    }

    private string GenOpenMPHints(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("// B+ OpenMP-style Parallel Hints");
        sb.AppendLine("// Fortran DO CONCURRENT / OpenMP SIMD directives for batch transitions");
        sb.AppendLine();

        foreach (var state in program.States)
        {
            if (state.Transitions.Count < 2) continue;
            sb.AppendLine($"// State {state.Name}: {state.Transitions.Count} transitions");
            sb.AppendLine($"// #pragma omp simd safelen({state.Transitions.Count})");
            sb.AppendLine($"// DO CONCURRENT (i = 1:{state.Transitions.Count})");

            foreach (var t in state.Transitions)
            {
                var hint = t.HotWeight.HasValue && t.HotWeight.Value >= 0.8
                    ? "// !$OMP ALWAYS" : "";
                sb.AppendLine($"    {hint}");
                sb.AppendLine($"    // transition: {t.EventName} → {t.Target}");
            }
            sb.AppendLine();
        }

        return sb.ToString();
    }
}
