using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

public class PrefetchSite
{
    public string Location { get; set; } = "";
    public string PrefetchType { get; set; } = "prefetcht0";
    public int Offset { get; set; }
    public string? StallWork { get; set; }
}

public static class PrefetchInjector
{
    public static List<PrefetchSite> Analyze(ProgramNode program, List<TierResult> tiers)
    {
        var sites = new List<PrefetchSite>();

        foreach (var state in program.States)
        {
            var tier = tiers.Find(t => t.StateName == state.Name);

            // Hot states: prefetch next state data
            if (tier?.IsHot == true)
            {
                foreach (var t in state.Transitions)
                {
                    var targetTier = tiers.Find(tt => tt.StateName == t.Target);
                    if (targetTier == null) continue;

                    // If target is in cooler tier, prefetch
                    if (targetTier.Section != tier.Section)
                    {
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
                            Offset = targetTier.Section switch
                            {
                                ".text.hot.L1" => 64,
                                ".text.warm.L2" => 256,
                                ".text.cold.L3" => 512,
                                _ => 1024
                            }
                        };

                        // Fill stall cycles with useful work
                        if (targetTier.Section is ".text.cold.L3" or ".text.warm.L2")
                        {
                            site.StallWork = "precompute next state_id, check guard conditions";
                        }

                        sites.Add(site);
                    }
                }
            }

            // Cold states: prefetch return path
            if (tier?.Section == ".text.cold.L3")
            {
                foreach (var t in state.Transitions)
                {
                    var targetTier = tiers.Find(tt => tt.StateName == t.Target);
                    if (targetTier?.IsHot == true)
                    {
                        sites.Add(new PrefetchSite
                        {
                            Location = $"{state.Name} → {t.Target} (return to hot)",
                            PrefetchType = "prefetcht0",
                            Offset = 64
                        });
                    }
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
            lines.Add($"    ; prefetch: {site.Location}");
            lines.Add($"    {site.PrefetchType} [rax + {site.Offset}]");

            if (site.StallWork != null)
            {
                lines.Add($"    ; stall fill: {site.StallWork}");
                lines.Add("    ; (10-15 cycles of useful computation inserted here)");
            }
        }

        return lines;
    }
}
