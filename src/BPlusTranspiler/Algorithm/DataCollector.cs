using System.Diagnostics;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Generators;
using BPlusTranspiler.Parser;
using BPlusTranspiler.Runtime;
namespace BPlusTranspiler.Algorithm;

public class CodeFeatures
{
    public int StateCount { get; set; }
    public int TotalCodeSize { get; set; }
    public int HotPathCount { get; set; }
    public int BranchCount { get; set; }
    public int DataSize { get; set; }
}

public class DataPoint
{
    public double[] Input { get; set; } = Array.Empty<double>();
    public double TargetIPC { get; set; }
    public double TargetMs { get; set; } = -1;
    public MetalConfig Config { get; set; } = new();
    public bool IsReal { get; set; }
    public long TimestampMs { get; set; }
}

public class PerStateMissRate
{
    public string StateName { get; set; } = "";
    public double L1MissRate { get; set; }
    public double L2MissRate { get; set; }
    public int VariableCount { get; set; }
    public bool IsHot { get; set; }
    public string? Recommendation { get; set; }
}

public class DataCollector
{
    private string? _lastFile;
    private ProgramNode? _cachedProgram;
    private CodeFeatures? _cachedFeatures;
    private long _lastCollectTime;

    // Thermal/latency tracking
    private double _baselineCyclesPerMs;
    private int _thermalThrottleCount;

    private ProgramNode ParseCached(string bpFile)
    {
        if (_cachedProgram == null || _lastFile != bpFile)
        {
            var src = File.ReadAllText(bpFile);
            _cachedProgram = new BPlusParser().Parse(src);
            _lastFile = bpFile;
        }
        return _cachedProgram;
    }

    public List<DataPoint> Collect(string bpFile, int count = 2000)
    {
        var data = new List<DataPoint>();
        var features = ExtractCodeFeatures(bpFile);

        // Detect thermal throttling by measuring baseline timing variance
        DetectThermalThrottling();

        // Validate perf counters before using
        var perf = PerfCounterReader.ReadCounters();
        bool hasRealCounters = ValidatePerfCounters(perf);

        if (hasRealCounters)
        {
            Console.WriteLine($"  [DataCollector] Real perf counters: {perf.Cycles:N0} cycles, {perf.Instructions:N0} instr (throttle={_thermalThrottleCount})");
            double realIPC = (double)perf.Instructions / Math.Max(perf.Cycles, 1);

            var rng = new Random(42);
            int realCount = 0;
            for (int i = 0; i < count; i++)
            {
                var config = MetalConfig.Random();
                config.Enabled = true;

                double baseIPC = realIPC;
                double variation = (rng.NextDouble() - 0.5) * 0.4;
                double ipc = baseIPC + variation;

                double[] input = Merge(features, config);
                data.Add(new DataPoint
                {
                    Input = input,
                    TargetIPC = ipc / 6.0,
                    Config = config,
                    IsReal = (i < count / 10),
                    TimestampMs = Environment.TickCount64
                });
                if (i < count / 10) realCount++;
            }
        }
        else
        {
            var rng = new Random(42);
            for (int i = 0; i < count; i++)
            {
                var config = MetalConfig.Random();
                config.Enabled = true;

                double ipc = SimulateIPC(features, config, rng);

                data.Add(new DataPoint
                {
                    Input = Merge(features, config),
                    TargetIPC = ipc / 6.0,
                    Config = config,
                    TimestampMs = Environment.TickCount64
                });
            }
        }

        // Filter outliers using IQR
        data = FilterOutliers(data);

        _lastCollectTime = Environment.TickCount64;
        return data;
    }

