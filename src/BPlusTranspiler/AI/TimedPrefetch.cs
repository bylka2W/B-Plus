namespace BPlusTranspiler.AI;

public class TimedPrefetch
{
    public class PrefetchDecision
    {
        public string Variable { get; set; } = "";
        public int DistanceCycles { get; set; }
        public string Instruction { get; set; } = "";
        public int StrideBytes { get; set; }
    }

    public class TimedPrefetchResult
    {
        public List<PrefetchDecision> Decisions { get; set; } = new();
        public int TotalCyclesSaved { get; set; }
        public double EstSpeedup { get; set; }
    }

    private static readonly (string hint, int cyclesAhead)[] PrefetchHints =
    {
        ("PREFETCHT0", 100),
        ("PREFETCHT1", 150),
        ("PREFETCHT2", 200),
        ("PREFETCHNTA", 80)
    };

    public TimedPrefetchResult ComputeTimedPrefetch(int cacheKB, int accessStride, int iterationTimeCycles, bool hasAvx512)
    {
        var result = new TimedPrefetchResult();

        if (cacheKB > 256)
        {
            int cyclesBetween = iterationTimeCycles / 1000;
            if (cyclesBetween <= 0) cyclesBetween = 50;

            int distance = 0;
            string hint = "PREFETCHT0";

            if (cacheKB > 2048)
            {
                hint = "PREFETCHNTA";
                distance = 80;
            }
            else if (cacheKB > 256)
            {
                if (accessStride >= 1024) { hint = "PREFETCHT2"; distance = 200; }
                else if (accessStride >= 256) { hint = "PREFETCHT1"; distance = 150; }
                else { hint = "PREFETCHT0"; distance = 100; }
            }

            if (distance > cyclesBetween)
            {
                result.Decisions.Add(new PrefetchDecision
                {
                    Variable = "arr",
                    DistanceCycles = distance,
                    Instruction = hint,
                    StrideBytes = accessStride
                });

                result.TotalCyclesSaved = distance * 10;
                result.EstSpeedup = 1.5 + (cacheKB / 1024.0) * 0.5;
            }
            else
            {
                result.EstSpeedup = 1.2;
            }
        }
        else
        {
            result.EstSpeedup = 1.0;
        }

        return result;
    }

    public string GeneratePrefetchCode(TimedPrefetchResult r, string variable, bool hasAvx512)
    {
        if (r.Decisions.Count == 0)
            return "// No prefetch needed (fits in cache)";

        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Timed prefetch insertions");
        sb.AppendLine($"// Variable: {variable}, Est speedup: {r.EstSpeedup:F2}x");
        sb.AppendLine();

        foreach (var d in r.Decisions)
        {
            sb.AppendLine($"// Prefetch {d.Variable}: {d.Instruction} at cycle -{d.DistanceCycles}");
            sb.AppendLine($"#define BPLUS_PREFETCH_DISTANCE {d.DistanceCycles}");
            sb.AppendLine($"#define BPLUS_PREFETCH_STRIDE {d.StrideBytes}");

            if (hasAvx512)
            {
                sb.AppendLine($"static inline void bplus_prefetch_{d.Variable}() {{");
                sb.AppendLine($"    for (int i = 0; i < count; i += BPLUS_PREFETCH_STRIDE) {{");
                sb.AppendLine($"        _mm_prefetch((char*)&{variable}[i + BPLUS_PREFETCH_DISTANCE], _MM_HINT_T0);");
                sb.AppendLine($"    }}");
                sb.AppendLine("}");
            }
            else
            {
                sb.AppendLine($"static inline void bplus_prefetch_{d.Variable}() {{");
                sb.AppendLine($"    for (int i = 0; i < count; i += BPLUS_PREFETCH_STRIDE) {{");
                sb.AppendLine($"        __builtin_prefetch(&{variable}[i + BPLUS_PREFETCH_DISTANCE], 0, 3);");
                sb.AppendLine($"    }}");
                sb.AppendLine("}");
            }
        }

        return sb.ToString();
    }

    public string GenerateHeader()
    {
        return @"// Timed prefetch header
#pragma once

#ifdef __GNUC__
#define PREFETCH_T0(addr) __builtin_prefetch(addr, 0, 3)
#define PREFETCH_T1(addr) __builtin_prefetch(addr, 0, 2)
#define PREFETCH_T2(addr) __builtin_prefetch(addr, 0, 1)
#define PREFETCH_NTA(addr) __builtin_prefetch(addr, 0, 0)
#else
#include <xmmintrin.h>
#define PREFETCH_T0(addr) _mm_prefetch(addr, _MM_HINT_T0)
#define PREFETCH_T1(addr) _mm_prefetch(addr, _MM_HINT_T1)
#define PREFETCH_T2(addr) _mm_prefetch(addr, _MM_HINT_T2)
#define PREFETCH_NTA(addr) _mm_prefetch(addr, _MM_HINT_NTA)
#endif

#define BPLUS_PREFETCH_AUTO 1
#define BPLUS_PREFETCH_STRIDE 64
#define BPLUS_PREFETCH_DISTANCE 128

static inline void bplus_auto_prefetch(const void* ptr, size_t stride, size_t count) {
    for (size_t i = 0; i < count; i += stride) {
        PREFETCH_T0((const char*)ptr + i * BPLUS_PREFETCH_DISTANCE);
    }
}
";
    }
}