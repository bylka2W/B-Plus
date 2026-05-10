using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class CSharpGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".cs";
    public string GetLanguageName() => "C#";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("using System;");
        sb.AppendLine();
        sb.AppendLine("namespace BPlusGenerated");
        sb.AppendLine("{");

        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine("    public static class Context");
            sb.AppendLine("    {");
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"        public static {v.Type} {v.Name} {{ get; set; }} = {v.DefaultValue ?? DefaultLiteral(v.Type)};");
            sb.AppendLine("    }");
            sb.AppendLine();
        }

        foreach (var en in program.Enums)
        {
            sb.AppendLine($"    public enum {en.Name}");
            sb.AppendLine("    {");
            foreach (var m in en.Members)
                sb.AppendLine($"        {m},");
            sb.AppendLine("    }");
            sb.AppendLine();
        }

        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States)
                EmitState(sb, st, 1);

        foreach (var st in program.States)
            EmitState(sb, st, 1);

        sb.AppendLine("}");
        return new Dictionary<string, string> { { "generated" + GetFileExtension(), sb.ToString() } };
    }

    private void EmitState(StringBuilder sb, StateDefNode state, int depth)
    {
        var ind = new string(' ', depth * 4);
        var baseCls = state.BaseClass ?? "State";

        if (state.IsBaseClass)
            sb.AppendLine($"{ind}public abstract class {state.Name} : {baseCls}");
        else
        {
            var generic = state.GenericParam != null ? $"<{state.GenericParam}>" : "";
            sb.AppendLine($"{ind}public class {state.Name}{generic} : {baseCls}");
        }
        sb.AppendLine($"{ind}{{");

        foreach (var v in state.Variables)
            sb.AppendLine($"{ind}    public {v.Type} {v.Name} {{ get; set; }} = {v.DefaultValue ?? DefaultLiteral(v.Type)};");
        if (state.Variables.Count > 0) sb.AppendLine();

        foreach (var a in state.Actions)
        {
            var name = a.Type == ActionType.Enter ? "Enter" : "Exit";
            sb.AppendLine($"{ind}    public override void {name}()");
            sb.AppendLine($"{ind}    {{");
            foreach (var line in SplitBody(a.Body))
                sb.AppendLine($"{ind}        {line};");
            sb.AppendLine($"{ind}    }}");
        }

        foreach (var t in state.Transitions)
        {
            var ev = ToPascal(t.EventName);
            var pars = string.Join(", ", t.Parameters.Select(p => $"{p.Type} {p.Name}"));

            if (t.IsAlways)
            {
                sb.AppendLine($"{ind}    public override State Always()");
                sb.AppendLine($"{ind}    {{");
                sb.AppendLine($"{ind}        return new {t.Target}();");
                sb.AppendLine($"{ind}    }}");
            }
            else
            {
                sb.AppendLine($"{ind}    public override State On{ev}({pars})");
                sb.AppendLine($"{ind}    {{");
                foreach (var line in SplitBody(t.Body))
                    sb.AppendLine($"{ind}        {line};");
                if (t.Guard != null)
                {
                    sb.AppendLine($"{ind}        if ({t.Guard})");
                    sb.AppendLine($"{ind}            return new {t.Target}();");
                    sb.AppendLine($"{ind}        return null;");
                }
                else
                {
                    sb.AppendLine($"{ind}        return new {t.Target}();");
                }
                sb.AppendLine($"{ind}    }}");
            }
        }

        foreach (var timer in state.Timers)
        {
            sb.AppendLine($"{ind}    public override State After{timer.Duration}()");
            sb.AppendLine($"{ind}    {{");
            if (timer.Guard != null)
            {
                sb.AppendLine($"{ind}        if ({timer.Guard})");
                sb.AppendLine($"{ind}            return new {timer.Target}();");
                sb.AppendLine($"{ind}        return null;");
            }
            else
                sb.AppendLine($"{ind}        return new {timer.Target}();");
            sb.AppendLine($"{ind}    }}");
        }

        foreach (var ns in state.NestedStates)
            EmitState(sb, ns, depth + 1);

        sb.AppendLine($"{ind}}}");
        sb.AppendLine();
    }

    private static string ToPascal(string snake)
    {
        if (string.IsNullOrEmpty(snake)) return snake;
        return string.Join("", snake.Split('_').Where(s => s.Length > 0).Select(s => char.ToUpper(s[0]) + s[1..]));
    }

    private static string[] SplitBody(string? body) =>
        body?.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) ?? Array.Empty<string>();

    private static string DefaultLiteral(string type) => type.ToLower() switch
    {
        "int" or "float" or "double" or "long" => "0",
        "bool" => "false",
        "string" => "\"\"",
        _ => "null"
    };
}