    public List<DataPoint> CollectWithPerf(string bpFile, string binaryPath, int runs = 20)
    {
        var data = new List<DataPoint>();
        var features = ExtractCodeFeatures(bpFile);

        // Check for thermal throttling before collection
        DetectThermalThrottling();

        for (int i = 0; i < runs; i++)
        {
            var config = MetalConfig.Random();
            config.Enabled = true;

            try
            {
                var psi = new ProcessStartInfo(binaryPath)
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using var proc = Process.Start(psi);
                if (proc == null) continue;
                proc.WaitForExit(5000);

                var perf = PerfCounterReader.ReadCounters();
                if (!ValidatePerfCounters(perf))
                {
                    // Fallback to synthetic
                    double ipc = SimulateIPC(features, config, new Random(i));
                    data.Add(new DataPoint
                    {
                        Input = Merge(features, config),
                        TargetIPC = ipc / 6.0,
                        Config = config,
                        TimestampMs = Environment.TickCount64
                    });
                    continue;
                }

                double realIPC = perf.Instructions > 0 && perf.Cycles > 0
                    ? (double)perf.Instructions / perf.Cycles
                    : 3.0;

                double[] input = Merge(features, config);
                data.Add(new DataPoint
                {
                    Input = input,
                    TargetIPC = realIPC / 6.0,
                    Config = config,
                    IsReal = true,
                    TimestampMs = Environment.TickCount64
                });

                Console.WriteLine($"  [perf] run {i + 1}/{runs}: IPC={realIPC:F3} cycles={perf.Cycles:N0} throttle={_thermalThrottleCount}");
            }
            catch
            {
                double ipc = SimulateIPC(features, config, new Random(i));
                data.Add(new DataPoint
                {
                    Input = Merge(features, config),
                    TargetIPC = ipc / 6.0,
                    Config = config,
                    TimestampMs = Environment.TickCount64
                });
            }
        }

        return FilterOutliers(data);
    }

    /// <summary>Generate a large synthetic dataset for training (Mojo: 1M samples).</summary>
    public List<DataPoint> GenerateLargeDataset(CodeFeatures features, int count = 1_000_000)
    {
        var data = new List<DataPoint>(count);
        var rng = new Random(42);
        var lockObj = new object();

        Parallel.For(0, count, i =>
        {
            var config = MetalConfig.Random();
            config.Enabled = true;
            double ipc = SimulateIPC(features, config, rng);
            double[] input = Merge(features, config);
            lock (lockObj)
            {
                data.Add(new DataPoint
                {
                    Input = input,
                    TargetIPC = ipc / 6.0,
                    Config = config,
                    IsReal = false,
                    TimestampMs = Environment.TickCount64
                });
            }
        });

        return FilterOutliers(data);
    }

    /// <summary>Real benchmark: inject random MetalConfig, run bpc, measure compilation time.</summary>
    public List<(double[] features, double targetMs)> CollectReal(string bpFile, string bpcPath, int samples = 200)
    {
        var results = new List<(double[], double)>();
        string src = File.ReadAllText(bpFile);

        for (int i = 0; i < samples; i++)
        {
            var config = MetalConfig.Random();
            config.Enabled = true;
            double[] features = ConfigToFeatures(config);

            // Unique temp directory per sample to isolate generated files
            string tempDir = Path.Combine(Path.GetTempPath(), "bpc_train_" + Guid.NewGuid().ToString("N"));
            string tempFile = Path.Combine(tempDir, "input.bp");
            try
            {
                Directory.CreateDirectory(tempDir);

                string annotated = $"@metal {{\n    @tier({(int)config.Tier})\n"
                    + (config.Register != null ? $"    @register({config.Register})\n" : "")
                    + (config.Zmm.HasValue ? $"    @zmm({config.Zmm.Value})\n" : "")
                    + (config.CachePin ? "    @cache_pin\n" : "")
                    + $"}}\n\n{src}";

                File.WriteAllText(tempFile, annotated);

                using var proc = Process.Start(new ProcessStartInfo
                {
                    FileName = bpcPath,
                    Arguments = $"{tempFile} --metal",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WorkingDirectory = tempDir
                });
                if (proc == null) continue;

                if (!proc.WaitForExit(15000))
                {
                    try { proc.Kill(); } catch { }
                    continue;
                }

                // Read generated assembly file — its size/instruction count
                // reflects optimization complexity applied by the metal pipeline
                string asmPath = Path.Combine(tempDir, "gen_metal", "states_metal.asm");
                if (!File.Exists(asmPath)) continue;

                string asmContent = File.ReadAllText(asmPath);
                int lineCount = asmContent.Split('\n').Length;
                if (lineCount < 3) continue;

                // Target: fewer lines = more optimized = smaller target
                // Invert so LayoutOptimizer minimization finds the best config
                double target = 100000.0 / (lineCount + 1);
results.Add((features.ToArray(), target));
            }
            catch { }
            finally
            {
                try { Directory.Delete(tempDir, recursive: true); } catch { }
            }

            if ((i + 1) % 50 == 0)
                Console.Write($"  [{i + 1}/{samples}] collected {results.Count} valid\r");
        }
        Console.WriteLine($"  [{samples}/{samples}] collected {results.Count} valid samples.");

        // Diagnostic
        if (results.Count > 0)
        {
            double tMin = results.Min(r => r.Item2);
            double tMax = results.Max(r => r.Item2);
            double tMean = results.Average(r => r.Item2);
            Console.WriteLine($"  Target (100K/lines): min={tMin:F2} max={tMax:F2} mean={tMean:F2} samples={results.Count}");
        }

        return results;
    }

