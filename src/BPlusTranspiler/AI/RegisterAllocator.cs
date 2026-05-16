using BPlusTranspiler.Ast;

namespace BPlusTranspiler.AI;

public class RegisterAllocationResult
{
    public string Variable { get; set; } = "";
    public string Register { get; set; } = "";
    public int Uses { get; set; }
    public bool OnStack { get; set; }
}

public class SimpleRegisterAllocator
{
    private static readonly string[] CalleeSaved = { "rbx", "r12", "r13", "r14", "r15" };
    private static readonly string[] CallerSaved = { "rax", "rcx", "rdx", "r8", "r9", "r10", "r11" };

    public List<RegisterAllocationResult> Allocate(ProgramNode program)
    {
        var results = new List<RegisterAllocationResult>();
        var freq = AnalyzeFrequency(program);

        int calleeIdx = 0;
        int callerIdx = 0;

        foreach (var (name, uses) in freq.OrderByDescending(x => x.Value))
        {
            string reg;
            bool onStack;

            if (uses >= 50 && calleeIdx < CalleeSaved.Length)
            {
                reg = CalleeSaved[calleeIdx++];
                onStack = false;
            }
            else if (uses >= 10 && callerIdx < CallerSaved.Length)
            {
                reg = CallerSaved[callerIdx++];
                onStack = false;
            }
            else
            {
                reg = "(stack)";
                onStack = true;
            }

            results.Add(new RegisterAllocationResult { Variable = name, Register = reg, Uses = uses, OnStack = onStack });
        }

        return results;
    }

    private Dictionary<string, int> AnalyzeFrequency(ProgramNode program)
    {
        var freq = new Dictionary<string, int>();

        foreach (var state in program.States)
        {
            foreach (var trans in state.Transitions)
            {
                if (trans.Guard != null)
                {
                    foreach (var var in state.Variables)
                    {
                        if (trans.Guard.Contains(var.Name))
                        {
                            if (!freq.ContainsKey(var.Name)) freq[var.Name] = 0;
                            freq[var.Name] += 50;
                        }
                    }
                }
            }
            foreach (var var in state.Variables)
            {
                if (!freq.ContainsKey(var.Name)) freq[var.Name] = 0;
                freq[var.Name] += state.Transitions.Count;
            }
        }

        return freq;
    }

    public string GenerateCode(List<RegisterAllocationResult> alloc, bool enableAvx512 = false)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("; Register allocation");
        foreach (var a in alloc.Where(x => !x.OnStack))
        {
            sb.AppendLine($"    ; {a.Variable} -> {a.Register} ({a.Uses} uses)");
        }
        if (enableAvx512)
        {
            sb.AppendLine("    vxorps ymm0, ymm0, ymm0");
        }
        return sb.ToString();
    }
}