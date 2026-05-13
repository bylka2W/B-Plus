using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

public class IlpScore
{
    public string StateName { get; set; } = "";
    public int MaxDependencyChain { get; set; }
    public double IlpScore { get; set; }
    public int IndependentPaths { get; set; }
    public string? Suggestion { get; set; }
}

public class IlpAnalyzer
{
    /// <summary>Score instruction-level parallelism for each state.</summary>
    public static List<IlpScore> Analyze(ProgramNode program, List<TierResult>? tiers = null)
    {
        var scores = new List<IlpScore>();

        foreach (var state in program.States)
        {
            int chainLength = 0;
            int maxChain = 0;
            int independentPaths = 0;

            // Analyze transitions for dependency chains
            foreach (var t in state.Transitions)
            {
                chainLength++;
                if (!string.IsNullOrEmpty(t.Guard))
                    chainLength += 2; // guard evaluation = extra deps

                // Concurrent transitions = independent paths
                if (state.Transitions.Count > 1)
                    independentPaths = state.Transitions.Count - 1;
            }
            maxChain = Math.Max(maxChain, chainLength);

            // Variables create data dependencies
            int varDeps = state.Variables.Count;
            maxChain += varDeps;

            double ilp = independentPaths > 0
                ? Math.Min((double)maxChain / Math.Max(independentPaths, 1), 4.0)
                : 1.0;

            double score = 1.0 / Math.Max(ilp, 1.0); // higher = more parallelism available

            string? suggestion = null;
            if (maxChain > 4)
                suggestion = $"Long dependency chain ({maxChain} ops). Break with: unroll, move independent work, or @ilp_max({maxChain / 2}) to hint reordering.";
            else if (independentPaths > 1)
                suggestion = $"Good ILP: {independentPaths} independent paths, chain length {maxChain}.";

            scores.Add(new IlpScore
            {
                StateName = state.Name,
                MaxDependencyChain = maxChain,
                IlpScore = score,
                IndependentPaths = independentPaths,
                Suggestion = suggestion
            });
        }

        return scores;
    }

    public static string GenerateReport(List<IlpScore> scores)
    {
        var lines = new List<string>
        {
            "╔═══════════════════════════════════════╗",
            "║     ILP DEPENDENCY ANALYSIS          ║",
            "╚═══════════════════════════════════════╝"
        };

        foreach (var s in scores)
        {
            lines.Add($"  {s.StateName}: chain={s.MaxDependencyChain} paths={s.IndependentPaths} ILP={s.IlpScore:F2}");
            if (s.Suggestion != null)
                lines.Add($"    → {s.Suggestion}");
        }

        return string.Join("\n", lines);
    }
}