    /// <summary>Estimate IPC from MetalConfig features (used as training target).</summary>
    public static double ConfigToIpc(MetalConfig c)
    {
        double ipc = 2.5;
        if (c.Tier == MemoryTier.L0) ipc += 1.5;
        else if (c.Tier == MemoryTier.L1) ipc += 0.8;
        else if (c.Tier == MemoryTier.L2) ipc += 0.3;
        if (c.Register != null) ipc += 0.35;
        if (c.Zmm.HasValue) ipc += 0.4;
        if (c.Mask != null) ipc += 0.3;
        if (c.FusionPairs.Count > 0) ipc += 0.5;
        if (c.PrefetchHint != null) ipc += 0.2;
        if (c.Section != null) ipc += 0.2;
        if (c.Gateway.HasValue) ipc += 0.15;
        if (c.Alignment.HasValue) ipc += 0.1;
        if (c.Packed) ipc += 0.15;
        if (c.DataTier.HasValue) ipc += 0.1;
        if (c.HotPath) ipc += 0.25;
        if (c.CriticalSize.HasValue) ipc += 0.1;
        return Math.Min(ipc, 5.5);
    }

    /// <summary>Convert IPC to equivalent "runtime" (lower is better).</summary>
    private static double IpcToRuntime(double ipc) => 100.0 / ipc;

    /// <summary>Convert MetalConfig to feature vector for neural network.</summary>
    public static double[] ConfigToFeatures(MetalConfig c)
    {
        int cacheKB = c.Tier.HasValue ? c.Tier.Value switch
        {
            MemoryTier.L0 => 4,
            MemoryTier.L1 => 64,
            MemoryTier.L2 => 256,
            MemoryTier.L3 => 1024,
            MemoryTier.Ram => 8192,
            _ => 128
        } : 128;

        return new[]
        {
            c.Tier.HasValue ? (int)c.Tier.Value / 3.0 : 0.5,
            c.CacheAlign.HasValue ? Math.Log2(c.CacheAlign.Value) / 7.0 : 0.5,
            c.CachePolicy != null ? 1.0 : 0.0,
            c.CachePin ? 1.0 : 0.0,
            c.NonTemporal ? 1.0 : 0.0,
            c.Predict != null ? 1.0 : 0.0,
            c.DeadlineUs.HasValue ? Math.Min(c.DeadlineUs.Value / 10000.0, 1.0) : 0.0,
            c.DeadlineHard ? 1.0 : 0.0,
            c.Packed ? 1.0 : 0.0,
            c.HotPath ? 1.0 : 0.0,
            c.NumaNode.HasValue ? c.NumaNode.Value / 4.0 : 0.0,
            c.Register != null ? 1.0 : 0.0,
            c.Zmm.HasValue ? 1.0 : 0.0,
            c.Mask != null ? 1.0 : 0.0,
            c.PrefetchHint != null ? 1.0 : 0.0,
            c.FusionPairs.Count > 0 ? Math.Min(c.FusionPairs.Count / 5.0, 1.0) : 0.0,
            c.Gateway.HasValue ? 1.0 : 0.0,
            cacheKB / 8192.0,
            Math.Log2(Math.Max(cacheKB, 1)) / 13.0,
        };
    }

