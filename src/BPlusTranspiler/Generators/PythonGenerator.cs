using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class PythonGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".py";
    public string GetLanguageName() => "Python";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var sb = new StringBuilder();

        foreach (var imp in program.Imports)
        {
            var mod = Path.GetFileNameWithoutExtension(imp.Path);
            sb.AppendLine($"from {mod} import *");
        }

        if (program.Imports.Count > 0)
            sb.AppendLine();

        foreach (var state in program.States)
        {
            sb.AppendLine($"class {state.Name}(State):");

            foreach (var action in state.Actions)
            {
                sb.AppendLine($"    def {action.Type.ToString().ToLower()}(self):");
                sb.AppendLine($"        {action.Body}");
            }

            foreach (var t in state.Transitions)
            {
                sb.AppendLine($"    def on_{t.Event}(self):");
                if (t.Guard != null)
                {
                    sb.AppendLine($"        if {t.Guard}:");
                    sb.AppendLine($"            return {t.Target}");
                }
                else
                {
                    sb.AppendLine($"        return {t.Target}");
                }
            }

            if (state.Actions.Count == 0 && state.Transitions.Count == 0)
                sb.AppendLine("    pass");

            sb.AppendLine();
        }

        return new Dictionary<string, string> { { "generated" + GetFileExtension(), sb.ToString() } };
    }
}