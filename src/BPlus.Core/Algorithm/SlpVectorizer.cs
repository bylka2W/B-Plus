namespace BPlus.Core.Algorithm;

public class SlpVectorizer
{
    public class SlpGroup
    {
        public List<string> Scalars { get; set; } = new();
        public string Vectorized { get; set; } = "";
        public int Width { get; set; }
    }

    public class SlpResult
    {
        public List<SlpGroup> Groups { get; set; } = new();
        public int ScalarOps { get; set; }
        public int VectorOps { get; set; }
        public double EstSpeedup { get; set; }
    }

    public SlpResult Analyze(string[] stmts)
    {
        var result = new SlpResult();
        var groups = new List<SlpGroup>();

        var sameOps = new Dictionary<string, List<string>>();
        foreach (var s in stmts)
        {
            string op = ExtractOp(s);
            if (string.IsNullOrEmpty(op)) continue;
            if (!sameOps.ContainsKey(op)) sameOps[op] = new List<string>();
            sameOps[op].Add(s);
        }

        foreach (var kvp in sameOps)
        {
            if (kvp.Value.Count >= 2)
            {
                groups.Add(new SlpGroup
                {
                    Scalars = kvp.Value,
                    Vectorized = kvp.Key,
                    Width = Math.Min(kvp.Value.Count, 8)
                });
                result.ScalarOps += kvp.Value.Count;
                result.VectorOps++;
            }
        }

        result.Groups = groups;
        result.EstSpeedup = result.ScalarOps > 0 ? (double)result.ScalarOps / Math.Max(1, result.VectorOps) : 1.0;

        return result;
    }

    private string ExtractOp(string stmt)
    {
        string lower = stmt.ToLower();
        if (lower.Contains("add") || lower.Contains("mul") || lower.Contains("sub"))
            return "arithmetic";
        if (lower.Contains("load") || lower.Contains("store"))
            return "memory";
        if (lower.Contains("cmp") || lower.Contains("test"))
            return "compare";
        return "";
    }

    public string GenerateHeader(SlpResult r)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// SLP (Superword-Level Parallelism) vectorizer");
        sb.AppendLine($"#define BPLUS_SLP_GROUPS {r.Groups.Count}");
        sb.AppendLine($"#define BPLUS_SLP_SPEEDUP {r.EstSpeedup:F1}");
        return sb.ToString();
    }
}
