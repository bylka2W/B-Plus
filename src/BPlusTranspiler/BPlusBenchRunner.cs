using System.Diagnostics;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Generators;

namespace BPlusTranspiler;

public static class BPlusBenchRunner
{
    public static int Run(string bpFile, int iterations)
    {
        var src = File.ReadAllText(bpFile);
        var prog = new Parser.BPlusParser().Parse(src);
        var title = Path.GetFileNameWithoutExtension(bpFile);

        // Generate Python
        var pyGen = new PythonGenerator();
        var files = pyGen.GenerateFiles(prog);
        var pyCode = files.Values.FirstOrDefault() ?? "";

        var tmpDir = Path.Combine(Path.GetTempPath(), "bplus_bench_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tmpDir);
        var genPy = Path.Combine(tmpDir, "generated.py");
        File.WriteAllText(genPy, pyCode);

        // Build harness
        var harness =
"import sys\n" +
"import os\n" +
$"sys.path.insert(0, {EscapePythonPath(tmpDir)})\n" +
"import generated\n" +
"import time\n" +
"\n" +
"ctx = generated\n" +
"state_classes = [v for v in dir(generated) if isinstance(getattr(generated, v), type) and v != 'State' and issubclass(getattr(generated, v), getattr(generated, 'State', type))]\n" +
"if not state_classes:\n" +
"    print('ERROR: no state classes found')\n" +
"    sys.exit(1)\n" +
"first_state = state_classes[0]\n" +
"state = getattr(generated, first_state)()\n" +
"\n" +
"if hasattr(generated, 'main'):\n" +
"    pass\n" +
"\n" +
"state.enter()\n" +
"event = 'timer'\n" +
"times = []\n" +
$"for i in range({iterations}):\n" +
"    t0 = time.perf_counter()\n" +
"    ns = state.handle_event(event)\n" +
"    t1 = time.perf_counter()\n" +
"    times.append(t1 - t0)\n" +
"    if ns is not None:\n" +
"        state.exit()\n" +
"        state = ns\n" +
"        state.enter()\n" +
"\n" +
"total = sum(times)\n" +
"avg = total / len(times)\n" +
"mn = min(times)\n" +
"mx = max(times)\n" +
"ops = len(times) / total\n" +
"print(f'ITERATIONS:{len(times)}')\n" +
"print(f'TOTAL:{total:.6f}')\n" +
"print(f'AVG:{avg:.9f}')\n" +
"print(f'MIN:{mn:.9f}')\n" +
"print(f'MAX:{mx:.9f}')\n" +
"print(f'OPS:{ops:.2f}')\n";

        var harnessPy = Path.Combine(tmpDir, "bench_harness.py");
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
            Console.Error.WriteLine("Benchmark harness failed:");
            if (!string.IsNullOrEmpty(stderr)) Console.Error.WriteLine(stderr);
            return 1;
        }

        // Parse results
        int iters = 0;
        double total = 0, avg = 0, min = 0, max = 0, ops = 0;
        foreach (var line in stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = line.Split(':');
            if (parts.Length < 2) continue;
            var key = parts[0].Trim();
            var val = parts[1].Trim();
            switch (key)
            {
                case "ITERATIONS": int.TryParse(val, out iters); break;
                case "TOTAL": double.TryParse(val, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out total); break;
                case "AVG": double.TryParse(val, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out avg); break;
                case "MIN": double.TryParse(val, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out min); break;
                case "MAX": double.TryParse(val, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out max); break;
                case "OPS": double.TryParse(val, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out ops); break;
            }
        }

        // Output results
        var ic = System.Globalization.CultureInfo.InvariantCulture;
        Console.WriteLine($"Benchmark: {title}");
        Console.WriteLine($"  Iterations: {iters.ToString("N0", ic)}");
        Console.WriteLine($"  Total time: {total.ToString("F3", ic)}s");
        Console.WriteLine($"  Avg: {(avg*1_000_000).ToString("F0", ic)}µs per run");
        Console.WriteLine($"  Min: {(min*1_000_000).ToString("F0", ic)}µs");
        Console.WriteLine($"  Max: {(max*1_000_000).ToString("F0", ic)}µs");
        Console.WriteLine($"  Ops/sec: {ops.ToString("N0", ic)}");

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
}
