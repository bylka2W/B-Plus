namespace BPlusTranspiler.AI;

public class NonTemporalHints
{
    public enum DataLifetime { Once, Few, Many }

    public class HintDecision
    {
        public string Variable { get; set; } = "";
        public DataLifetime Lifetime { get; set; }
        public string Instruction { get; set; } = "";
        public bool IsTemporal { get; set; }
    }

    public class HintResult
    {
        public List<HintDecision> Decisions { get; set; } = new();
        public int CacheLinesSaved { get; set; }
        public double EstSpeedup { get; set; }
    }

    public HintResult Analyze(int[] accessCounts, string[] variableNames)
    {
        var result = new HintResult();

        for (int i = 0; i < variableNames.Length && i < accessCounts.Length; i++)
        {
            string name = variableNames[i];
            int count = accessCounts[i];

            DataLifetime lifetime;
            bool useNonTemporal;
            string instruction;

            if (count == 1)
            {
                lifetime = DataLifetime.Once;
                useNonTemporal = true;
                instruction = "_mm_stream_si32 (non-temporal store)";
            }
            else if (count <= 3)
            {
                lifetime = DataLifetime.Few;
                useNonTemporal = true;
                instruction = "_mm_stream_si64 (non-temporal)";
            }
            else
            {
                lifetime = DataLifetime.Many;
                useNonTemporal = false;
                instruction = "_mm_storeu_si64 (temporal store)";
            }

            result.Decisions.Add(new HintDecision
            {
                Variable = name,
                Lifetime = lifetime,
                Instruction = instruction,
                IsTemporal = !useNonTemporal
            });

            if (useNonTemporal)
                result.CacheLinesSaved += 1;
        }

        result.EstSpeedup = result.CacheLinesSaved > 10 ? 1.15 : 1.05;
        return result;
    }

    public string GenerateHeader(HintResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Non-temporal store hints");
        sb.AppendLine("#define BPLUS_NONTEMPORAL 1");
        sb.AppendLine();
        sb.AppendLine("// Temporal stores (use cache)");
        sb.AppendLine("static inline void bplus_store_temporal(void* ptr, int64_t val) {");
        sb.AppendLine("    _mm_storeu_si64((__m128i*)ptr, _mm_set1_epi64x(val));");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("// Non-temporal stores (bypass cache)");
        sb.AppendLine("static inline void bplus_store_nontemporal(void* ptr, int64_t val) {");
        sb.AppendLine("    _mm_stream_si64((long long*)ptr, val);");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("#ifdef __AVX512F__");
        sb.AppendLine("static inline void bplus_store_nontemporal_avx512(void* ptr, __m512i val) {");
        sb.AppendLine("    _mm512_stream_si64((long long*)ptr, _mm512_cvtsi512_si64(val));");
        sb.AppendLine("}");
        sb.AppendLine("#endif");

        return sb.ToString();
    }

    public string GetOptimizationHints()
    {
        return @"// Cache bypass for streaming data:
// 1. Video frame buffers -> _mm_stream_si32/_mm_stream_si64
// 2. Large intermediate buffers -> non-temporal stores
// 3. Temporary accumulators -> temporal stores (keep in cache)
// 4. Ring buffer head/tail -> temporal stores (frequently accessed)
#define BPLUS_USE_NONTEMPORAL(x) ((x)->access_count <= 3)
#define BPLUS_USE_TEMPORAL(x) ((x)->access_count > 3)
";
    }
}