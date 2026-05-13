using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

public class RegisterAssignment
{
    public string Variable { get; set; } = "";
    public string Register { get; set; } = "";
    public RegisterClass Class { get; set; } = RegisterClass.GPR;
}

public enum RegisterClass { GPR, ZMM, Mask }

public static class RegisterAllocator
{
    // Fixed GPR assignments
    private static readonly string[] GprPool =
        { "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };

    // Hot GPR: first 6 (rax-r9) for hot path
    private static readonly string[] HotGpr = { "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9" };
    private static readonly string[] ColdGpr = { "r10", "r11", "r12", "r13", "r14", "r15" };

    public static List<RegisterAssignment> Allocate(ProgramNode program, List<MetalBlock> blocks)
    {
        var assignments = new List<RegisterAssignment>();
        int hotIdx = 0, coldIdx = 0;

        var blockMap = new Dictionary<string, MetalConfig>();
        foreach (var b in blocks)
        {
            if (b.TargetState != null)
                blockMap[b.TargetState] = b.Config;
        }

        // Assign fixed registers from annotations
        foreach (var state in program.States)
        {
            if (blockMap.TryGetValue(state.Name, out var cfg))
            {
                // User-specified register
                if (cfg.Register != null)
                {
                    assignments.Add(new RegisterAssignment
                    {
                        Variable = $"{state.Name}_state_ptr",
                        Register = cfg.Register,
                        Class = RegisterClass.GPR
                    });
                }

                // ZMM table
                if (cfg.Zmm.HasValue)
                {
                    assignments.Add(new RegisterAssignment
                    {
                        Variable = $"{state.Name}_table",
                        Register = $"zmm{cfg.Zmm.Value}",
                        Class = RegisterClass.ZMM
                    });
                }

                // Mask register
                if (cfg.Mask != null)
                {
                    assignments.Add(new RegisterAssignment
                    {
                        Variable = $"{state.Name}_mask",
                        Register = cfg.Mask,
                        Class = RegisterClass.Mask
                    });
                }

                // Assign variables
                foreach (var v in state.Variables)
                {
                    bool isHot = cfg.Tier == MemoryTier.L0 || cfg.Tier == MemoryTier.L1 || cfg.HotPath;
                    string reg;

                    if (isHot && hotIdx < HotGpr.Length)
                    {
                        reg = HotGpr[hotIdx++];
                    }
                    else if (coldIdx < ColdGpr.Length)
                    {
                        reg = ColdGpr[coldIdx++];
                    }
                    else
                    {
                        reg = "r15"; // fallback
                    }

                    assignments.Add(new RegisterAssignment
                    {
                        Variable = $"{state.Name}_{v.Name}",
                        Register = reg,
                        Class = RegisterClass.GPR
                    });
                }
            }
            else
            {
                // Auto-detect: hot states get GPR, cold states get stack
                bool isHot = state.Transitions.Any(t => t.HotWeight.HasValue && t.HotWeight.Value >= 0.5);

                foreach (var v in state.Variables)
                {
                    string reg;
                    if (isHot && hotIdx < HotGpr.Length)
                    {
                        reg = HotGpr[hotIdx++];
                    }
                    else if (coldIdx < ColdGpr.Length)
                    {
                        reg = ColdGpr[coldIdx++];
                    }
                    else
                    {
                        reg = "r15";
                    }

                    assignments.Add(new RegisterAssignment
                    {
                        Variable = $"{state.Name}_{v.Name}",
                        Register = reg,
                        Class = RegisterClass.GPR
                    });
                }

                // ZMM0 = transition table for all states
                if (isHot && !assignments.Any(a => a.Register == "zmm0"))
                {
                    assignments.Add(new RegisterAssignment
                    {
                        Variable = "transition_table",
                        Register = "zmm0",
                        Class = RegisterClass.ZMM
                    });
                }
            }
        }

        return assignments;
    }
}
