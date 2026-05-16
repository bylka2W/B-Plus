namespace BPlusTranspiler.AI;

public class ConstantFolder
{
    public class FoldResult
    {
        public string Original { get; set; } = "";
        public string Optimized { get; set; } = "";
        public bool WasFolded { get; set; }
        public int FoldsCount { get; set; }
    }

    private static readonly (string from, string to)[] FoldingRules =
    {
        ("0 + x", "x"), ("x + 0", "x"), ("1 * x", "x"), ("x * 1", "x"),
        ("0 * x", "0"), ("x / 1", "x"), ("x ^ 0", "1"), ("x & 0", "0"),
        ("x | 0", "x"), ("x << 0", "x"), ("x >> 0", "x"), ("x * 2", "x + x"),
        ("x * 4", "x << 2"), ("x * 8", "x << 3"), ("x / 2", "x >> 1"),
        ("a + a", "a * 2"), ("a - a", "0"), ("a * a", "a ^ 2")
    };

    public FoldResult Fold(string expr)
    {
        var result = new FoldResult { Original = expr };
        string optimized = expr;

        foreach (var (from, to) in FoldingRules)
        {
            string pattern = from.Replace("x", "X").Replace("a", "A");
            string fromPattern = from;

            if (optimized.Contains(fromPattern))
            {
                optimized = optimized.Replace(fromPattern, to);
                result.WasFolded = true;
                result.FoldsCount++;
            }
        }

        result.Optimized = optimized;
        return result;
    }

    public string GenerateHeader(int foldCount)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// Constant folding");
        sb.AppendLine($"#define BPLUS_CONSTANT_FOLDS {foldCount}");
        sb.AppendLine();
        sb.AppendLine("// Fold rules:");
        sb.AppendLine("// 0 + x -> x, 1 * x -> x, x * 2 -> x + x");
        sb.AppendLine("// x * 4 -> x << 2, x / 2 -> x >> 1");
        return sb.ToString();
    }
}

public class DeadCodeEliminator
{
    public class DceResult
    {
        public int RemovedCount { get; set; }
        public int KeptCount { get; set; }
        public List<string> Removed { get; set; } = new();
    }

    public DceResult Eliminate(string[] stmts)
    {
        var result = new DceResult();

        foreach (var s in stmts)
        {
            string lower = s.ToLower();
            bool isDead = lower.Contains("// dead") || lower.Contains("unreachable")
                       || lower.Contains("result unused") || lower.Contains("debug_print");

            if (isDead)
            {
                result.Removed.Add(s);
                result.RemovedCount++;
            }
            else
            {
                result.KeptCount++;
            }
        }

        return result;
    }
}

public class LicmOptimizer
{
    public class LicmResult
    {
        public int HoistedCount { get; set; }
        public int InvariantsCount { get; set; }
        public List<string> Hoisted { get; set; } = new();
    }

    private static readonly string[] InvariantPatterns = { "const", "sqrt", "sin", "cos", "exp", "log", "div" };

    public LicmResult Analyze(string[] stmts)
    {
        var result = new LicmResult();

        foreach (var s in stmts)
        {
            bool isInvariant = false;
            foreach (var p in InvariantPatterns)
            {
                if (s.ToLower().Contains(p))
                {
                    isInvariant = true;
                    result.InvariantsCount++;
                    break;
                }
            }

            if (isInvariant)
                result.Hoisted.Add(s);
        }

        result.HoistedCount = result.Hoisted.Count;
        return result;
    }
}

public class StrengthReducer
{
    public class ReductionResult
    {
        public int MulToShift { get; set; }
        public int DivToShift { get; set; }
        public int MulToAdd { get; set; }
        public List<string> Replacements { get; set; } = new();
    }

    private static readonly (string from, string to)[] StrengthRules =
    {
        ("x * 2", "x << 1"), ("x * 4", "x << 2"), ("x * 8", "x << 3"), ("x * 16", "x << 4"),
        ("x / 2", "x >> 1"), ("x / 4", "x >> 2"), ("x / 8", "x >> 3"),
        ("x * 3", "(x << 1) + x"), ("x * 5", "(x << 2) + x"), ("x * 9", "(x << 3) + x")
    };

    public ReductionResult Reduce(string[] stmts)
    {
        var result = new ReductionResult();

        foreach (var s in stmts)
        {
            foreach (var (from, to) in StrengthRules)
            {
                if (s.Contains(from))
                {
                    result.Replacements.Add($"{from} -> {to}");
                    if (from.Contains("*")) result.MulToShift++;
                    else if (from.Contains("/")) result.DivToShift++;
                }
            }
        }

        return result;
    }
}