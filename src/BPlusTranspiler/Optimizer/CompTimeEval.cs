using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

// Zig comptime: evaluate Metal annotations at compile time
// Metal annotations (@tier, @zmm, @align) are evaluated statically
// and folded into the state graph before code generation.
// This replaces runtime parsing of annotation strings with compile-time constants.

public class CompTimeValue
{
    public bool IsConstant { get; set; }
    public string? StringValue { get; set; }
    public long? IntValue { get; set; }
    public double? FloatValue { get; set; }
    public bool? BoolValue { get; set; }

    public static CompTimeValue FromString(string s) => new()
    {
        IsConstant = true,
        StringValue = s,
        IntValue = long.TryParse(s, out var n) ? n : null,
        FloatValue = double.TryParse(s, out var f) ? f : null,
        BoolValue = bool.TryParse(s, out var b) ? b : null
    };
}

public class CompTimeEnv
{
    public Dictionary<string, CompTimeValue> Vars { get; } = new();
    public List<CompTimeOp> Ops { get; } = new();

    public void Set(string key, CompTimeValue val) => Vars[key] = val;

    public CompTimeValue? Get(string key) => Vars.GetValueOrDefault(key);

    public long EvalInt(string key, long fallback = 0)
    {
        var v = Get(key);
        return v?.IntValue ?? fallback;
    }

    public bool EvalBool(string key, bool fallback = false)
    {
        var v = Get(key);
        return v?.BoolValue ?? fallback;
    }

    // Evaluate at compile time — unroll transition table for N states
    public List<CompTimeResult> Eval(ProgramNode program)
    {
        var results = new List<CompTimeResult>();

        foreach (var state in program.States)
        {
            var r = new CompTimeResult { StateName = state.Name };

            // Inline all constant annotations
            foreach (var v in state.Variables)
            {
                if (v.DefaultValue != null && long.TryParse(v.DefaultValue, out var _))
                    r.Constants[v.Name] = CompTimeValue.FromString(v.DefaultValue);
            }

            // Evaluate inline hint
            r.Inline = state.Inline switch
            {
                InlineHint.AlwaysInline => "alwaysinline",
                InlineHint.NoInline => "noinline",
                _ => "default"
            };

            // Evaluate ownership
            r.Ownership = state.Ownership switch
            {
                OwnershipHint.Owned => "owned",
                OwnershipHint.Borrowed => "borrowed",
                _ => "default"
            };

            // Unroll transitions
            r.TransitionCount = state.Transitions.Count;
            foreach (var t in state.Transitions)
            {
                var tResult = new CompTimeTransitionResult
                {
                    EventName = t.EventName,
                    Target = t.Target,
                    IsFallible = t.IsFallible,
                    ErrorType = t.ErrorType
                };

                if (t.HotWeight.HasValue)
                    tResult.HotWeight = t.HotWeight.Value;

                r.Transitions.Add(tResult);
            }

            // Error transitions
            foreach (var et in state.ErrorTransitions)
            {
                var tResult = new CompTimeTransitionResult
                {
                    EventName = et.EventName,
                    Target = et.OkTarget,
                    ErrorType = et.ErrorType,
                    IsFallible = true
                };
                r.Transitions.Add(tResult);
            }

            results.Add(r);
        }

        return results;
    }
}

public class CompTimeOp
{
    public string Op { get; set; } = ""; // "unroll", "inline", "specialize"
    public string Target { get; set; } = "";
    public Dictionary<string, string> Args { get; } = new();
}

public class CompTimeResult
{
    public string StateName { get; set; } = "";
    public Dictionary<string, CompTimeValue> Constants { get; } = new();
    public string Inline { get; set; } = "default";
    public string Ownership { get; set; } = "default";
    public int TransitionCount { get; set; }
    public List<CompTimeTransitionResult> Transitions { get; } = new();
}

public class CompTimeTransitionResult
{
    public string EventName { get; set; } = "";
    public string Target { get; set; } = "";
    public bool IsFallible { get; set; }
    public string? ErrorType { get; set; }
    public double HotWeight { get; set; } = 0.5;
}

// Extension methods for applying comptime results back to AST
public static class CompTimeExtensions
{
    public static void ApplyCompTimeEval(this ProgramNode program, List<CompTimeResult> results)
    {
        foreach (var r in results)
        {
            var state = program.States.Find(s => s.Name == r.StateName);
            if (state == null) continue;

            // Apply comptime-determined ownership
            if (r.Ownership == "owned") state.Ownership = OwnershipHint.Owned;
            else if (r.Ownership == "borrowed") state.Ownership = OwnershipHint.Borrowed;

            // Apply comptime-determined inline
            if (r.Inline == "alwaysinline") state.Inline = InlineHint.AlwaysInline;
            else if (r.Inline == "noinline") state.Inline = InlineHint.NoInline;
        }
    }
}
