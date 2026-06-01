using System.Diagnostics;
using System.Text.RegularExpressions;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Generators;

namespace BPlusTranspiler;

public static class BPlusProfileRunner
{
    public static int Run(string bpFile, int runs)
    {
        var src = File.ReadAllText(bpFile);
        var prog = new Parser.BPlusParser().Parse(src);
        var title = Path.GetFileNameWithoutExtension(bpFile);

        // Generate Python
        var pyGen = new PythonGenerator();
        var files = pyGen.GenerateFiles(prog);
        var pyCode = files.Values.FirstOrDefault() ?? "";
        pyCode = NormalizePyCode(pyCode);

        var tmpDir = Path.Combine(Path.GetTempPath(), "bplus_prof_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tmpDir);
        File.WriteAllText(Path.Combine(tmpDir, "generated.py"), pyCode);

        // Build harness with transition counting
        var harness =
"import sys\n" +
$"sys.path.insert(0, {EscapePythonPath(tmpDir)})\n" +
"import generated\n" +
"from collections import Counter\n" +
"\n" +
"# Transition counter: (from_state, to_state) -> count\n" +
"transitions = Counter()\n" +
"\n" +
"# Monkey-patch handle_event on every state class to count transitions\n" +
"_state_names = []\n" +
"for _name in dir(generated):\n" +
"    _cls = getattr(generated, _name)\n" +
"    if isinstance(_cls, type) and _name != 'State' and hasattr(_cls, 'handle_event'):\n" +
"        _state_names.append(_name)\n" +
"        _orig = _cls.handle_event\n" +
"        def _make_wrapped(orig, cls_name):\n" +
"            def wrapped(self, event):\n" +
"                result = orig(self, event)\n" +
"                if result is not None:\n" +
"                    transitions[(cls_name, result.__class__.__name__)] += 1\n" +
"                return result\n" +
"            return wrapped\n" +
"        _cls.handle_event = _make_wrapped(_orig, _name)\n" +
"\n" +
"if not _state_names:\n" +
"    print('ERROR: no state classes found')\n" +
"    sys.exit(1)\n" +
"\n" +
"state = getattr(generated, _state_names[0])()\n" +
"state.enter()\n" +
"event = 'timer'\n" +
$"for _i in range({runs}):\n" +
"    ns = state.handle_event(event)\n" +
"    if ns is not None:\n" +
"        state.exit()\n" +
"        state = ns\n" +
"        state.enter()\n" +
"\n" +
"total = sum(transitions.values())\n" +
"print(f'TRANSITIONS:{total}')\n" +
"for (f, t), c in sorted(transitions.items()):\n" +
"    pct = (c / total * 100) if total > 0 else 0\n" +
"    print(f'EDGE:{f}|{t}|{c}|{pct:.1f}')\n";

        var harnessPy = Path.Combine(tmpDir, "prof_harness.py");
        File.WriteAllText(harnessPy, harness);

        // Find python
        var python = FindPython();
        if (python == null)
        {
            Console.Error.WriteLine("Python not found. Install Python 3 or add to PATH.");
            return 1;
        }

        // Run
        var psi = new ProcessStartInfo(python, $"-X utf8 \"{harnessPy}\"")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8
        };
        psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
        var proc = Process.Start(psi);
        if (proc == null)
        {
            Console.Error.WriteLine("Failed to start Python.");
            return 1;
        }
        proc.WaitForExit(60000);

        var stdout = proc.StandardOutput.ReadToEnd();
        var stderr = proc.StandardError.ReadToEnd();

        // Cleanup
        try { Directory.Delete(tmpDir, true); } catch { }

        if (proc.ExitCode != 0)
        {
            Console.Error.WriteLine("Profile harness failed:");
            if (!string.IsNullOrEmpty(stderr)) Console.Error.WriteLine(stderr);
            return 1;
        }

        // Parse results
        var ic = System.Globalization.CultureInfo.InvariantCulture;
        var edges = new List<(string from, string to, int count, double pct)>();
        int totalTransitions = 0;

        foreach (var line in stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = line.Trim().Split(':');
            if (parts.Length < 2) continue;
            var key = parts[0];
            var val = parts[1];

            if (key == "TRANSITIONS")
                int.TryParse(val, out totalTransitions);
            else if (key == "EDGE")
            {
                var edge = val.Split('|');
                if (edge.Length >= 4 &&
                    int.TryParse(edge[2], out var ec) &&
                    double.TryParse(edge[3], System.Globalization.NumberStyles.Any, ic, out var ep))
                {
                    edges.Add((edge[0], edge[1], ec, ep));
                }
            }
        }

        // Output
        Console.WriteLine($"Transition Profile ({runs} runs):");
        var maxLen = 20;
        foreach (var (f, t, _, _) in edges)
        {
            var l = f.Length + t.Length + 3;
            if (l > maxLen) maxLen = l;
        }
        foreach (var (f, t, c, p) in edges)
        {
            var label = $"{f} → {t}";
            var pad = maxLen - label.Length;
            if (pad < 0) pad = 0;
            Console.WriteLine($"  {label}{new string(' ', pad)}  {c,6} ({p.ToString("F1", ic)}%)");
        }
        Console.WriteLine($"  {"Total"}{new string(' ', maxLen - 5)}  {totalTransitions,6}");

        return 0;
    }

    static string? FindPython()
    {
        var candidates = new[] { "python3", "python.exe", "python3.exe", "py" };
        foreach (var c in candidates)
        {
            try
            {
                var psi = new ProcessStartInfo("where", c) { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
                var proc = Process.Start(psi);
                if (proc != null)
                {
                    proc.WaitForExit(3000);
                    if (proc.ExitCode == 0)
                    {
                        var path = proc.StandardOutput.ReadToEnd().Trim().Split('\n', '\r')[0].Trim();
                        if (File.Exists(path)) return path;
                    }
                }
            }
            catch { }
        }
        return null;
    }

    static string EscapePythonPath(string path) => "r'" + path.Replace("\\", "\\\\") + "'";

    static string NormalizePyCode(string code)
    {
        code = Regex.Replace(code, @"\bfalse\b", "False");
        code = Regex.Replace(code, @"\btrue\b", "True");
        code = Regex.Replace(code, @"\bnull\b", "None");
        return code;
    }
}
