using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

/// <summary>Agner Fog / uops.info microarchitecture tables embedded.</summary>
public class MicroArchEntry
{
    public string Name { get; set; } = "";
    public string Vendor { get; set; } = "";
    public int L1Latency { get; set; } = 4;
    public int L2Latency { get; set; } = 12;
    public int L3Latency { get; set; } = 45;
    public int MemLatency { get; set; } = 200;
    public bool HasAvx512 { get; set; }
    public bool HasFusionCmpJne { get; set; } = true;
    public bool HasFusionDecJnz { get; set; } = true;
    public bool HasFusionTestJne { get; set; } = true;
    public bool HasFusionAddCmp { get; set; }
    public int L1SizeKb { get; set; } = 32;
    public int L2SizeKb { get; set; } = 256;
    public int L3SizeKb { get; set; } = 12288;
    public int L0UopCacheSize { get; set; } = 1536;
    public int LsdSizeBytes { get; set; } = 64;
    public int StoreBufferEntries { get; set; } = 42;
    public int LoadBufferEntries { get; set; } = 72;
    public int LfbEntries { get; set; } = 12;
    public int BtbEntries { get; set; } = 1024;
}

public static class MicroArchProfiles
{
    private static readonly Dictionary<string, MicroArchEntry> Profiles = new()
    {
        ["intel_adl"] = new MicroArchEntry
        {
            Name = "Alder Lake P-core", Vendor = "Intel", L1Latency = 4, L2Latency = 12, L3Latency = 40, MemLatency = 200,
            HasAvx512 = false, HasFusionCmpJne = true, HasFusionDecJnz = true, HasFusionAddCmp = false,
            L1SizeKb = 32, L2SizeKb = 1280, L3SizeKb = 30720, L0UopCacheSize = 1536,
            LsdSizeBytes = 64, StoreBufferEntries = 42, LoadBufferEntries = 72, LfbEntries = 12, BtbEntries = 1024
        },
        ["intel_skx"] = new MicroArchEntry
        {
            Name = "Skylake-SP", Vendor = "Intel", L1Latency = 4, L2Latency = 14, L3Latency = 55, MemLatency = 220,
            HasAvx512 = true, HasFusionCmpJne = true, HasFusionDecJnz = true, HasFusionAddCmp = false,
            L1SizeKb = 32, L2SizeKb = 1024, L3SizeKb = 38400, L0UopCacheSize = 1536,
            LsdSizeBytes = 64, StoreBufferEntries = 42, LoadBufferEntries = 72, LfbEntries = 12, BtbEntries = 1536
        },
        ["intel_icx"] = new MicroArchEntry
        {
            Name = "Ice Lake-SP", Vendor = "Intel", L1Latency = 5, L2Latency = 12, L3Latency = 50, MemLatency = 210,
            HasAvx512 = true, HasFusionCmpJne = true, HasFusionDecJnz = true, HasFusionAddCmp = false,
            L1SizeKb = 32, L2SizeKb = 1024, L3SizeKb = 46080, L0UopCacheSize = 1536,
            LsdSizeBytes = 64, StoreBufferEntries = 56, LoadBufferEntries = 128, LfbEntries = 16, BtbEntries = 2048
        },
        ["intel_gni"] = new MicroArchEntry
        {
            Name = "Granite Rapids", Vendor = "Intel", L1Latency = 4, L2Latency = 12, L3Latency = 45, MemLatency = 200,
            HasAvx512 = true, HasFusionCmpJne = true, HasFusionDecJnz = true, HasFusionAddCmp = true,
            L1SizeKb = 32, L2SizeKb = 2048, L3SizeKb = 61440, L0UopCacheSize = 4096,
            LsdSizeBytes = 128, StoreBufferEntries = 56, LoadBufferEntries = 128, LfbEntries = 16, BtbEntries = 4096
        },
        ["amd_zen4"] = new MicroArchEntry
        {
            Name = "Zen 4", Vendor = "AMD", L1Latency = 4, L2Latency = 14, L3Latency = 45, MemLatency = 190,
            HasAvx512 = true, HasFusionCmpJne = true, HasFusionDecJnz = true, HasFusionAddCmp = true,
            L1SizeKb = 32, L2SizeKb = 1024, L3SizeKb = 32768, L0UopCacheSize = 4096,
            LsdSizeBytes = 0, StoreBufferEntries = 48, LoadBufferEntries = 80, LfbEntries = 14, BtbEntries = 2048
        },
        ["amd_zen3"] = new MicroArchEntry
        {
            Name = "Zen 3", Vendor = "AMD", L1Latency = 4, L2Latency = 12, L3Latency = 40, MemLatency = 180,
            HasAvx512 = false, HasFusionCmpJne = true, HasFusionDecJnz = true, HasFusionAddCmp = true,
            L1SizeKb = 32, L2SizeKb = 512, L3SizeKb = 32768, L0UopCacheSize = 3072,
            LsdSizeBytes = 0, StoreBufferEntries = 48, LoadBufferEntries = 80, LfbEntries = 14, BtbEntries = 2048
        },
        ["arm_neoverse"] = new MicroArchEntry
        {
            Name = "Neoverse N1", Vendor = "ARM", L1Latency = 4, L2Latency = 11, L3Latency = 35, MemLatency = 160,
            HasAvx512 = false, HasFusionCmpJne = true, HasFusionDecJnz = false, HasFusionAddCmp = false,
            L1SizeKb = 64, L2SizeKb = 1024, L3SizeKb = 16384, L0UopCacheSize = 0,
            LsdSizeBytes = 0, StoreBufferEntries = 56, LoadBufferEntries = 96, LfbEntries = 16, BtbEntries = 4096
        },
        ["generic"] = new MicroArchEntry
        {
            Name = "Generic x86-64", Vendor = "Generic", L1Latency = 4, L2Latency = 12, L3Latency = 45, MemLatency = 200,
            HasAvx512 = false, HasFusionCmpJne = true, HasFusionDecJnz = true,
            L1SizeKb = 32, L2SizeKb = 256, L3SizeKb = 8192, L0UopCacheSize = 1536,
            LsdSizeBytes = 64, StoreBufferEntries = 42, LoadBufferEntries = 72, LfbEntries = 12, BtbEntries = 1024
        }
    };

