using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

public class PrefetchSite
{
    public string Location { get; set; } = "";
    public string PrefetchType { get; set; } = "prefetcht0";
    public int Offset { get; set; }
    public int Distance { get; set; }
    public string? StallWork { get; set; }
}

public static class PrefetchInjector
{
    // CPU latency table (cycles)
    private static readonly Dictionary<string, (int L1, int L2, int L3, int Mem)> CpuLatency = new()
    {
        { "intel_adl",   (4, 12, 40,  200) },
        { "intel_skx",   (4, 14, 55,  220) },
        { "intel_icx",   (5, 12, 50,  210) },
        { "amd_zen4",    (4, 14, 45,  190) },
        { "amd_zen3",    (4, 12, 40,  180) },
        { "arm_neoverse",(4, 11, 35,  160) },
        { "generic",     (4, 12, 45,  200) }
    };

    private static (int L1, int L2, int L3, int Mem) GetLatency(string? cpuHint)
    {
        if (cpuHint != null && CpuLatency.TryGetValue(cpuHint, out var lat))
            return lat;
        return CpuLatency["generic"];
    }

    /// <summary>
    /// Calculate optimal prefetch distance: memory_latency_cycles / loop_body_cycles.
    /// </summary>
    public static int CalculateDistance(int memoryLatencyCycles, int loopBodyCycles)
    {
        if (loopBodyCycles <= 0) return 64;
        int dist = memoryLatencyCycles / loopBodyCycles;
        return Math.Clamp(dist, 4, 512);
    }

    public static List<PrefetchSite> Analyze(ProgramNode program, List<TierResult> tiers, string? cpuHint = null)
    {
        var sites = new List<PrefetchSite>();
        var lat = GetLatency(cpuHint);

        foreach (var state in program.States)
        {
            var tier = tiers.Find(t => t.StateName == state.Name);
            if (tier?.IsHot != true) continue;

            // Estimate loop body size (cycles) from transition count
            int loopBodyCycles = Math.Max(state.Transitions.Count * 2, 4);

            foreach (var t in state.Transitions)
            {
                var targetTier = tiers.Find(tt => tt.StateName == t.Target);
                if (targetTier == null) continue;

                if (targetTier.Section != tier.Section)
                {
                    int memLat = targetTier.Section switch
                    {
                        ".text.hot.L0" or ".text.hot.L1" => lat.L1,
                        ".text.warm.L2" => lat.L2,
                        ".text.cold.L3" => lat.L3,
                        _ => lat.Mem
                    };

                    int dist = CalculateDistance(memLat, loopBodyCycles);
                    int offset = targetTier.Section switch
                    {
                        ".text.hot.L1" => 64,
                        ".text.warm.L2" => 256,
                        ".text.cold.L3" => 512 * dist / 20,
                        _ => 1024 * dist / 20
                    };

                    string prefetchType = targetTier.Section switch
                    {
                        ".text.hot.L1" => "prefetcht0",
                        ".text.warm.L2" => "prefetcht1",
                        ".text.cold.L3" => "prefetcht2",
                        _ => "prefetchnta"
                    };

                    var site = new PrefetchSite
                    {
                        Location = $"{state.Name} → {t.Target}",
                        PrefetchType = prefetchType,
                        Offset = offset,
                        Distance = dist
                    };

                    if (targetTier.Section is ".text.cold.L3" or ".text.warm.L2")
                        site.StallWork = "precompute next state_id, check guard conditions";

                    sites.Add(site);
                }
            }
        }

        return sites;
    }

    public static List<string> GenerateAsm(List<PrefetchSite> sites)
    {
        var lines = new List<string>();

        foreach (var site in sites)
        {
            lines.Add($"    ; prefetch (dist={site.Distance}): {site.Location}");
            lines.Add($"    {site.PrefetchType} [rax + {site.Offset}]");

            if (site.StallWork != null)
            {
                lines.Add($"    ; stall fill ({site.Distance} cycles): {site.StallWork}");
                lines.Add("    ; (useful computation inserted here)");
            }
        }

        return lines;
    }

    /// <summary>Auto-detect CPU microarchitecture from environment.</summary>
    public static string DetectCpu()
    {
        try
        {
            string? arch = Environment.GetEnvironmentVariable("PROCESSOR_IDENTIFIER");
            if (arch != null)
            {
                if (arch.Contains("AMD", StringComparison.OrdinalIgnoreCase)) return "amd_zen4";
                if (arch.Contains("Intel", StringComparison.OrdinalIgnoreCase)) return "intel_icx";
            }
            string? model = Environment.GetEnvironmentVariable("BPLUS_CPU_MODEL");
            if (model != null) return model;
        }
        catch { }
        return "generic";
    }
}