using System.Diagnostics;

namespace BPlus.Runtime;

public class TimingEngine
{
    private readonly Stopwatch _sw = new();
    private readonly Dictionary<string, Deadline> _deadlines = new();
    private readonly List<TimingViolation> _violations = new();
    private long _currentDeadlineNs;

    public void RegisterDeadline(string name, long maxNs, bool isHard = true)
    {
        _deadlines[name] = new Deadline { Name = name, MaxNs = maxNs, IsHard = isHard };
    }

    public void StartTimer(long? budgetNs = null)
    {
        _currentDeadlineNs = budgetNs ?? long.MaxValue;
        _sw.Restart();
    }

    public long ElapsedNs => _sw.ElapsedTicks * 1_000_000_000 / Stopwatch.Frequency;

    public bool CheckDeadline(string name)
    {
        if (!_deadlines.TryGetValue(name, out var deadline))
            return true;

        long elapsed = ElapsedNs;
        if (elapsed > deadline.MaxNs)
        {
            _violations.Add(new TimingViolation
            {
                Name = name,
                BudgetNs = deadline.MaxNs,
                ActualNs = elapsed,
                IsHard = deadline.IsHard,
                Timestamp = DateTime.UtcNow,
            });
            return false;
        }
        return true;
    }

    public bool TryWaitForDeadline(string name, long safetyMarginNs = 100_000)
    {
        if (!_deadlines.TryGetValue(name, out var deadline))
            return true;

        long remaining = deadline.MaxNs - ElapsedNs - safetyMarginNs;
        if (remaining <= 0)
        {
            _violations.Add(new TimingViolation
            {
                Name = name,
                BudgetNs = deadline.MaxNs,
                ActualNs = ElapsedNs,
                IsHard = deadline.IsHard,
                Timestamp = DateTime.UtcNow,
            });
            return false;
        }

        if (remaining > 10_000)
        {
            Thread.SpinWait((int)Math.Min(remaining / 10, 1000));
        }

        return true;
    }

    public bool AllDeadlinesMet()
    {
        return _violations.Count == 0;
    }

    public string GenerateReport()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("╔══════════════════════════════════════════════╗");
        sb.AppendLine("║            TIMING ENGINE REPORT             ║");
        sb.AppendLine("╚══════════════════════════════════════════════╝");
        foreach (var (name, d) in _deadlines)
        {
            long elapsed = ElapsedNs;
            bool met = elapsed <= d.MaxNs;
            sb.AppendLine($"  {name}: budget={d.MaxNs / 1000} us, actual={elapsed / 1000} us, {(met ? "✓" : "✗")}");
        }
        if (_violations.Count > 0)
        {
            sb.AppendLine("Violations:");
            foreach (var v in _violations)
                sb.AppendLine($"  ✗ {v.Name}: {v.ActualNs / 1000} us > {v.BudgetNs / 1000} us (hard={v.IsHard})");
        }
        return sb.ToString();
    }

    public class Deadline
    {
        public string Name { get; set; } = "";
        public long MaxNs { get; set; }
        public bool IsHard { get; set; }
    }

    public class TimingViolation
    {
        public string Name { get; set; } = "";
        public long BudgetNs { get; set; }
        public long ActualNs { get; set; }
        public bool IsHard { get; set; }
        public DateTime Timestamp { get; set; }
    }
}
