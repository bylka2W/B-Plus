using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class CppGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".cpp";
    public string GetLanguageName() => "C++";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var files = new Dictionary<string, string>
        {
            { "states.h", GenerateHeader(program) },
            { "states.cpp", GenerateImpl(program) }
        };
        return files;
    }

    private string GenerateHeader(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("#include \"State.h\"");
        sb.AppendLine();
        sb.AppendLine("namespace bplus {");

        foreach (var state in program.States)
        {
            sb.AppendLine($"    class {state.Name} : public State {{");
            sb.AppendLine("    public:");

            foreach (var action in state.Actions)
            {
                sb.AppendLine($"        void {action.Type.ToString().ToLower()}() override;");
            }

            foreach (var t in state.Transitions)
            {
                sb.AppendLine($"        State* on_{t.Event}() override;");
            }

            sb.AppendLine("    };");
            sb.AppendLine();
        }

        sb.AppendLine("} // namespace bplus");
        return sb.ToString();
    }

    private string GenerateImpl(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#include \"states.h\"");
        sb.AppendLine("#include <new>");
        sb.AppendLine();
        sb.AppendLine("namespace bplus {");

        foreach (var state in program.States)
        {
            foreach (var action in state.Actions)
            {
                var name = action.Type.ToString().ToLower();
                sb.AppendLine($"    void {state.Name}::{name}() {{ {action.Body}; }}");
            }

            foreach (var t in state.Transitions)
            {
                var guard = t.Guard != null ? $"if ({t.Guard}) " : "";
                sb.AppendLine($"    State* {state.Name}::on_{t.Event}() {{ {guard}return new {t.Target}(); }}");
            }
        }

        sb.AppendLine("} // namespace bplus");
        return sb.ToString();
    }
}