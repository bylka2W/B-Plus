using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

// Rust: Polonius — Datalog-based borrow/region analysis
// For HiddenBufferOptimizer: instead of heuristics, use Datalog facts
// from AST to determine which states compete for LFB/TLB resources.

public class PoloniusFact
{
    public string Kind { get; set; } = ""; // "loan", "region", "point"
    public string Subject { get; set; } = "";
    public string Object { get; set; } = "";
}

public class PoloniusResult
{
    public string StateName { get; set; } = "";
    public HashSet<string> BorrowedVars { get; } = new();
    public HashSet<string> LoanedVars { get; } = new();
    public List<string> Conflicts { get; } = new(); // states with conflicting resource use
}

public static class PoloniusPass
{
    public static List<PoloniusResult> Run(ProgramNode program)
    {
        var facts = ExtractFacts(program);
        var results = new List<PoloniusResult>();
        var borrowedMap = new Dictionary<string, HashSet<string>>(); // state → borrowed vars

        foreach (var state in program.States)
        {
            var pr = new PoloniusResult { StateName = state.Name };

            foreach (var f in facts.Where(f => f.Subject == state.Name))
            {
                if (f.Kind == "borrow")
                    pr.BorrowedVars.Add(f.Object);
                else if (f.Kind == "loan")
                    pr.LoanedVars.Add(f.Object);
            }

            // Detect conflicts: two states borrowing overlapping resources
            foreach (var other in program.States)
            {
                if (other.Name == state.Name) continue;
                var otherBorrows = facts.Where(f => f.Subject == other.Name && f.Kind == "borrow")
                    .Select(f => f.Object).ToHashSet();

                if (pr.BorrowedVars.Overlaps(otherBorrows))
                    pr.Conflicts.Add(other.Name);
            }

            results.Add(pr);
        }

        return results;
    }

    private static List<PoloniusFact> ExtractFacts(ProgramNode program)
    {
        var facts = new List<PoloniusFact>();

        foreach (var state in program.States)
        {
            // Each variable in a state is a "loan" from the state to its transitions
            foreach (var v in state.Variables)
            {
                facts.Add(new PoloniusFact
                {
                    Kind = "loan",
                    Subject = state.Name,
                    Object = v.Name
                });
            }

            // Each transition that reads a variable "borrows" it
            foreach (var t in state.Transitions)
            {
                if (t.Body == null) continue;
                foreach (var v in state.Variables)
                {
                    if (t.Body.Contains(v.Name))
                    {
                        facts.Add(new PoloniusFact
                        {
                            Kind = "borrow",
                            Subject = state.Name,
                            Object = v.Name
                        });
                    }
                }

                // NLL: point facts — variable is live at this transition point
                if (t.Guard != null && t.Guard.Contains("=="))
                {
                    facts.Add(new PoloniusFact
                    {
                        Kind = "point",
                        Subject = state.Name,
                        Object = $"{t.EventName}:guard"
                    });
                }
            }

            // Error transitions also borrow
            foreach (var et in state.ErrorTransitions)
            {
                facts.Add(new PoloniusFact
                {
                    Kind = "borrow",
                    Subject = state.Name,
                    Object = $"error:{et.ErrorType ?? "unknown"}"
                });
            }
        }

        return facts;
    }
}
