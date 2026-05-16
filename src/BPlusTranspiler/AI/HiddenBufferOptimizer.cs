namespace BPlusTranspiler.AI;

public class SimpleHiddenBufferOptimizer
{
    public class BufferConfig
    {
        public string Name { get; set; } = "";
        public int SizeKB { get; set; }
        public int LineSize { get; set; }
        public int Associativity { get; set; }
        public double HitRate { get; set; }
        public int LatencyCycles { get; set; }
    }

    public class OptimizationResult
    {
        public string BufferType { get; set; } = "";
        public int OriginalSizeKB { get; set; }
        public int OptimizedSizeKB { get; set; }
        public string Technique { get; set; } = "";
        public double EstSpeedup { get; set; }
    }

    private static readonly (string name, int size, int line, int assoc, int latency)[] IntelBuffers =
    {
        ("L1D", 32, 64, 8, 4),
        ("L2", 256, 64, 4, 12),
        ("L3", 2048, 64, 16, 50),
        ("LSD", 64, 0, 0, 1),
        ("BTB", 32, 0, 4, 1),
        ("RSB", 16, 0, 0, 1),
        ("TLB", 48, 4096, 6, 1),
        ("LFB", 64, 0, 0, 1)
    };

    public List<OptimizationResult> OptimizeForTarget(string cpuMicroarch)
    {
        var results = new List<OptimizationResult>();

        foreach (var (name, sizeKB, lineSize, assoc, latency) in IntelBuffers)
        {
            var opt = new OptimizationResult
            {
                BufferType = name,
                OriginalSizeKB = sizeKB
            };

            switch (name)
            {
                case "L1D":
                    opt.OptimizedSizeKB = sizeKB;
                    opt.Technique = "DLP loop fission + stream prefetch";
                    opt.EstSpeedup = EstimateL1Speedup(sizeKB, lineSize);
                    break;
                case "L2":
                    opt.OptimizedSizeKB = sizeKB;
                    opt.Technique = "2MB hugepages + spatial prefetch";
                    opt.EstSpeedup = EstimateL2Speedup(sizeKB, lineSize);
                    break;
                case "L3":
                    opt.OptimizedSizeKB = sizeKB;
                    opt.Technique = "non-temporal stores + CLWB";
                    opt.EstSpeedup = EstimateL3Speedup(sizeKB);
                    break;
                case "LSD":
                    opt.OptimizedSizeKB = sizeKB * 2;
                    opt.Technique = "loop stream decoder bypass";
                    opt.EstSpeedup = 1.03;
                    break;
                case "BTB":
                    opt.OptimizedSizeKB = sizeKB;
                    opt.Technique = "indirect branch predictor tuning";
                    opt.EstSpeedup = 1.05;
                    break;
                case "RSB":
                    opt.OptimizedSizeKB = sizeKB;
                    opt.Technique = "RSB refilling on context switch";
                    opt.EstSpeedup = 1.02;
                    break;
                case "TLB":
                    opt.OptimizedSizeKB = sizeKB;
                    opt.Technique = "1GB hugepages for TLB avoidance";
                    opt.EstSpeedup = EstimateTlbSpeedup(sizeKB);
                    break;
                case "LFB":
                    opt.OptimizedSizeKB = sizeKB;
                    opt.Technique = "load clustering + dependency breaking";
                    opt.EstSpeedup = 1.04;
                    break;
            }

            results.Add(opt);
        }

        return results;
    }

    private double EstimateL1Speedup(int sizeKB, int lineSize)
    {
        if (lineSize == 64) return 1.10 + (sizeKB / 32.0) * 0.05;
        return 1.08;
    }

    private double EstimateL2Speedup(int sizeKB, int lineSize)
    {
        return 1.12 + (sizeKB / 256.0) * 0.08;
    }

    private double EstimateL3Speedup(int sizeKB)
    {
        return 1.15 + (sizeKB / 2048.0) * 0.10;
    }

    private double EstimateTlbSpeedup(int sizeKB)
    {
        return 1.20 + (sizeKB / 48.0) * 0.15;
    }

    public string GenerateHeader(string cpuMicroarch)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("#pragma once");
        sb.AppendLine("// Hidden buffer optimizations for " + cpuMicroarch);
        sb.AppendLine();

        foreach (var r in OptimizeForTarget(cpuMicroarch))
        {
            sb.AppendLine($"// {r.BufferType}: {r.OriginalSizeKB}KB -> {r.OptimizedSizeKB}KB ({r.Technique})");
        }

        sb.AppendLine();
        sb.AppendLine("#define BPLUS_HIDDEN_BUF_OPT 1");
        sb.AppendLine("#define BPLUS_LFB_CLUSTERING 1");
        sb.AppendLine("#define BPLUS_TLB_HUGEPAGES 1");
        sb.AppendLine("#define BPLUS_RSB_REFILL 1");
        sb.AppendLine("#define BPLUS_LSD_BYPASS 1");
        sb.AppendLine("#define BPLUS_BTB_INDIRECT 1");
        sb.AppendLine("#define BPLUS_NONTEMPORAL_STORES 1");
        sb.AppendLine("#define BPLUS_CLWB_WBINVD 1");

        return sb.ToString();
    }
}