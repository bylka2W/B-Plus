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
            { "states.h", GenerateHeader(program) },
            { "states.c", GenerateImpl(program) }
        };
    }

    private string GenerateHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine();

        // Forward declarations
        foreach (var state in program.States)
            sb.AppendLine($"typedef struct {state.Name} {state.Name};");

        sb.AppendLine();
        sb.AppendLine("typedef struct State State;");
        sb.AppendLine("struct State {");

        bool anyEnter = program.States.Any(s => s.Actions.Any(a => a.Type == ActionType.Enter));
        bool anyExit = program.States.Any(s => s.Actions.Any(a => a.Type == ActionType.Exit));
        if (anyEnter)
            sb.AppendLine("    void (*enter)(void);");
        if (anyExit)
            sb.AppendLine("    void (*exit)(void);");

        foreach (var state in program.States)
        {
            foreach (var t in state.Transitions)
            {
                var fnName = $"{Lower(state.Name)}_on_{t.Event}";
                sb.AppendLine($"    State* (*{fnName})(void);");
            }
        }

        sb.AppendLine("};");
        sb.AppendLine();

        foreach (var state in program.States)
            sb.AppendLine($"extern State {Lower(state.Name)}_state;");

        sb.AppendLine();

        foreach (var state in program.States)
        {
            foreach (var action in state.Actions)
            {
                var fnName = $"{Lower(state.Name)}_{action.Type.ToString().ToLower()}";
                sb.AppendLine($"void {fnName}(void);");
            }

            foreach (var t in state.Transitions)
            {
                var fnName = $"{Lower(state.Name)}_on_{t.Event}";
                sb.AppendLine($"State* {fnName}(void);");
            }
        }

        return sb.ToString();
    }

    private string GenerateImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"states.h\"");
        sb.AppendLine();

        foreach (var state in program.States)
        {
            foreach (var action in state.Actions)
            {
                var fnName = $"{Lower(state.Name)}_{action.Type.ToString().ToLower()}";
                sb.AppendLine($"void {fnName}(void) {{ {action.Body}; }}");
            }

            foreach (var t in state.Transitions)
            {
                var fnName = $"{Lower(state.Name)}_on_{t.Event}";
                if (t.Guard != null)
                    sb.AppendLine($"State* {fnName}(void) {{ if ({t.Guard}) return &{Lower(t.Target)}_state; return NULL; }}");
                else
                    sb.AppendLine($"State* {fnName}(void) {{ return &{Lower(t.Target)}_state; }}");
            }
        }

        sb.AppendLine();

        foreach (var state in program.States)
        {
            sb.AppendLine($"State {Lower(state.Name)}_state = {{");

            foreach (var action in state.Actions)
            {
                var fnName = $"{Lower(state.Name)}_{action.Type.ToString().ToLower()}";
                sb.AppendLine($"    .{action.Type.ToString().ToLower()} = {fnName},");
            }

            foreach (var t in state.Transitions)
            {
                var fnName = $"{Lower(state.Name)}_on_{t.Event}";
                sb.AppendLine($"    .{fnName} = {fnName},");
            }

            sb.AppendLine("};");
        }

        return sb.ToString();
    }

    private static string Lower(string s) =>
        char.ToLower(s[0]) + s[1..];
}