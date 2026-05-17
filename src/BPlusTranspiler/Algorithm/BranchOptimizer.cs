namespace BPlusTranspiler.Algorithm;

public class BranchOptimizer
{
    public class BranchInfo
    {
        public string Condition { get; set; } = "";
        public int Frequency { get; set; }
        public bool IsHot { get; set; }
        public string Replacement { get; set; } = "";
    }

    public class OptimizationResult
    {
        public List<BranchInfo> Branches { get; set; } = new();
        public int HotLayout { get; set; }
        public int CmovReplaces { get; set; }
        public int UnrollFactors { get; set; }
    }

    public OptimizationResult Analyze(string[] stmts, int threshold = 100)
    {
        var result = new OptimizationResult();

        foreach (var s in stmts)
        {
            if (!s.Contains("if") && !s.Contains("branch") && !s.Contains("jmp")) continue;

            int freq = EstimateFrequency(s);
            var info = new BranchInfo
            {
                Condition = s,
                Frequency = freq,
                IsHot = freq > threshold
            };

            if (info.IsHot && s.Contains("x < y") || s.Contains("x > y"))
            {
                info.Replacement = "cmov (branchless)";
                result.CmovReplaces++;
            }

            result.Branches.Add(info);
        }

        result.HotLayout = result.Branches.Count(b => b.IsHot);
        return result;
    }

    private int EstimateFrequency(string stmt)
    {
        if (stmt.Contains("hot") || stmt.Contains("critical")) return 500;
        if (stmt.Contains("common") || stmt.Contains("normal")) return 100;
        return 50;
    }

    public string GenerateHeader(OptimizationResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Branch optimizer");
        sb.AppendLine($"#define BPLUS_HOT_BRANCHES {r.HotLayout}");
        sb.AppendLine($"#define BPLUS_CMOV_REPLACES {r.CmovReplaces}");
        sb.AppendLine();
        sb.AppendLine("// Branchless replacements:");
        sb.AppendLine("// if (a < b) x = c; -> x = (a < b) ? c : x;");
        sb.AppendLine("// if (a == 0) x = b; -> x = a ? b : x;");
        return sb.ToString();
    }
}

public class LoopUnroller
{
    public class UnrollResult
    {
        public int OriginalTripCount { get; set; }
        public int UnrollFactor { get; set; }
        public int EstimatedOps { get; set; }
        public double EstSpeedup { get; set; }
    }

    public UnrollResult Unroll(int tripCount, string loopBody)
    {
        int factor = 1;
        if (tripCount > 1000) factor = 8;
        else if (tripCount > 100) factor = 4;
        else if (tripCount > 20) factor = 2;

        return new UnrollResult
        {
            OriginalTripCount = tripCount,
            UnrollFactor = factor,
            EstimatedOps = tripCount / factor,
            EstSpeedup = factor * 0.9
        };
    }

    public string GenerateHeader(UnrollResult r)
    {
        return $"// Loop unroll: factor={r.UnrollFactor}, speedup={r.EstSpeedup:F1}x\n" +
               $"#define BPLUS_UNROLL_FACTOR {r.UnrollFactor}\n";
    }
}
