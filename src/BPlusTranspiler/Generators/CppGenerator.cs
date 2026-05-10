using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class CppGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".cpp";
    public string GetLanguageName() => "C++";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        return new Dictionary<string, string>
        {
            { "states.h", GenHeader(program) },
            { "states.cpp", GenImpl(program) }
        };
    }

    private string GenHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("#include <cstdint>");
        sb.AppendLine("#include \"State.h\"");
        sb.AppendLine();

        // Enums
        foreach (var en in program.Enums)
        {
            sb.AppendLine($"enum class {en.Name} {{ {string.Join(", ", en.Members)} }};");
        }
        if (program.Enums.Count > 0) sb.AppendLine();

        // Context
        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine("namespace bplus_ctx {");
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"    extern {v.Type} {v.Name};");
            sb.AppendLine("}");
            sb.AppendLine();
        }

        sb.AppendLine("namespace bplus {");

        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States)
                EmitStateHeader(sb, st, 1);

        foreach (var st in program.States)
            EmitStateHeader(sb, st, 1);

        sb.AppendLine("} // namespace bplus");
        return sb.ToString();
    }

    private string GenImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"states.h\"");
        sb.AppendLine("#include <new>");
        sb.AppendLine();

        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine("namespace bplus_ctx {");
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"    {v.Type} {v.Name} = {v.DefaultValue ?? DefaultLiteral(v.Type)};");
            sb.AppendLine("}");
            sb.AppendLine();
        }

        sb.AppendLine("namespace bplus {");

        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States)
                EmitStateImpl(sb, st, 1);

        foreach (var st in program.States)
            EmitStateImpl(sb, st, 1);

        sb.AppendLine("} // namespace bplus");
        return sb.ToString();
    }

    private void EmitStateHeader(StringBuilder sb, StateDefNode state, int depth)
    {
        var ind = new string(' ', depth * 4);
        var baseCls = state.BaseClass ?? "State";
        var generic = state.GenericParam != null ? $"<typename {state.GenericParam}>" : "";

        if (state.IsBaseClass)
            sb.AppendLine($"{ind}class {state.Name} : public {baseCls} {{");
        else
            sb.AppendLine($"{ind}class {state.Name}{generic} : public {baseCls} {{");
        sb.AppendLine($"{ind}public:");

        foreach (var v in state.Variables)
            sb.AppendLine($"{ind}    {v.Type} {v.Name} = {v.DefaultValue ?? DefaultLiteral(v.Type)};");
        if (state.Variables.Count > 0) sb.AppendLine();

        foreach (var a in state.Actions)
            sb.AppendLine($"{ind}    void {a.Type.ToString().ToLower()}() override;");

        foreach (var t in state.Transitions)
        {
            var pars = string.Join(", ", t.Parameters.Select(p => $"{p.Type} {p.Name}"));
            if (t.IsAlways)
                sb.AppendLine($"{ind}    State* always() override;");
            else
                sb.AppendLine($"{ind}    State* on_{t.EventName}({pars}) override;");
        }

        foreach (var timer in state.Timers)
            sb.AppendLine($"{ind}    State* after_{timer.Duration}() override;");

        foreach (var ns in state.NestedStates)
            EmitStateHeader(sb, ns, depth + 1);

        sb.AppendLine($"{ind}}};");
        sb.AppendLine();
    }

    private void EmitStateImpl(StringBuilder sb, StateDefNode state, int depth)
    {
        var ind = new string(' ', depth * 4);

        foreach (var a in state.Actions)
        {
            var n = a.Type.ToString().ToLower();
            sb.AppendLine($"{ind}void {state.Name}::{n}() {{ {a.Body}; }}");
        }

        foreach (var t in state.Transitions)
        {
            if (t.IsAlways)
            {
                sb.AppendLine($"{ind}State* {state.Name}::always() {{ return new {t.Target}(); }}");
            }
            else
            {
                var pars = string.Join(", ", t.Parameters.Select(p => $"{p.Type} {p.Name}"));
                sb.AppendLine($"{ind}State* {state.Name}::on_{t.EventName}({pars}) {{");
                if (t.Body != null)
                    sb.AppendLine($"{ind}    {t.Body};");
                if (t.Guard != null)
                {
                    sb.AppendLine($"{ind}    if ({t.Guard})");
                    sb.AppendLine($"{ind}        return new {t.Target}();");
                    sb.AppendLine($"{ind}    return nullptr;");
                }
                else
                {
                    sb.AppendLine($"{ind}    return new {t.Target}();");
                }
                sb.AppendLine($"{ind}}}");
            }
        }

        foreach (var timer in state.Timers)
        {
            sb.AppendLine($"{ind}State* {state.Name}::after_{timer.Duration}() {{");
            if (timer.Guard != null)
            {
                sb.AppendLine($"{ind}    if ({timer.Guard})");
                sb.AppendLine($"{ind}        return new {timer.Target}();");
                sb.AppendLine($"{ind}    return nullptr;");
            }
            else
                sb.AppendLine($"{ind}    return new {timer.Target}();");
            sb.AppendLine($"{ind}}}");
        }

        foreach (var ns in state.NestedStates)
            EmitStateImpl(sb, ns, depth + 1);
    }

    private static string DefaultLiteral(string type) => type.ToLower() switch
    {
        "int" or "float" or "double" or "long" => "0",
        "bool" => "false",
        "string" => "\"\"",
        _ => "{}"
    };
}