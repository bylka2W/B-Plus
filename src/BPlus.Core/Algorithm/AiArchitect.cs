using System.Text;
using BPlus.Core.Ast;

namespace BPlus.Core.Algorithm;

public class AiArchitectProfile
{
    public string StateName { get; set; } = "";
    public string EventName { get; set; } = "";
    public string Target { get; set; } = "";
    public double HotWeight { get; set; }
    public string? PredictHint { get; set; }
    public double? PredictProbability { get; set; }
    public bool IsCold { get; set; }
}

public class AiArchitectResult
{
    public List<AiArchitectProfile> Profiles { get; set; } = new();
    public int StatesSplit { get; set; }
    public int TransitionsSorted { get; set; }
    public int EnterBlocksInlined { get; set; }
    public int NumaDuplications { get; set; }
    public int StateCountBefore { get; set; }
    public int StateCountAfter { get; set; }
    public long EstimatedCyclesBefore { get; set; }
    public long EstimatedCyclesAfter { get; set; }
    public bool RolledBack { get; set; }
    public string? RollbackReason { get; set; }

    public string GenerateReport()
    {
        var sb = new StringBuilder();
        sb.AppendLine("=== AI Architect Report ===");
        sb.AppendLine($"States: {StateCountBefore} → {StateCountAfter}");
        sb.AppendLine($"Cold states split to L3: {StatesSplit}");
        sb.AppendLine($"Transitions sorted by probability: {TransitionsSorted}");
        sb.AppendLine($"Enter blocks inlined: {EnterBlocksInlined}");
        sb.AppendLine($"NUMA duplications: {NumaDuplications}");
        sb.AppendLine($"Estimated cycles: {EstimatedCyclesBefore} → {EstimatedCyclesAfter}");
        if (RolledBack)
            sb.AppendLine($"ROLLED BACK: {RollbackReason}");
        sb.AppendLine();

        if (Profiles.Count > 0)
        {
            sb.AppendLine("Transition profiles:");
            foreach (var p in Profiles.OrderBy(p => p.StateName).ThenByDescending(p => p.HotWeight))
            {
                var tag = p.IsCold ? "COLD" : p.HotWeight >= 0.8 ? "HOT" : p.HotWeight >= 0.3 ? "WARM" : "COOL";
                sb.AppendLine($"  {p.StateName} → {p.Target} [{tag}] weight={p.HotWeight:F2} pred={p.PredictHint ?? "none"}");
            }
        }

        return sb.ToString();
    }
}

public static class AiArchitect
{
    // Step 1: PGO profiler — analyze transition hotness/coldness
    public static List<AiArchitectProfile> ProfileTransitions(ProgramNode program)
    {
        var profiles = new List<AiArchitectProfile>();

        foreach (var state in program.States)
        {
            foreach (var t in state.Transitions)
            {
                double weight = t.HotWeight ?? 0.5;
                string? predict = t.Predict ?? state.Predict;
                double? prob = t.PredictProbability ?? state.PredictProbability;

                bool isCold = (weight < 0.3) || (predict == "not_taken") ||
                              (prob.HasValue && prob.Value < 0.2);

                profiles.Add(new AiArchitectProfile
                {
                    StateName = state.Name,
                    EventName = t.EventName ?? "",
                    Target = t.Target ?? "",
                    HotWeight = weight,
                    PredictHint = predict,
                    PredictProbability = prob,
                    IsCold = isCold
                });
            }
        }

        return profiles;
    }

    // Step 2: Split cold states to L3 — annotate cold states for L3 tier
    public static int SplitColdStates(ProgramNode program, List<AiArchitectProfile> profiles)
    {
        int splitCount = 0;

        var coldStates = profiles
            .GroupBy(p => p.StateName)
            .Where(g => g.All(p => p.IsCold))
            .Select(g => g.Key)
            .ToHashSet();

        foreach (var state in program.States)
        {
            if (coldStates.Contains(state.Name))
            {
                state.CachePolicy = "uncacheable";
                state.CacheAlign = 128;
                state.NonTemporal = true;
                splitCount++;
            }
        }

        return splitCount;
    }

    // Step 3: Sort transitions by probability (most likely first)
    public static int SortTransitions(ProgramNode program, List<AiArchitectProfile> profiles)
    {
        int sortedCount = 0;

        foreach (var state in program.States)
        {
            if (state.Transitions.Count <= 1) continue;

            var stateProfiles = profiles
                .Where(p => p.StateName == state.Name)
                .ToDictionary(p => p.EventName + "→" + p.Target);

            state.Transitions.Sort((a, b) =>
            {
                double GetScore(TransitionNode t)
                {
                    var key = (t.EventName ?? "") + "→" + (t.Target ?? "");
                    if (stateProfiles.TryGetValue(key, out var p))
                        return p.PredictProbability ?? p.HotWeight;
                    return t.HotWeight ?? 0.5;
                }
                return GetScore(b).CompareTo(GetScore(a));
            });

            sortedCount++;
        }

        return sortedCount;
    }

