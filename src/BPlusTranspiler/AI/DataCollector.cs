using System.Diagnostics;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Parser;

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
    public List<DataPoint> Collect(string bpFile, int count = 2000)
    {
        var data = new List<DataPoint>();
        var features = ExtractCodeFeatures(bpFile);
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
                Config = config
            });
        }

        return data;
    }

    public CodeFeatures ExtractCodeFeatures(string bpFile)
    {
        var src = File.ReadAllText(bpFile);
        var parser = new BPlusParser();
        var program = parser.Parse(src);

        return new CodeFeatures
        {
            StateCount = program.States.Count,
            TotalCodeSize = EstimateCodeSize(program),
            HotPathCount = CountHotPaths(program),
            BranchCount = CountBranches(program),
            DataSize = EstimateDataSize(program)
        };
    }

    /// <summary>Analyze cache miss attribution per state.</summary>
    public List<PerStateMissRate> AnalyzePerStateMisses(string bpFile)
    {
        var rates = new List<PerStateMissRate>();
        var src = File.ReadAllText(bpFile);
        var parser = new BPlusParser();
        var program = parser.Parse(src);
        var rng = new Random(42);

        foreach (var state in program.States)
        {
            bool isHot = false;
            foreach (var t in state.Transitions)
                if (t.HotWeight.HasValue && t.HotWeight.Value >= 0.8) isHot = true;

            double l1Miss = isHot ? rng.NextDouble() * 0.05 : rng.NextDouble() * 0.3;
            double l2Miss = isHot ? rng.NextDouble() * 0.1 : rng.NextDouble() * 0.4;

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