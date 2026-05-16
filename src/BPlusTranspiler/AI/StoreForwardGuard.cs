namespace BPlusTranspiler.AI;

public class SimpleStoreForwardGuard
{
    public enum HazardType
    {
        None,
        SizeMismatch,
        Alignment,
        PartialLoad,
        MemoryDisambiguation
    }

    public class HazardInfo
    {
        public HazardType Type { get; set; }
        public string Instruction { get; set; } = "";
        public int LatencyPenalty { get; set; }
        public string Fix { get; set; } = "";
    }

    public class GuardResult
    {
        public List<HazardInfo> Hazards { get; set; } = new();
        public int TotalPenaltyCycles { get; set; }
        public string OptimizedCode { get; set; } = "";
        public double EstSpeedup { get; set; }
    }

    private static readonly (string pattern, HazardType type, int penalty, string fix)[] KnownHazards =
    {
        ("movzx after store", HazardType.SizeMismatch, 3, "Use same-size load"),
        ("movdqu after stosb", HazardType.MemoryDisambiguation, 5, "Add nop stall"),
        ("partial reg write", HazardType.PartialLoad, 4, "Use full-reg mov"),
        ("unaligned load after store", HazardType.Alignment, 6, "Align data to 16B"),
        ("mmx after sse", HazardType.SizeMismatch, 2, "Use mfence")
    };

    public GuardResult Analyze(string[] instructions)
    {
        var result = new GuardResult();

        for (int i = 0; i < instructions.Length - 1; i++)
        {
            string l1 = instructions[i];
            string l2 = instructions[i + 1];

            var hazard = DetectHazard(l1, l2);
            if (hazard.Type != HazardType.None)
            {
                result.Hazards.Add(hazard);
                result.TotalPenaltyCycles += hazard.LatencyPenalty;
            }
        }

        result.EstSpeedup = result.TotalPenaltyCycles > 10 ? 1.15 : 1.05;
        result.OptimizedCode = GenerateGuardCode(result.Hazards);

        return result;
    }

    private HazardInfo DetectHazard(string i1, string i2)
    {
        string l1 = i1.ToLower();
        string l2 = i2.ToLower();

        if (l1.Contains("stos") && l2.Contains("mov"))
            return new HazardInfo { Type = HazardType.MemoryDisambiguation, Instruction = i1 + " -> " + i2, LatencyPenalty = 5, Fix = "mfence before " + i2 };

        if (l1.Contains("store") && l2.Contains("load") && l1.Contains("byte") && !l2.Contains("byte"))
            return new HazardInfo { Type = HazardType.SizeMismatch, Instruction = i1 + " -> " + i2, LatencyPenalty = 3, Fix = "Use matching load size" };

        if (l2.Contains("eax") && l1.Contains("al"))
            return new HazardInfo { Type = HazardType.PartialLoad, Instruction = i1 + " -> " + i2, LatencyPenalty = 4, Fix = "Zero-extend before use" };

        if (l2.Contains("[r") && l2.Contains("+") && l1.Contains("store"))
            return new HazardInfo { Type = HazardType.Alignment, Instruction = i1 + " -> " + i2, LatencyPenalty = 6, Fix = "Align to 16 bytes" };

        return new HazardInfo { Type = HazardType.None };
    }

    private string GenerateGuardCode(List<HazardInfo> hazards)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("; Store-forwarding guard optimizations");
        sb.AppendLine();

        foreach (var h in hazards)
        {
            if (h.Type == HazardType.MemoryDisambiguation)
                sb.AppendLine("mfence ; fix: " + h.Fix);
            else if (h.Type == HazardType.PartialLoad)
                sb.AppendLine("movzx rax, al ; fix: " + h.Fix);
            else if (h.Type == HazardType.Alignment)
                sb.AppendLine("; align data: " + h.Fix);
        }

        return sb.ToString();
    }

    public string GenerateHeader()
    {
        return @"// Store-forwarding hazard guards
#define BPLUS_SF_GUARD 1
#define BPLUS_MFENCE_BEFORE_LOAD 1

static inline void bplus_sf_guard(void* ptr) {
    _mm_mfence();
    volatile char c = ((volatile char*)ptr)[0];
    (void)c;
}

static inline uint64_t bplus_safe_load64(const void* ptr) {
    _mm_mfence();
    return *(const uint64_t*)ptr;
}

static inline uint32_t bplus_safe_load32(const void* ptr) {
    _mm_mfence();
    return *(const uint32_t*)ptr;
}
";
    }
}