namespace BPlusTranspiler.Algorithm;

public class CoreAffinityController
{
    public enum CoreType { Performance, Efficiency, Unknown }

    public class CoreInfo
    {
        public int Id { get; set; }
        public CoreType Type { get; set; }
        public int FrequencyMHz { get; set; }
        public int CacheKB { get; set; }
        public bool IsOnline { get; set; }
    }

    public class AffinityResult
    {
        public List<CoreInfo> Cores { get; set; } = new();
        public int PCoreCount { get; set; }
        public int ECoreCount { get; set; }
        public string Strategy { get; set; } = "";
        public double EstSpeedup { get; set; }
    }

    public AffinityResult DetectAndConfigure(string cpuMicroarch)
    {
        var result = new AffinityResult();

        int totalCores = Environment.ProcessorCount;
        int pCores = totalCores;
        int eCores = 0;

        if (cpuMicroarch.Contains("alderlake") || cpuMicroarch.Contains("raptorlake"))
        {
            pCores = totalCores * 2 / 3;
            eCores = totalCores - pCores;
            result.Strategy = "Hybrid: P-cores for hot tasks, E-cores for background";
        }
        else if (cpuMicroarch.Contains("icelake"))
        {
            pCores = totalCores;
            eCores = 0;
            result.Strategy = "Server: all P-cores, use SMT for background tasks";
        }
        else
        {
            result.Strategy = "Standard: all cores equal priority";
        }

        result.PCoreCount = pCores;
        result.ECoreCount = eCores;

        for (int i = 0; i < totalCores; i++)
        {
            result.Cores.Add(new CoreInfo
            {
                Id = i,
                Type = i < pCores ? CoreType.Performance : CoreType.Efficiency,
                FrequencyMHz = i < pCores ? 4500 : 2500,
                CacheKB = i < pCores ? 256 : 128,
                IsOnline = true
            });
        }

        result.EstSpeedup = eCores > 0 ? 1.3 : 1.0;
        return result;
    }

    public string GetAffinityMask(bool forHotTask)
    {
        if (forHotTask)
            return "0x55555555... (P-cores only)";
        else
            return "0xAAAAAAAA... (E-cores only)";
    }

    public string GenerateHeader(AffinityResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Core affinity controller");
        sb.AppendLine($"#define BPLUS_P_CORES {r.PCoreCount}");
        sb.AppendLine($"#define BPLUS_E_CORES {r.ECoreCount}");
        sb.AppendLine($"#define BPLUS_TOTAL_CORES {r.Cores.Count}");
        sb.AppendLine($"// Strategy: {r.Strategy}");
        sb.AppendLine($"// Est speedup: {r.EstSpeedup:F2}x");
        sb.AppendLine();
        sb.AppendLine("static inline void bplus_set_affinity_hot(int mask) {");
        sb.AppendLine("#ifdef _WIN32");
        sb.AppendLine("    SetThreadAffinityMask(GetCurrentThread(), mask);");
        sb.AppendLine("#else");
        sb.AppendLine("    cpu_set_t cs; CPU_ZERO(&cs);");
        sb.AppendLine("    for (int i = 0; i < 64; i++) if (mask & (1 << i)) CPU_SET(i, &cs);");
        sb.AppendLine("    sched_setaffinity(0, sizeof(cs), &cs);");
        sb.AppendLine("#endif");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("static inline void bplus_set_affinity_cold(void) {");
        sb.AppendLine("    bplus_set_affinity_hot(~0x55555555);  // E-cores");
        sb.AppendLine("}");
        return sb.ToString();
    }

    public string GetSchedulingHint(AffinityResult affResult, bool isHot)
    {
        int pCount = affResult.PCoreCount;
        if (isHot && pCount > 0)
            return $"Pin to P-core (0-{pCount - 1})";
        else if (isHot)
            return "No P-cores available, use any core";
        else
            return "Background task, use E-cores or idle P-cores";
    }
}
