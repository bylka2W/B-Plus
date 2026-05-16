namespace BPlusTranspiler.AI;

public class SimpleRooflineAnalyzer
{
    public enum ComputeBound
    {
        Unknown,
        MemoryBound,
        ComputeBound,
        Balanced
    }

    public class RooflineResult
    {
        public double FlopsPerByte { get; set; }
        public double OperationalIntensity { get; set; }
        public double PeakGflops { get; set; }
        public double AchievableGflops { get; set; }
        public ComputeBound Bound { get; set; }
        public string Recommendation { get; set; } = "";
    }

    private static readonly (string cpu, double peakGflops)[] IntelPeaks =
    {
        ("skylake", 1024.0), ("cannonlake", 1536.0), ("icelake", 2048.0),
        ("icelake_sp", 2048.0), ("cometlake", 512.0), ("tigerlake", 1536.0),
        ("alderlake", 1280.0), ("rocketlake", 1024.0), ("sapphire", 2048.0)
    };

    public RooflineResult Analyze(string kernelName, int flops, int bytesLoaded, int bytesStored, string cpuMicroarch)
    {
        var result = new RooflineResult();

        double peakGflops = 1024.0;
        foreach (var (cpu, gflops) in IntelPeaks)
        {
            if (cpuMicroarch.Contains(cpu))
            {
                peakGflops = gflops;
                break;
            }
        }
        result.PeakGflops = peakGflops;

        int totalBytes = bytesLoaded + bytesStored;
        result.OperationalIntensity = totalBytes > 0 ? (double)flops / totalBytes : 0;

        double bandwidthGBs = 50.0;
        if (cpuMicroarch.Contains("skylake")) bandwidthGBs = 50.0;
        else if (cpuMicroarch.Contains("icelake")) bandwidthGBs = 100.0;
        else if (cpuMicroarch.Contains("alderlake")) bandwidthGBs = 75.0;

        double rooflineGflops = Math.Min(peakGflops, bandwidthGBs * result.OperationalIntensity);
        result.AchievableGflops = rooflineGflops;

        if (result.OperationalIntensity < 2.0)
        {
            result.Bound = ComputeBound.MemoryBound;
            result.Recommendation = "Memory-bound: add more FLOPs or reduce memory traffic";
        }
        else if (result.OperationalIntensity > 20.0)
        {
            result.Bound = ComputeBound.ComputeBound;
            result.Recommendation = "Compute-bound: increase AVX-512 utilization";
        }
        else
        {
            result.Bound = ComputeBound.Balanced;
            result.Recommendation = "Balanced: current optimization is near-optimal";
        }

        return result;
    }

    public string GenerateReport(RooflineResult r)
    {
        return $"  AI roofline: {r.AchievableGflops:F1} GFLOPS ({r.Bound})\n" +
               $"  Peak: {r.PeakGflops:F1} GFLOPS, OI: {r.OperationalIntensity:F2} FLOPs/byte\n" +
               $"  Recommendation: {r.Recommendation}";
    }

    public string GenerateHeader()
    {
        return @"// Roofline analysis
#define BPLUS_ROOFLINE 1
#define BPLUS_MATH_BOUND 0
#define BPLUS_MEM_BOUND 1

static inline double bplus_roofline_gi(double flops, double bytes) {
    return bytes > 0 ? flops / bytes : 0;
}

static inline double bplus_roofline_gflops(double gi, double bw_gbps) {
    return bw_gbps * gi;
}

static inline int bplus_is_compute_bound(double operational_intensity, double peak_gflops, double bandwidth_gbps) {
    return operational_intensity > (peak_gflops / bandwidth_gbps);
}
";
    }
}