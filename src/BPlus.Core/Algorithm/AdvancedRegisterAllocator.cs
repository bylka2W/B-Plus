namespace BPlus.Core.Algorithm;

public class AdvancedRegisterAllocator
{
    public class RegisterInfo
    {
        public string Name { get; set; } = "";
        public int Uses { get; set; }
        public int SpillCost { get; set; }
        public bool IsCalleeSaved { get; set; }
        public bool IsAllocated { get; set; }
    }

    public class AllocationResult
    {
        public List<RegisterInfo> Allocations { get; set; } = new();
        public int SpillCount { get; set; }
        public int RegisterCount { get; set; }
        public double EstSpeedup { get; set; }
    }

    private static readonly string[] CalleeSaved = { "rbx", "r12", "r13", "r14", "r15" };
    private static readonly string[] CallerSaved = { "rax", "rcx", "rdx", "r8", "r9", "r10", "r11" };

    public AllocationResult Allocate(string[] variables, int maxRegs = 16)
    {
        var result = new AllocationResult();

        var sorted = variables.Select((v, i) => new { Name = v, Uses = EstimateUses(v), Index = i })
                             .OrderByDescending(x => x.Uses).ToList();

        int regIdx = 0;
        int spills = 0;

        foreach (var v in sorted)
        {
            if (regIdx < CalleeSaved.Length)
            {
                result.Allocations.Add(new RegisterInfo { Name = v.Name, Uses = v.Uses, IsCalleeSaved = true, IsAllocated = true });
            }
            else if (regIdx < CalleeSaved.Length + CallerSaved.Length)
            {
                result.Allocations.Add(new RegisterInfo { Name = v.Name, Uses = v.Uses, IsCalleeSaved = false, IsAllocated = true });
            }
            else
            {
                result.Allocations.Add(new RegisterInfo { Name = v.Name, Uses = v.Uses, IsAllocated = false, SpillCost = v.Uses });
                spills++;
            }
            regIdx++;
        }

        result.SpillCount = spills;
        result.RegisterCount = Math.Min(maxRegs, variables.Length);
        result.EstSpeedup = spills > 0 ? 1.0 - spills * 0.05 : 1.5;

        return result;
    }

    private int EstimateUses(string varName)
    {
        return varName.Length + 10;
    }

    public string GenerateHeader(AllocationResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Advanced register allocator");
        sb.AppendLine($"#define BPLUS_REG_COUNT {r.RegisterCount}");
        sb.AppendLine($"#define BPLUS_SPILLS {r.SpillCount}");
        sb.AppendLine($"#define BPLUS_REG_SPEEDUP {r.EstSpeedup:F1}");
        sb.AppendLine();
        sb.AppendLine("// Callee-saved: rbx, r12-r15");
        sb.AppendLine("// Caller-saved: rax, rcx, rdx, r8-r11");
        return sb.ToString();
    }
}

public class StackFrameOptimizer
{
    public class FrameResult
    {
        public int OriginalSize { get; set; }
        public int OptimizedSize { get; set; }
        public int Alignment { get; set; }
        public double EstSpeedup { get; set; }
    }

    public FrameResult Optimize(int varCount, int avgVarSize)
    {
        int original = varCount * avgVarSize;
        int optimized = (original + 15) / 16 * 16;
        int alignment = 16;

        return new FrameResult
        {
            OriginalSize = original,
            OptimizedSize = optimized,
            Alignment = alignment,
            EstSpeedup = original > optimized ? 1.1 : 1.0
        };
    }
}

public class LcpStallDetector
{
    public class LcpResult
    {
        public List<string> Instructions { get; set; } = new();
        public int StallsFound { get; set; }
        public string Recommendation { get; set; } = "";
    }

    private static readonly string[] LcpPrefixes = { "0x66", "0x67" };

    public LcpResult Detect(string[] instructions)
    {
        var result = new LcpResult();

        foreach (var inst in instructions)
        {
            if (inst.Contains("0x66") || inst.Contains("rex"))
            {
                result.Instructions.Add(inst);
                result.StallsFound++;
            }
        }

        result.Recommendation = result.StallsFound > 0
            ? "Reorder: move LCP instructions after immediate operands"
            : "No LCP stalls detected";

        return result;
    }
}