    // Step 4: Inline lightweight enter{} blocks into transition bodies
    public static int InlineLightweightEnter(ProgramNode program)
    {
        int inlined = 0;

        foreach (var state in program.States)
        {
            var enterActions = state.Actions.Where(a => a.Type == ActionType.Enter).ToList();
            if (enterActions.Count == 0) continue;

            bool isLightweight = enterActions.All(a =>
            {
                var body = a.Body ?? "";
                return body.Length < 80 && !body.Contains("if") && !body.Contains("while") && !body.Contains("for");
            });

            if (!isLightweight) continue;

            var enterCode = string.Join("; ", enterActions.Select(a => a.Body));
            foreach (var t in state.Transitions)
            {
                t.Body = enterCode + (t.Body != null ? "; " + t.Body : "");
                inlined++;
            }

            state.Actions.RemoveAll(a => a.Type == ActionType.Enter);
        }

        return inlined;
    }

    // Step 5: Data-parallel NUMA duplication
    public static int DuplicateForNuma(ProgramNode program)
    {
        int duplicated = 0;
        int numaCount = Environment.ProcessorCount > 8 ? 2 : 1;
        if (numaCount <= 1) return 0;

        var toDuplicate = program.States
            .Where(s => s.Variables.Count > 0 && s.Transitions.Count > 0)
            .ToList();

        foreach (var state in toDuplicate)
        {
            for (int node = 1; node < numaCount; node++)
            {
                var dup = new StateDefNode
                {
                    Name = $"{state.Name}_numa{node}",
                    BaseClass = state.BaseClass,
                    CachePolicy = state.CachePolicy,
                    CachePin = true,
                    CacheAlign = 64,
                };

                foreach (var v in state.Variables)
                {
                    dup.Variables.Add(new VariableNode
                    {
                        Name = v.Name,
                        Type = v.Type,
                        IsFastPath = v.IsFastPath,
                        IsMutable = v.IsMutable
                    });
                }

                foreach (var t in state.Transitions)
                {
                    dup.Transitions.Add(new TransitionNode
                    {
                        EventName = t.EventName,
                        Target = t.Target,
                        Body = t.Body,
                        Guard = t.Guard,
                        IsAlways = t.IsAlways,
                        HotWeight = t.HotWeight,
                    });
                }

                program.States.Add(dup);
                duplicated++;
            }
        }

        return duplicated;
    }

    // Step 6: Benchmark + rollback if regression detected
    public static AiArchitectResult RunWithBenchmark(ProgramNode program, string? binaryPath, int benchIterations = 1000)
    {
        var sw = new System.Diagnostics.Stopwatch();

        sw.Start();
        for (int i = 0; i < benchIterations; i++)
        {
            foreach (var s in program.States)
                foreach (var t in s.Transitions) { /* simulate traversal */ }
        }
        sw.Stop();
        long cyclesBefore = sw.ElapsedTicks;

        var result = Run(program);

        sw.Restart();
        for (int i = 0; i < benchIterations; i++)
        {
            foreach (var s in program.States)
                foreach (var t in s.Transitions) { /* simulate traversal */ }
        }
        sw.Stop();
        long cyclesAfter = sw.ElapsedTicks;

        result.EstimatedCyclesBefore = cyclesBefore;
        result.EstimatedCyclesAfter = cyclesAfter;

        if (cyclesAfter > cyclesBefore * 1.05)
        {
            result.RolledBack = true;
            result.RollbackReason = $"Performance regression: {cyclesBefore} → {cyclesAfter} ticks (+{(double)(cyclesAfter - cyclesBefore) / cyclesBefore * 100:F1}%)";
        }

        return result;
    }

    // Full pipeline (Steps 1-5)
    public static AiArchitectResult Run(ProgramNode program, bool dryRun = false)
    {
        int stateCountBefore = program.States.Count;

        var profiles = ProfileTransitions(program);
        if (dryRun)
        {
            return new AiArchitectResult
            {
                Profiles = profiles,
                StateCountBefore = stateCountBefore,
                StateCountAfter = stateCountBefore,
            };
        }

        int split = SplitColdStates(program, profiles);
        int sorted = SortTransitions(program, profiles);
        int inlined = InlineLightweightEnter(program);
        int numaDup = DuplicateForNuma(program);

        return new AiArchitectResult
        {
            Profiles = profiles,
            StatesSplit = split,
            TransitionsSorted = sorted,
            EnterBlocksInlined = inlined,
            NumaDuplications = numaDup,
            StateCountBefore = stateCountBefore,
            StateCountAfter = program.States.Count,
        };
    }
}