    public static MicroArchEntry Get(string? name)
    {
        if (name != null && Profiles.TryGetValue(name, out var entry))
            return entry;
        return Profiles["generic"];
    }

    public static string Detect()
    {
        try
        {
            string? arch = Environment.GetEnvironmentVariable("PROCESSOR_IDENTIFIER");
            if (arch != null)
            {
                if (arch.Contains("AMD", StringComparison.OrdinalIgnoreCase)) return "amd_zen4";
                if (arch.Contains("Intel", StringComparison.OrdinalIgnoreCase))
                {
                    if (arch.Contains("13") || arch.Contains("14")) return "intel_icx";
                    if (arch.Contains("12")) return "intel_adl";
                    return "intel_icx";
                }
            }
            string? model = Environment.GetEnvironmentVariable("BPLUS_CPU_MODEL");
            if (model != null) return model;
        }
        catch { }
        return "generic";
    }

    public static string GenerateReport(string? muarch)
    {
        var m = Get(muarch);
        return $@"µarch: {m.Name} ({m.Vendor})
  L1: {m.L1Latency}cyc {m.L1SizeKb}KB  L2: {m.L2Latency}cyc {m.L2SizeKb}KB  L3: {m.L3Latency}cyc {m.L3SizeKb}KB
  AVX-512: {m.HasAvx512}  LSD: {(m.LsdSizeBytes > 0 ? m.LsdSizeBytes + "B" : "none")}
  Fusion: cmp+jne={m.HasFusionCmpJne} dec+jnz={m.HasFusionDecJnz} add+cmp={m.HasFusionAddCmp}
  µop cache: {m.L0UopCacheSize}uops  BTB: {m.BtbEntries}entries
  StoreBuf: {m.StoreBufferEntries}  LoadBuf: {m.LoadBufferEntries}  LFB: {m.LfbEntries}";
    }

    public static bool IsFusionValid(string pair, string? muarch)
    {
        var m = Get(muarch);
        return pair switch
        {
            "cmp+jne" or "cmp+je" => m.HasFusionCmpJne,
            "dec+jnz" or "dec+jz" => m.HasFusionDecJnz,
            "test+jne" or "test+je" => m.HasFusionTestJne,
            "add+cmp" or "add+test" => m.HasFusionAddCmp,
            _ => false
        };
    }
}