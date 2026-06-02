using BPlus.Core.Ast;

namespace BPlus.Core.Algorithm.Optimizer;

// Haskell/GHC: Demand analysis — know what WILL definitely execute
// For each enter{} block, determine if it's strict (definitely needed)
// or lazy (may be skipped). Strict blocks can be hoisted to registers
// and prefetched ahead of the transition.

public static class DemandPass
{
    public static List<DemandResult> Run(ProgramNode program)
    {
        var results = new List<DemandResult>();

        foreach (var state in program.States)
        {
            var dr = new DemandResult { StateName = state.Name };

            foreach (var a in state.Actions)
            {
                var demand = AnalyzeExpression(a.Body);
                dr.ActionDemands[a.Type] = demand;
            }

            foreach (var t in state.Transitions)
            {
                foreach (var a in state.Actions.Where(ac => ac.Type == ActionType.Exit && ac.Body != t.Body))
                    dr.PrefetchCandidates.Add(a.Body);
            }

            // Combine action demands into overall state demand
            dr.Overall = new DemandSignature
            {
                IsStrict = state.Actions.All(a =>
                    state.Transitions.Any(t => t.Body != null && t.Body.Contains(a.Body))),
                IsUsed = state.Transitions.Count > 0,
                IsCalled = state.Actions.Any(a => a.Type == ActionType.Enter),
                CallCount = state.Transitions.Count,
                IsPoly = state.Transitions.Select(t => t.Target).Distinct().Count() > 1
            };

            state.Demand = dr.Overall;
            results.Add(dr);
        }

        return results;
    }

    private static DemandSignature AnalyzeExpression(string body)
    {
        var sig = new DemandSignature();

        // Strict if it contains a store, call, or direct state modification
        sig.IsStrict = body.Contains('=') || body.Contains("call") || body.Contains("->");

        // Called if it's an invocation
        sig.IsCalled = body.Contains('(');

        // Count invocations
        sig.CallCount = body.Count(c => c == '(');

        // Used if result is assigned or passed
        sig.IsUsed = body.Contains('=') || body.Contains("return");

        return sig;
    }
}

public class DemandResult
{
    public string StateName { get; set; } = "";
    public Dictionary<ActionType, DemandSignature> ActionDemands { get; } = new();
    public List<string> PrefetchCandidates { get; } = new();
    public DemandSignature? Overall { get; set; }
}