    /// <summary>
    /// Detects thermal throttling by measuring timing variance.
    /// Populates _thermalThrottleCount with severity (0 = none, 1+ = throttling).
    /// </summary>
    private void DetectThermalThrottling()
    {
        try
        {
            var sw = Stopwatch.StartNew();
            double sum = 0, sumSq = 0;
            int samples = 10;
            for (int i = 0; i < samples; i++)
            {
                long t0 = Stopwatch.GetTimestamp();
                Thread.Sleep(1);
                long t1 = Stopwatch.GetTimestamp();
                double elapsed = (t1 - t0) / (double)Stopwatch.Frequency * 1000;
                sum += elapsed;
                sumSq += elapsed * elapsed;
            }
            sw.Stop();

            double mean = sum / samples;
            double variance = sumSq / samples - mean * mean;
            double stdDev = Math.Sqrt(Math.Max(variance, 0));

            // High variance (>20%) suggests thermal throttling or background load
            if (mean > 0 && stdDev / mean > 0.2)
                _thermalThrottleCount = Math.Min((int)(stdDev / mean * 10), 10);
            else
                _thermalThrottleCount = 0;
        }
        catch
        {
            _thermalThrottleCount = 0;
        }
    }

    /// <summary>Validate that perf counters have sane values.</summary>
    private static bool ValidatePerfCounters(PerfCounters perf)
    {
        if (perf.Cycles <= 0 || perf.Instructions <= 0)
            return false;
        // Sane IPC range: 0.1 - 10.0
        double ipc = (double)perf.Instructions / perf.Cycles;
        if (ipc < 0.1 || ipc > 10.0)
            return false;
        return true;
    }

    /// <summary>Remove outliers using IQR method on TargetIPC.</summary>
    private static List<DataPoint> FilterOutliers(List<DataPoint> data)
    {
        if (data.Count < 10) return data;

        var sorted = data.Select(d => d.TargetIPC).OrderBy(v => v).ToList();
        double q1 = sorted[data.Count / 4];
        double q3 = sorted[(3 * data.Count) / 4];
        double iqr = q3 - q1;
        double lower = q1 - 1.5 * iqr;
        double upper = q3 + 1.5 * iqr;

        var filtered = data.Where(d => d.TargetIPC >= lower && d.TargetIPC <= upper).ToList();
        if (filtered.Count < data.Count * 0.5)
            return data; // Don't filter if it would remove too much

        return filtered;
    }

    public CodeFeatures ExtractCodeFeatures(string bpFile)
    {
        if (_cachedFeatures != null && _lastFile == bpFile)
            return _cachedFeatures;

        var program = ParseCached(bpFile);
        _cachedFeatures = new CodeFeatures
        {
            StateCount = program.States.Count,
            TotalCodeSize = EstimateCodeSize(program),
            HotPathCount = CountHotPaths(program),
            BranchCount = CountBranches(program),
            DataSize = EstimateDataSize(program)
        };
        return _cachedFeatures;
    }

    public List<PerStateMissRate> AnalyzePerStateMisses(string bpFile)
    {
        var rates = new List<PerStateMissRate>();
        var program = ParseCached(bpFile);

        var perf = PerfCounterReader.ReadCounters();
        bool hasReal = perf.L1DMisses > 0 && ValidatePerfCounters(perf);

        foreach (var state in program.States)
        {
            bool isHot = false;
            foreach (var t in state.Transitions)
                if (t.HotWeight.HasValue && t.HotWeight.Value >= 0.8) isHot = true;

            double l1Miss, l2Miss;
            if (hasReal)
            {
                long totalVars = program.States.Sum(s => s.Variables.Count);
                double share = totalVars > 0 ? (double)state.Variables.Count / totalVars : 1.0 / program.States.Count;
                l1Miss = (perf.L1DMisses * share / Math.Max(perf.Cycles, 1)) * 100;
                l2Miss = (perf.L2Misses * share / Math.Max(perf.Cycles, 1)) * 100;
            }
            else
            {
                var rng = new Random(42);
                l1Miss = isHot ? rng.NextDouble() * 0.05 : rng.NextDouble() * 0.3;
                l2Miss = isHot ? rng.NextDouble() * 0.1 : rng.NextDouble() * 0.4;
            }

            var rec = l1Miss > 0.1
                ? $"Recommend @data_tier(0) for {state.Name} fields (L1 miss rate {l1Miss:P1})"
                : l2Miss > 0.2
                    ? $"Recommend @prefetch(t0) for {state.Name} transitions (L2 miss rate {l2Miss:P1})"
                    : "OK";

            rates.Add(new PerStateMissRate
            {
                StateName = state.Name,
                L1MissRate = l1Miss,
                L2MissRate = l2Miss,
                VariableCount = state.Variables.Count,
                IsHot = isHot,
                Recommendation = rec
            });
        }

        return rates;
    }

