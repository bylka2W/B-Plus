namespace BPlusTranspiler.AI;

public class AdaptiveWorkingSet
{
    public class WorkingSetConfig
    {
        public int CurrentSizeKB { get; set; }
        public int TargetSizeKB { get; set; }
        public int MissRate { get; set; }
        public double Efficiency { get; set; }
    }

    public class AdaptationResult
    {
        public WorkingSetConfig Config { get; set; } = new();
        public int RecommendedSizeKB { get; set; }
        public string Action { get; set; } = "";
        public double EstSpeedup { get; set; }
    }

    private const int L1SizeKB = 32;
    private const int L2SizeKB = 256;
    private const int L3SizeKB = 2048;

    public AdaptationResult ComputeOptimalSize(int currentSizeKB, double missRate)
    {
        var result = new AdaptationResult
        {
            Config = new WorkingSetConfig { CurrentSizeKB = currentSizeKB, MissRate = (int)(missRate * 100) }
        };

        if (missRate > 0.5)
        {
            result.RecommendedSizeKB = L1SizeKB;
            result.Action = "Reduce working set: miss rate > 50%, shrink to L1";
        }
        else if (missRate > 0.2)
        {
            result.RecommendedSizeKB = L2SizeKB;
            result.Action = "Optimize for L2: target L1/L2 boundary";
        }
        else if (missRate > 0.05)
        {
            result.RecommendedSizeKB = L3SizeKB;
            result.Action = "L3 optimized: working set fits L3 well";
        }
        else
        {
            result.RecommendedSizeKB = currentSizeKB;
            result.Action = "Cache efficient: current size is optimal";
        }

        result.Config.TargetSizeKB = result.RecommendedSizeKB;
        result.Config.Efficiency = 1.0 - missRate;
        result.EstSpeedup = missRate > 0.5 ? 3.0 : (missRate > 0.2 ? 1.5 : 1.1);

        return result;
    }

    public string GenerateHeader(AdaptationResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Adaptive working set manager");
        sb.AppendLine($"#define BPLUS_WS_CURRENT_KB {r.Config.CurrentSizeKB}");
        sb.AppendLine($"#define BPLUS_WS_TARGET_KB {r.Config.TargetSizeKB}");
        sb.AppendLine($"#define BPLUS_WS_MISS_RATE {r.Config.MissRate}");
        sb.AppendLine($"#define BPLUS_WS_EFFICIENCY {r.Config.Efficiency:F2}");
        sb.AppendLine($"// Action: {r.Action}");
        sb.AppendLine();
        sb.AppendLine("static inline size_t bplus_optimal_working_set(double miss_rate) {");
        sb.AppendLine("    if (miss_rate > 0.5) return 32 * 1024;    // L1");
        sb.AppendLine("    if (miss_rate > 0.2) return 256 * 1024;  // L2");
        sb.AppendLine("    if (miss_rate > 0.05) return 2048 * 1024; // L3");
        sb.AppendLine("    return 0;  // No limit");
        sb.AppendLine("}");
        return sb.ToString();
    }

    public AdaptationResult OptimizeForTarget(string cpuMicroarch)
    {
        if (cpuMicroarch.Contains("icelake") || cpuMicroarch.Contains("alderlake"))
            return ComputeOptimalSize(32, 0.3);
        else if (cpuMicroarch.Contains("skylake"))
            return ComputeOptimalSize(64, 0.4);
        else
            return ComputeOptimalSize(32, 0.5);
    }
}