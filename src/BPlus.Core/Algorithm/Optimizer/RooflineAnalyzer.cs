using BPlus.Core.Ast;

namespace BPlus.Core.Algorithm.Optimizer;

public class RooflineResult
{
    public double ArithmeticIntensity { get; set; } // FLOP/byte
    public double PeakFlops { get; set; } = 500e9;  // 500 GFLOPS
    public double PeakBandwidth { get; set; } = 90e9; // DDR5 ~90 GB/s
    public double AttainableFlops { get; set; }
    public bool IsComputeBound { get; set; }
    public bool IsMemoryBound { get; set; }
    public string? Bottleneck { get; set; }
    public string? Suggestion { get; set; }
}

public class RooflineAnalyzer
{
    /// <summary>
    /// Roofline model: attainable = min(peak_flops, bandwidth * intensity).
    /// If intensity is low → memory bound. High → compute bound.
    /// </summary>
    public static RooflineResult Analyze(ProgramNode program)
    {
        var result = new RooflineResult();

        // Count FLOPs and bytes
        long totalFlops = 0;
        long totalBytes = 0;

        foreach (var state in program.States)
        {
            foreach (var t in state.Transitions)
            {
                totalFlops += 2; // compare + branch
                totalBytes += 8; // state variable access
            }

            foreach (var v in state.Variables)
                totalBytes += 8; // variable load/store

            foreach (var a in state.Actions)
            {
                totalFlops += a.Body.Length / 2;
                totalBytes += a.Body.Length;
            }
        }

        foreach (var k in program.Kernels)
        {
            totalFlops += 1000;
            totalBytes += 1024;
        }

        long totalWork = Math.Max(totalFlops + totalBytes, 1);
        double flopsPerByte = (double)totalFlops / Math.Max(totalBytes, 1);

        result.ArithmeticIntensity = flopsPerByte;
        result.AttainableFlops = Math.Min(result.PeakFlops, result.PeakBandwidth * flopsPerByte);

        // Roofline ridge point: intensity = peak_flops / bandwidth
        double ridgePoint = result.PeakFlops / result.PeakBandwidth;

        if (flopsPerByte < ridgePoint)
        {
            result.IsMemoryBound = true;
            result.Bottleneck = "Memory bandwidth";
            result.Suggestion = $"Arithmetic intensity {flopsPerByte:F2} FLOP/byte below ridge {ridgePoint:F1}. " +
                                "Increase data reuse (tiling, register blocking) or use prefetchnta.";
        }
        else
        {
            result.IsComputeBound = true;
            result.Bottleneck = "Compute (FLOPs)";
            result.Suggestion = $"Arithmetic intensity {flopsPerByte:F2} FLOP/byte above ridge {ridgePoint:F1}. " +
                                "Use wider SIMD (ZMM), reduce dependency chains.";
        }

        return result;
    }

    public static string GenerateReport(RooflineResult r)
    {
        return $@"╔═══════════════════════════════════════╗
║      ROOFLINE MODEL ANALYSIS       ║
╚═══════════════════════════════════════╝

Arithmetic intensity: {r.ArithmeticIntensity:F2} FLOP/byte
Peak FLOPS:          {r.PeakFlops / 1e9:F1} GFLOPS
Peak bandwidth:      {r.PeakBandwidth / 1e9:F1} GB/s
Attainable FLOPS:    {r.AttainableFlops / 1e9:F1} GFLOPS
Ridge point:         {r.PeakFlops / r.PeakBandwidth:F1} FLOP/byte

Bottleneck: {r.Bottleneck}
{r.Suggestion}";
    }
}