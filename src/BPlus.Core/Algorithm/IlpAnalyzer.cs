namespace BPlus.Core.Algorithm;

public class SimpleIlpAnalyzer
{
    public class DependencyChain
    {
        public string Inst1 { get; set; } = "";
        public string Inst2 { get; set; } = "";
        public int Latency { get; set; }
        public string Type { get; set; } = "";
    }

    public class IlpResult
    {
        public int ChainLength { get; set; }
        public int CriticalPath { get; set; }
        public double IlpScore { get; set; }
        public List<DependencyChain> Chains { get; set; } = new();
        public string[] Suggestions { get; set; } = [];
    }

    private static readonly (string from, string to, int latency)[] IntelLatencies =
    {
        ("add", "add", 1), ("add", "cmp", 1), ("mul", "add", 3), ("div", "add", 20),
        ("load", "add", 1), ("load", "mul", 2), ("store", "load", 1)
    };

    public IlpResult Analyze(string[] instructions)
    {
        var result = new IlpResult();

        if (instructions.Length == 0) return result;

        int maxLatency = 0;
        var chains = new List<DependencyChain>();

        for (int i = 0; i < instructions.Length - 1; i++)
        {
            var (from, to, lat) = FindDependency(instructions[i], instructions[i + 1]);
            if (lat > 0)
            {
                chains.Add(new DependencyChain { Inst1 = from, Inst2 = to, Latency = lat, Type = "data" });
                maxLatency += lat;
            }
        }

        result.Chains = chains;
        result.CriticalPath = maxLatency;
        result.ChainLength = instructions.Length;
        result.IlpScore = instructions.Length / Math.Max(1, maxLatency);
        result.Suggestions = GenerateSuggestions(result);

        return result;
    }

    private (string from, string to, int latency) FindDependency(string i1, string i2)
    {
        string l1 = i1.ToLower();
        string l2 = i2.ToLower();

        foreach (var (from, to, lat) in IntelLatencies)
        {
            if (l1.Contains(from) && l2.Contains(to))
                return (i1, i2, lat);
        }

        return ("", "", 0);
    }

    private string[] GenerateSuggestions(IlpResult r)
    {
        var suggestions = new List<string>();

        if (r.CriticalPath > 10)
            suggestions.Add("Break critical path with register renaming");

        if (r.IlpScore < 2.0)
            suggestions.Add("Increase ILP with loop unrolling (+4x)");

        if (r.Chains.Count > 5)
            suggestions.Add("Reduce dependency chains via instruction scheduling");

        if (r.CriticalPath > 20)
            suggestions.Add("Use out-of-order execution hints to hide latencies");

        if (suggestions.Count == 0)
            suggestions.Add("ILP is already optimized");

        return suggestions.ToArray();
    }

    public string GenerateHeader()
    {
        return @"// ILP Analyzer recommendations
#define BPLUS_ILP_UNROLL_FACTOR 4
#define BPLUS_ILP_SCHEDULE 1
#define BPLUS_ILP_RENAME 1

static inline void bplus_ilp_hint(const char* op) {
#if defined(__INTEL_COMPILER)
    __assume_aligned(op, 64);
#endif
}
";
    }

    public string OptimizeCode(string asm)
    {
        var lines = asm.Split('\n').ToList();
        var optimized = new List<string>();

        for (int i = 0; i < lines.Count; i++)
        {
            string l = lines[i];

            if (l.Contains("add") && i + 1 < lines.Count && lines[i + 1].Contains("add"))
            {
                optimized.Add(l + " ; ILP hint: independent add");
                continue;
            }

            if (l.Contains("mul") && i + 1 < lines.Count && lines[i + 1].Contains("add"))
            {
                optimized.Add("#pragma unroll(2)");
                optimized.Add(l);
                i++;
                optimized.Add(lines[i]);
                optimized.Add("#pragma unroll(1)");
                continue;
            }

            optimized.Add(l);
        }

        return string.Join("\n", optimized);
    }
}