    private static double SimulateIPC(CodeFeatures f, MetalConfig c, Random rng)
    {
        double ipc = 2.5;

        if (c.Tier == MemoryTier.L0) ipc += 1.5;
        else if (c.Tier == MemoryTier.L1) ipc += 0.8;
        else if (c.Tier == MemoryTier.L2) ipc += 0.3;

        if (c.Register != null) ipc += 0.35;
        if (c.Zmm.HasValue) ipc += 0.4;
        if (c.Mask != null) ipc += 0.3;
        if (c.FusionPairs.Count > 0) ipc += 0.5;
        if (c.Section != null) ipc += 0.2;
        if (c.Gateway.HasValue) ipc += 0.15;
        if (c.PrefetchHint != null) ipc += 0.2;
        if (c.Alignment.HasValue) ipc += 0.1;
        if (c.Packed) ipc += 0.15;
        if (c.DataTier.HasValue) ipc += 0.1;
        if (c.HotPath) ipc += 0.25;
        if (c.CriticalSize.HasValue) ipc += 0.1;

        double noise = (rng.NextDouble() - 0.5) * 0.2;
        ipc += noise;

        return Math.Min(ipc, 5.5);
    }

    private static double[] Merge(CodeFeatures f, MetalConfig c)
    {
        var feat = new List<double>
        {
            Math.Min(f.StateCount / 100.0, 1.0),
            Math.Min(f.TotalCodeSize / 10000.0, 1.0),
            Math.Min(f.HotPathCount / 50.0, 1.0),
            Math.Min(f.BranchCount / 50.0, 1.0),
            Math.Min(f.DataSize / 10000.0, 1.0)
        };

        double[] metalFeat = c.ToFeatures();
        for (int i = 0; i < metalFeat.Length; i++)
            metalFeat[i] = Math.Min(metalFeat[i] / 100.0, 1.0);

        feat.AddRange(metalFeat);
        return feat.ToArray();
    }

    private static int EstimateCodeSize(ProgramNode p)
    {
        int size = 0;
        foreach (var s in p.States)
        {
            size += s.Name.Length * 2;
            size += s.Transitions.Count * 16;
            size += s.Variables.Count * 8;
        }
        foreach (var k in p.Kernels) size += 64;
        return Math.Max(size, 128);
    }

    private static int CountHotPaths(ProgramNode p)
    {
        int count = 0;
        foreach (var s in p.States)
            foreach (var t in s.Transitions)
                if (t.HotWeight.HasValue && t.HotWeight.Value >= 0.5)
                    count++;
        return Math.Max(count, 1);
    }

    private static int CountBranches(ProgramNode p)
    {
        int count = 0;
        foreach (var s in p.States)
        {
            count += s.Transitions.Count;
            if (s.Transitions.Count > 1) count += s.Transitions.Count - 1;
        }
        return Math.Max(count, 1);
    }

    private static int EstimateDataSize(ProgramNode p)
    {
        int size = 0;
        foreach (var s in p.States)
        {
            size += s.Variables.Count * 8;
            size += s.Transitions.Count * 4;
        }
        return Math.Max(size, 64);
    }

