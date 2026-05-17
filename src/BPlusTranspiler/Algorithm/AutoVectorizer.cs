namespace BPlusTranspiler.Algorithm;

public class AutoVectorizer
{
    public enum VecW { Scalar, W128, W256, W512 }

    public class LoopInfo
    {
        public string LoopId { get; set; } = "";
        public int TripCount { get; set; }
        public VecW Width { get; set; }
        public bool CanVectorize { get; set; }
        public string Reason { get; set; } = "";
        public double EstSpeedup { get; set; }
    }

    public class VectorizationResult
    {
        public List<LoopInfo> Loops { get; set; } = new();
        public int VectorizedCount { get; set; }
        public int TotalCount { get; set; }
        public string IsaExtension { get; set; } = "";
    }

    private static readonly (string pattern, bool canVec, string reason)[] VectorizePatterns =
    {
        ("for (int i = 0; i < n; i++)", true, "Simple loop"),
        ("while", true, "While loop"),
        ("reduction", true, "Reduction pattern"),
        ("pointer++", true, "Sequential pointer"),
        ("break", false, "Contains break"),
        ("call", false, "Function call"),
        ("indirection", false, "Pointer aliasing")
    };

    public VectorizationResult Analyze(string[] loops, string cpuMicroarch)
    {
        var result = new VectorizationResult();

        result.IsaExtension = cpuMicroarch.Contains("avx512") ? "AVX-512" :
                             cpuMicroarch.Contains("avx2") ? "AVX2" : "SSE";

        foreach (var loop in loops)
        {
            var info = new LoopInfo { LoopId = loop };

            bool canVec = true;
            string reason = "OK";

            foreach (var (pattern, can, rsn) in VectorizePatterns)
            {
                if (loop.Contains(pattern) && !can)
                {
                    canVec = false;
                    reason = rsn;
                    break;
                }
            }

            info.CanVectorize = canVec;
            info.Reason = reason;
            info.TripCount = EstimateTripCount(loop);
            info.Width = result.IsaExtension == "AVX-512" ? VecW.W512 :
                        result.IsaExtension == "AVX2" ? VecW.W256 : VecW.W128;
            info.EstSpeedup = canVec ? (info.Width == VecW.W512 ? 16.0 : info.Width == VecW.W256 ? 8.0 : 4.0) : 1.0;

            result.Loops.Add(info);
            if (canVec) result.VectorizedCount++;
        }

        result.TotalCount = result.Loops.Count;
        return result;
    }

    private int EstimateTripCount(string loop)
    {
        int n = 1000;
        if (loop.Contains("10000")) n = 10000;
        else if (loop.Contains("1000")) n = 1000;
        else if (loop.Contains("100")) n = 100;
        return n;
    }

    public string GenerateHeader(VectorizationResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Auto vectorizer");
        sb.AppendLine($"#define BPLUS_VEC_COUNT {r.VectorizedCount}/{r.TotalCount}");
        sb.AppendLine($"#define BPLUS_ISA {r.IsaExtension}");
        sb.AppendLine();

        if (r.IsaExtension == "AVX-512")
        {
            sb.AppendLine("#include <immintrin.h>");
            sb.AppendLine("#define VEC_WIDTH 512");
            sb.AppendLine("#define VEC_LEN 16  // 16 x 32-bit");
            sb.AppendLine();
            sb.AppendLine("static inline void bplus_vec_add_f32(float* a, const float* b, const float* c, int n) {");
            sb.AppendLine("    for (int i = 0; i < n; i += 16) {");
            sb.AppendLine("        __m512 va = _mm512_loadu_ps(&a[i]);");
            sb.AppendLine("        __m512 vb = _mm512_loadu_ps(&b[i]);");
            sb.AppendLine("        __m512 vc = _mm512_loadu_ps(&c[i]);");
            sb.AppendLine("        __m512 vr = _mm512_add_ps(_mm512_add_ps(va, vb), vc);");
            sb.AppendLine("        _mm512_storeu_ps(&a[i], vr);");
            sb.AppendLine("    }");
            sb.AppendLine("}");
        }
        else if (r.IsaExtension == "AVX2")
        {
            sb.AppendLine("#include <immintrin.h>");
            sb.AppendLine("#define VEC_WIDTH 256");
            sb.AppendLine("#define VEC_LEN 8");
            sb.AppendLine();
            sb.AppendLine("static inline void bplus_vec_add_f32(float* a, const float* b, const float* c, int n) {");
            sb.AppendLine("    for (int i = 0; i < n; i += 8) {");
            sb.AppendLine("        __m256 va = _mm256_loadu_ps(&a[i]);");
            sb.AppendLine("        __m256 vb = _mm256_loadu_ps(&b[i]);");
            sb.AppendLine("        __m256 vc = _mm256_loadu_ps(&c[i]);");
            sb.AppendLine("        __m256 vr = _mm256_add_ps(_mm256_add_ps(va, vb), vc);");
            sb.AppendLine("        _mm256_storeu_ps(&a[i], vr);");
            sb.AppendLine("    }");
            sb.AppendLine("}");
        }

        return sb.ToString();
    }
}
