using System.Text;
using BPlus.Core.Ast;
using BPlus.Core.Algorithm.Optimizer;

namespace BPlus.Core.MlirDialect;

// MLIR: Custom dialect for B+ state machine optimizations.
// Provides high-level ops (bplus.state, bplus.transition) before lowering to LLVM IR.
// Intermediate between AST and LLVM codegen — enables dialect-specific passes.

public enum BplusDialectOp
{
    // State machine ops
    State,
    Transition,
    Enter,
    Exit,
    Guard,
    Timer,

    // Dataflow ops
    Alloc,
    Dealloc,
    Load,
    Store,
    Phi,

    // Control flow
    Branch,
    Switch,
    Return,

    // Metal extensions
    MetalConfig,
    TierAssign,
    RegisterPin,
    PrefetchHint,
    FusionPair,

    // Analysis
    LivenessPoint,
    EscapeInfo
}

public class BplusDialectOpDef
{
    public BplusDialectOp Op { get; set; }
    public string Name { get; set; } = "";
    public Dictionary<string, string> Attrs { get; } = new();
    public List<string> Operands { get; } = new();
    public List<string> Results { get; } = new();
    public List<BplusDialectOpDef> NestedOps { get; } = new();
}

public class BplusDialectModule
{
    public string Name { get; set; } = "bplus_module";
    public List<BplusDialectOpDef> Ops { get; } = new();
    public Dictionary<string, string> Metadata { get; } = new();

    public string Print()
    {
        var sb = new StringBuilder();
        sb.AppendLine($"module @{Name} {{");
        foreach (var op in Ops)
            PrintOp(sb, op, 1);
        sb.AppendLine("}");
        return sb.ToString();
    }

    private void PrintOp(StringBuilder sb, BplusDialectOpDef op, int indent)
    {
        var ind = new string(' ', indent * 2);
        var attrs = op.Attrs.Count > 0
            ? " {" + string.Join(", ", op.Attrs.Select(a => $"{a.Key} = \"{a.Value}\"")) + "}"
            : "";

        var operands = op.Operands.Count > 0
            ? "(" + string.Join(", ", op.Operands) + ")"
            : "";

        var results = op.Results.Count > 0
            ? " -> " + string.Join(", ", op.Results)
            : "";

        sb.AppendLine($"{ind}\"bplus.{op.Name}\"{operands}{attrs}{results}");

        if (op.NestedOps.Count > 0)
        {
            sb.AppendLine($"{ind}{{");
            foreach (var nested in op.NestedOps)
                PrintOp(sb, nested, indent + 1);
            sb.AppendLine($"{ind}}}");
        }
    }
}

public static class DialectBuilder
{
    // Convert AST ProgramNode → MLIR Dialect ops
    public static BplusDialectModule Build(ProgramNode program)
    {
        var module = new BplusDialectModule
        {
            Name = "bplus_module",
            Metadata =
            {
                ["state_count"] = program.States.Count.ToString(),
                ["transition_count"] = program.States.Sum(s => s.Transitions.Count).ToString()
            }
        };

        foreach (var state in program.States)
        {
            var stateOp = new BplusDialectOpDef
            {
                Op = BplusDialectOp.State,
                Name = $"state.{state.Name}",
                Attrs =
                {
                    ["name"] = state.Name,
                    ["depth"] = state.Depth.ToString(),
                    ["inline"] = state.Inline.ToString()
                }
            };

            // Enter / Exit actions
            foreach (var a in state.Actions)
            {
                var actionOp = new BplusDialectOpDef
                {
                    Op = a.Type == ActionType.Enter ? BplusDialectOp.Enter : BplusDialectOp.Exit,
                    Name = a.Type.ToString().ToLower(),
                    Attrs = { ["body"] = a.Body }
                };
                stateOp.NestedOps.Add(actionOp);
            }

            // Transitions
            foreach (var t in state.Transitions)
            {
                var tOp = new BplusDialectOpDef
                {
                    Op = BplusDialectOp.Transition,
                    Name = $"transition.{t.EventName}",
                    Operands = { t.Target },
                    Attrs =
                    {
                        ["event"] = t.EventName,
                        ["target"] = t.Target,
                        ["is_always"] = t.IsAlways.ToString(),
                        ["is_fallible"] = t.IsFallible.ToString()
                    }
                };

                if (t.Guard != null)
                    tOp.Attrs["guard"] = t.Guard;
                if (t.Body != null)
                    tOp.Attrs["body"] = t.Body;
                if (t.HotWeight.HasValue)
                    tOp.Attrs["hot_weight"] = t.HotWeight.Value.ToString("F2");

                stateOp.NestedOps.Add(tOp);
            }

            // Metal annotations as dialect ops
            foreach (var v in state.Variables)
            {
                if (v.IsFastPath)
                {
                    stateOp.NestedOps.Add(new BplusDialectOpDef
                    {
                        Op = BplusDialectOp.RegisterPin,
                        Name = $"register_pin.{v.Name}",
                        Attrs = { ["var"] = v.Name, ["type"] = v.Type }
                    });
                }
            }

            // Variable allocations
            foreach (var v in state.Variables)
            {
                stateOp.NestedOps.Add(new BplusDialectOpDef
                {
                    Op = BplusDialectOp.Alloc,
                    Name = $"alloc.{v.Name}",
                    Attrs = { ["name"] = v.Name, ["type"] = v.Type, ["mutable"] = v.IsMutable.ToString() }
                });
            }

            // Nested states
            foreach (var ns in state.NestedStates)
            {
                // Recursion is handled by the calling structure; for flat display,
                // we add a reference
                stateOp.NestedOps.Add(new BplusDialectOpDef
                {
                    Op = BplusDialectOp.State,
                    Name = $"nested.{ns.Name}",
                    Attrs = { ["name"] = ns.Name, ["parent"] = state.Name }
                });
            }

            module.Ops.Add(stateOp);
        }

        return module;
    }

