using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

// Julia: Abstract interpretation — infer data types in states without user annotations
// Propagates abstract values through the state graph to determine
// what types of data live in each state. This replaces manual @metal blocks.

public class AbstractValue
{
    public string Type { get; set; } = "unknown";
    public bool IsConstant { get; set; }
    public object? ConstantValue { get; set; }
    public HashSet<string> PossibleStates { get; } = new();
}

public class AbstractDomain
{
    public Dictionary<string, AbstractValue> Vars { get; } = new();
}

public static class TypeInferPass
{
    public static Dictionary<string, Dictionary<string, string>> Run(ProgramNode program)
    {
        var results = new Dictionary<string, Dictionary<string, string>>();

        foreach (var state in program.States)
        {
            var domain = new AbstractDomain();
            var stateTypes = new Dictionary<string, string>();

            foreach (var v in state.Variables)
            {
                var abs = new AbstractValue { Type = NormalizeType(v.Type) };
                if (v.DefaultValue != null)
                {
                    abs.IsConstant = true;
                    abs.ConstantValue = v.DefaultValue;
                }
                domain.Vars[v.Name] = abs;
                stateTypes[v.Name] = abs.Type;
            }

            // Propagate through transitions
            foreach (var t in state.Transitions)
            {
                if (t.Body != null)
                    PropagateThroughBody(domain, t.Body);

                if (t.Parameters.Count > 0)
                {
                    foreach (var p in t.Parameters)
                    {
                        if (!domain.Vars.ContainsKey(p.Name))
                        {
                            var abs = new AbstractValue { Type = NormalizeType(p.Type) };
                            domain.Vars[p.Name] = abs;
                            stateTypes[p.Name] = abs.Type;
                        }
                    }
                }
            }

            // Error transitions
            foreach (var et in state.ErrorTransitions)
            {
                if (et.ErrorType != null && !stateTypes.ContainsValue(et.ErrorType))
                {
                    var abs = new AbstractValue { Type = NormalizeType(et.ErrorType) };
                    domain.Vars["__error"] = abs;
                    stateTypes["__error"] = abs.Type;
                }
            }

            // Write inferred types back to state
            foreach (var kv in stateTypes)
            {
                state.InferredTypes[kv.Key] = kv.Value;
            }

            results[state.Name] = stateTypes;
        }

        return results;
    }

    private static void PropagateThroughBody(AbstractDomain domain, string body)
    {
        // Simple propagation: assignments update types
        var parts = body.Split('=');
        if (parts.Length == 2)
        {
            var lhs = parts[0].Trim();
            var rhs = parts[1].Trim();

            // Infer type from RHS
            string inferredType = InferTypeFromExpr(rhs);
            if (!domain.Vars.ContainsKey(lhs))
            {
                domain.Vars[lhs] = new AbstractValue { Type = inferredType };
            }
            else
            {
                // Widen type if needed
                var existing = domain.Vars[lhs];
                if (existing.Type != inferredType && existing.Type != "unknown")
                    existing.Type = WidenType(existing.Type, inferredType);
            }
        }
    }

    private static string InferTypeFromExpr(string expr)
    {
        if (expr.Contains(".") && double.TryParse(expr, out _)) return "f64";
        if (long.TryParse(expr, out _)) return "i64";
        if (bool.TryParse(expr, out _)) return "bool";
        if (expr.StartsWith("\"") && expr.EndsWith("\"")) return "string";
        if (expr.Contains("new ")) return expr.Split("new ")[1].Split('(')[0].Trim();
        return "unknown";
    }

    private static string NormalizeType(string type) => type.ToLower() switch
    {
        "int" or "i32" => "i32",
        "i64" or "long" => "i64",
        "float" or "f32" => "f32",
        "double" or "f64" => "f64",
        "bool" => "bool",
        "string" or "str" => "string",
        _ => type
    };

    private static string WidenType(string a, string b)
    {
        var order = new[] { "bool", "i32", "i64", "f32", "f64", "string" };
        var ia = Array.IndexOf(order, a);
        var ib = Array.IndexOf(order, b);
        if (ia < 0 && ib < 0) return "unknown";
        if (ia < 0) return b;
        if (ib < 0) return a;
        return order[Math.Max(ia, ib)];
    }
}
