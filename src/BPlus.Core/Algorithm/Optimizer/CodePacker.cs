using BPlus.Core.Ast;

namespace BPlus.Core.Algorithm.Optimizer;

public class CodeBundle
{
    public int BundleSize { get; set; }
    public int Alignment { get; set; }
    public List<string> Instructions { get; } = new();
    public string? FusionPair { get; set; }
}

public class CodePacker
{
    public List<CodeBundle> PackL0(string stateName, List<string> dispatchInstrs)
    {
        var bundles = new List<CodeBundle>();
        var current = new CodeBundle { Alignment = 16 };

        for (int i = 0; i < dispatchInstrs.Count; i++)
        {
            current.Instructions.Add(dispatchInstrs[i]);
            current.BundleSize += EstimateInstrSize(dispatchInstrs[i]);

            if (i + 1 < dispatchInstrs.Count && IsFusionPair(dispatchInstrs[i], dispatchInstrs[i + 1], out var pair))
            {
                current.Instructions.Add(dispatchInstrs[++i]);
                current.BundleSize += EstimateInstrSize(dispatchInstrs[i]);
                current.FusionPair = pair;
            }

            if (current.BundleSize >= 16 || current.Instructions.Count >= 4)
            {
                bundles.Add(current);
                current = new CodeBundle { Alignment = 16 };
            }
        }

        if (current.Instructions.Count > 0)
            bundles.Add(current);

        return bundles;
    }

    public List<CodeBundle> PackL1(List<string> hotStates, List<List<string>> stateBodies)
    {
        var bundles = new List<CodeBundle>();

        for (int i = 0; i < hotStates.Count; i++)
        {
            var bundle = new CodeBundle { Alignment = 32 };

            // Check if next state follows in 90%+ cases → jmp rel8 (2 bytes)
            bundle.Instructions.Add($"// --- {hotStates[i]} (hot) ---");
            bundle.Instructions.AddRange(stateBodies[i]);

            if (i + 1 < hotStates.Count)
            {
                // Fused jump to next hot state
                bundle.Instructions.Add("// fused jmp rel8 to next hot state");
                bundle.Instructions.Add("jmp .L_" + hotStates[i + 1]);
            }

            bundle.BundleSize = bundle.Instructions.Sum(l => EstimateInstrSize(l));
            bundles.Add(bundle);
        }

        return bundles;
    }

    public List<CodeBundle> PackL2(List<string> warmStates, List<List<string>> stateBodies)
    {
        var bundles = new List<CodeBundle>();

        foreach (var state in warmStates)
        {
            var bundle = new CodeBundle { Alignment = 64 };
            bundle.Instructions.Add($"// --- {state} (warm) ---");
            bundle.Instructions.Add("// L3 gateway");
            bundle.Instructions.Add("prefetcht2 [rax + 64]");
            bundle.Instructions.AddRange(stateBodies.FirstOrDefault(b => b.Count > 0) ?? new List<string>());
            bundle.BundleSize = bundle.Instructions.Sum(l => EstimateInstrSize(l));
            bundles.Add(bundle);
        }

        return bundles;
    }

    public List<CodeBundle> PackL3(List<string> coldStates, List<List<string>> stateBodies)
    {
        var bundles = new List<CodeBundle>();

        foreach (var state in coldStates)
        {
            var bundle = new CodeBundle { Alignment = 128 };
            bundle.Instructions.Add($"// --- {state} (cold) ---");
            bundle.Instructions.AddRange(stateBodies.FirstOrDefault(b => b.Count > 0) ?? new List<string>());
            bundle.BundleSize = bundle.Instructions.Sum(l => EstimateInstrSize(l));
            bundles.Add(bundle);
        }

        return bundles;
    }

    private static int EstimateInstrSize(string instr)
    {
        if (instr.StartsWith("//")) return 0;
        if (instr.StartsWith("jmp") || instr.StartsWith("je") || instr.StartsWith("jne") ||
            instr.StartsWith("jg") || instr.StartsWith("jl") || instr.StartsWith("jge") ||
            instr.StartsWith("jle") || instr.StartsWith("ja") || instr.StartsWith("jb") ||
            instr.StartsWith("jz") || instr.StartsWith("jnz"))
            return 5;
        if (instr.StartsWith("call")) return 5;
        if (instr.StartsWith("ret")) return 1;
        if (instr.StartsWith("nop")) return 1;
        if (instr.StartsWith("mov")) return 4;
        if (instr.StartsWith("cmp")) return 3;
        if (instr.StartsWith("test")) return 3;
        if (instr.StartsWith("add") || instr.StartsWith("sub") || instr.StartsWith("dec") ||
            instr.StartsWith("inc"))
            return 3;
        if (instr.StartsWith("push") || instr.StartsWith("pop")) return 1;
        if (instr.StartsWith("prefetch")) return 4;
        if (instr.StartsWith("vpermq") || instr.StartsWith("vmovq") || instr.StartsWith("vpgather"))
            return 6;
        if (instr.StartsWith("kortest") || instr.StartsWith("kor") || instr.StartsWith("kand"))
            return 4;
        return 4; // default
    }

    private static bool IsFusionPair(string a, string b, out string pair)
    {
        pair = "";
        if ((a.StartsWith("cmp") || a.StartsWith("test")) &&
            (b.StartsWith("j") && b.Length == 3))
        {
            pair = a.Split(' ')[0] + "+" + b.Split(' ')[0];
            return true;
        }
        if ((a.StartsWith("dec") || a.StartsWith("inc")) &&
            (b.StartsWith("j") && b.Length == 3))
        {
            pair = a.Split(' ')[0] + "+" + b.Split(' ')[0];
            return true;
        }
        if (a.StartsWith("mov") && (b.StartsWith("add") || b.StartsWith("sub")))
        {
            pair = "mov+alu";
            return true;
        }
        return false;
    }
}
