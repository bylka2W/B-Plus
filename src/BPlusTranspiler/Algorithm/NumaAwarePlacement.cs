namespace BPlusTranspiler.Algorithm;

public class NumaAwarePlacement
{
    public class NumaNode
    {
        public int Id { get; set; }
        public int Cores { get; set; }
        public long SizeBytes { get; set; }
        public double BandwidthGBps { get; set; }
        public int LatencyNs { get; set; }
    }

    public class PlacementResult
    {
        public List<NumaNode> Nodes { get; set; } = new();
        public int PrimaryNode { get; set; }
        public string AllocationStrategy { get; set; } = "";
        public double EstSpeedup { get; set; }
    }

    private static readonly (int cores, long size, double bw, int lat)[] IntelProfiles =
    {
        (4, 8L * 1024, 40.0, 80),
        (8, 16L * 1024, 80.0, 75),
        (16, 32L * 1024, 160.0, 70),
        (32, 64L * 1024, 320.0, 60),
        (64, 128L * 1024, 640.0, 55)
    };

    public PlacementResult DetectAndPlace(string cpuMicroarch)
    {
        var result = new PlacementResult();

        int nodes = 1;
        if (cpuMicroarch.Contains("epyc")) nodes = 2;
        else if (cpuMicroarch.Contains("xeon")) nodes = 2;

        var profile = IntelProfiles[0];
        if (cpuMicroarch.Contains("skylake")) profile = IntelProfiles[1];
        else if (cpuMicroarch.Contains("icelake")) profile = IntelProfiles[2];
        else if (cpuMicroarch.Contains("alderlake")) profile = IntelProfiles[3];

        for (int i = 0; i < nodes; i++)
        {
            result.Nodes.Add(new NumaNode
            {
                Id = i,
                Cores = profile.cores,
                SizeBytes = profile.size * 1024 * 1024,
                BandwidthGBps = profile.bw,
                LatencyNs = profile.lat
            });
        }

        result.PrimaryNode = 0;
        result.AllocationStrategy = nodes > 1
            ? "Interleaved: distribute across NUMA nodes for max bandwidth"
            : "Local: allocate all on node 0 (single-socket)";
        result.EstSpeedup = nodes > 1 ? 1.3 : 1.0;

        return result;
    }

    public string GenerateHeader(PlacementResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// NUMA-aware placement");
        sb.AppendLine($"#define BPLUS_NUMA_NODES {r.Nodes.Count}");
        sb.AppendLine($"#define BPLUS_PRIMARY_NODE {r.PrimaryNode}");
        sb.AppendLine($"// Strategy: {r.AllocationStrategy}");

        if (r.Nodes.Count > 1)
        {
            sb.AppendLine();
            sb.AppendLine("#ifdef NUMA");
            sb.AppendLine("#include <numa.h>");
            sb.AppendLine("#endif");
            sb.AppendLine();
            sb.AppendLine("static inline void* bplus_numa_alloc(size_t size, int node) {");
            sb.AppendLine("#ifdef NUMA");
            sb.AppendLine("    return numa_alloc_onnode(size, node);");
            sb.AppendLine("#else");
            sb.AppendLine("    return malloc(size);");
            sb.AppendLine("#endif");
            sb.AppendLine("}");
            sb.AppendLine();
            sb.AppendLine("static inline void bplus_numa_bind(void* ptr, size_t size, int node) {");
            sb.AppendLine("#ifdef NUMA");
            sb.AppendLine("    numa_bind(numa_parse_nodestring(&node));");
            sb.AppendLine("#endif");
            sb.AppendLine("}");
        }

        return sb.ToString();
    }

    public string GetPlacementHint(int dataSizeKB, string accessPattern)
    {
        if (dataSizeKB < 64)
            return "Local node (fits in L1/L2, NUMA affinity not critical)";
        else if (dataSizeKB < 512)
            return "Local node with interleaved pages for L3";
        else
            return "Interleaved across NUMA nodes, use libnuma for allocation";
    }
}
