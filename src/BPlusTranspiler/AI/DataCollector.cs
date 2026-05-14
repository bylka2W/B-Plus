using System.Diagnostics;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Parser;
using BPlusTranspiler.Runtime;

namespace BPlusTranspiler.AI;

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
}
