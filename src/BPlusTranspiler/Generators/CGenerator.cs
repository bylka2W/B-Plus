using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class CGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".c";
    public string GetLanguageName() => "C";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        return new Dictionary<string, string>
        {
            { "states.h", GenHeader(program) },
            { "states.c", GenImpl(program) }
        };
    }

    private string GenHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("#include <stdbool.h>");
        sb.AppendLine("#include <stdint.h>");
        sb.AppendLine();

        // Enums
        foreach (var en in program.Enums)
        {
            sb.AppendLine($"typedef enum {{ {string.Join(", ", en.Members.Select((m, i) => $"{en.Name}_{m}"))} }} {en.Name};");
        }
        if (program.Enums.Count > 0) sb.AppendLine();

        // Gather all states (including nested)
        var allStates = new List<StateDefNode>();
        void Collect(StateDefNode s) { allStates.Add(s); foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var st in program.States) Collect(st);
        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States) Collect(st);

        // Forward decls
        foreach (var s in allStates)
            sb.AppendLine($"typedef struct {s.Name} {s.Name};");
        sb.AppendLine();

        sb.AppendLine("typedef struct State State;");

        bool hasMembers = false;
        var stateMembers = new List<string>();

        // Group transitions by (state, event) to avoid duplicate struct fields
        foreach (var s in allStates)
        {
            foreach (var group in s.Transitions.GroupBy(t => t.EventName))
            {
                stateMembers.Add($"    State* (*{Lower(s.Name)}_on_{group.Key})(void);");
                hasMembers = true;
            }
            foreach (var timer in s.Timers)
            {
                stateMembers.Add($"    State* (*{Lower(s.Name)}_after_{timer.Duration})(void);");
                hasMembers = true;
            }
        }

        if (hasMembers)
        {
            sb.AppendLine("struct State {");
            foreach (var m in stateMembers)
                sb.AppendLine(m);
            sb.AppendLine("};");
        }
        else
        {
            sb.AppendLine("struct State { int __dummy; };");
        }
        sb.AppendLine();

        foreach (var s in allStates)
            sb.AppendLine($"extern State {Lower(s.Name)}_state;");
        sb.AppendLine();

        if (program.Context is { Variables.Count: > 0 })
        {
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"extern {v.Type} {v.Name};");
            sb.AppendLine();
        }

        foreach (var s in allStates)
        {
            foreach (var a in s.Actions)
                sb.AppendLine($"void {Lower(s.Name)}_{a.Type.ToString().ToLower()}(void);");
            foreach (var group in s.Transitions.GroupBy(t => t.EventName))
                sb.AppendLine($"State* {Lower(s.Name)}_on_{group.Key}(void);");
            foreach (var timer in s.Timers)
                sb.AppendLine($"State* {Lower(s.Name)}_after_{timer.Duration}(void);");
        }

        return sb.ToString();
    }

    private string GenImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"states.h\"");
        sb.AppendLine("#include <stdio.h>");
        sb.AppendLine();

        // Context
        if (program.Context is { Variables.Count: > 0 })
        {
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"{v.Type} {v.Name} = {v.DefaultValue ?? DefaultLiteral(v.Type)};");
            sb.AppendLine();
        }

        // Gather all states
        var allStates = new List<StateDefNode>();
        void Collect(StateDefNode s) { allStates.Add(s); foreach (var ns in s.NestedStates) Collect(ns); }
        foreach (var st in program.States) Collect(st);
        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States) Collect(st);

        foreach (var s in allStates)
        {
            foreach (var a in s.Actions)
                sb.AppendLine($"void {Lower(s.Name)}_{a.Type.ToString().ToLower()}(void) {{ {a.Body.TrimEnd(';')}; }}");

            foreach (var group in s.Transitions.GroupBy(t => t.EventName))
            {
                var fn = $"{Lower(s.Name)}_on_{group.Key}";
                var needsFallback = group.All(t => t.Guard != null);
                sb.AppendLine($"State* {fn}(void) {{");
                foreach (var t in group)
                {
                    foreach (var line in SplitBodyCGen(t.Body))
                        sb.AppendLine($"    {line.TrimEnd(';')};");
                    if (t.Guard != null)
                    {
                        sb.AppendLine($"    if ({t.Guard}) return &{Lower(t.Target)}_state;");
                    }
                    else
                    {
                        sb.AppendLine($"    return &{Lower(t.Target)}_state;");
                    }
                }
                if (needsFallback)
                    sb.AppendLine($"    return NULL;");
                sb.AppendLine("}");
            }

            foreach (var timer in s.Timers)
            {
                var fn = $"{Lower(s.Name)}_after_{timer.Duration}";
                if (timer.Guard != null)
                {
                    sb.AppendLine($"State* {fn}(void) {{");
                    sb.AppendLine($"    if ({timer.Guard}) return &{Lower(timer.Target)}_state;");
                    sb.AppendLine($"    return NULL;");
                    sb.AppendLine("}");
                }
                else
                {
                    sb.AppendLine($"State* {fn}(void) {{ return &{Lower(timer.Target)}_state; }}");
                }
            }
        }

        sb.AppendLine();

        // State instance definitions
        foreach (var s in allStates)
        {
            sb.AppendLine($"State {Lower(s.Name)}_state = {{");

            foreach (var a in s.Actions)
                sb.AppendLine($"    .{a.Type.ToString().ToLower()} = {Lower(s.Name)}_{a.Type.ToString().ToLower()},");

            foreach (var group in s.Transitions.GroupBy(t => t.EventName))
                sb.AppendLine($"    .{Lower(s.Name)}_on_{group.Key} = {Lower(s.Name)}_on_{group.Key},");

            foreach (var timer in s.Timers)
                sb.AppendLine($"    .{Lower(s.Name)}_after_{timer.Duration} = {Lower(s.Name)}_after_{timer.Duration},");

            sb.AppendLine("};");
        }

        // Entry point
        foreach (var entry in program.Entries)
        {
            sb.AppendLine();
            var retType = entry.ReturnType ?? "int";
            sb.AppendLine($"{retType} main(int argc, char** argv) {{");
            sb.AppendLine("    (void)argc; (void)argv;");
            var stack = new List<string>();
            foreach (var line in entry.BodyLines)
            {
                var trimmed = line.TrimStart();
                var indent = new string(' ', 4 + stack.Count * 4);
                if (trimmed.StartsWith("$$"))
                {
                    sb.AppendLine($"{indent}{trimmed[2..]}");
                    continue;
                }
                if (trimmed == "end")
                {
                    if (stack.Count > 0) { stack.RemoveAt(stack.Count - 1); sb.AppendLine($"{indent[..^4]}}}"); }
                    continue;
                }
                if (trimmed.StartsWith("while ") || trimmed.StartsWith("if ") || trimmed.StartsWith("for "))
                {
                    stack.Add("");
                    var parts = trimmed.Split(' ');
                    var kw = parts[0];
                    var rest = string.Join(" ", parts.Skip(1));
                    sb.AppendLine($"{indent}{kw} ({rest}) {{");
                    continue;
                }
                sb.AppendLine($"{indent}{TranslateBPlusToC(trimmed)};");
            }
            while (stack.Count > 0) { sb.AppendLine("    }"); stack.RemoveAt(stack.Count - 1); }
            sb.AppendLine("}");
        }

        return sb.ToString();
    }

    private static string Lower(string s) =>
        s.Length > 0 ? char.ToLower(s[0]) + s[1..] : s;

    private static string[] SplitBodyCGen(string? body) =>
        body?.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) ?? Array.Empty<string>();

    private static string TranslateBPlusToC(string line)
    {
        if (line.StartsWith("print(") && line.EndsWith(")"))
        {
            var inner = line.Substring(6, line.Length - 7);
            if (inner.StartsWith("\""))
            {
                var content = inner.Substring(1, inner.Length - 2);
                return $"printf(\"{content}\\n\")";
            }
            return $"printf(\"%d\\n\", {inner})";
        }
        return line;
    }

    private static string DefaultLiteral(string type) => type.ToLower() switch
    {
        "int" or "float" or "double" or "long" => "0",
        "bool" => "false",
        "string" => "\"\"",
        string t when t.StartsWith("bigfloat") => "0.0",
        _ => "0"
    };
}