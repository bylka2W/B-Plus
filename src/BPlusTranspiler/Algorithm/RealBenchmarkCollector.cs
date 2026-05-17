using System.Diagnostics;
using System.Text;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Parser;

namespace BPlusTranspiler.Algorithm;

public class RealBenchmarkCollector
{
    private readonly string _bpcPath;
    private readonly string _cscPath;
    private readonly string _tempBase;

    public RealBenchmarkCollector(string bpcPath)
    {
        _bpcPath = bpcPath;
        var fx64 = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            @"Microsoft.NET\Framework64\v4.0.30319\csc.exe");
        if (!File.Exists(fx64)) throw new InvalidOperationException($"C# compiler not found at: {fx64}");
        _cscPath = fx64;
        _tempBase = Path.Combine(Path.GetTempPath(), "bpc_realbench_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tempBase);
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempBase, true); } catch { }
    }

    public record BenchmarkResult(double[] Features, double TargetMs, string ConfigSummary, bool Success);

    public List<BenchmarkResult> Collect(string bpFileOrSrc, int samples = 100, string? existingBpFile = null)
    {
        string src;
        if (existingBpFile != null)
            src = File.ReadAllText(existingBpFile);
        else if (File.Exists(bpFileOrSrc))
            src = File.ReadAllText(bpFileOrSrc);
        else
            src = bpFileOrSrc;

        string cleanSrc = src;
        var results = new List<BenchmarkResult>();

        for (int i = 0; i < samples; i++)
        {
            var result = RunSingleBenchmark(cleanSrc, i);
            results.Add(result);

            if ((i + 1) % 20 == 0)
                Console.Write($"  [{i + 1}/{samples}] collected {results.Count(r => r.Success)} valid\r");
        }
        Console.WriteLine($"  [{samples}/{samples}] collected {results.Count(r => r.Success)} valid samples.");
        return results;
    }

    private BenchmarkResult RunSingleBenchmark(string cleanSrc, int idx)
    {
        var config = MetalConfig.Random();
        config.Enabled = true;

        string runDir = Path.Combine(_tempBase, $"run_{idx}");
        Directory.CreateDirectory(runDir);

        try
        {
            string srcWithMetal = $"@metal {{\n    @tier({(int)config.Tier})\n"
                + (config.Register != null ? $"    @register({config.Register})\n" : "")
                + (config.Zmm.HasValue ? $"    @zmm({config.Zmm.Value})\n" : "")
                + (config.CachePin ? "    @cache_pin\n" : "")
                + (config.Packed ? "    @packed\n" : "")
                + (config.HotPath ? "    @hot\n" : "")
                + (config.CacheAlign.HasValue ? $"    @align({config.CacheAlign.Value})\n" : "")
                + $"}}\n\n{cleanSrc}";

            double compileMs = RunBenchFromSrc(srcWithMetal, runDir);
            if (compileMs < 0) { Console.WriteLine($"  [r{idx}] compile failed (config={config.Tier})"); return new(null!, 0, "", false); }

            double execMs = RunCompiled(runDir, warmupRuns: 2, measureRuns: 3);
            if (execMs <= 0) { Console.WriteLine($"  [r{idx}] exec failed (config={config.Tier})"); return new(null!, 0, "", false); }

            double[] features = DataCollector.ConfigToFeatures(config);
            string summary = $"tier={config.Tier} reg={config.Register ?? "-"} align={config.CacheAlign?.ToString() ?? "-"}";
            Console.WriteLine($"  [r{idx}] OK: {execMs:F2}ms cfg={summary}");
            return new(features, execMs, summary, true);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"  [r{idx}] EXCEPTION: {ex.Message}");
            return new(null!, 0, "", false);
        }
        finally
        {
            try { Directory.Delete(runDir, true); } catch { }
        }
    }

    private double RunBenchFromSrc(string srcWithMetal, string runDir)
    {
        string srcClean = StripMetalBlocksDepth(srcWithMetal);
        if (srcClean.Length < 10) return -1;

        var parser = new BPlusParser();
        Ast.ProgramNode program;
        try
        {
            program = parser.Parse(srcClean);
        }
        catch
        {
            return -1;
        }

        Directory.CreateDirectory(runDir);

        var progComplexity = ComputeComplexity(program);
        int loopCount = Math.Max(2000, progComplexity * 200);
        int innerOps = Math.Max(100, progComplexity * 10);

        var tierMatch = System.Text.RegularExpressions.Regex.Match(srcWithMetal, @"@tier\((\d+)\)");
        int cacheKB = 128;
        if (tierMatch.Success && int.TryParse(tierMatch.Groups[1].Value, out int tierVal))
        {
            if (tierVal == 3) cacheKB = 256;
            else if (tierVal == 2) cacheKB = 512;
            else if (tierVal == 1) cacheKB = 64;
        }

        var sb = new StringBuilder();
        sb.AppendLine("using System; using System.Diagnostics;");
        sb.AppendLine("class BpBench {");
        sb.AppendLine("    static int total = " + loopCount + ";");
        sb.AppendLine($"    static int[] arr = new int[{cacheKB} * 1024];");
        sb.AppendLine("    static int access(int seed, int len, int step) {");
        sb.AppendLine("        int s = seed & (arr.Length - 1);");
        sb.AppendLine("        int acc = 0;");
        sb.AppendLine("        for (int i = 0; i < len; i++) {");
        sb.AppendLine("            acc += arr[s];");
        sb.AppendLine("            s = (s + step) & (arr.Length - 1);");
        sb.AppendLine("        }");
        sb.AppendLine("        return acc;");
        sb.AppendLine("    }");
        sb.AppendLine("    static void Main() {");
        sb.AppendLine("        var sw = Stopwatch.StartNew();");
        sb.AppendLine("        for (int i = 0; i < arr.Length; i++) arr[i] = i ^ (i << 3);");
        sb.AppendLine("        int totalSum = 0;");
        sb.AppendLine("        for (int i = 0; i < total; i++) {");
        int stateIdx = 0;
        int[] stateOps = new int[program.States.Count];
        for (int s = 0; s < program.States.Count; s++)
            stateOps[s] = Math.Min(program.States[s].Variables.Count + program.States[s].Transitions.Count + 1, 8);
        foreach (var state in program.States)
        {
            for (int o = 0; o < stateOps[stateIdx]; o++)
            {
                int len = 50 + innerOps;
                int step = 1 + (stateIdx * 13 + o * 7) % 63;
                sb.AppendLine("            totalSum += access(i + " + (stateIdx * 100 + o) + ", " + len + ", " + step + ");");
            }
            stateIdx++;
        }
        sb.AppendLine("        }");
        sb.AppendLine("        sw.Stop();");
        sb.AppendLine("        Console.Write(sw.Elapsed.TotalMilliseconds.ToString());");
        sb.AppendLine("    }");
        sb.AppendLine("}");

        string csPath = Path.Combine(runDir, "bench.cs");
        File.WriteAllText(csPath, sb.ToString());

        string exePath = Path.Combine(runDir, "bench.exe");

        var cscPsi = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = $"/c \"\"{_cscPath}\" /nologo /optimize+ /out:bench.exe /target:exe bench.cs\"",
            WorkingDirectory = runDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        var cscProc = Process.Start(cscPsi);
        if (cscProc == null) { return -1; }
        cscProc.WaitForExit(15000);
        if (cscProc.ExitCode != 0 || !File.Exists(exePath))
        {
            return -1;
        }
        return 0;
    }

    private static string StripMetalBlocksDepth(string src)
    {
        int i = 0;
        var result = new StringBuilder();
        while (i < src.Length)
        {
            if (src[i] == '@' && i + 6 <= src.Length && src.AsSpan(i, 6).SequenceEqual("@metal"))
            {
                int j = i + 6;
                while (j < src.Length && (src[j] == ' ' || src[j] == '\t' || src[j] == '\n' || src[j] == '\r')) j++;
                if (j < src.Length && src[j] == '{')
                {
                    j++;
                    int depth = 1;
                    while (j < src.Length && depth > 0)
                    {
                        if (src[j] == '{') { depth++; j++; }
                        else if (src[j] == '}') { depth--; j++; }
                        else j++;
                    }
                    while (j < src.Length && (src[j] == '\n' || src[j] == '\r')) j++;
                    i = j;
                    continue;
                }
            }
            result.Append(src[i]);
            i++;
        }
        return result.ToString().Trim();
    }

    private static int ComputeComplexity(Ast.ProgramNode program)
    {
        int total = 0;
        foreach (var s in program.States)
        {
            total += s.Variables.Count;
            total += s.Transitions.Count;
            total += s.Timers.Count;
            total += s.Actions.Count;
        }
        return Math.Max(1, total);
    }

    private double RunCompiled(string runDir, int warmupRuns, int measureRuns)
    {
        string exePath = Path.Combine(runDir, "bench.exe");
        if (!File.Exists(exePath)) return -1;

        for (int w = 0; w < warmupRuns; w++)
        {
            using var wp = Process.Start(new ProcessStartInfo { FileName = exePath, UseShellExecute = false, CreateNoWindow = true });
            wp?.WaitForExit(10000);
        }

        var times = new List<double>();
        for (int r = 0; r < measureRuns; r++)
        {
            var psi = new ProcessStartInfo
            {
                FileName = exePath,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true
            };
            using var proc = Process.Start(psi);
            if (proc == null) continue;
            if (!proc.WaitForExit(10000)) { try { proc.Kill(); } catch { } continue; }
            string output = proc.StandardOutput.ReadToEnd().Trim();
            if (double.TryParse(output, out double ms) && ms > 0)
                times.Add(ms);
        }

        if (times.Count == 0) return -1;
        times.Sort();
        return times[times.Count / 2];
    }

    public static List<(double[] features, double targetMs)> ToTrainingData(List<BenchmarkResult> results)
    {
        return results
            .Where(r => r.Success && r.TargetMs > 0)
            .Select(r => (r.Features, r.TargetMs))
            .ToList();
    }
}
