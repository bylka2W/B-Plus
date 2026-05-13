using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

public class StoreForwardResult
{
    public string StateName { get; set; } = "";
    public bool HasStoreForwardStall { get; set; }
    public string? Location { get; set; }
    public string? Fix { get; set; }
}

/// <summary>
/// Store forwarding penalty: if store and load access overlapping/same address 
/// at different sizes or misaligned → 10-15 cycle penalty.
/// </summary>
public class StoreForwardGuard
{
    public static List<StoreForwardResult> Analyze(ProgramNode program)
    {
        var results = new List<StoreForwardResult>();

        foreach (var state in program.States)
        {
            bool hasStore = false;
            bool hasLoad = false;
            string? lastStoreVar = null;
            string? lastLoadVar = null;

            foreach (var a in state.Actions)
            {
                if (a.Body.Contains("=") || a.Body.Contains("store") || a.Body.Contains("write"))
                {
                    hasStore = true;
                    lastStoreVar = a.Body;
                }
                else if (a.Body.Contains("load") || a.Body.Contains("read") || char.IsLower(a.Body[0]))
                {
                    hasLoad = true;
                    lastLoadVar = a.Body;
                }

                // If same variable store-then-load with different sizes → stall
                if (hasStore && hasLoad && lastStoreVar != null && lastLoadVar != null)
                {
                    // Heuristic: consecutive store then load of same var
                    if (lastStoreVar.Split('=')[0].Trim() == lastLoadVar)
                    {
                        results.Add(new StoreForwardResult
                        {
                            StateName = state.Name,
                            HasStoreForwardStall = true,
                            Location = $"{lastStoreVar} → {lastLoadVar}",
                            Fix = "Pad store to full-width (64-bit) before narrow load, or reorder to separate by 3+ instructions."
                        });
                    }
                }
            }
        }

        // If no issues detected, report clean
        if (results.Count == 0)
        {
            results.Add(new StoreForwardResult
            {
                StateName = program.States.FirstOrDefault()?.Name ?? "",
                HasStoreForwardStall = false,
                Location = "No store-forwarding hazards detected"
            });
        }

        return results;
    }

    public static string GenerateReport(List<StoreForwardResult> results)
    {
        var lines = new List<string>
        {
            "╔═══════════════════════════════════════╗",
            "║   STORE FORWARDING ANALYSIS          ║",
            "╚═══════════════════════════════════════╝"
        };

        foreach (var r in results)
        {
            if (r.HasStoreForwardStall)
                lines.Add($"  ⚠ {r.StateName}: {r.Location} — {r.Fix}");
            else if (r.Location != null)
                lines.Add($"  ✓ {r.Location}");
        }

        return string.Join("\n", lines);
    }
}