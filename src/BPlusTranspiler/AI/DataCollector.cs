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
                TargetIPC = ipc / 6.0, // normalize IPC to [0,1]
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

        // Deterministic — no noise
        return Math.Min(ipc, 5.5);
    }

    private static double[] Merge(CodeFeatures f, MetalConfig c)
    {
        // Normalize all inputs to [0, 1] range for stable network training
        var feat = new List<double>
        {
            Math.Min(f.StateCount / 100.0, 1.0),
            Math.Min(f.TotalCodeSize / 10000.0, 1.0),
            Math.Min(f.HotPathCount / 50.0, 1.0),
            Math.Min(f.BranchCount / 50.0, 1.0),
            Math.Min(f.DataSize / 10000.0, 1.0)
        };

        double[] metalFeat = c.ToFeatures();
        // Normalize metal features
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
        {
            foreach (var t in s.Transitions)
                if (t.HotWeight.HasValue && t.HotWeight.Value >= 0.5)
                    count++;
        }
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
