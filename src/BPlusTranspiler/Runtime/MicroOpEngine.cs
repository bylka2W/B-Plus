using System.Text;

namespace BPlusTranspiler.Runtime;

public enum MicroOpType
{
    Load, Store, ALU, FMA, Shuffle, Masked, Branch, Fence, Prefetch
}

public class MicroOp
{
    public MicroOpType OpType { get; set; }
    public int Latency { get; set; }
    public int Ports { get; set; }
    public int ThroughputSlots { get; set; }
    public string? Comment { get; set; }
}

public class DecodedSequence
{
    public List<MicroOp> Ops { get; set; } = new();
    public int IssueWidth { get; set; } = 6;
    public int TotalLatency => Ops.Count > 0 ? Ops.Max(o => o.Latency) : 0;
    public double BottleneckThroughput => ComputeBottleneckThroughput();
    public int MicroOpCount => Ops.Count;

    private double ComputeBottleneckThroughput()
    {
        if (Ops.Count == 0) return 0;
        var portGroups = Ops.GroupBy(o => o.Ports).ToDictionary(g => g.Key, g => g.Sum(o => o.ThroughputSlots));
        int maxSlots = portGroups.Values.Count > 0 ? portGroups.Values.Max() : 0;
        return maxSlots > 0 ? (double)maxSlots / IssueWidth : 0;
    }
}

public static class MicroOpEngine
{
    private static readonly Dictionary<MicroOpType, MicroOp> BaseOps = new()
    {
        [MicroOpType.Load] = new() { OpType = MicroOpType.Load, Latency = 4, Ports = 23, ThroughputSlots = 1 },
        [MicroOpType.Store] = new() { OpType = MicroOpType.Store, Latency = 1, Ports = 4, ThroughputSlots = 1 },
        [MicroOpType.ALU] = new() { OpType = MicroOpType.ALU, Latency = 1, Ports = 015, ThroughputSlots = 1 },
        [MicroOpType.FMA] = new() { OpType = MicroOpType.FMA, Latency = 4, Ports = 01, ThroughputSlots = 2 },
        [MicroOpType.Masked] = new() { OpType = MicroOpType.Masked, Latency = 6, Ports = 05, ThroughputSlots = 3 },
        [MicroOpType.Branch] = new() { OpType = MicroOpType.Branch, Latency = 1, Ports = 6, ThroughputSlots = 0 },
    };

    public static DecodedSequence Decode(string instruction, int? issueWidth = null)
    {
        var seq = new DecodedSequence { IssueWidth = issueWidth ?? 6 };
        var lower = instruction.ToLower().Trim();

        if (lower.StartsWith("vfmadd") || lower.StartsWith("vfmul"))
            seq.Ops.Add(Clone(MicroOpType.FMA));
        else if (lower.StartsWith("vmov") || lower.StartsWith("mov"))
            seq.Ops.Add(Clone(MicroOpType.Load));
        else if (lower.StartsWith("vadd") || lower.StartsWith("vsub") || lower.StartsWith("add"))
            seq.Ops.Add(Clone(MicroOpType.ALU));
        else if (lower.StartsWith("vxor") || lower.StartsWith("xor") || lower.StartsWith("and"))
            seq.Ops.Add(Clone(MicroOpType.ALU));
        else if (lower.StartsWith("cmp") || lower.StartsWith("test"))
            seq.Ops.Add(Clone(MicroOpType.ALU));
        else if (lower.StartsWith("j") || lower.StartsWith("call") || lower.StartsWith("ret"))
            seq.Ops.Add(Clone(MicroOpType.Branch));
        else if (lower.StartsWith("prefetch"))
            seq.Ops.Add(new() { OpType = MicroOpType.Prefetch, Latency = 2, Ports = 23, ThroughputSlots = 1 });
        else if (lower.StartsWith("clflush") || lower.StartsWith("mfence"))
            seq.Ops.Add(new() { OpType = MicroOpType.Fence, Latency = 10, Ports = 4, ThroughputSlots = 4 });

        return seq;
    }

    public static DecodedSequence DecodeSequence(string[] instructions, int? issueWidth = null)
    {
        var seq = new DecodedSequence { IssueWidth = issueWidth ?? 6 };
        foreach (var instr in instructions)
        {
            var decoded = Decode(instr, issueWidth);
            seq.Ops.AddRange(decoded.Ops);
        }
        return seq;
    }

    public static string Analyze(DecodedSequence seq)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"Micro-ops: {seq.MicroOpCount}");
        sb.AppendLine($"Issue width: {seq.IssueWidth}");
        sb.AppendLine($"Total latency: {seq.TotalLatency} cycles");
        sb.AppendLine($"Bottleneck throughput: {seq.BottleneckThroughput:F2} cycles/iteration");

        var typeSummary = seq.Ops.GroupBy(o => o.OpType)
            .Select(g => $"  {g.Key}: {g.Count()} ops (lat={g.First().Latency})");
        sb.AppendLine("Op breakdown:");
        foreach (var t in typeSummary)
            sb.AppendLine(t);

        return sb.ToString();
    }

    private static MicroOp Clone(MicroOpType type) => new()
    {
        OpType = BaseOps[type].OpType,
        Latency = BaseOps[type].Latency,
        Ports = BaseOps[type].Ports,
        ThroughputSlots = BaseOps[type].ThroughputSlots,
    };
}