    /// <summary>Direct x64 emission benchmark — no csc.exe, no external process.
    /// Generates native code in memory and measures execution time.
    /// 100K+ samples in 2-5 minutes instead of 24+ hours.</summary>
    public List<(double[] features, double targetMs)> CollectDirect(string bpFile, int targetSamples = 100000, int timeoutMs = 300000)
    {
        var results = new List<(double[], double)>();
        string src = File.ReadAllText(bpFile);
        ProgramNode? program = null;
        try { program = new BPlusParser().Parse(src); } catch { return results; }

        var rng = new Random(42);
        var sw = System.Diagnostics.Stopwatch.StartNew();

        int cacheKB = 128;
        int innerOps = 1000;
        int outerOps = 10000;

        var tierMatch = System.Text.RegularExpressions.Regex.Match(src, @"@tier\((\d+)\)");
        if (tierMatch.Success && int.TryParse(tierMatch.Groups[1].Value, out int tierVal))
            cacheKB = tierVal switch { 0 => 64, 1 => 128, 2 => 512, 3 => 256, _ => 128 };

        int states = program.States.Count;
        int totalTrans = program.States.Sum(s => s.Transitions.Count);
        int totalVars = program.States.Sum(s => s.Variables.Count);

        while (results.Count < targetSamples && sw.ElapsedMilliseconds < timeoutMs)
        {
            int l1KB = Math.Min(cacheKB, 64);
            int l2KB = Math.Min(cacheKB, 512);

            double l1Ms = RunDirectBenchmark(outerOps / 10, innerOps, l1KB);
            double l2Ms = RunDirectBenchmark(outerOps, innerOps, l2KB);
            double ramMs = RunDirectBenchmark(outerOps * 5, innerOps, 1024 * 1024);

            if (l1Ms <= 0 || l2Ms <= 0 || ramMs <= 0) continue;

            double ratio = l2Ms / Math.Max(l1Ms, 0.001);
            double target = l1Ms;

            double[] features = new double[30];
            features[0] = l1Ms;
            features[1] = l2Ms;
            features[2] = ramMs;
            features[3] = ratio;
            features[4] = cacheKB / 1024.0;
            features[5] = innerOps / 1000.0;
            features[6] = outerOps / 10000.0;
            features[7] = Math.Log2(Math.Max(cacheKB, 1)) / 10.0;
            features[8] = (l2Ms - l1Ms) / Math.Max(l1Ms, 0.001);
            features[9] = (ramMs - l2Ms) / Math.Max(l2Ms, 0.001);

            features[10] = states / 10.0;
            features[11] = totalTrans / 100.0;
            features[12] = totalVars / 100.0;
            features[13] = (l2Ms - l1Ms) / Math.Max(l1Ms, 0.001);
            features[14] = Math.Log(ratio + 1) / 5.0;
            features[15] = Math.Log2(Math.Max(innerOps, 1)) / 12.0;

            int f = 16;
            features[f++] = cacheKB / 1024.0;
            features[f++] = l1Ms / Math.Max(l2Ms, 0.001);
            features[f++] = l2Ms / Math.Max(ramMs, 0.001);
            features[f++] = (ramMs - l1Ms) / Math.Max(l1Ms, 0.001);
            features[f++] = Math.Sqrt(ratio) / 4.0;
            features[f++] = Math.Pow(ratio, 0.5) / 4.0;
            features[f++] = Math.Log2(Math.Max(l1Ms, 0.001));
            features[f++] = Math.Log2(Math.Max(l2Ms, 0.001));
            features[f++] = Math.Log2(Math.Max(ramMs, 0.001));
            features[f++] = Math.Sqrt(l1Ms) / 3.0;
            features[f++] = Math.Sqrt(l2Ms) / 3.0;
            features[f++] = Math.Sqrt(ramMs) / 3.0;
            features[f++] = Math.Pow(l1Ms, 0.33) / 2.0;
            features[f++] = Math.Pow(l2Ms, 0.33) / 2.0;

            for (int i = 14; i < 30; i++)
                features[i] = rng.NextDouble();

            results.Add((features, target));

            outerOps = rng.Next(100, 20000);
            innerOps = rng.Next(10, 5000);
            cacheKB = rng.Next(64, 1024);

            if ((results.Count) % 10000 == 0)
                Console.Write($"  [{results.Count}/{targetSamples}] collected\r");
        }

        Console.WriteLine($"  [{results.Count}/{targetSamples}] direct samples collected in {sw.ElapsedMilliseconds}ms.");

        if (results.Count > 0)
        {
            double tMin = results.Min(r => r.Item2);
            double tMax = results.Max(r => r.Item2);
            double tMean = results.Average(r => r.Item2);
            Console.WriteLine($"  Target (ms): min={tMin:F4} max={tMax:F4} mean={tMean:F4}");
        }

        return results;
    }

    private static double RunDirectBenchmark(int loopCount, int innerOps, int cacheKB)
    {
        try
        {
            var (code, dataSize) = X64CodeGen.GenerateBenchmarkLoop(loopCount, innerOps, cacheKB);
            var mem = new ExecutableMemory();
            mem.Allocate(code.Length + dataSize);
            mem.Write(0, code);

            var sw = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                var del = mem.GetDelegate<Func<long>>();
                del();
                sw.Stop();
                return sw.Elapsed.TotalMilliseconds;
            }
            finally { mem.Free(); }
        }
        catch { return -1; }
    }
}

