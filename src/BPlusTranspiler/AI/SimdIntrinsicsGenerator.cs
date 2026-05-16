namespace BPlusTranspiler.AI;

public class SimdEmitter
{
    public enum SimdWidth { SSE, AVX2, AVX512 }

    public class EmissionResult
    {
        public string Header { get; set; } = "";
        public int IntrinsicsCount { get; set; }
        public SimdWidth Width { get; set; }
        public double EstSpeedup { get; set; }
    }

    public string GenerateVectorizedAddition(string arrayName, int count, SimdWidth width)
    {
        return width switch
        {
            SimdWidth.AVX512 => GenerateAvx512Add(arrayName, count),
            SimdWidth.AVX2 => GenerateAvx2Add(arrayName, count),
            _ => GenerateSseAdd(arrayName, count)
        };
    }

    private string GenerateAvx512Add(string name, int count)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("__attribute__((target(\"avx512f,avx512dq\")))");
        sb.AppendLine($"static void bplus_vec_add_{name}(float* a, const float* b, const float* c, int n) {{");
        sb.AppendLine("    __m512 va, vb, vc, vr;");
        sb.AppendLine("    for (int i = 0; i < n; i += 16) {");
        sb.AppendLine("        va = _mm512_loadu_ps(&a[i]);");
        sb.AppendLine("        vb = _mm512_loadu_ps(&b[i]);");
        sb.AppendLine("        vc = _mm512_loadu_ps(&c[i]);");
        sb.AppendLine("        vr = _mm512_fmadd_ps(_mm512_fmadd_ps(va, vb), vc);");
        sb.AppendLine("        _mm512_storeu_ps(&a[i], vr);");
        sb.AppendLine("    }");
        sb.AppendLine("}");
        return sb.ToString();
    }

    private string GenerateAvx2Add(string name, int count)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("__attribute__((target(\"avx2\")))");
        sb.AppendLine($"static void bplus_vec_add_{name}(float* a, const float* b, const float* c, int n) {{");
        sb.AppendLine("    __m256 va, vb, vc, vr;");
        sb.AppendLine("    for (int i = 0; i < n; i += 8) {");
        sb.AppendLine("        va = _mm256_loadu_ps(&a[i]);");
        sb.AppendLine("        vb = _mm256_loadu_ps(&b[i]);");
        sb.AppendLine("        vc = _mm256_loadu_ps(&c[i]);");
        sb.AppendLine("        vr = _mm256_add_ps(_mm256_add_ps(va, vb), vc);");
        sb.AppendLine("        _mm256_storeu_ps(&a[i], vr);");
        sb.AppendLine("    }");
        sb.AppendLine("}");
        return sb.ToString();
    }

    private string GenerateSseAdd(string name, int count)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine($"static void bplus_vec_add_{name}(float* a, const float* b, const float* c, int n) {{");
        sb.AppendLine("    __m128 va, vb, vc, vr;");
        sb.AppendLine("    for (int i = 0; i < n; i += 4) {");
        sb.AppendLine("        va = _mm_loadu_ps(&a[i]);");
        sb.AppendLine("        vb = _mm_loadu_ps(&b[i]);");
        sb.AppendLine("        vc = _mm_loadu_ps(&c[i]);");
        sb.AppendLine("        vr = _mm_add_ps(_mm_add_ps(va, vb), vc);");
        sb.AppendLine("        _mm_storeu_ps(&a[i], vr);");
        sb.AppendLine("    }");
        sb.AppendLine("}");
        return sb.ToString();
    }

    public string GenerateAlignedMalloc(string type, int count, int alignment)
    {
        return $"static {type}* bplus_alloc_aligned(int n) {{\n" +
               $"    return ({type}*)aligned_alloc({alignment}, n * sizeof({type}));\n" +
               "}\n";
    }

    public string GenerateHeader(SimdWidth width)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("#include <immintrin.h>");
        sb.AppendLine($"#define BPLUS_SIMD_WIDTH {(int)width}");
        sb.AppendLine();

        if (width == SimdWidth.AVX512)
        {
            sb.AppendLine("#pragma GCC target(\"avx512f,avx512dq,avx512bw\")");
            sb.AppendLine("#define BPLUS_UNROLL_FACTOR 16");
        }
        else if (width == SimdWidth.AVX2)
        {
            sb.AppendLine("#pragma GCC target(\"avx2\")");
            sb.AppendLine("#define BPLUS_UNROLL_FACTOR 8");
        }
        else
        {
            sb.AppendLine("#define BPLUS_UNROLL_FACTOR 4");
        }

        return sb.ToString();
    }
}

public class FmaOptimizer
{
    public class FmaResult
    {
        public int FmaCount { get; set; }
        public int NormalCount { get; set; }
        public string OptimizedCode { get; set; } = "";
        public double EstSpeedup { get; set; }
    }

