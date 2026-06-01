using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.DocGen;

public static class BPlusDocGenerator
{
    /// <summary>
    /// Parse .bp source, generate README.md in output/.
    /// No code generation — only human-readable documentation.
    /// </summary>
    public static void Generate(ProgramNode program, string output, string title)
    {
        var md = BuildMarkdown(program, title);

        Directory.CreateDirectory(output);
        var path = Path.Combine(output, "README.md");
        File.WriteAllText(path, md);
        Console.WriteLine($"  [docs] {path}");
    }

    static string BuildMarkdown(ProgramNode program, string title)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"# {title}");
        sb.AppendLine();

        // Context
        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine("## Context");
            foreach (var v in program.Context.Variables)
            {
                sb.Append($"- `{v.Name}`: `{v.Type}`");
                if (v.DefaultValue != null) sb.Append($" = {v.DefaultValue}");
                sb.AppendLine();
            }
            sb.AppendLine();
        }

        // Enums
        foreach (var en in program.Enums)
        {
            sb.AppendLine($"## Enum: `{en.Name}`");
            foreach (var m in en.Members)
                sb.AppendLine($"- `{m}`");
            sb.AppendLine();
        }

        // States
        var allEvents = new HashSet<string>();

        void WalkStates(IEnumerable<StateDefNode> states, int depth)
        {
            foreach (var s in states)
            {
                var heading = new string('#', 3 + depth);
                sb.AppendLine($"{heading} {s.Name}");
                sb.AppendLine();

                // Transitions
                if (s.Transitions.Count > 0)
                {
                    sb.AppendLine("**Переходы**:");
                    foreach (var t in s.Transitions)
                    {
                        var ev = t.IsAlways ? "`always`" : t.IsEnterAuto ? "`enter`" : $"`{t.EventName}`";
                        var tgt = string.IsNullOrEmpty(t.Target) ? "(stay)" : $"`{t.Target}`";
                        sb.AppendLine($"- {ev} → {tgt}");
                        if (!t.IsAlways && !t.IsEnterAuto)
                            allEvents.Add(t.EventName);
                    }
                    sb.AppendLine();
                }

                // Guards
                var withGuard = s.Transitions.Where(t => t.Guard != null).ToList();
                if (withGuard.Count > 0)
                {
                    sb.AppendLine("**Гарды**:");
                    foreach (var t in withGuard)
                        sb.AppendLine($"- `[{t.Guard}]` → `{t.Target}`");
                    sb.AppendLine();
                }

                // Variables
                if (s.Variables.Count > 0)
                {
                    sb.AppendLine("**Переменные**:");
                    foreach (var v in s.Variables)
                    {
                        sb.Append($"- `{v.Name}`: `{v.Type}`");
                        if (v.DefaultValue != null) sb.Append($" = {v.DefaultValue}");
                        sb.AppendLine();
                    }
                    sb.AppendLine();
                }

                // Timers
                if (s.Timers.Count > 0)
                {
                    sb.AppendLine("**Таймеры**:");
                    foreach (var t in s.Timers)
                    {
                        sb.Append($"- After `{t.Duration}`");
                        if (t.Guard != null) sb.Append($" [{t.Guard}]");
                        sb.AppendLine($" → `{t.Target}`");
                    }
                    sb.AppendLine();
                }

                // Actions (enter / exit)
                foreach (var a in s.Actions)
                {
                    var header = a.Type == ActionType.Enter ? "enter" : "exit";
                    sb.AppendLine($"**{header}**:");
                    sb.AppendLine("```");
                    sb.AppendLine(a.Body.Replace("\r", ""));
                    sb.AppendLine("```");
                    sb.AppendLine();
                }

                WalkStates(s.NestedStates, depth + 1);
            }
        }

        if (program.States.Count > 0)
        {
            sb.AppendLine("## States");
            sb.AppendLine();
            WalkStates(program.States, 0);
        }

        // Parallel blocks
        foreach (var pb in program.ParallelBlocks)
        {
            sb.AppendLine($"## Parallel Block: `{pb.Name}`");
            sb.AppendLine();
            WalkStates(pb.States, 1);
        }

        // Events
        if (allEvents.Count > 0)
        {
            sb.AppendLine("## Events");
            foreach (var e in allEvents.OrderBy(x => x))
                sb.AppendLine($"- `{e}`");
            sb.AppendLine();
        }

        // Entry
        foreach (var entry in program.Entries)
        {
            sb.AppendLine("## Entry");
            sb.AppendLine();
            sb.AppendLine($"`{entry.Name}()`");
            sb.AppendLine();
            if (!string.IsNullOrEmpty(entry.Body))
            {
                sb.AppendLine("```");
                sb.AppendLine(entry.Body.Replace("\r", ""));
                sb.AppendLine("```");
            }
            else if (entry.BodyLines.Count > 0)
            {
                sb.AppendLine("```");
                foreach (var line in entry.BodyLines)
                    sb.AppendLine(line.Replace("\r", ""));
                sb.AppendLine("```");
            }
            sb.AppendLine();
        }

        // Kernels
        foreach (var k in program.Kernels)
        {
            sb.AppendLine($"## Kernel: `{k.Name}`");
            sb.AppendLine();
            if (k.Parameters.Count > 0)
            {
                sb.AppendLine("**Parameters**:");
                foreach (var p in k.Parameters)
                    sb.AppendLine($"- `{p.Name}`: `{p.Type}`");
                sb.AppendLine();
            }
        }

        return sb.ToString();
    }
}
