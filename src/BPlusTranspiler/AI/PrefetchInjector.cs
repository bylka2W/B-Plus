namespace BPlusTranspiler.AI;

public class SimplePrefetchInjector
{
    public enum PrefetchStrategy
    {
        None,
        SoftwareTemporal,   // PREFETCHT0/T1/T2
        HardwareTemporal,   // nt.store
        NonTemporal,        // _mm_stream_si32
        OpcodeHint          // prefetch hint in opcode
    }

    public class PrefetchDecision
    {
        public string Variable { get; set; } = "";
        public int Offset { get; set; }
        public PrefetchStrategy Strategy { get; set; }
        public int Distance { get; set; }
        public int TriggerThreshold { get; set; }
    }

    public class PrefetchResult
    {
        public List<PrefetchDecision> Decisions { get; set; } = new();
        public string GeneratedCode { get; set; } = "";
        public double EstSpeedup { get; set; }
    }

    private static readonly (string pattern, int minStride, int maxStride)[] PrefetchPatterns =
    {
        ("sequential", 64, 4096),
        ("strided", 128, 8192),
        ("random", 0, 0),
        ("pointer_chase", 8, 128)
    };

    public PrefetchResult AnalyzeAndInject(string variable, int stride, int accessCount, bool hasAvx512)
    {
        var result = new PrefetchResult();
        var decision = new PrefetchDecision { Variable = variable };

        if (stride < 64)
        {
            decision.Strategy = PrefetchStrategy.None;
            result.EstSpeedup = 1.0;
        }
        else if (stride >= 64 && stride <= 256)
        {
            decision.Strategy = PrefetchStrategy.SoftwareTemporal;
            decision.Distance = stride * 2;
            decision.TriggerThreshold = accessCount > 1000 ? 32 : 16;
            result.EstSpeedup = 1.15;
        }
        else if (stride > 256 && stride <= 1024)
        {
            decision.Strategy = PrefetchStrategy.HardwareTemporal;
            decision.Distance = stride;
            decision.TriggerThreshold = 64;
            result.EstSpeedup = 1.20;
        }
        else
        {
            decision.Strategy = PrefetchStrategy.NonTemporal;
            decision.Distance = stride * 4;
            decision.TriggerThreshold = 128;
            result.EstSpeedup = 1.25;
        }

        result.Decisions.Add(decision);
        result.GeneratedCode = GeneratePrefetchCode(decision, hasAvx512);

        return result;
    }

    private string GeneratePrefetchCode(PrefetchDecision d, bool hasAvx512)
    {
        if (d.Strategy == PrefetchStrategy.None)
            return "// No prefetch needed";

        var sb = new System.Text.StringBuilder();

        switch (d.Strategy)
        {
            case PrefetchStrategy.SoftwareTemporal:
                sb.AppendLine($"// Prefetch {d.Variable} with stride {d.Distance}");
                sb.AppendLine($"for (int i = 0; i < count; i += {d.TriggerThreshold}) {{");
                sb.AppendLine($"    _mm_prefetch((char*)&{d.Variable}[i + {d.Distance / 8}], _MM_HINT_T0);");
                sb.AppendLine("}");
                break;

            case PrefetchStrategy.HardwareTemporal:
                sb.AppendLine($"// Hardware temporal prefetch for {d.Variable}");
                sb.AppendLine($"#pragma loop_hint(hint_perf_monitor)");
                sb.AppendLine($"for (int i = 0; i < count; i++) {{");
                sb.AppendLine($"    _mm_stream_si32((int*)&{d.Variable}[i], {d.Variable}[i]);");
                sb.AppendLine("}");
                break;

            case PrefetchStrategy.NonTemporal:
                if (hasAvx512)
                {
                    sb.AppendLine($"// AVX-512 non-temporal for {d.Variable}");
                    sb.AppendLine($"for (int i = 0; i < count; i += 16) {{");
                    sb.AppendLine($"    __m512i v = _mm512_loadu_epi64(&{d.Variable}[i]);");
                    sb.AppendLine($"    _mm512_stream_si64((long long*)&{d.Variable}[i], _mm512_cvtsi512_si64(v));");
                    sb.AppendLine("}");
                }
                else
                {
                    sb.AppendLine($"// Non-temporal store for {d.Variable}");
                    sb.AppendLine($"for (int i = 0; i < count; i++) {{");
                    sb.AppendLine($"    _mm_stream_si32((int*)&{d.Variable}[i], {d.Variable}[i]);");
                    sb.AppendLine("}");
                }
                break;
        }

        return sb.ToString();
    }

    public string GenerateHeader()
    {
        return @"#if defined(__GNUC__) || defined(__clang__)
    #define PREFETCH_T0(addr) __builtin_prefetch(addr, 0, 3)
    #define PREFETCH_T1(addr) __builtin_prefetch(addr, 0, 2)
    #define PREFETCH_T2(addr) __builtin_prefetch(addr, 0, 1)
    #define PREFETCH NTA(addr) __builtin_prefetch(addr, 0, 0)
#else
    #include <xmmintrin.h>
    #define PREFETCH_T0(addr) _mm_prefetch((const char*)(addr), _MM_HINT_T0)
    #define PREFETCH_T1(addr) _mm_prefetch((const char*)(addr), _MM_HINT_T1)
    #define PREFETCH_T2(addr) _mm_prefetch((const char*)(addr), _MM_HINT_T2)
    #define PREFETCH_NTA(addr) _mm_prefetch((const char*)(addr), _MM_HINT_NTA)
#endif

#define BPLUS_PREFETCH_STRIDE 64
#define BPLUS_PREFETCH_DISTANCE 2
#define BPLUS_PREFETCH_THRESHOLD 32

static inline void bplus_prefetch_array(const void* ptr, size_t count, size_t stride) {
    for (size_t i = 0; i < count; i += BPLUS_PREFETCH_THRESHOLD) {
        const char* addr = (const char*)ptr + (i + BPLUS_PREFETCH_DISTANCE) * stride;
        PREFETCH_T0(addr);
    }
}
";
    }
}