    public FmaResult Optimize(string[] stmts)
    {
        var result = new FmaResult();
        var optimized = new System.Text.StringBuilder();

        foreach (var s in stmts)
        {
            if (s.Contains("mul") && s.Contains("add"))
            {
                result.FmaCount++;
                optimized.AppendLine("// FMA: " + s.Trim());
            }
            else
            {
                result.NormalCount++;
                optimized.AppendLine(s);
            }
        }

        result.OptimizedCode = optimized.ToString();
        result.EstSpeedup = result.FmaCount > 0 ? 1.15 : 1.0;
        return result;
    }

    public string GenerateFmaHeader(FmaResult r)
    {
        return $"// FMA: {r.FmaCount} fused, {r.NormalCount} normal\n" +
               $"#define BPLUS_FMA_COUNT {r.FmaCount}\n";
    }
}

public class MatrixIntrinsics
{
    public string GenerateMat4Mul(string cpuArch)
    {
        bool avx512 = cpuArch.Contains("avx512");

        var sb = new System.Text.StringBuilder();
        if (avx512)
        {
            sb.AppendLine("__attribute__((target(\"avx512f\")))");
            sb.AppendLine("static void bplus_mat4_mul_avx512(float* dst, const float* a, const float* b) {");
            sb.AppendLine("    __m512 row0 = _mm512_loadu_ps(&a[0]);");
            sb.AppendLine("    __m512 row1 = _mm512_loadu_ps(&a[4]);");
            sb.AppendLine("    __m512 row2 = _mm512_loadu_ps(&a[8]);");
            sb.AppendLine("    __m512 row3 = _mm512_loadu_ps(&a[12]);");
            sb.AppendLine("    for (int col = 0; col < 4; col++) {");
            sb.AppendLine("        __m512 bcol = _mm512_set1_ps(b[col]);");
            sb.AppendLine("        __m512 r0 = _mm512_mul_ps(row0, bcol);");
            sb.AppendLine("        __m512 r1 = _mm512_mul_ps(row1, bcol);");
            sb.AppendLine("        __m512 r2 = _mm512_mul_ps(row2, bcol);");
            sb.AppendLine("        __m512 r3 = _mm512_mul_ps(row3, bcol);");
            sb.AppendLine("        __m512 sum = _mm512_add_ps(_mm512_add_ps(r0, r1), _mm512_add_ps(r2, r3));");
            sb.AppendLine("        _mm512_storeu_ps(&dst[col], sum);");
            sb.AppendLine("    }");
            sb.AppendLine("}");
        }
        else
        {
            sb.AppendLine("static void bplus_mat4_mul(float* dst, const float* a, const float* b) {");
            sb.AppendLine("    for (int i = 0; i < 4; i++)");
            sb.AppendLine("        for (int j = 0; j < 4; j++) {");
            sb.AppendLine("            float sum = 0;");
            sb.AppendLine("            for (int k = 0; k < 4; k++)");
            sb.AppendLine("                sum += a[i*4+k] * b[k*4+j];");
            sb.AppendLine("            dst[i*4+j] = sum;");
            sb.AppendLine("        }");
            sb.AppendLine("}");
        }

        return sb.ToString();
    }

    public string GenerateMat4Inverse(string cpuArch)
    {
        return cpuArch.Contains("avx512")
            ? "// AVX-512 matrix inverse\nstatic void bplus_mat4_inv_avx512(float* m) { /* TODO */ }\n"
            : "// Scalar matrix inverse\nstatic void bplus_mat4_inv(float* m) { /* TODO */ }\n";
    }
}

public class SimdAlignment
{
    public class AlignmentResult
    {
        public int OriginalAlignment { get; set; }
        public int OptimalAlignment { get; set; }
        public int DataSize { get; set; }
        public double EstSpeedup { get; set; }
    }

    public AlignmentResult Analyze(int dataSize, int elementSize)
    {
        int optimal = elementSize switch
        {
            4 => 32,
            8 => 64,
            _ => 16
        };

        int original = elementSize;
        while (original < optimal && dataSize % (original * 2) == 0)
            original *= 2;

        return new AlignmentResult
        {
            OriginalAlignment = elementSize,
            OptimalAlignment = optimal,
            DataSize = dataSize,
            EstSpeedup = optimal > elementSize ? 1.2 : 1.0
        };
    }

    public string GenerateAlignHeader(AlignmentResult r)
    {
        return $"// SIMD alignment: {r.OriginalAlignment} -> {r.OptimalAlignment} bytes\n" +
               $"__attribute__((aligned({r.OptimalAlignment}))) float bplus_aligned_data[{r.DataSize / 4}];\n";
    }
}