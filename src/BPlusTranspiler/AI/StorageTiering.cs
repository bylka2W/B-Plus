namespace BPlusTranspiler.AI;

public enum StorageTier { L0Cache, L1Cache, L2Cache, L3Cache, Ram, Nvme, Sata, Archival }

public class StorageTiering
{
    public class TierInfo
    {
        public StorageTier Tier { get; set; }
        public string Name { get; set; } = "";
        public int LatencyNs { get; set; }
        public long MaxSizeBytes { get; set; }
        public double BandwidthGBps { get; set; }
        public bool IsPersistent { get; set; }
    }

    public class PlacementResult
    {
        public List<TierInfo> Tiers { get; set; } = new();
        public int HotDataBytes { get; set; }
        public int WarmDataBytes { get; set; }
        public int ColdDataBytes { get; set; }
        public double EstSpeedup { get; set; }
    }

    private static readonly TierInfo[] TierProfile =
    {
        new TierInfo { Tier = StorageTier.L0Cache, Name = "L0 µop", LatencyNs = 1, MaxSizeBytes = 4 * 1024, BandwidthGBps = 1000, IsPersistent = false },
        new TierInfo { Tier = StorageTier.L1Cache, Name = "L1", LatencyNs = 4, MaxSizeBytes = 64 * 1024, BandwidthGBps = 500, IsPersistent = false },
        new TierInfo { Tier = StorageTier.L2Cache, Name = "L2", LatencyNs = 12, MaxSizeBytes = 256 * 1024, BandwidthGBps = 200, IsPersistent = false },
        new TierInfo { Tier = StorageTier.L3Cache, Name = "L3", LatencyNs = 50, MaxSizeBytes = 2 * 1024 * 1024, BandwidthGBps = 100, IsPersistent = false },
        new TierInfo { Tier = StorageTier.Ram, Name = "RAM", LatencyNs = 100, MaxSizeBytes = 32L * 1024 * 1024 * 1024, BandwidthGBps = 50, IsPersistent = false },
        new TierInfo { Tier = StorageTier.Nvme, Name = "NVMe SSD", LatencyNs = 10000, MaxSizeBytes = 2L * 1024 * 1024 * 1024 * 1024, BandwidthGBps = 7, IsPersistent = true },
        new TierInfo { Tier = StorageTier.Sata, Name = "SATA SSD", LatencyNs = 100000, MaxSizeBytes = 8L * 1024 * 1024 * 1024 * 1024, BandwidthGBps = 0.5, IsPersistent = true },
        new TierInfo { Tier = StorageTier.Archival, Name = "HDD/Cloud", LatencyNs = 500000, MaxSizeBytes = long.MaxValue, BandwidthGBps = 0.1, IsPersistent = true }
    };

    public PlacementResult PlaceData(long totalDataBytes, int accessFrequency, string cpuMicroarch)
    {
        var result = new PlacementResult { Tiers = TierProfile.ToList() };

        long ramBytes = GetRamBytes();
        long nvmeBytes = 2L * 1024 * 1024 * 1024 * 1024;

        if (totalDataBytes <= 256 * 1024)
        {
            result.HotDataBytes = (int)totalDataBytes;
            result.WarmDataBytes = 0;
            result.ColdDataBytes = 0;
            result.EstSpeedup = 10.0;
        }
        else if (totalDataBytes <= ramBytes)
        {
            result.HotDataBytes = Math.Min((int)(totalDataBytes / 4), 256 * 1024);
            result.WarmDataBytes = (int)(totalDataBytes - result.HotDataBytes);
            result.ColdDataBytes = 0;
            result.EstSpeedup = 5.0;
        }
        else
        {
            result.HotDataBytes = Math.Min(256 * 1024, (int)ramBytes / 4);
            result.WarmDataBytes = (int)ramBytes / 2;
            result.ColdDataBytes = (int)(totalDataBytes - ramBytes);
            result.EstSpeedup = 2.5;
        }

        return result;
    }

    private long GetRamBytes()
    {
        try
        {
            long mem = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;
            if (mem > 0) return mem;
        }
        catch { }
        return 16L * 1024 * 1024 * 1024;
    }

    public string GetPlacementStrategy(long dataBytes)
    {
        if (dataBytes <= 256 * 1024) return "All in L0/L1 cache (no tiering needed)";
        if (dataBytes <= 256 * 1024 * 1024) return "Hot in RAM, cold not needed";
        return $"NVMe tiering: hot={Math.Min(dataBytes / 4, 256L * 1024)}B, warm in RAM, cold on NVMe";
    }

    public string GenerateHeader(PlacementResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Storage tiering");
        sb.AppendLine($"#define BPLUS_HOT_BYTES {r.HotDataBytes}");
        sb.AppendLine($"#define BPLUS_WARM_BYTES {r.WarmDataBytes}");
        sb.AppendLine($"#define BPLUS_COLD_BYTES {r.ColdDataBytes}");
        sb.AppendLine($"#define BPLUS_EST_SPEEDUP {r.EstSpeedup:F1}");
        sb.AppendLine();
        sb.AppendLine("// Tier latencies (ns):");
        sb.AppendLine("// L0: 1, L1: 4, L2: 12, L3: 50, RAM: 100, NVMe: 10000");
        sb.AppendLine();
        sb.AppendLine("#ifdef _WIN32");
        sb.AppendLine("#include <windows.h>");
        sb.AppendLine("static inline void* bplus_alloc_tiered(long size, int tier) {");
        sb.AppendLine("    if (tier == 6) { // NVMe");
        sb.AppendLine("        return VirtualAlloc(NULL, size, MEM_COMMIT | MEM_LARGE_PAGES, PAGE_READWRITE);");
        sb.AppendLine("    }");
        sb.AppendLine("    return malloc(size);");
        sb.AppendLine("}");
        sb.AppendLine("#else");
        sb.AppendLine("static inline void* bplus_alloc_tiered(long size, int tier) {");
        sb.AppendLine("    if (tier == 6) return mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);");
        sb.AppendLine("    return malloc(size);");
        sb.AppendLine("}");
        sb.AppendLine("#endif");
        return sb.ToString();
    }
}