using System.Text;
using System.Text.RegularExpressions;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.DocGen;

public static partial class BPlusDocGenerator
{
    public static Dictionary<string, string> GenerateFiles(ProgramNode program, string title)
    {
        var md = GenerateMarkdown(program, title);
        return new Dictionary<string, string>
        {
            { $"{Sanitize(title)}.md", md },
            { $"{Sanitize(title)}.html", MdToHtml(md, title) }
        };
    }

    public static string GenerateMarkdown(ProgramNode program, string title)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"# {title}");
        sb.AppendLine();
        sb.AppendLine($"Auto-generated documentation for `{title}.bp`.");
        sb.AppendLine();

        if (program.Context is { Variables.Count: > 0 })
        {
            sb.AppendLine("## Global Context");
            sb.AppendLine();
            sb.AppendLine("| Variable | Type | Default |");
            sb.AppendLine("|----------|------|---------|");
            foreach (var v in program.Context.Variables)
                sb.AppendLine($"| `{v.Name}` | `{v.Type}` | `{v.DefaultValue ?? "-"}` |");
            sb.AppendLine();
        }

        foreach (var en in program.Enums)
        {
            sb.AppendLine($"## Enum: `{en.Name}`");
            sb.AppendLine();
            foreach (var m in en.Members)
                sb.AppendLine($"- `{m}`");
            sb.AppendLine();
        }

        void EmitStates(IEnumerable<StateDefNode> states, int depth)
        {
            foreach (var s in states)
            {
                var heading = new string('#', 2 + depth);
                sb.AppendLine($"{heading} State: `{s.Name}`");
                sb.AppendLine();

                if (s.BaseClass != null) sb.AppendLine($"- **Extends:** `{s.BaseClass}`");
                if (s.GenericParam != null) sb.AppendLine($"- **Generic:** `<{s.GenericParam}>`");
                if (s.IsBaseClass) sb.AppendLine("- **Is base class**");
                if (s.BaseClass != null || s.GenericParam != null || s.IsBaseClass) sb.AppendLine();

                if (s.Variables.Count > 0)
                {
                    sb.AppendLine("### Variables");
                    sb.AppendLine("| Name | Type | Default |");
                    sb.AppendLine("|------|------|---------|");
                    foreach (var v in s.Variables)
                        sb.AppendLine($"| `{v.Name}` | `{v.Type}` | `{v.DefaultValue ?? "-"}` |");
                    sb.AppendLine();
                }

                if (s.Transitions.Count > 0)
                {
                    sb.AppendLine("### Transitions");
                    sb.AppendLine("| Event → Target | Guard | Body | Async |");
                    sb.AppendLine("|--------------|-------|------|-------|");
                    foreach (var t in s.Transitions)
                    {
                        var ev = t.IsAlways ? "always" : t.IsEnterAuto ? "enter" : $"`{t.EventName}`";
                        if (t.IsSignal) ev = $"signal `{t.SignalName}`";
                        var tgt = string.IsNullOrEmpty(t.Target) ? "-" : $"`{t.Target}`";
                        var g = t.Guard != null ? $"`[{t.Guard}]`" : "-";
                        sb.AppendLine($"| {ev} → {tgt} | {g} | {(t.Body != null ? "yes" : "-")} | {(t.IsAsync ? "yes" : "-")} |");
                    }
                    sb.AppendLine();
                }

                if (s.Actions.Count > 0)
                {
                    sb.AppendLine("### Actions");
                    foreach (var a in s.Actions)
                        sb.AppendLine($"- **{a.Type}:** `{a.Body}`");
                    sb.AppendLine();
                }

                if (s.Timers.Count > 0)
                {
                    sb.AppendLine("### Timers");
                    foreach (var t in s.Timers)
                        sb.AppendLine($"- After `{t.Duration}`{(t.Guard != null ? $" [{t.Guard}]" : "")} → `{t.Target}`");
                    sb.AppendLine();
                }

                if (depth == 0 && program.Imports.Count > 0)
                {
                    sb.AppendLine("### Imports");
                    foreach (var imp in program.Imports)
                        sb.AppendLine($"- `{imp.Path}`");
                    sb.AppendLine();
                }

                sb.AppendLine("---");
                sb.AppendLine();
                EmitStates(s.NestedStates, depth + 1);
            }
        }

        EmitStates(program.States, 2);

        foreach (var pb in program.ParallelBlocks)
        {
            sb.AppendLine($"## Parallel Block: `{pb.Name}`");
            sb.AppendLine();
            EmitStates(pb.States, 3);
        }

        return sb.ToString();
    }

    private static string MdToHtml(string md, string title)
    {
        var lines = md.Split('\n');
        var sb = new StringBuilder();
        var inTable = false;

        sb.AppendLine("<!DOCTYPE html><html lang=\"en\"><head>");
        sb.AppendLine($"<meta charset=\"UTF-8\"><title>{EscapeHtml(title)} — B+ Docs</title>");
        sb.AppendLine("<style>");
        sb.AppendLine("body{font-family:'Segoe UI',sans-serif;max-width:960px;margin:0 auto;padding:20px;background:#1e1e2e;color:#cdd6f4;line-height:1.6}");
        sb.AppendLine("h1,h2,h3,h4{color:#cba6f7}a{color:#89b4fa}");
        sb.AppendLine("code{background:#313244;padding:2px 6px;border-radius:3px;font-size:.9em}");
        sb.AppendLine("pre{background:#181825;padding:12px;border-radius:6px;overflow-x:auto}");
        sb.AppendLine("table{border-collapse:collapse;width:100%;margin:12px 0}");
        sb.AppendLine("th,td{border:1px solid #45475a;padding:8px 12px;text-align:left}");
        sb.AppendLine("th{background:#313244}tr:nth-child(even){background:#181825}");
        sb.AppendLine("hr{border:none;border-top:1px solid #45475a;margin:24px 0}");
        sb.AppendLine("</style></head><body>");

        foreach (var raw in lines)
        {
            var line = raw.TrimEnd();

            if (line == "") { if (inTable) { sb.AppendLine("</tbody></table>"); inTable = false; } continue; }
            if (line.StartsWith("---")) { sb.AppendLine("<hr>"); continue; }

            if (line.StartsWith("|") && line.EndsWith("|"))
            {
                var cells = line.Split('|', StringSplitOptions.RemoveEmptyEntries)
                    .Select(c => c.Trim()).ToArray();

                if (!inTable)
                {
                    sb.AppendLine("<table><thead><tr>");
                    foreach (var c in cells) sb.AppendLine($"<th>{RenderInline(c)}</th>");
                    sb.AppendLine("</tr></thead><tbody>");
                    inTable = true;
                }
                else if (cells.All(c => c.All(ch => ch == '-' || ch == ':')))
                {
                    // separator row — skip
                }
                else
                {
                    sb.AppendLine("<tr>");
                    foreach (var c in cells) sb.AppendLine($"<td>{RenderInline(c)}</td>");
                    sb.AppendLine("</tr>");
                }
                continue;
            }

            if (inTable) { sb.AppendLine("</tbody></table>"); inTable = false; }

            if (line.StartsWith("#### "))
                sb.AppendLine($"<h4>{RenderInline(line[5..])}</h4>");
            else if (line.StartsWith("### "))
                sb.AppendLine($"<h3>{RenderInline(line[4..])}</h3>");
            else if (line.StartsWith("## "))
                sb.AppendLine($"<h2>{RenderInline(line[3..])}</h2>");
            else if (line.StartsWith("# "))
                sb.AppendLine($"<h1>{RenderInline(line[2..])}</h1>");
            else if (line.StartsWith("- ") || line.StartsWith("* "))
                sb.AppendLine($"<li>{RenderInline(line[2..])}</li>");
            else
                sb.AppendLine($"<p>{RenderInline(line)}</p>");
        }

        if (inTable) sb.AppendLine("</tbody></table>");

        sb.AppendLine("</body></html>");
        return sb.ToString();
    }

    private static string RenderInline(string text)
    {
        text = EscapeHtml(text);
        text = InlineCodeRegex().Replace(text, m => $"<code>{m.Groups[1].Value}</code>");
        text = BoldRegex().Replace(text, m => $"<strong>{m.Groups[1].Value}</strong>");
        return text;
    }

    private static string EscapeHtml(string text) =>
        text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    [GeneratedRegex(@"`([^`]+)`")]
    private static partial Regex InlineCodeRegex();
    [GeneratedRegex(@"\*\*([^*]+)\*\*")]
    private static partial Regex BoldRegex();

    private static string Sanitize(string name) =>
        string.Join("_", name.Split(Path.GetInvalidFileNameChars()));
}
