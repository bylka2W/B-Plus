namespace BPlusTranspiler.Algorithm;

public class KernelFusion
{
    public class FusionResult
    {
        public int Operations { get; set; }
        public int MemoryPasses { get; set; }
        public double EstSpeedup { get; set; }
        public string FusedKernel { get; set; } = "";
    }

    public static string[] SplitOps = { "load", "store", "add", "mul", "relu", "sigmoid", "softmax" };

    public FusionResult Fuse(string[] ops)
    {
        var result = new FusionResult { Operations = ops.Length };

        var fused = new System.Text.StringBuilder();
        fused.AppendLine("// Fused kernel - single memory pass");
        fused.AppendLine("static void bplus_fused_kernel(float* data, int n) {");
        fused.AppendLine("    for (int i = 0; i < n; i += 16) {");

        int loads = 0, stores = 0;
        foreach (var op in ops)
        {
            string lower = op.ToLower();
            if (lower.Contains("load")) loads++;
            else if (lower.Contains("store")) stores++;
        }

        result.MemoryPasses = loads + stores;

        fused.AppendLine($"        // {ops.Length} ops, {loads} loads, {stores} stores -> 1 pass");
        fused.AppendLine("        // TODO: emit fused x64 code");
        fused.AppendLine("    }");
        fused.AppendLine("}");

        result.FusedKernel = fused.ToString();
        result.EstSpeedup = ops.Length > 0 ? (double)result.MemoryPasses / 1.0 : 1.0;

        return result;
    }

    public string GenerateHeader(FusionResult r)
    {
        return $"// Kernel fusion: {r.Operations} ops -> {r.MemoryPasses} passes -> 1\n" +
               $"#define BPLUS_FUSION_SPEEDUP {r.EstSpeedup:F1}\n";
    }
}

public class AosToSoaTransformer
{
    public class TransformResult
    {
        public string OriginalLayout { get; set; } = "";
        public string TransformedLayout { get; set; } = "";
        public int FieldsCount { get; set; }
        public double EstSpeedup { get; set; }
    }

    public TransformResult Transform(string[] fields, int elementCount)
    {
        var result = new TransformResult
        {
            FieldsCount = fields.Length,
            OriginalLayout = $"struct {{ {string.Join(", ", fields)} }}[{elementCount}]",
            TransformedLayout = $"struct SoA {{\n" +
                               $"    float {string.Join("[{elementCount}], float ", fields)}[{elementCount}];\n}};"
        };

        result.EstSpeedup = fields.Length > 1 ? 2.0 + fields.Length * 0.3 : 1.0;
        return result;
    }

    public string GenerateHeader(TransformResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// AoS -> SoA transformation");
        sb.AppendLine($"// Original: {r.OriginalLayout}");
        sb.AppendLine($"// Transformed: {r.TransformedLayout}");
        sb.AppendLine($"// Speedup: {r.EstSpeedup:F1}x");
        return sb.ToString();
    }
}

public class CpuIdDispatcher
{
    public enum CpuFeature { SSE, AVX2, AVX512F, AVX512DQ, AMX }

    public class DispatchResult
    {
        public List<string> Paths { get; set; } = new();
        public string BestPath { get; set; } = "";
        public string Dispatcher { get; set; } = "";
    }

    public DispatchResult GenerateDispatcher(string functionName, CpuFeature[] features)
    {
        var result = new DispatchResult();

        foreach (var f in features)
            result.Paths.Add($"{functionName}_{f}");

        result.BestPath = result.Paths[^1];

        var sb = new System.Text.StringBuilder();
        sb.AppendLine($"static void {functionName}(float* a, float* b, int n) {{");
        sb.AppendLine("    unsigned int cpuInfo[4];");
        sb.AppendLine("    __cpuid(cpuInfo, 1);");
        sb.AppendLine("    bool has512 = (cpuInfo[1] & (1 << 30)) != 0;");
        sb.AppendLine("    bool has256 = (cpuInfo[1] & (1 << 27)) != 0;");
        sb.AppendLine("    if (has512) {");
        sb.AppendLine($"        {functionName}_AVX512(a, b, n);");
        sb.AppendLine("    } else if (has256) {");
        sb.AppendLine($"        {functionName}_AVX2(a, b, n);");
        sb.AppendLine("    } else {");
        sb.AppendLine($"        {functionName}_SSE(a, b, n);");
        sb.AppendLine("    }");
        sb.AppendLine("}");

        result.Dispatcher = sb.ToString();
        return result;
    }

    public string GenerateHeader(DispatchResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// CPUID dispatcher - single binary, optimal path per CPU");
        sb.AppendLine($"// Paths: {string.Join(", ", r.Paths)}");
        return sb.ToString();
    }
}

public class SizeSpecializer
{
    public class SpecializationResult
    {
        public string Function { get; set; } = "";
        public int[] Sizes { get; set; } = [];
        public List<string> Specializations { get; set; } = new();
        public double EstSpeedup { get; set; }
    }

    private static readonly int[] CommonSizes = { 64, 128, 256, 512, 1024 };

    public SpecializationResult Specialize(string functionName, int minSize, int maxSize)
    {
        var result = new SpecializationResult
        {
            Function = functionName,
            Sizes = CommonSizes.Where(s => s >= minSize && s <= maxSize).ToArray()
        };

        foreach (int size in result.Sizes)
        {
            result.Specializations.Add($"// {functionName}_{size}x{size} - optimal for L{GetCacheLevel(size)}");
        }

        result.EstSpeedup = result.Sizes.Length * 0.15;
        return result;
    }

    private int GetCacheLevel(int size)
    {
        if (size <= 64) return 1;
        if (size <= 256) return 2;
        if (size <= 1024) return 3;
        return 4;
    }

    public string GenerateHeader(SpecializationResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine($"// Size specialization: {r.Function}");
        foreach (int s in r.Sizes)
            sb.AppendLine($"// {s}x{s} -> optimal tiling for L{GetCacheLevel(s)}");
        return sb.ToString();
    }
}

public class AlgorithmSelector
{
    public enum Algorithm { Naive, Strassen, Coppersmith, FFT }

    public class SelectionResult
    {
        public Algorithm Selected { get; set; }
        public int SizeThreshold { get; set; }
        public double EstSpeedup { get; set; }
        public string Recommendation { get; set; } = "";
    }

    public SelectionResult Select(string operation, int size)
    {
        var result = new SelectionResult();

        switch (operation.ToLower())
        {
            case "matmul":
                if (size > 512)
                {
                    result.Selected = Algorithm.Strassen;
                    result.SizeThreshold = 512;
                    result.Recommendation = "Strassen O(n^2.807) > Naive O(n^3) for n > 512";
                }
                else
                {
                    result.Selected = Algorithm.Naive;
                    result.Recommendation = "Naive optimal for small matrices";
                }
                break;
            case "fft":
                result.Selected = Algorithm.FFT;
                result.Recommendation = "FFT O(n log n) for transform";
                break;
            default:
                result.Selected = Algorithm.Naive;
                result.Recommendation = "Use naive algorithm";
                break;
        }

        result.EstSpeedup = result.Selected switch
        {
            Algorithm.Strassen when size > 512 => 2.5,
            Algorithm.FFT => 10.0,
            _ => 1.0
        };

        return result;
    }

    public string GenerateHeader(SelectionResult r)
    {
        return $"// Algorithm: {r.Selected}, threshold={r.SizeThreshold}\n" +
               $"// {r.Recommendation}\n" +
               $"#define BPLUS_ALGO_SPEEDUP {r.EstSpeedup:F1}\n";
    }
}
