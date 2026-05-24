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
        sb.AppendLine("    public abstract class State");
        sb.AppendLine("    {");
        sb.AppendLine("        public virtual void Enter() {}");
        sb.AppendLine("        public virtual void Exit() {}");
        sb.AppendLine("        public virtual State Always() => null;");
        sb.AppendLine("        public static void print(object s) => Console.WriteLine(s);");

        // Collect all unique event names across all states
        var allEvents = new HashSet<string>();
        void CollectEvents(StateDefNode s)
        {
            foreach (var t in s.Transitions)
                if (!t.IsAlways) allEvents.Add(t.EventName);
            foreach (var ns in s.NestedStates) CollectEvents(ns);
        }
        foreach (var st in program.States) CollectEvents(st);
        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States) CollectEvents(st);
        foreach (var ev in allEvents.OrderBy(e => e))
            sb.AppendLine($"        public virtual State On{ToPascal(ev)}() => null;");
        sb.AppendLine("    }");
        sb.AppendLine();

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

        foreach (var entry in program.Entries)
        {
            sb.AppendLine();
            sb.AppendLine("    class Program");
            sb.AppendLine("    {");
            var retType = entry.ReturnType ?? "int";
            sb.AppendLine($"        static {retType} Main(string[] args)");
            sb.AppendLine("        {");
            var stack = new List<string>();
            foreach (var line in entry.BodyLines)
            {
                var trimmed = line.TrimStart();
                var indent = new string(' ', 12 + stack.Count * 4);
                if (trimmed.StartsWith("$$"))
                {
                    sb.AppendLine($"{indent}{trimmed[2..]}");
                    continue;
                }
                if (trimmed == "end")
                {
                    if (stack.Count > 0)
                    {
                        stack.RemoveAt(stack.Count - 1);
                        sb.AppendLine($"{indent[..^4]}}}");
                    }
                    continue;
                }
                if (trimmed.StartsWith("while ") || trimmed.StartsWith("if ") || trimmed.StartsWith("for "))
                {
                    stack.Add("");
                    var parts = trimmed.Split(' ');
                    var kw = parts[0];
                    var rest = string.Join(" ", parts.Skip(1));
                    sb.AppendLine($"{indent}{kw} ({rest})");
                    sb.AppendLine($"{indent}{{");
                    continue;
                }
                var csharp = TranslateEntryLine(trimmed);
                sb.AppendLine($"{indent}{csharp};");
            }
            while (stack.Count > 0) { sb.AppendLine("            }"); stack.RemoveAt(stack.Count - 1); }
            sb.AppendLine("        }");
            sb.AppendLine("    }");
        }

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
                sb.AppendLine($"{ind}        {line.TrimEnd(';')};");
            sb.AppendLine($"{ind}    }}");
        }

        // Group transitions by event name to avoid duplicate methods
        var alwaysTrans = state.Transitions.Where(t => t.IsAlways).ToList();
        var eventGroups = state.Transitions.Where(t => !t.IsAlways).GroupBy(t => t.EventName).ToList();

        if (alwaysTrans.Count > 0)
        {
            sb.AppendLine($"{ind}    public override State Always()");
            sb.AppendLine($"{ind}    {{");
            foreach (var t in alwaysTrans)
            {
                if (t.Guard != null)
                    sb.AppendLine($"{ind}        if ({t.Guard}) return new {t.Target}();");
                else
                    sb.AppendLine($"{ind}        return new {t.Target}();");
            }
            sb.AppendLine($"{ind}        return null;");
            sb.AppendLine($"{ind}    }}");
        }

        foreach (var group in eventGroups)
        {
            var ev = ToPascal(group.Key);
            var first = group.First();
            var pars = string.Join(", ", first.Parameters.Select(p => $"{p.Type} {p.Name}"));
            var needsFallback = group.All(t => t.Guard != null);
            sb.AppendLine($"{ind}    public override State On{ev}({pars})");
            sb.AppendLine($"{ind}    {{");
            foreach (var t in group)
            {
                foreach (var line in SplitBody(t.Body))
                    sb.AppendLine($"{ind}        {line.TrimEnd(';')};");
                if (t.Guard != null)
                {
                    if (t.Body != null)
                    {
                        sb.AppendLine($"{ind}        if ({t.Guard})");
                        sb.AppendLine($"{ind}            return new {t.Target}();");
                    }
                    else
                    {
                        sb.AppendLine($"{ind}        if ({t.Guard}) return new {t.Target}();");
                    }
                }
                else
                {
                    sb.AppendLine($"{ind}        return new {t.Target}();");
                }
            }
            if (needsFallback)
                sb.AppendLine($"{ind}        return null;");
            sb.AppendLine($"{ind}    }}");
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

    private static string TranslateEntryLine(string line)
    {
        if (line.StartsWith("print("))
            return "Console.WriteLine" + line.Substring(5);
        return line;
    }
}