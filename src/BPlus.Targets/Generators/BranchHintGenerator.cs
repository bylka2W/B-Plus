using System.Text;
using BPlus.Core.Ast;

namespace BPlus.Targets.Generators;

public enum BranchPrediction
{
    Taken,
    NotTaken,
    Dynamic,
    BTFNT
}

public class BranchHint
{
    public string? TargetLabel { get; set; }
    public BranchPrediction Prediction { get; set; } = BranchPrediction.Dynamic;
    public double Probability { get; set; } = 0.5;
}

public static class BranchHintGenerator
{
    private static readonly Dictionary<BranchPrediction, string> HintPrefixes = new()
    {
        [BranchPrediction.Taken] = "3E",     // DS segment override = branch taken (GAS)
        [BranchPrediction.NotTaken] = "2E",   // CS segment override = branch not taken
        [BranchPrediction.Dynamic] = "",
        [BranchPrediction.BTFNT] = "2E",
    };

    private static readonly string[] CondJumps =
        ["je", "jne", "jg", "jl", "jge", "jle", "ja", "jb", "jae", "jbe",
         "jz", "jnz", "jo", "jno", "js", "jns", "jp", "jnp", "jecxz", "jrcxz"];

    public static List<BranchHint> ExtractHints(StateDefNode state)
    {
        var hints = new List<BranchHint>();

        foreach (var t in state.Transitions)
        {
            var hint = new BranchHint
            {
                TargetLabel = t.Target,
            };

            if (t.HotWeight.HasValue)
            {
                if (t.HotWeight.Value >= 0.8)
                {
                    hint.Prediction = BranchPrediction.Taken;
                    hint.Probability = t.HotWeight.Value;
                }
                else if (t.HotWeight.Value <= 0.2)
                {
                    hint.Prediction = BranchPrediction.NotTaken;
                    hint.Probability = t.HotWeight.Value;
                }
                else
                {
                    hint.Prediction = BranchPrediction.Dynamic;
                    hint.Probability = t.HotWeight.Value;
                }
            }
            else if (t.Guard != null)
            {
                hint.Prediction = BranchPrediction.Dynamic;
                hint.Probability = 0.5;
            }

            hints.Add(hint);
        }

        return hints;
    }

    public static string ApplyBranchHints(string assembly, List<BranchHint> hints, bool useIntelSyntax = true)
    {
        if (hints.Count == 0) return assembly;

        var sb = new StringBuilder();
        var lines = assembly.Split('\n');

        foreach (var line in lines)
        {
            var trimmed = line.Trim();
            var isCondJump = CondJumps.Any(cj =>
                trimmed.StartsWith(cj, StringComparison.OrdinalIgnoreCase) ||
                trimmed.StartsWith($"\t{cj}", StringComparison.OrdinalIgnoreCase));

            if (isCondJump && hints.Count > 0)
            {
                var hint = hints[0];
                hints.RemoveAt(0);

                if (hint.Prediction == BranchPrediction.Taken)
                {
                    if (useIntelSyntax)
                        sb.AppendLine($"\tds prefix ; {line.Trim()} ; taken (p={hint.Probability:P0})");
                    else
                        sb.AppendLine($"\t.byte 0x3e ; branch taken prefix");
                    sb.AppendLine(line);
                }
                else if (hint.Prediction == BranchPrediction.NotTaken)
                {
                    if (useIntelSyntax)
                        sb.AppendLine($"\tcs prefix ; {line.Trim()} ; not taken (p={hint.Probability:P0})");
                    else
                        sb.AppendLine($"\t.byte 0x2e ; branch not taken prefix");
                    sb.AppendLine(line);
                }
                else
                {
                    sb.AppendLine(line);
                }
            }
            else
            {
                sb.AppendLine(line);
            }
        }

        return sb.ToString().TrimEnd();
    }

    public static string GeneratePredictAnnotation(BranchPrediction p, double prob = 0.5)
    {
        return p switch
        {
            BranchPrediction.Taken => $"@predict(taken, p={prob:F2})",
            BranchPrediction.NotTaken => $"@predict(not_taken, p={prob:F2})",
            BranchPrediction.BTFNT => $"@predict(btfnt)",
            _ => $"@predict(dynamic)"
        };
    }

    public static string Report(List<BranchHint> hints)
    {
        var sb = new StringBuilder();
        sb.AppendLine("=== Branch Prediction Hints ===");
        foreach (var h in hints)
        {
            sb.AppendLine($"  → {h.TargetLabel ?? "(unknown)"}: " +
                          $"{h.Prediction} (p={h.Probability:P0})");
        }
        return sb.ToString();
    }
}
