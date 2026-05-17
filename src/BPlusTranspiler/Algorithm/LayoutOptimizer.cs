using System.Diagnostics;
using System.IO;
using System.Text;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Generators;

namespace BPlusTranspiler.Algorithm;

public class LayoutOptimizer
{
    private NeuralPredictor? _model;

    public LayoutOptimizer(string modelPath)
    {
        _model = NeuralPredictor.Load(modelPath);
    }

    public LayoutOptimizer(NeuralPredictor model)
    {
        _model = model;
    }

    public MetalConfig Optimize(int candidates = 10000)
    {
        MetalConfig? bestConfig = null;
        double bestTimeMs = double.MaxValue;

        foreach (var config in GenerateCandidates(candidates))
        {
            double predictedMs = PredictMs(config);
            if (predictedMs < bestTimeMs)
            {
                bestTimeMs = predictedMs;
                bestConfig = config;
            }
        }

        if (bestConfig != null)
            bestConfig.Enabled = true;
        else
            bestConfig = new MetalConfig { Enabled = true };

        return bestConfig;
    }

    public MetalConfig OptimizeWithFallback(int candidates = 10000)
    {
        if (_model != null && _model.ValR2 >= 0.3)
            return Optimize(candidates);

        return GreedySearch(candidates);
    }

    public MetalConfig GreedySearch(int candidates = 10000)
    {
        var rng = new Random(42);
        double bestTime = double.MaxValue;
        MetalConfig bestConfig = new MetalConfig { Enabled = true, Tier = MemoryTier.L0 };

        for (int i = 0; i < candidates; i++)
        {
            var config = MetalConfig.Random();
            double time = MeasureConfigTime(config);

            if (time < bestTime)
            {
                bestTime = time;
                bestConfig = config;
            }
        }

        bestConfig.Enabled = true;
        return bestConfig;
    }

    private double MeasureConfigTime(MetalConfig config)
    {
        int cacheKB = config.Tier.HasValue ? config.Tier.Value switch
        {
            MemoryTier.L0 => 4,
            MemoryTier.L1 => 64,
            MemoryTier.L2 => 256,
            MemoryTier.L3 => 1024,
            MemoryTier.Ram => 8192,
            _ => 128
        } : 128;

        string runDir = Path.Combine(Path.GetTempPath(), "bplus_layout_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(runDir);

        try
        {
            var sb = new StringBuilder();
            sb.AppendLine("using System; using System.Diagnostics;");
            sb.AppendLine("class Bench {");
            sb.AppendLine("    static long[] arr;");
            sb.AppendLine("    static long acc;");
            sb.AppendLine("    static void Main() {");
            sb.AppendLine($"        arr = new long[{cacheKB * 1024 / 8}];");
            sb.AppendLine("        for (int i = 0; i < arr.Length; i++) arr[i] = i;");
            sb.AppendLine("        var sw = Stopwatch.StartNew();");
            sb.AppendLine("        for (int iter = 0; iter < 200; iter++) {");
            sb.AppendLine("            for (int i = 0; i < 10000; i++) {");
            sb.AppendLine("                int idx = (i * 7 + iter * 3) % arr.Length;");
            sb.AppendLine("                acc += arr[idx];");
            sb.AppendLine("            }");
            sb.AppendLine("        }");
            sb.AppendLine("        sw.Stop();");
            sb.AppendLine("        Console.Write(sw.Elapsed.TotalMilliseconds.ToString());");
            sb.AppendLine("    }");
            sb.AppendLine("}");

            string csPath = Path.Combine(runDir, "bench.cs");
            File.WriteAllText(csPath, sb.ToString());

            string cscPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"Microsoft.NET\Framework64\v4.0.30319\csc.exe");

            if (!File.Exists(cscPath))
                return cacheKB / 64.0 * 0.1;

            var psi = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = $"/c \"{cscPath}\" /out:\"{runDir}\\bench.exe\" \"{csPath}\" 2>nul",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                CreateNoWindow = true
            };

            var compile = Process.Start(psi);
            compile?.WaitForExit(30000);

            if (!File.Exists(Path.Combine(runDir, "bench.exe")))
            {
                try { Directory.Delete(runDir, true); } catch { }
                return cacheKB / 64.0 * 0.1;
            }

            var runPsi = new ProcessStartInfo
            {
                FileName = Path.Combine(runDir, "bench.exe"),
                UseShellExecute = false,
                RedirectStandardOutput = true,
                CreateNoWindow = true
            };

            var run = Process.Start(runPsi);
            run?.WaitForExit(30000);
            string output = run?.StandardOutput.ReadToEnd() ?? "";

            try { Directory.Delete(runDir, true); } catch { }

            if (double.TryParse(output.Trim(), out double ms))
                return ms;
            return cacheKB / 64.0 * 0.1;
        }
        catch
        {
            try { Directory.Delete(runDir, true); } catch { }
            return cacheKB / 64.0 * 0.1;
        }
    }

    public double PredictMs(MetalConfig config)
    {
        if (_model == null) return MeasureConfigTime(config);
        return _model.PredictMs(DataCollector.ConfigToFeatures(config));
    }

    private static IEnumerable<MetalConfig> GenerateCandidates(int count)
    {
        var tiers = new[] { MemoryTier.L0, MemoryTier.L1, MemoryTier.L2, MemoryTier.L3 };
        for (int i = 0; i < count; i++)
        {
            var cfg = new MetalConfig { Enabled = true };
            cfg.Tier = tiers[i % tiers.Length];
            cfg.CacheAlign = 64 << (i % 4);
            cfg.CachePin = i % 2 == 0;
            cfg.HotPath = i % 3 != 0;
            cfg.Packed = i % 2 == 0;
            yield return cfg;
        }
    }
}