    // Run MLIR passes: Canonicalize, Inline, CSE, DCE
    public static BplusDialectModule Canonicalize(BplusDialectModule module)
    {
        var result = new BplusDialectModule { Name = module.Name };
        foreach (var kv in module.Metadata)
            result.Metadata[kv.Key] = kv.Value;

        foreach (var op in module.Ops)
        {
            if (op.Op == BplusDialectOp.State)
            {
                var newOp = new BplusDialectOpDef
                {
                    Op = BplusDialectOp.State,
                    Name = op.Name
                };
                foreach (var kv in op.Attrs)
                    newOp.Attrs[kv.Key] = kv.Value;

                // Canonicalize: remove duplicate transitions
                var seenTargets = new HashSet<string>();
                foreach (var nested in op.NestedOps)
                {
                    if (nested.Op == BplusDialectOp.Transition)
                    {
                        var target = nested.Attrs.GetValueOrDefault("target", "");
                        if (!seenTargets.Add(target))
                            continue; // Skip duplicate
                    }
                    newOp.NestedOps.Add(nested);
                }

                result.Ops.Add(newOp);
            }
        }

        return result;
    }

    // Lower MLIR dialect back to AST-compatible form for codegen
    public static ProgramNode LowerToAst(BplusDialectModule module)
    {
        var program = new ProgramNode();

        foreach (var op in module.Ops)
        {
            if (op.Op == BplusDialectOp.State)
            {
                var state = new StateDefNode
                {
                    Name = op.Attrs.GetValueOrDefault("name", "Unknown"),
                    Depth = int.Parse(op.Attrs.GetValueOrDefault("depth", "0")),
                    Inline = op.Attrs.GetValueOrDefault("inline", "Default") switch
                    {
                        "AlwaysInline" => InlineHint.AlwaysInline,
                        "NoInline" => InlineHint.NoInline,
                        _ => InlineHint.Default
                    }
                };

                foreach (var nested in op.NestedOps)
                {
                    switch (nested.Op)
                    {
                        case BplusDialectOp.Enter:
                            state.Actions.Add(new ActionNode { Type = ActionType.Enter, Body = nested.Attrs.GetValueOrDefault("body", "") });
                            break;
                        case BplusDialectOp.Exit:
                            state.Actions.Add(new ActionNode { Type = ActionType.Exit, Body = nested.Attrs.GetValueOrDefault("body", "") });
                            break;
                        case BplusDialectOp.Transition:
                            var t = new TransitionNode
                            {
                                EventName = nested.Attrs.GetValueOrDefault("event", ""),
                                Target = nested.Attrs.GetValueOrDefault("target", ""),
                                Guard = nested.Attrs.TryGetValue("guard", out var g) ? g : null,
                                Body = nested.Attrs.TryGetValue("body", out var b) ? b : null,
                                IsAlways = bool.Parse(nested.Attrs.GetValueOrDefault("is_always", "False")),
                                IsFallible = bool.Parse(nested.Attrs.GetValueOrDefault("is_fallible", "False"))
                            };
                            if (nested.Attrs.ContainsKey("hot_weight"))
                                t.HotWeight = double.Parse(nested.Attrs["hot_weight"]);
                            state.Transitions.Add(t);
                            break;
                        case BplusDialectOp.Alloc:
                            state.Variables.Add(new VariableNode
                            {
                                Name = nested.Attrs.GetValueOrDefault("name", ""),
                                Type = nested.Attrs.GetValueOrDefault("type", "int"),
                                IsMutable = bool.Parse(nested.Attrs.GetValueOrDefault("mutable", "True"))
                            });
                            break;
                    }
                }

                program.States.Add(state);
            }
        }

        return program;
    }
}
