namespace BPlusTranspiler.Algorithm;

public class MacroFusionOptimizer
{
    public class FusionPair
    {
        public string Inst1 { get; set; } = "";
        public string Inst2 { get; set; } = "";
        public string FusedInst { get; set; } = "";
        public bool IsFusable { get; set; }
    }

    private static readonly (string pattern, string fused)[] IntelPatterns =
    {
        ("cmp r, 0\nje", "test r, r\nje"),
        ("cmp r, imm\nje", "test r, r\nje"),
        ("sub r, 1\njnz", "dec r\njnz"),
        ("add r, -1\njnz", "dec r\njnz"),
        ("test r, r\njz", "test r, r\njz"),
        ("test r, r\njnz", "test r, r\njnz"),
        ("cmp r1, r2\nje", "cmp r1, r2\nje"),
        ("cmp r1, r2\njne", "cmp r1, r2\njne"),
    };

    private static readonly (string from, string to)[] AgnerFogFusions =
    {
        ("mov r, 0", "xor r, r"),
        ("mov eax, 0", "xor eax, eax"),
        ("mov r64, r64", ""),
        ("add r, 0", ""),
        ("sub r, 0", ""),
    };

    public string Optimize(string asm)
    {
        var lines = asm.Split('\n').Select(l => l.Trim()).ToList();
        var result = new List<string>();

        for (int i = 0; i < lines.Count - 1; i++)
        {
            string l1 = lines[i];
            string l2 = lines[i + 1];

            if (CanFuse(l1, l2, out string fused))
            {
                result.Add("    " + fused + " ; fused");
                i++;
            }
            else
            {
                result.Add(l1);
            }
        }

        if (lines.Count > 0)
            result.Add(lines[^1]);

        return string.Join("\n", result);
    }

    private bool CanFuse(string l1, string l2, out string fused)
    {
        fused = "";
        string lower1 = l1.ToLower();
        string lower2 = l2.ToLower();

        if (lower1.StartsWith("cmp") && lower2.StartsWith("je"))
        {
            string target = lower2.Contains(".") ? lower2.Split(' ')[1] : "";
            fused = lower1 + " + " + lower2;
            return true;
        }

        if (lower1.StartsWith("cmp") && (lower2.StartsWith("jne") || lower2.StartsWith("jl") || lower2.StartsWith("jg")))
        {
            fused = lower1 + " + " + lower2;
            return true;
        }

        if (lower1.StartsWith("test") && (lower2.StartsWith("jz") || lower2.StartsWith("jnz")))
        {
            fused = lower1 + " + " + lower2 + " ; macro-fused";
            return true;
        }

        if (lower1.StartsWith("dec") && lower2.StartsWith("jnz"))
        {
            fused = lower1 + " + " + lower2 + " ; macro-fused";
            return true;
        }

        if (lower1.StartsWith("sub") && lower2.StartsWith("jnz"))
        {
            fused = lower1 + " + " + lower2;
            return true;
        }

        return false;
    }

    public List<FusionPair> FindFusionCandidates(string asm)
    {
        var pairs = new List<FusionPair>();
        var lines = asm.Split('\n');

        for (int i = 0; i < lines.Length - 1; i++)
        {
            string l1 = lines[i].Trim();
            string l2 = lines[i + 1].Trim();

            if (CanFuse(l1, l2, out string fused))
            {
                pairs.Add(new FusionPair
                {
                    Inst1 = l1,
                    Inst2 = l2,
                    FusedInst = fused,
                    IsFusable = true
                });
            }
            else
            {
                pairs.Add(new FusionPair { Inst1 = l1, Inst2 = l2, IsFusable = false });
            }
        }

        return pairs;
    }

    public int CountFusionSavings(List<FusionPair> pairs)
    {
        return pairs.Count(p => p.IsFusable);
    }
}
