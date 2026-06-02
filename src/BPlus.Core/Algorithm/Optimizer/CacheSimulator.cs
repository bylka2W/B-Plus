using BPlus.Core.Ast;

namespace BPlus.Core.Algorithm.Optimizer;

public class CacheProfile
{
    public int L1SizeKB = 32;
    public int L1LatencyNs = 1;
    public int L2SizeKB = 256;
    public int L2LatencyNs = 4;
    public int L3SizeKB = 2048;
    public int L3LatencyNs = 12;
    public int RamLatencyNs = 100;
    public int CacheLine = 64;
}

public class CacheSimulator
{
    private readonly CacheProfile _profile;

    public CacheSimulator(CacheProfile? profile = null)
    {
        _profile = profile ?? DetectProfile();
    }

    public static CacheProfile DetectProfile()
    {
        var p = new CacheProfile();
        try
        {
            using var proc = System.Diagnostics.Process.GetCurrentProcess();
            p.L1SizeKB = 32;
            p.L2SizeKB = 256;
            p.L3SizeKB = 2048;
            p.L1LatencyNs = 1;
            p.L2LatencyNs = 4;
            p.L3LatencyNs = 12;
            p.RamLatencyNs = 80;
            p.CacheLine = 64;
        }
        catch { }
        return p;
    }

    public double PredictMs(int cacheKB, int align, bool cachePin, bool hotPath, int dataAccesses)
    {
        double ns = EstimateNsPerAccess(cacheKB);
        double totalNs = ns * dataAccesses;

        if (hotPath) totalNs *= 0.85;
        if (cachePin) totalNs *= 0.80;
        if (align == 128) totalNs *= 0.97;
        else if (align == 256) totalNs *= 0.94;

        return totalNs / 1_000_000.0;
    }

    private double EstimateNsPerAccess(int cacheKB)
    {
        if (cacheKB <= _profile.L1SizeKB)
            return _profile.L1LatencyNs;
        if (cacheKB <= _profile.L2SizeKB)
        {
            double l1Miss = 1.0 - ((double)_profile.L1SizeKB / cacheKB);
            return _profile.L1LatencyNs + l1Miss * _profile.L2LatencyNs;
        }
        if (cacheKB <= _profile.L3SizeKB)
        {
            double l1Miss = 0.5;
            double l2Miss = 1.0 - ((double)_profile.L2SizeKB / cacheKB);
            return _profile.L1LatencyNs + l1Miss * (_profile.L2LatencyNs + l2Miss * _profile.L3LatencyNs);
        }
        double l1M = 0.3, l2M = 0.3, l3M = 0.5;
        return _profile.L1LatencyNs + l1M * (_profile.L2LatencyNs + l2M * (_profile.L3LatencyNs + l3M * _profile.RamLatencyNs));
    }

    public MetalConfig FindBest(int dataSizeKB, int iterations = 1)
    {
        var tiers = new[] { (MemoryTier.L0, 4), (MemoryTier.L1, 64), (MemoryTier.L2, 256), (MemoryTier.L3, 1024), (MemoryTier.Ram, 8192) };
        int accesses = 200 * 10000 / 10;
        double best = double.MaxValue;
        MetalConfig bestCfg = new() { Enabled = true, Tier = MemoryTier.L0 };

        foreach (var (tier, cacheKB) in tiers)
        {
            foreach (var align in new[] { 64, 128, 256 })
            {
                foreach (var pin in new[] { true, false })
                {
                    foreach (var hot in new[] { true, false })
                    {
                        double ms = PredictMs(cacheKB, align, pin, hot, accesses);
                        if (ms < best) { best = ms; bestCfg = new MetalConfig { Enabled = true, Tier = tier, CacheAlign = align, CachePin = pin, HotPath = hot, Packed = true }; }
                    }
                }
            }
        }
        return bestCfg;
    }
}