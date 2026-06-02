using System.Text;

namespace BPlus.Runtime;

public enum RamChannel
{
    Channel0,
    Channel1,
    Channel2,
    Channel3,
    Auto
}

public enum MemoryPattern
{
    Sequential,
    Strided,
    Random,
    Gather,
    Scatter,
    Streaming
}

public class MemoryRegionHint
{
    public string? Name { get; set; }
    public ulong BaseAddress { get; set; }
    public ulong Size { get; set; }
    public RamChannel PreferredChannel { get; set; } = RamChannel.Auto;
    public MemoryPattern Pattern { get; set; } = MemoryPattern.Sequential;
    public int StrideBytes { get; set; }
    public bool Prefetch { get; set; }
    public bool NonTemporal { get; set; }
    public bool HugePages { get; set; }
    public int NumaNode { get; set; } = -1;
}

public static class MemoryControllerHints
{
    public static string SuggestChannelLayout(ulong totalSize)
    {
        ulong pageSize = 4096;
        ulong numPages = totalSize / pageSize;
        int numChannels = 4;

        var sb = new StringBuilder();
        sb.AppendLine("// Memory Channel Layout:");
        for (int ch = 0; ch < numChannels; ch++)
        {
            ulong start = (ulong)ch * (numPages / (ulong)numChannels) * pageSize;
            ulong end = (ulong)(ch + 1) * (numPages / (ulong)numChannels) * pageSize - 1;
            sb.AppendLine($"//   Channel {ch}: {start:X16} - {end:X16}");
        }
        return sb.ToString();
    }

    public static string SuggestInterleave(MemoryPattern pattern)
    {
        return pattern switch
        {
            MemoryPattern.Sequential => "64-byte cache line interleave across 4 channels",
            MemoryPattern.Strided => "1024-byte block interleave (reduce bank conflict)",
            MemoryPattern.Random => "No interleave — use random hash-based addressing",
            MemoryPattern.Gather => "Cluster idle gather with 4KB page striping",
            MemoryPattern.Scatter => "Use write-combining buffer per channel",
            MemoryPattern.Streaming => "2MB hugepage interleave + nontemporal stores",
            _ => "64-byte interleave"
        };
    }

    public static string EmitPrefetchHints(MemoryRegionHint region, int aheadLines = 8)
    {
        var sb = new StringBuilder();
        if (region.Prefetch)
        {
            sb.AppendLine($"\t; Prefetch {region.Name} ({region.Pattern})");
            if (region.Pattern == MemoryPattern.Sequential)
                sb.AppendLine($"\tprefetcht0 [{region.BaseAddress + (ulong)aheadLines * 64}] ; {aheadLines} lines ahead");
            else if (region.Pattern == MemoryPattern.Strided)
                sb.AppendLine($"\tprefetcht1 [{region.BaseAddress + (ulong)(aheadLines * Math.Max(64, region.StrideBytes))}]");
            else
                sb.AppendLine($"\tprefetcht2 [{region.BaseAddress}] ; random prefetch");
        }
        if (region.NonTemporal)
        {
            sb.AppendLine($"\tmovntdq [{region.BaseAddress}], zmm0 ; nontemporal store");
        }
        return sb.ToString();
    }

    public static string GenerateReport(List<MemoryRegionHint> regions)
    {
        var sb = new StringBuilder();
        sb.AppendLine("╔══════════════════════════════════════════════╗");
        sb.AppendLine("║        MEMORY CONTROLLER HINTS REPORT      ║");
        sb.AppendLine("╚══════════════════════════════════════════════╝");
        foreach (var r in regions)
        {
            sb.AppendLine($"Region: {r.Name ?? "(unnamed)"}");
            sb.AppendLine($"  Address: 0x{r.BaseAddress:X16} - 0x{r.BaseAddress + r.Size:X16}");
            sb.AppendLine($"  Size: {r.Size / 1024} KB");
            sb.AppendLine($"  Channel: {r.PreferredChannel}");
            sb.AppendLine($"  Pattern: {r.Pattern}");
            sb.AppendLine($"  Interleave: {SuggestInterleave(r.Pattern)}");
            if (r.Prefetch) sb.AppendLine("  ● Prefetch enabled");
            if (r.NonTemporal) sb.AppendLine("  ● Non-temporal stores");
            if (r.HugePages) sb.AppendLine("  ● Huge pages (2MB)");
            sb.AppendLine();
        }
        return sb.ToString();
    }
}
