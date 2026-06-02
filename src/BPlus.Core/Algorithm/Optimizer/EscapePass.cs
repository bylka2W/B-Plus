using BPlus.Core.Ast;

namespace BPlus.Core.Algorithm.Optimizer;

// Go: Escape analysis — determine if variables escape their state scope
// If a variable does NOT escape the transition, it can live on the stack.
// If it escapes but stays within the state machine pool, use pool allocator.
// If it fully escapes (e.g., passed to external callback), use heap.

public static class EscapePass
{
    public static Dictionary<string, EscapeKind> Run(ProgramNode program)
    {
        var results = new Dictionary<string, EscapeKind>();

        foreach (var state in program.States)
            AnalyzeState(state, results);

        // Apply results back to AST
        foreach (var state in program.States)
        {
            foreach (var v in state.Variables)
            {
                if (results.TryGetValue(v.Name, out var kind))
                {
                    state.EscapeResults[v.Name] = kind;
                    // Auto-set fast_path for stack-allocated vars
                    if (kind == EscapeKind.Stack)
                        v.IsFastPath = true;
                }
            }
        }

        return results;
    }

    private static void AnalyzeState(StateDefNode state, Dictionary<string, EscapeKind> results)
    {
        foreach (var v in state.Variables)
        {
            var kind = EscapeKind.Stack; // default: stack

            // Check if variable appears in any transition body that passes it to another state
            foreach (var t in state.Transitions)
            {
                if (t.Body != null && t.Body.Contains(v.Name))
                {
                    // Variable is used in transition — check if it's passed to target
                    if (IsPassedToTarget(t, v.Name))
                    {
                        kind = UpgradeEscape(kind, EscapeKind.Pool);
                    }

                    // Check if it's used in a callback/external call
                    if (ContainsExternalCall(t.Body))
                    {
                        kind = UpgradeEscape(kind, EscapeKind.Heap);
                    }
                }
            }

            // Check error transitions
            foreach (var et in state.ErrorTransitions)
            {
                if ((et.OkBody != null && et.OkBody.Contains(v.Name)) ||
                    (et.ErrorBody != null && et.ErrorBody.Contains(v.Name)))
                {
                    kind = UpgradeEscape(kind, EscapeKind.Pool);
                }
            }

            // Variables marked as mutable and used outside → pool or heap
            if (v.IsAtomic)
                kind = EscapeKind.Heap;

            // Variables referenced in nested states → pool
            foreach (var ns in state.NestedStates)
            {
                if (ReferencesVariable(ns, v.Name))
                    kind = UpgradeEscape(kind, EscapeKind.Pool);
            }

            results[v.Name] = kind;
        }
    }

    private static bool IsPassedToTarget(TransitionNode t, string varName)
    {
        if (t.Body == null) return false;
        // Check if variable is in the return/new expression
        return t.Body.Contains($"->{t.Target}") && t.Body.Contains(varName)
            || t.Body.Contains($"new {t.Target}") && t.Body.Contains(varName);
    }

    private static bool ContainsExternalCall(string body)
    {
        var externalHints = new[] { "extern ", "callback", "delegate", "Func<", "Action<", "Task<" };
        return externalHints.Any(h => body.Contains(h));
    }

    private static bool ReferencesVariable(StateDefNode state, string varName)
    {
        foreach (var t in state.Transitions)
            if (t.Body != null && t.Body.Contains(varName))
                return true;
        foreach (var a in state.Actions)
            if (a.Body.Contains(varName))
                return true;
        return false;
    }

    private static EscapeKind UpgradeEscape(EscapeKind current, EscapeKind upgrade)
    {
        if ((int)upgrade > (int)current) return upgrade;
        return current;
    }
}
