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

        // Runtime: State base class
        sb.AppendLine("import enum");
        sb.AppendLine("from enum import auto");
        sb.AppendLine();
        sb.AppendLine();
        sb.AppendLine("class State:");
        sb.AppendLine("    def enter(self): pass");
        sb.AppendLine("    def exit(self): pass");
        sb.AppendLine("    def always(self): return None");
        sb.AppendLine();

        foreach (var imp in program.Imports)
            sb.AppendLine($"from {Path.GetFileNameWithoutExtension(imp.Path)} import *");
        if (program.Imports.Count > 0) sb.AppendLine();

        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine("# Context");
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"{v.Name}: {v.Type} = {v.DefaultValue ?? DefaultLiteral(v.Type)}");
            sb.AppendLine();
        }

        foreach (var en in program.Enums)
        {
            sb.AppendLine($"class {en.Name}(Enum):");
            foreach (var m in en.Members)
                sb.AppendLine($"    {m} = auto()");
            sb.AppendLine();
        }

        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States)
                EmitState(sb, st, 0);

        foreach (var st in program.States)
            EmitState(sb, st, 0);

        return new Dictionary<string, string> { { "generated" + GetFileExtension(), sb.ToString() } };
    }

    private void EmitState(StringBuilder sb, StateDefNode state, int depth)
    {
        var indent = new string(' ', depth * 4);
        var baseCls = state.BaseClass ?? "State";
        sb.AppendLine($"{indent}class {state.Name}({baseCls}):");

        foreach (var v in state.Variables)
        {
            var def = v.DefaultValue ?? DefaultLiteral(v.Type);
            sb.AppendLine($"{indent}    {v.Name}: {v.Type} = {def}");
        }

        if (state.Variables.Count > 0)
        {
            var initParams = string.Join(", ", state.Variables.Select(v => $"{v.Name}: {v.Type} = {v.DefaultValue ?? DefaultLiteral(v.Type)}"));
            sb.AppendLine();
            sb.AppendLine($"{indent}    def __init__(self, {initParams}):");
            foreach (var v in state.Variables)
                sb.AppendLine($"{indent}        self.{v.Name} = {v.Name}");
        }

        foreach (var a in state.Actions)
        {
            sb.AppendLine();
            sb.AppendLine($"{indent}    def {a.Type.ToString().ToLower()}(self):");
            sb.AppendLine($"{indent}        {a.Body.TrimEnd(';')}");
        }

        foreach (var t in state.Transitions)
        {
            sb.AppendLine();
            if (t.IsAlways)
            {
                sb.AppendLine($"{indent}    def always(self):");
                sb.AppendLine($"{indent}        return {t.Target}");
            }
            else
            {
                var pars = string.Join(", ", t.Parameters.Select(p => $"{p.Name}: {p.Type}"));
                sb.AppendLine($"{indent}    def on_{t.EventName}(self{(pars != "" ? ", " + pars : "")}):");
                if (t.Body != null)
                    sb.AppendLine($"{indent}        {t.Body.TrimEnd(';')}");
                if (t.Guard != null)
                {
                    sb.AppendLine($"{indent}        if {t.Guard}:");
                    sb.AppendLine($"{indent}            return {t.Target}");
                }
                else
                {
                    sb.AppendLine($"{indent}        return {t.Target}");
                }
            }
        }

        foreach (var timer in state.Timers)
        {
            sb.AppendLine();
            sb.AppendLine($"{indent}    def after_{timer.Duration}(self):");
            if (timer.Guard != null)
            {
                sb.AppendLine($"{indent}        if {timer.Guard}:");
                sb.AppendLine($"{indent}            return {timer.Target}");
            }
            else
            {
                sb.AppendLine($"{indent}        return {timer.Target}");
            }
        }

        foreach (var ns in state.NestedStates)
        {
            sb.AppendLine();
            EmitState(sb, ns, depth + 1);
        }

        if (state.Variables.Count == 0 && state.Actions.Count == 0 && state.Transitions.Count == 0 && state.NestedStates.Count == 0)
            sb.AppendLine($"{indent}    pass");

        sb.AppendLine();
    }

    private static string DefaultLiteral(string type) => type.ToLower() switch
    {
        "int" or "float" or "double" or "long" => "0",
        "bool" => "False",
        "string" => "\"\"",
        _ => "None"
    };
}