namespace BPlusTranspiler.AI;

public enum BitfieldStrategy
{
    Movzx,      // ≤8 bits: movzx r, byte ptr [mem]
    ShrAnd,     // 9-32 bits: shr r, N; and r, mask
    Vpermq,     // >32 bits with AVX-512
    PdepPext    // BMI2: parallel deposit/extract
}

public class BitfieldPattern
{
    public string Name { get; set; } = "";
    public int BitSize { get; set; }
    public BitfieldStrategy Strategy { get; set; }
    public string Instruction { get; set; } = "";
    public int CyclesEstimate { get; set; }
}

public class BitfieldPatternPredictor
{
    private static readonly int[] IntelLatencies = { 1, 1, 1, 2, 3, 5 };

    public BitfieldPattern Predict(string name, int bitSize, bool hasAvx512 = false, bool hasBmi2 = false)
    {
        var pattern = new BitfieldPattern { Name = name, BitSize = bitSize };

        if (bitSize <= 8)
        {
            pattern.Strategy = BitfieldStrategy.Movzx;
            pattern.Instruction = "movzx r64, byte ptr [rsi]";
            pattern.CyclesEstimate = 1;
        }
        else if (bitSize <= 16)
        {
            pattern.Strategy = BitfieldStrategy.Movzx;
            pattern.Instruction = "movzx r64, word ptr [rsi]";
            pattern.CyclesEstimate = 1;
        }
        else if (bitSize <= 32)
        {
            pattern.Strategy = BitfieldStrategy.ShrAnd;
            pattern.Instruction = $"shr rax, {bitSize - 1}; and rax, {(1 << bitSize) - 1}";
            pattern.CyclesEstimate = 2;
        }
        else if (bitSize <= 64 && hasBmi2)
        {
            pattern.Strategy = BitfieldStrategy.PdepPext;
            pattern.Instruction = "pdep rax, rax, rdx ; BMI2";
            pattern.CyclesEstimate = 3;
        }
        else if (bitSize > 32 && hasAvx512)
        {
            pattern.Strategy = BitfieldStrategy.Vpermq;
            pattern.Instruction = "vpermq ymm0, ymm1, imm8 ; AVX-512";
            pattern.CyclesEstimate = 4;
        }
        else
        {
            pattern.Strategy = BitfieldStrategy.ShrAnd;
            pattern.Instruction = $"shr rax, {bitSize - 32}; and rax, 0x{(1 << (bitSize - 32)) - 1:X}";
            pattern.CyclesEstimate = 5;
        }

        return pattern;
    }

    public string GenerateHeader()
    {
        return @"#define BPLUS_BITFIELD_MOVZX 1
#define BPLUS_BITFIELD_SHRAND 2
#define BPLUS_BITFIELD_VPERMQ 3
#define BPLUS_BITFIELD_PDEP 4

static inline uint64_t extract_bitfield_movzx(const uint8_t* p) {
    return (uint64_t)p[0];
}

static inline uint64_t extract_bitfield_shrand(uint64_t val, int shift, uint64_t mask) {
    return (val >> shift) & mask;
}

static inline uint64_t extract_bitfield_vpermq(__m512i src, int imm) {
    return _mm512_cvtsi512_si64(_mm512_permutexvar_epi64(_mm512_set1_epi64(imm), src));
}

static inline uint64_t extract_bitfield_pdep(uint64_t val, uint64_t mask) {
    return _pdep_u64(val, mask);
}
";
    }

    public int EstimateLatency(string name, int bitSize)
    {
        var p = Predict(name, bitSize, false, false);
        return p.CyclesEstimate;
    }

    public BitfieldStrategy[] GetFallbackChain(int bitSize, bool hasAvx512, bool hasBmi2)
    {
        var chain = new List<BitfieldStrategy>();

        if (bitSize <= 8) chain.Add(BitfieldStrategy.Movzx);
        else if (bitSize <= 16) chain.Add(BitfieldStrategy.Movzx);
        else if (bitSize <= 32) chain.Add(BitfieldStrategy.ShrAnd);

        if (hasBmi2) chain.Add(BitfieldStrategy.PdepPext);
        if (hasAvx512) chain.Add(BitfieldStrategy.Vpermq);

        chain.Add(BitfieldStrategy.ShrAnd);
        return chain.ToArray();
    }
}