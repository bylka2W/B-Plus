using BPlus.Core.Ast;

namespace BPlus.Core.Parser;

// Swift: @resultBuilder — transform a block of code into a builder pattern
// For enter{} blocks: the compiler sees what actions the user constructs
// and can reorder them for cache efficiency.
//
// Usage in .bp:
//   enter {
//     @resultBuilder
//     let actions = ActionBuilder.build {
//       loadData()
//       processState()
//       storeResult()
//     }
//     // Compiler can reorder: storeResult ↓ loadData ↑ if data is already cached
//   }

public static class ResultBuilder
{
    // Build a list of actions from a block body, with reordering analysis
    public static List<ResultBuilderExpr> Build(string blockBody)
    {
        var exprs = new List<ResultBuilderExpr>();

        var lines = blockBody.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        foreach (var line in lines)
        {
            var trimmed = line.Trim().TrimEnd(';');
            if (string.IsNullOrEmpty(trimmed) || trimmed.StartsWith("//"))
                continue;

            var reads = ExtractReads(trimmed);
            var writes = ExtractWrites(trimmed);
            var expr = new ResultBuilderExpr
            {
                Raw = trimmed,
                Type = ClassifyExpression(trimmed),
                Allocates = trimmed.Contains("new ") || trimmed.Contains("alloc"),
                IsVolatile = trimmed.Contains("volatile") || trimmed.Contains("atomic")
            };
            foreach (var r in reads) expr.Reads.Add(r);
            foreach (var w in writes) expr.Writes.Add(w);
            exprs.Add(expr);
        }

        // Reorder for cache efficiency: writes after reads by default,
        // but if a write produces data that a later read needs, keep order.
        ReorderForCache(exprs);

        return exprs;
    }

    public enum BuilderExprType { Load, Store, Call, Alloc, Guard, Nop }

    public class ResultBuilderExpr
    {
        public string Raw { get; set; } = "";
        public BuilderExprType Type { get; set; }
        public HashSet<string> Reads { get; } = new();
        public HashSet<string> Writes { get; } = new();
        public bool IsVolatile { get; set; }
        public bool Allocates { get; set; }
        public int OriginalIndex { get; set; }
    }

    private static BuilderExprType ClassifyExpression(string expr)
    {
        if (expr.Contains('=') || expr.Contains("store") || expr.Contains("write"))
            return BuilderExprType.Store;
        if (expr.Contains("load") || expr.Contains("read") || expr.Contains("fetch"))
            return BuilderExprType.Load;
        if (expr.Contains("new ") || expr.Contains("alloc") || expr.Contains("malloc"))
            return BuilderExprType.Alloc;
        if (expr.Contains("if ") || expr.Contains("guard") || expr.Contains("check"))
            return BuilderExprType.Guard;
        if (expr.Contains('('))
            return BuilderExprType.Call;
        return BuilderExprType.Nop;
    }

    private static HashSet<string> ExtractReads(string expr)
    {
        var reads = new HashSet<string>();
        // Simple extraction: words before '=' or in function args
        var parts = expr.Split('=');
        if (parts.Length > 1)
        {
            // RHS contains reads
            foreach (var word in parts[1].Split(new[] { ' ', '(', ')', ',', ';' }, StringSplitOptions.RemoveEmptyEntries))
                if (IsVariable(word) && !IsKeyword(word))
                    reads.Add(word);
        }
        return reads;
    }

    private static HashSet<string> ExtractWrites(string expr)
    {
        var writes = new HashSet<string>();
        var parts = expr.Split('=');
        if (parts.Length > 1)
        {
            var lhs = parts[0].Trim();
            if (IsVariable(lhs))
                writes.Add(lhs);
        }
        if (expr.Contains("store") || expr.Contains("write"))
        {
            foreach (var word in expr.Split(new[] { ' ', '(', ')', ',', ';' }, StringSplitOptions.RemoveEmptyEntries))
                if (IsVariable(word) && !IsKeyword(word))
                    writes.Add(word);
        }
        return writes;
    }

    // Reorder for cache: move independent loads earlier, stores later
    private static void ReorderForCache(List<ResultBuilderExpr> exprs)
    {
        bool changed;
        do
        {
            changed = false;
            for (int i = 0; i < exprs.Count - 1; i++)
            {
                var a = exprs[i];
                var b = exprs[i + 1];

                // Can swap if no data dependency and better cache ordering
                if (a.Type == BuilderExprType.Store && b.Type == BuilderExprType.Load
                    && !a.Writes.Overlaps(b.Reads) && !a.IsVolatile && !b.IsVolatile)
                {
                    // Load before store is better for cache (reduce stall)
                    (exprs[i], exprs[i + 1]) = (exprs[i + 1], exprs[i]);
                    changed = true;
                }

                // Move allocs to the beginning of the block
                if (b.Allocates && !a.Allocates && !a.IsVolatile)
                {
                    (exprs[i], exprs[i + 1]) = (exprs[i + 1], exprs[i]);
                    changed = true;
                }
            }
        } while (changed);
    }

    private static bool IsVariable(string word) =>
        word.Length > 0 && char.IsLetter(word[0]) && word.All(c => char.IsLetterOrDigit(c) || c == '_');

    private static bool IsKeyword(string word) => word.ToLower() switch
    {
        "if" or "else" or "for" or "while" or "do" or "switch" or "case" or "return"
        or "new" or "delete" or "alloc" or "free"
        or "int" or "float" or "double" or "bool" or "char" or "void" or "string"
        or "load" or "store" or "read" or "write" or "fetch" => true,
        _ => false
    };

    // Generate reordered code from builder result
    public static string GenerateReordered(List<ResultBuilderExpr> exprs)
    {
        var lines = new List<string>();
        foreach (var e in exprs)
        {
            var comment = e.Type switch
            {
                BuilderExprType.Load => " // cache: load early",
                BuilderExprType.Store => " // cache: store late",
                BuilderExprType.Alloc => " // cache: alloc first",
                _ => ""
            };
            lines.Add($"    {e.Raw};{comment}");
        }
        return string.Join("\n", lines);
    }
}

// Extension: parse enter{} block with result builder
public static class ResultBuilderExtensions
{
    public static List<string> ParseWithResultBuilder(this string blockBody)
    {
        var exprs = ResultBuilder.Build(blockBody);
        return exprs.Select(e => e.Raw).ToList();
    }

    public static string ReorderWithResultBuilder(this string blockBody)
    {
        var exprs = ResultBuilder.Build(blockBody);
        return ResultBuilder.GenerateReordered(exprs);
    }
}
