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

        foreach (var state in program.States)
        {
            sb.AppendLine($"    public class {state.Name} : State");
            sb.AppendLine("    {");

            foreach (var action in state.Actions)
            {
                var name = action.Type == ActionType.Enter ? "Enter" : "Exit";
                sb.AppendLine($"        public override void {name}()");
                sb.AppendLine("        {");
                sb.AppendLine($"            {action.Body};");
                sb.AppendLine("        }");
            }

            foreach (var t in state.Transitions)
            {
                var eventName = char.ToUpper(t.Event[0]) + t.Event[1..];
                var guard = t.Guard != null ? $"if ({t.Guard}) " : "";
                sb.AppendLine($"        public override State On{eventName}()");
                sb.AppendLine("        {");
                if (t.Guard != null)
                    sb.AppendLine($"            {guard}return new {t.Target}();");
                else
                    sb.AppendLine($"            return new {t.Target}();");
                sb.AppendLine("        }");
            }

            sb.AppendLine("    }");
            sb.AppendLine();
        }

        sb.AppendLine("}");
        return new Dictionary<string, string> { { "generated" + GetFileExtension(), sb.ToString() } };
    }
}