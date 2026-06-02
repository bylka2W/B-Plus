namespace BPlus.Core.Algorithm;

public class ResourceOrchestrator
{
    public class ResourceStatus
    {
        public string Name { get; set; } = "";
        public double Utilization { get; set; }
        public bool IsIdle { get; set; }
        public string SuggestedTask { get; set; } = "";
    }

    public class OrchestrationResult
    {
        public List<ResourceStatus> Resources { get; set; } = new();
        public double OverallEfficiency { get; set; }
        public string[] Tasks { get; set; } = [];
    }

    public OrchestrationResult Analyze(string cpuMicroarch, bool hasGpu, bool hasNpu, bool hasNvme)
    {
        var result = new OrchestrationResult();
        var tasks = new List<string>();

        result.Resources.Add(new ResourceStatus { Name = "P-cores", Utilization = 60, IsIdle = false, SuggestedTask = "Main computation" });
        result.Resources.Add(new ResourceStatus { Name = "E-cores", Utilization = 10, IsIdle = true, SuggestedTask = "Background compression, prefetch" });

        if (hasGpu)
        {
            result.Resources.Add(new ResourceStatus { Name = "dGPU", Utilization = 80, IsIdle = false, SuggestedTask = "Rendering" });
            result.Resources.Add(new ResourceStatus { Name = "iGPU", Utilization = 0, IsIdle = true, SuggestedTask = "Texture decompression, physics" });
            tasks.Add("iGPU: decompress textures");
        }

        if (hasNpu)
        {
            result.Resources.Add(new ResourceStatus { Name = "NPU", Utilization = 0, IsIdle = true, SuggestedTask = "ML inference, collision prediction" });
            tasks.Add("NPU: predict future collisions");
        }

        if (hasNvme)
        {
            result.Resources.Add(new ResourceStatus { Name = "NVMe", Utilization = 5, IsIdle = true, SuggestedTask = "Asset preloading, level streaming" });
            tasks.Add("NVMe: preload next level");
        }

        result.Resources.Add(new ResourceStatus { Name = "Network", Utilization = 2, IsIdle = true, SuggestedTask = "Cloud asset prefetch" });
        tasks.Add("Network: prefetch cloud chunks");

        result.Tasks = tasks.ToArray();
        result.OverallEfficiency = 100.0 - (result.Resources.Count(r => r.IsIdle) * 10.0);

        return result;
    }

    public string GenerateHeader(OrchestrationResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Resource orchestrator");
        sb.AppendLine($"#define BPLUS_ORCH_EFFICIENCY {r.OverallEfficiency:F1}");
        sb.AppendLine($"#define BPLUS_IDLE_RESOURCES {r.Resources.Count(x => x.IsIdle)}");
        sb.AppendLine();
        sb.AppendLine("static inline void bplus_schedule_background(void) {");
        sb.AppendLine("    // Background tasks:");
        foreach (var t in r.Tasks)
            sb.AppendLine($"    // - {t}");
        sb.AppendLine("}");
        return sb.ToString();
    }
}
