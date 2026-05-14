using System.Text;
using BPlusTranspiler.Ast;

namespace BPlusTranspiler.AI;

public class DeadlineAttribute
{
    public string? Target { get; set; }
    public long DeadlineUs { get; set; }
    public bool IsHard { get; set; } = true;
    public int? BudgetPercent { get; set; }
}

public class TimingPlan
{
    public string? StateName { get; set; }
    public long BudgetNs { get; set; }
    public long WorstCaseNs { get; set; }
    public long BestCaseNs { get; set; }
    public long MeasuredNs { get; set; }
    public bool DeadlineMet => MeasuredNs <= BudgetNs;
    public double SlackMs => (BudgetNs - MeasuredNs) / 1_000_000.0;
    public List<string> Violations { get; set; } = new();
}

public static class TimingOptimizer
{
    public static TimingPlan AnalyzeTiming(StateDefNode state, DeadlineAttribute deadline, long measuredNs = 0)
    {
        var plan = new TimingPlan
        {
            StateName = state.Name,
            BudgetNs = deadline.DeadlineUs * 1000,
        };

        long worstCase = 0;
        long bestCase = long.MaxValue;

        foreach (var t in state.Transitions)
        {
            long transitionCost = 10;
            worstCase += transitionCost;
            bestCase = Math.Min(bestCase, transitionCost);
        }

        plan.WorstCaseNs = worstCase;
        plan.BestCaseNs = bestCase;
        plan.MeasuredNs = measuredNs > 0 ? measuredNs : worstCase;

        if (plan.MeasuredNs > plan.BudgetNs)
        {
            plan.Violations.Add($"Timing violation: {plan.MeasuredNs / 1000} us > {deadline.DeadlineUs} us budget");
            if (deadline.IsHard)
                plan.Violations.Add("  HARD DEADLINE — schedule intervention required");
        }

        return plan;
    }

    public static long SuggestFrequency(long worstCaseNs, long deadlineUs)
    {
        double targetRatio = (double)deadlineUs * 1000 / worstCaseNs;
        return (long)(2500 * Math.Max(1.0, targetRatio));
    }

    public static bool CheckFeasibility(TimingPlan plan, long freqMHz)
    {
        double adjustedWcet = plan.WorstCaseNs * (2500.0 / freqMHz);
        return adjustedWcet <= plan.BudgetNs;
    }

    public static string GenerateReport(TimingPlan plan, long freqMHz = 2500)
    {
        bool feasible = CheckFeasibility(plan, freqMHz);
        long suggestedFreq = plan.Violations.Count > 0
            ? SuggestFrequency(plan.WorstCaseNs, (long)(plan.BudgetNs / 1000))
            : freqMHz;

        var sb = new StringBuilder();
        sb.AppendLine("╔══════════════════════════════════════════════╗");
        sb.AppendLine("║           TIMING OPTIMIZER REPORT          ║");
        sb.AppendLine("╚══════════════════════════════════════════════╝");
        sb.AppendLine($"State:      {plan.StateName}");
        sb.AppendLine($"Budget:     {plan.BudgetNs / 1000} us");
        sb.AppendLine($"Best:       {plan.BestCaseNs} ns");
        sb.AppendLine($"Worst:      {plan.WorstCaseNs} ns ({plan.WorstCaseNs / 1000} us)");
        sb.AppendLine($"Measured:   {plan.MeasuredNs / 1000} us");
        sb.AppendLine($"Slack:      {plan.SlackMs:F3} ms");
        sb.AppendLine($"Deadline:   {(plan.DeadlineMet ? "✓ MET" : "✗ VIOLATED")}");
        sb.AppendLine($"Feasible @ {freqMHz} MHz: {(feasible ? "Yes" : "No")}");
        if (suggestedFreq != freqMHz)
            sb.AppendLine($"Suggested freq: {suggestedFreq} MHz");
        foreach (var v in plan.Violations)
            sb.AppendLine($"  ⚠ {v}");

        return sb.ToString();
    }
}
