namespace BPlus.Core.Algorithm;

public class LoadController
{
    public enum PowerPolicy { Performance, Balanced, PowerSaving }

    public class LoadInfo
    {
        public double TemperatureC { get; set; }
        public double PowerW { get; set; }
        public int FrequencyMHz { get; set; }
        public int Utilization { get; set; }
        public int ActiveCores { get; set; }
    }

    public class ControlResult
    {
        public LoadInfo Current { get; set; } = new();
        public PowerPolicy Policy { get; set; }
        public string Action { get; set; } = "";
        public int SuggestedFrequencyMHz { get; set; }
        public double EstSpeedup { get; set; }
    }

    private const double MaxTempC = 95.0;
    private const double ThrottleTempC = 85.0;

    public ControlResult AnalyzeAndControl(LoadInfo load, string cpuMicroarch)
    {
        var result = new ControlResult { Current = load };

        if (load.TemperatureC > ThrottleTempC)
        {
            result.Policy = PowerPolicy.PowerSaving;
            result.Action = "Throttle: temperature > 85°C, reduce frequency";
            result.SuggestedFrequencyMHz = Math.Max(800, load.FrequencyMHz - 400);
            result.EstSpeedup = 0.8;
        }
        else if (load.TemperatureC > MaxTempC)
        {
            result.Policy = PowerPolicy.PowerSaving;
            result.Action = "Emergency throttle: temperature > 95°C";
            result.SuggestedFrequencyMHz = 800;
            result.EstSpeedup = 0.5;
        }
        else if (load.Utilization > 90)
        {
            result.Policy = PowerPolicy.Performance;
            result.Action = "Boost: high utilization, increase frequency";
            result.SuggestedFrequencyMHz = Math.Min(5000, load.FrequencyMHz + 200);
            result.EstSpeedup = 1.15;
        }
        else
        {
            result.Policy = PowerPolicy.Balanced;
            result.Action = "Balanced: current settings are optimal";
            result.SuggestedFrequencyMHz = load.FrequencyMHz;
            result.EstSpeedup = 1.0;
        }

        if (cpuMicroarch.Contains("alderlake") || cpuMicroarch.Contains("icelake"))
        {
            if (load.Utilization > 50 && load.ActiveCores <= 4)
                result.EstSpeedup *= 1.1;
        }

        return result;
    }

    public string GenerateHeader(ControlResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Load controller");
        sb.AppendLine($"#define BPLUS_LOAD_TEMP {r.Current.TemperatureC:F1}");
        sb.AppendLine($"#define BPLUS_LOAD_POWER {r.Current.PowerW:F1}");
        sb.AppendLine($"#define BPLUS_LOAD_FREQ {r.Current.FrequencyMHz}");
        sb.AppendLine($"#define BPLUS_SUGGESTED_FREQ {r.SuggestedFrequencyMHz}");
        sb.AppendLine($"#define BPLUS_POLICY_{r.Policy.ToString().ToUpper()} 1");
        sb.AppendLine($"// Action: {r.Action}");
        sb.AppendLine();
        sb.AppendLine("static inline void bplus_set_freq(int mhz) {");
        sb.AppendLine("#ifdef __linux__");
        sb.AppendLine("    char buf[128];");
        sb.AppendLine("    snprintf(buf, sizeof(buf), \"/sys/devices/system/cpu/cpu0/cpufreq/scaling_setspeed\", mhz);");
        sb.AppendLine("    FILE* f = fopen(buf, \"w\");");
        sb.AppendLine("    if (f) { fprintf(f, \"%d\", mhz); fclose(f); }");
        sb.AppendLine("#endif");
        sb.AppendLine("}");
        return sb.ToString();
    }

    public string GetTurboBoostStrategy(int activeCores)
    {
        if (activeCores <= 2) return "Request max Turbo Boost (all cores can boost)";
        if (activeCores <= 4) return "Request moderate boost (2-3 cores will boost)";
        return "No boost expected (too many active cores)";
    }
}
