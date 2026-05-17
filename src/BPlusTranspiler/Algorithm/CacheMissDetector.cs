using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Algorithm;

public class CacheMissDetector
{
    public class MissInfo
    {
        public string Variable { get; set; } = "";
        public int SizeBytes { get; set; }
        public int AccessesPerIteration { get; set; }
        public int Stride { get; set; }
        public bool WillMiss { get; set; }
        public string Tier { get; set; } = "";
        public int MissPenaltyCycles { get; set; }
    }

    public class DetectionResult
    {
        public List<MissInfo> Misses { get; set; } = new();
        public int TotalMissPenalty { get; set; }
        public double EstSpeedupFromFix { get; set; }
    }

    private static readonly (string tier, int sizeKB, int latency)[] TierProfile =
    {
        ("L0", 4, 1),
        ("L1", 32, 4),
        ("L2", 256, 12),
        ("L3", 2048, 50),
        ("RAM", 65536, 200)
    };

    public DetectionResult Analyze(ProgramNode program)
    {
        var result = new DetectionResult();

        foreach (var state in program.States)
        {
            foreach (var v in state.Variables)
            {
                int sizeBytes = EstimateSize(v.Type);
                int accesses = state.Transitions.Count + state.Actions.Count;
                int stride = EstimateStride(v, state);

                string tier = DetermineTier(sizeBytes);
                bool willMiss = tier == "L2" || tier == "L3" || tier == "RAM";
                int penalty = GetPenalty(tier);

                result.Misses.Add(new MissInfo
                {
                    Variable = v.Name,
                    SizeBytes = sizeBytes,
                    AccessesPerIteration = accesses,
                    Stride = stride,
                    WillMiss = willMiss,
                    Tier = tier,
                    MissPenaltyCycles = penalty
                });

                if (willMiss)
                    result.TotalMissPenalty += penalty * accesses;
            }
        }

        result.EstSpeedupFromFix = result.TotalMissPenalty > 1000 ? 5.0 : 3.0;
        return result;
    }

    private int EstimateSize(string type)
    {
        return type.ToLower() switch
        {
            "int" or "i32" or "float" => 4,
            "long" or "i64" or "double" or "f64" => 8,
            "byte" or "i8" => 1,
            "short" or "i16" => 2,
            "string" => 256,
            _ when type.Contains("[") => 64,
            _ => 8
        };
    }

    private int EstimateStride(VariableNode v, StateDefNode state)
    {
        if (state.Transitions.Count > 5) return 64;
        return 8;
    }

    private string DetermineTier(int sizeBytes)
    {
        int sizeKB = sizeBytes / 1024;
        foreach (var (tier, threshold, _) in TierProfile)
            if (sizeKB <= threshold) return tier;
        return "RAM";
    }

    private int GetPenalty(string tier)
    {
        foreach (var (t, _, latency) in TierProfile)
            if (t == tier) return latency;
        return 200;
    }

    public string GenerateFixes(DetectionResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("; Cache miss fixes");
        foreach (var m in r.Misses.Where(x => x.WillMiss))
        {
            if (m.Tier == "L2" || m.Tier == "L3")
                sb.AppendLine($"    ; prefetch {m.Variable} (size={m.SizeBytes}B, penalty={m.MissPenaltyCycles}cyc)");
            else
                sb.AppendLine($"    ; hoist {m.Variable} to register (size={m.SizeBytes}B)");
        }
        return sb.ToString();
    }
}
