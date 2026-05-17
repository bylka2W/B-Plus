using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Algorithm;

public enum AccessPattern { Sequential, Stride, Random, Unknown }

public class MemoryAccessPatternDetector
{
    public class PatternInfo
    {
        public string Variable { get; set; } = "";
        public AccessPattern Pattern { get; set; }
        public int StrideBytes { get; set; }
        public int Confidence { get; set; }
        public string Recommendation { get; set; } = "";
    }

    public class DetectionResult
    {
        public List<PatternInfo> Patterns { get; set; } = new();
        public int SequentialCount { get; set; }
        public int StrideCount { get; set; }
        public int RandomCount { get; set; }
    }

    public DetectionResult Analyze(ProgramNode program)
    {
        var result = new DetectionResult();

        foreach (var state in program.States)
        {
            foreach (var v in state.Variables)
            {
                var pattern = DetectPattern(state, v);
                result.Patterns.Add(pattern);

                switch (pattern.Pattern)
                {
                    case AccessPattern.Sequential: result.SequentialCount++; break;
                    case AccessPattern.Stride: result.StrideCount++; break;
                    case AccessPattern.Random: result.RandomCount++; break;
                }
            }
        }

        return result;
    }

    private PatternInfo DetectPattern(StateDefNode state, VariableNode v)
    {
        var info = new PatternInfo { Variable = v.Name };

        int transitions = state.Transitions.Count;
        int actions = state.Actions.Count;

        if (transitions > 10 && actions > 10)
        {
            info.Pattern = AccessPattern.Sequential;
            info.StrideBytes = 8;
            info.Confidence = 90;
            info.Recommendation = "Sequential: use hardware prefetch, no software prefetch needed";
        }
        else if (transitions > 5)
        {
            info.Pattern = AccessPattern.Stride;
            info.StrideBytes = transitions * 8;
            info.Confidence = 75;
            info.Recommendation = $"Stride: use PREFETCHT0 at distance {info.StrideBytes * 2} bytes";
        }
        else
        {
            info.Pattern = AccessPattern.Random;
            info.StrideBytes = 0;
            info.Confidence = 50;
            info.Recommendation = "Random: minimize working set, use fast path";
        }

        return info;
    }

    public string GenerateHeader(DetectionResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Memory access pattern analysis");
        sb.AppendLine($"#define BPLUS_SEQUENTIAL_PATTERNS {r.SequentialCount}");
        sb.AppendLine($"#define BPLUS_STRIDE_PATTERNS {r.StrideCount}");
        sb.AppendLine($"#define BPLUS_RANDOM_PATTERNS {r.RandomCount}");

        foreach (var p in r.Patterns.Where(x => x.Pattern == AccessPattern.Stride))
        {
            sb.AppendLine($"// {p.Variable}: stride={p.StrideBytes}B, prefetch recommended");
        }

        return sb.ToString();
    }

    public string GetOptimizationStrategy(AccessPattern pattern, int strideBytes)
    {
        return pattern switch
        {
            AccessPattern.Sequential => "Hardware prefetch will handle this. No action needed.",
            AccessPattern.Stride when strideBytes >= 64 && strideBytes <= 1024 =>
                $"Software prefetch (PREFETCHT0/T1) at distance {strideBytes * 2}. Use _mm_prefetch.",
            AccessPattern.Stride => $"Large stride ({strideBytes}B). Consider blocking to reduce cache pressure.",
            AccessPattern.Random => "Reduce working set. Use register allocation. Consider SoA layout.",
            _ => "Unknown pattern. Use conservative settings."
        };
    }
}
