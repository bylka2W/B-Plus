using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

public class TierResult
{
    public string StateName { get; set; } = "";
    public string Section { get; set; } = ".text";
    public int Alignment { get; set; } = 16;
    public bool IsHot { get; set; }
    public bool NeedsGateway { get; set; }
    public string? GatewayTier { get; set; }
}

public static class TierClassifier
{
    public static List<TierResult> Classify(ProgramNode program, List<MetalBlock> blocks)
    {
        var results = new List<TierResult>();

        var blockMap = new Dictionary<string, MetalConfig>();
        foreach (var b in blocks)
        {
            if (b.TargetState != null)
                blockMap[b.TargetState] = b.Config;
        }

        foreach (var state in program.States)
            results.Add(ClassifyState(state, blockMap));

        return results;
    }

    private static TierResult ClassifyState(StateDefNode state, Dictionary<string, MetalConfig> blockMap)
    {
        var r = new TierResult { StateName = state.Name };

        if (blockMap.TryGetValue(state.Name, out var cfg))
        {
            if (cfg.Tier.HasValue)
                ApplyTier(r, cfg.Tier.Value);
            if (cfg.Alignment.HasValue)
                r.Alignment = cfg.Alignment.Value;
            if (cfg.HotPath)
                r.IsHot = true;
            if (cfg.Gateway.HasValue)
            {
                r.NeedsGateway = true;
                r.GatewayTier = cfg.Gateway.Value.ToString();
            }
        }
        else
        {
            DetectTierFromHotWeights(state, r);
        }

        return r;
    }

    private static void ApplyTier(TierResult r, MemoryTier tier)
    {
        switch (tier)
        {
            case MemoryTier.L0:
                r.Section = ".text.hot.L0";
                r.Alignment = 16;
                r.IsHot = true;
                break;
            case MemoryTier.L1:
                r.Section = ".text.hot.L1";
                r.Alignment = 32;
                r.IsHot = true;
                break;
            case MemoryTier.L2:
                r.Section = ".text.warm.L2";
                r.Alignment = 64;
                break;
            case MemoryTier.L3:
                r.Section = ".text.cold.L3";
                r.Alignment = 128;
                break;
            default:
                r.Section = ".text";
                r.Alignment = 16;
                break;
        }
    }

    private static void DetectTierFromHotWeights(StateDefNode state, TierResult r)
    {
        bool hasHot = false;
        bool hasCold = false;

        foreach (var t in state.Transitions)
        {
            if (t.HotWeight.HasValue && t.HotWeight.Value >= 0.8) hasHot = true;
            else if (t.HotWeight.HasValue && t.HotWeight.Value <= 0.1) hasCold = true;
        }

        if (hasHot)
        {
            r.Section = ".text.hot.L1";
            r.Alignment = 32;
            r.IsHot = true;
        }
        else if (hasCold)
        {
            r.Section = ".text.cold.L3";
            r.Alignment = 128;
        }
        else
        {
            r.Section = ".text.warm.L2";
            r.Alignment = 64;
        }
    }
}
