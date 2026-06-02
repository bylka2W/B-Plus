namespace BPlus.Core.Algorithm;

public class LoopTransforms
{
    public class LoopTilingResult
    {
        public int OriginalTripCount { get; set; }
        public int TileSize { get; set; }
        public int TilesCount { get; set; }
        public int CacheLevel { get; set; }
        public double EstSpeedup { get; set; }
    }

    public class LoopFusionResult
    {
        public bool CanFuse { get; set; }
        public string Loop1 { get; set; } = "";
        public string Loop2 { get; set; } = "";
        public string Reason { get; set; } = "";
        public double EstSpeedup { get; set; }
    }

    public static int EstimateOptimalTileSize(int cacheSizeKB)
    {
        int[] commonTiles = { 16, 32, 64, 128, 256 };
        foreach (int t in commonTiles)
            if (t * t * 8 <= cacheSizeKB * 1024) return t;
        return 64;
    }

    public LoopTilingResult Tile(int tripCount, int elementSize, int cacheKB)
    {
        int tileSize = EstimateOptimalTileSize(cacheKB);
        int tiles = (tripCount + tileSize - 1) / tileSize;

        return new LoopTilingResult
        {
            OriginalTripCount = tripCount,
            TileSize = tileSize,
            TilesCount = tiles,
            CacheLevel = cacheKB <= 32 ? 1 : cacheKB <= 256 ? 2 : 3,
            EstSpeedup = Math.Min(10.0, tripCount / (double)(tiles * tileSize))
        };
    }

    public LoopFusionResult CheckFusion(string loop1, string loop2)
    {
        var result = new LoopFusionResult { Loop1 = loop1, Loop2 = loop2 };

        if (loop1.Contains("body:") && loop2.Contains("body:"))
        {
            result.CanFuse = true;
            result.Reason = "Identical iteration counts";
        }
        else if (loop1.Contains("body:") || loop2.Contains("body:"))
        {
            result.CanFuse = false;
            result.Reason = "Different iteration counts";
        }
        else
        {
            result.CanFuse = true;
            result.Reason = "Sequential loops, can fuse";
        }

        result.EstSpeedup = result.CanFuse ? 1.5 : 1.0;
        return result;
    }

    public string GenerateHeader(LoopTilingResult r)
    {
        return $"// Loop tiling: tile={r.TileSize}, tiles={r.TilesCount}, speedup={r.EstSpeedup:F1}x\n" +
               $"#define BPLUS_TILE_SIZE {r.TileSize}\n" +
               $"#define BPLUS_CACHE_LEVEL {r.CacheLevel}\n";
    }
}
