using System.Text;
using BPlus.Core.Ast;

namespace BPlus.Tooling;

public static class BPlusVisualizer
{
    public static string GenerateHtml(ProgramNode program, string title)
    {
        var mermaid = GenerateMermaid(program);
        return $@"<!DOCTYPE html>
<html lang=""en"">
<head>
<meta charset=""UTF-8"">
<meta name=""viewport"" content=""width=device-width, initial-scale=1.0"">
<title>{title} — B+ State Diagram</title>
<script src=""https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js""></script>
<style>
  body {{ font-family: 'Segoe UI', sans-serif; margin: 20px; background: #1e1e2e; color: #cdd6f4; }}
  h1 {{ color: #cba6f7; text-align: center; }}
  .controls {{ text-align: center; margin: 16px 0; }}
  .controls button {{ background: #45475a; color: #cdd6f4; border: none; padding: 8px 20px; margin: 0 4px; border-radius: 6px; cursor: pointer; font-size: 14px; }}
  .controls button:hover {{ background: #585b70; }}
  .mermaid {{ background: #313244; padding: 20px; border-radius: 8px; overflow: auto; }}
  #log {{ margin-top: 20px; padding: 12px; background: #11111b; border-radius: 6px; font-family: monospace; font-size: 13px; min-height: 60px; white-space: pre-wrap; }}
</style>
</head>
<body>
<h1>&#x1F4CA; {title}</h1>
<div class=""controls"">
  <button onclick=""document.querySelector('.mermaid svg')?.remove();document.querySelector('.mermaid').innerHTML='{mermaid.Replace("\"", "&quot;").Replace("\n", "\\n")}';mermaid.run({{nodes:[document.querySelector('.mermaid')]}})"">Reset</button>
  <button onclick=""downloadSvg()"">Download SVG</button>
  <button onclick=""toggleTheme()"">Theme</button>
</div>
<div class=""mermaid"">
{mermaid}
</div>
<div id=""log"">B+ State Diagram — click on a state or transition</div>
<script>
  mermaid.initialize({{ startOnLoad: true, theme: 'dark', securityLevel: 'loose' }});
  function toggleTheme() {{ document.body.style.background = document.body.style.background === '#1e1e2e' ? '#f5f5f5' : '#1e1e2e'; }}
  function downloadSvg() {{ var s = document.querySelector('.mermaid svg'); if(!s) return; var c = s.cloneNode(true); var b = new Blob([new XMLSerializer().serializeToString(c)],{{type:'image/svg+xml'}}); var a = document.createElement('a'); a.href = URL.createObjectURL(b); a.download = '{Sanitize(title)}.svg'; a.click(); }}
  document.addEventListener('click',function(e){{ var el = e.target.closest('g'); if(el) document.getElementById('log').textContent = el.querySelector('title')?.textContent || el.querySelector('text')?.textContent || 'clicked'; }});
</script>
</body>
</html>";
    }

    public static string GenerateMermaid(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("stateDiagram-v2");
        sb.AppendLine("    direction LR");

        // Build flat list of all state names (no nesting in mermaid)
        var allNames = new List<string>();
        var allTransitions = new List<(string from, string to, string label)>();

        void Walk(IEnumerable<StateDefNode> states)
        {
            foreach (var s in states)
            {
                allNames.Add(s.Name);
                foreach (var t in s.Transitions)
                {
                    if (string.IsNullOrEmpty(t.Target)) continue;
                    var label = t.EventName;
                    if (t.Parameters.Count > 0)
                        label += $"({string.Join(",", t.Parameters.Select(p => $"{p.Name}:{p.Type}"))})";
                    if (t.Guard != null) label += $" [{t.Guard}]";
                    if (t.IsAsync) label = "async " + label;
                    allTransitions.Add((s.Name, t.Target, label));
                }
                foreach (var t in s.Timers)
                {
                    if (string.IsNullOrEmpty(t.Target)) continue;
                    var label = $"after_{t.Duration}";
                    if (t.Guard != null) label += $" [{t.Guard}]";
                    allTransitions.Add((s.Name, t.Target, label));
                }
                if (s.Actions.Count > 0)
                    allTransitions.Add((s.Name, s.Name, "enter¦exit"));
                Walk(s.NestedStates);
            }
        }

        Walk(program.States);

        // Parallel blocks
        foreach (var pb in program.ParallelBlocks)
        {
            sb.AppendLine($"    state \"? {pb.Name}\" as par_{pb.Name} {{");
            foreach (var s in pb.States)
            {
                allNames.Add(s.Name);
                sb.AppendLine($"        state \"{s.Name}\" as {s.Name}");
                foreach (var t in s.Transitions)
                {
                    if (string.IsNullOrEmpty(t.Target)) continue;
                    var label = t.EventName;
                    if (t.Parameters.Count > 0)
                        label += $"({string.Join(",", t.Parameters.Select(p => $"{p.Name}:{p.Type}"))})";
                    if (t.Guard != null) label += $" [{t.Guard}]";
                    if (t.IsAsync) label = "async " + label;
                    allTransitions.Add((s.Name, t.Target, label));
                }
                foreach (var t in s.Timers)
                {
                    if (string.IsNullOrEmpty(t.Target)) continue;
                    var label = $"after_{t.Duration}";
                    if (t.Guard != null) label += $" [{t.Guard}]";
                    allTransitions.Add((s.Name, t.Target, label));
                }
            }
            sb.AppendLine("    }");
        }

        // Declare all non-parallel states
        foreach (var name in allNames)
        {
            if (program.ParallelBlocks.Any(pb => pb.States.Any(s => s.Name == name))) continue;
            sb.AppendLine($"    state \"{name}\"");
        }

        // Initial pointer
        var first = program.States.FirstOrDefault()?.Name;
        if (first != null)
            sb.AppendLine($"    [*] --> {first}");

        // Emit all transitions (dedup)
        var seen = new HashSet<string>();
        foreach (var (from, to, label) in allTransitions)
        {
            var key = $"{from}-->{to}:{label}";
            if (seen.Add(key))
                sb.AppendLine($"    {from} --> {to}: {label}");
        }

        return sb.ToString();
    }

    public static Dictionary<string, string> GenerateFiles(ProgramNode program, string title)
    {
        return new Dictionary<string, string>
        {
            { $"{Sanitize(title)}.html", GenerateHtml(program, title) },
            { $"{Sanitize(title)}.mmd", GenerateMermaid(program) }
        };
    }

    private static string Sanitize(string name) =>
        string.Join("_", name.Split(Path.GetInvalidFileNameChars()));
}
