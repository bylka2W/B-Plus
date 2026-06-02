namespace BPlus.Core.Algorithm;

public class AutoFeedbackLoop
{
    public class ParameterConfig
    {
        public string Name { get; set; } = "";
        public string Value { get; set; } = "";
        public double TimeMs { get; set; }
        public bool IsBest { get; set; }
    }

    public class LoopResult
    {
        public List<ParameterConfig> History { get; set; } = new();
        public ParameterConfig BestConfig { get; set; } = new();
        public double Improvement { get; set; }
        public int Iterations { get; set; }
    }

    public class TuningConfig
    {
        public string[] TierOptions { get; set; } = { "L0", "L1", "L2", "L3" };
        public int[] AlignOptions { get; set; } = { 64, 128, 256 };
        public bool[] PinOptions { get; set; } = { true, false };
        public bool[] HotOptions { get; set; } = { true, false };
        public int MaxIterations { get; set; } = 10;
    }

    private readonly TuningConfig _config;

    public AutoFeedbackLoop(TuningConfig? config = null)
    {
        _config = config ?? new TuningConfig();
    }

    public LoopResult Run(Func<string, double> measureFn)
    {
        var result = new LoopResult();
        double bestTime = double.MaxValue;
        string bestConfig = "";

        for (int i = 0; i < _config.MaxIterations; i++)
        {
            string configStr = GenerateConfig(i);
            double time = measureFn(configStr);

            var param = new ParameterConfig
            {
                Name = $"iter_{i}",
                Value = configStr,
                TimeMs = time,
                IsBest = false
            };

            result.History.Add(param);

            if (time < bestTime)
            {
                bestTime = time;
                bestConfig = configStr;
            }

            result.Iterations = i + 1;
        }

        foreach (var p in result.History)
            if (p.Value == bestConfig) p.IsBest = true;

        result.BestConfig = new ParameterConfig { Name = "best", Value = bestConfig, TimeMs = bestTime, IsBest = true };
        result.Improvement = result.History[0].TimeMs > 0 ? bestTime / result.History[0].TimeMs : 1.0;

        return result;
    }

    private string GenerateConfig(int iteration)
    {
        int t = iteration % _config.TierOptions.Length;
        int a = (iteration / _config.TierOptions.Length) % _config.AlignOptions.Length;
        int p = iteration % 2;
        int h = (iteration / 2) % 2;

        return $"tier={_config.TierOptions[t]},align={_config.AlignOptions[a]},pin={_config.PinOptions[p]},hot={_config.HotOptions[h]}";
    }

    public string GenerateHeader(LoopResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Auto feedback loop results");
        sb.AppendLine($"#define BPLUS_ABL_ITERATIONS {r.Iterations}");
        sb.AppendLine($"#define BPLUS_ABL_BEST_TIME {r.BestConfig.TimeMs:F4}");
        sb.AppendLine($"#define BPLUS_ABL_IMPROVEMENT {r.Improvement:F2}");
        sb.AppendLine($"// Best config: {r.BestConfig.Value}");
        sb.AppendLine();
        sb.AppendLine("static inline void bplus_apply_config(const char* cfg) {");
        sb.AppendLine("    // Apply best configuration automatically");
        sb.AppendLine("    // tier, align, pin, hot parameters");
        sb.AppendLine("}");
        return sb.ToString();
    }

    public string GetImprovementReport(LoopResult r)
    {
        double first = r.History.Count > 0 ? r.History[0].TimeMs : 0;
        double last = r.BestConfig.TimeMs;
        double pct = first > 0 ? (1 - last / first) * 100 : 0;
        return $"Auto-tuning: {r.Iterations} iterations, best={last:F4}ms, improvement={pct:F1}%";
    }
}
