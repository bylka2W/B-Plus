using BPlus.Core.Ast;

namespace BPlus.Core.Algorithm.Optimizer;

public class TierResult
{
    public string StateName { get; set; } = "";
    public string Section { get; set; } = ".text";
    public int Alignment { get; set; } = 16;
    public bool IsHot { get; set; }
    public bool NeedsGateway { get; set; }
    public string? GatewayTier { get; set; }
}

public class WorkingSetAnalysis
{
    public int WorkingSetBytes { get; set; }
    public int L1Size { get; set; } = 32768;
    public int L2Size { get; set; } = 262144;
    public int L3Size { get; set; } = 12582912;
    public bool FitsL1 => WorkingSetBytes <= L1Size;
    public bool FitsL2 => WorkingSetBytes <= L2Size;
    public bool FitsL3 => WorkingSetBytes <= L3Size;
    public string RecommendedTier => WorkingSetBytes switch
    {
        <= 32768 => "L0/L1 — µop cache or L1-I",
        <= 262144 => "L2 — warm",
        <= 12582912 => "L3 — cold with huge pages",
        _ => "RAM — needs tiling"
    };
    public bool NeedsTiling => WorkingSetBytes > L2Size;
    public int TileSize { get; set; }
    public string? Warning { get; set; }
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
        {
            var r = ClassifyState(state, blockMap);
            results.Add(r);
        }

        return results;
    }

    public static WorkingSetAnalysis AnalyzeWorkingSet(ProgramNode program)
    {
        var ws = new WorkingSetAnalysis();
        int totalBytes = 0;

        foreach (var state in program.States)
        {
            int stateCodeSize = state.Name.Length + state.Transitions.Count * 16;
            int stateDataSize = state.Variables.Count * 8;
            totalBytes += stateCodeSize + stateDataSize;
        }
        ws.WorkingSetBytes = totalBytes;

        // Propose tile size for L2
        if (ws.NeedsTiling)
        {
            ws.TileSize = ws.L2Size / 2;
            ws.Warning = $"Working set {totalBytes / 1024}KB > L2 {ws.L2Size / 1024}KB — auto-tiling suggested (tile={ws.TileSize}B). " +
                         $"Split data into {totalBytes / ws.TileSize + 1} tiles.";
        }

        return ws;
    }

    private static TierResult ClassifyState(StateDefNode state, Dictionary<string, MetalConfig> blockMap)
    {
        var r = new TierResult { StateName = state.Name };

        if (blockMap.TryGetValue(state.Name, out var cfg))
        {
            if (cfg.Tier.HasValue)
            {
                ApplyTier(r, cfg.Tier.Value);
            }
            else
            {
                // Metal block exists but no tier set — fall back to hot weight detection
                DetectTierFromHotWeights(state, r);
            }
            if (cfg.Alignment.HasValue)
                r.Alignment = cfg.Alignment.Value;
            if (cfg.HotPath)
                r.IsHot = true;
            if (cfg.Gateway.HasValue)
            {
                r.NeedsGateway = true;
                r.GatewayTier = cfg.Gateway.Value.ToString();
            }
            if (cfg.CacheAlign.HasValue)
                r.Alignment = cfg.CacheAlign.Value;
            if (cfg.CachePolicy == "write_through")
                r.Section = r.Section + ".wt";
            if (cfg.NonTemporal)
                r.Section = r.Section + ".nt";
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

        // Check state-level @hot/@cold first
        if (state.HotWeight.HasValue)
        {
            if (state.HotWeight.Value >= 0.8)
                hasHot = true;
            else if (state.HotWeight.Value <= 0.1)
                hasCold = true;
        }

        // Also check transition-level hot weights
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