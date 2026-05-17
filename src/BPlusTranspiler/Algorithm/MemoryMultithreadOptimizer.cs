namespace BPlusTranspiler.Algorithm;

public class EscapeAnalysis
{
    public class EscapeResult
    {
        public string Variable { get; set; } = "";
        public bool Escapes { get; set; }
        public string Scope { get; set; } = "";
        public bool CanStack { get; set; }
    }

    public class AnalysisResult
    {
        public List<EscapeResult> Results { get; set; } = new();
        public int StackAllocatable { get; set; }
        public int HeapAllocatable { get; set; }
    }

    private static readonly string[] EscapingPatterns = { "return", "global", "static", "shared", "pointer" };

    public AnalysisResult Analyze(string[] variables, string[] scopes)
    {
        var result = new AnalysisResult();

        for (int i = 0; i < variables.Length; i++)
        {
            string v = variables[i];
            string scope = i < scopes.Length ? scopes[i] : "local";

            bool escapes = false;
            foreach (var p in EscapingPatterns)
            {
                if (scope.ToLower().Contains(p))
                { escapes = true; break; }
            }

            result.Results.Add(new EscapeResult
            {
                Variable = v,
                Escapes = escapes,
                Scope = scope,
                CanStack = !escapes
            });

            if (!escapes) result.StackAllocatable++;
            else result.HeapAllocatable++;
        }

        return result;
    }
}

public class MemoizationDetector
{
    public class MemoResult
    {
        public string Function { get; set; } = "";
        public bool IsPure { get; set; }
        public int CallCount { get; set; }
        public string CacheKey { get; set; } = "";
    }

    private static readonly string[] ImpurePatterns = { "global", "static", "io", "network", "rand", "time" };

    public List<MemoResult> Detect(string[] functions)
    {
        var results = new List<MemoResult>();

        foreach (var f in functions)
        {
            bool isPure = true;
            foreach (var p in ImpurePatterns)
            {
                if (f.ToLower().Contains(p))
                { isPure = false; break; }
            }

            results.Add(new MemoResult
            {
                Function = f,
                IsPure = isPure,
                CallCount = 100
            });
        }

        return results;
    }
}

public class MlpAnalyzer
{
    public class MlpResult
    {
        public int LoadStores { get; set; }
        public int IndependentLoads { get; set; }
        public double MlpScore { get; set; }
        public string Bottleneck { get; set; } = "";
        public double EstSpeedup { get; set; }
    }

    public MlpResult Analyze(string[] instructions)
    {
        var result = new MlpResult();

        foreach (var inst in instructions)
        {
            if (inst.ToLower().Contains("load") || inst.ToLower().Contains("store"))
                result.LoadStores++;
        }

        result.IndependentLoads = Math.Max(1, result.LoadStores / 4);
        result.MlpScore = result.IndependentLoads * 0.5;
        result.Bottleneck = result.MlpScore < 2 ? "Memory bound" : "Compute bound";
        result.EstSpeedup = Math.Min(4.0, result.MlpScore);

        return result;
    }
}

public class FalseSharingDetector
{
    public class SharingResult
    {
        public string Variable1 { get; set; } = "";
        public string Variable2 { get; set; } = "";
        public int DistanceBytes { get; set; }
        public bool WillShare { get; set; }
        public string Fix { get; set; } = "";
    }

    public class DetectionResult
    {
        public List<SharingResult> Issues { get; set; } = new();
        public int DetectedCount { get; set; }
    }

    private const int CacheLineSize = 64;

    public DetectionResult Detect(string[] variables, int[] offsets)
    {
        var result = new DetectionResult();

        for (int i = 0; i < variables.Length - 1; i++)
        {
            for (int j = i + 1; j < variables.Length; j++)
            {
                int dist = Math.Abs(offsets[i] - offsets[j]);
                if (dist < CacheLineSize)
                {
                    result.Issues.Add(new SharingResult
                    {
                        Variable1 = variables[i],
                        Variable2 = variables[j],
                        DistanceBytes = dist,
                        WillShare = true,
                        Fix = $"Pad to {CacheLineSize} bytes: add {CacheLineSize - dist} bytes"
                    });
                    result.DetectedCount++;
                }
            }
        }

        return result;
    }
}

public class AtomicContentionTracker
{
    public class ContentionResult
    {
        public string Operation { get; set; } = "";
        public int ThreadCount { get; set; }
        public double AvgContention { get; set; }
        public string Recommendation { get; set; } = "";
    }

    public List<ContentionResult> Track(string[] atomicOps, int threads)
    {
        var results = new List<ContentionResult>();

        foreach (var op in atomicOps)
        {
            results.Add(new ContentionResult
            {
                Operation = op,
                ThreadCount = threads,
                AvgContention = threads > 4 ? 0.5 : 0.1,
                Recommendation = threads > 4 ? "Use lock-free数据结构 (MPSC queue)" : "Fine-grained locking sufficient"
            });
        }

        return results;
    }
}

public class WorkStealingScheduler
{
    public class StealingResult
    {
        public int ThreadCount { get; set; }
        public int TaskCount { get; set; }
        public double LoadBalance { get; set; }
        public double EstSpeedup { get; set; }
    }

    public StealingResult Simulate(int threads, int tasks)
    {
        double balance = tasks / (double)threads;
        double imbalance = Math.Abs(balance - 10) / 10;

        return new StealingResult
        {
            ThreadCount = threads,
            TaskCount = tasks,
            LoadBalance = 1.0 - imbalance * 0.3,
            EstSpeedup = Math.Min(threads, tasks / 10.0)
        };
    }
}

public class AguBottleneckAnalyzer
{
    public class AguResult
    {
        public int Loads { get; set; }
        public int Stores { get; set; }
        public int ComplexAddrs { get; set; }
        public double AguStalls { get; set; }
        public string Fix { get; set; } = "";
    }

    public AguResult Analyze(string[] instructions)
    {
        var result = new AguResult();

        foreach (var inst in instructions)
        {
            if (inst.ToLower().Contains("load")) result.Loads++;
            if (inst.ToLower().Contains("store")) result.Stores++;
            if (inst.Contains("[") && (inst.Contains("+") || inst.Contains("*")))
                result.ComplexAddrs++;
        }

        result.AguStalls = result.ComplexAddrs * 0.5;
        result.Fix = result.AguStalls > 5
            ? "Use indexed addressing: [base + index*scale] instead of [base + offset1 + offset2]"
            : "No AGU bottlenecks detected";

        return result;
    }
}
