using BPlus.Core.Ast;

namespace BPlus.Core.Mir;

// Rust: MIR — Mid-level Intermediate Representation
// Graph of states with explicit edges, phi-nodes, and liveness info.
// All optimizations operate on MIR; generators consume lowered MIR.

public class MirProgram
{
    public string Name { get; set; } = "";
    public List<MirBlock> Blocks { get; } = new();
    public List<MirEdge> Edges { get; } = new();
    public Dictionary<string, MirValue> Values { get; } = new();
    public Dictionary<string, HashSet<string>> Liveness { get; set; } = new();
}

public enum MirOpcode
{
    Enter, Exit, Transition, Guard, Assign, Call,
    Phi, Return, Error, Defer, ErrDefer,
    Alloc, Free, Load, Store,
    Branch, Switch
}

public class MirBlock
{
    public string Name { get; set; } = "";
    public StateDefNode? Source { get; set; }
    public List<MirInst> Instructions { get; } = new();
    public List<string> LiveIn { get; set; } = new();
    public List<string> LiveOut { get; set; } = new();
    public int Depth { get; set; }
}

public class MirEdge
{
    public string From { get; set; } = "";
    public string To { get; set; } = "";
    public string? Guard { get; set; }
    public double? HotWeight { get; set; }
    public string? EventName { get; set; }
    public bool IsError { get; set; }
}

public class MirInst
{
    public MirOpcode Opcode { get; set; }
    public string? Dest { get; set; }
    public List<string> Args { get; } = new();
    public Dictionary<string, string> Attrs { get; } = new();
}

public class MirValue
{
    public string Name { get; set; } = "";
    public string Type { get; set; } = "";
    public bool IsPhi { get; set; }
    public List<string> PhiSources { get; } = new();
}

public static class MirBuilder
{
    public static MirProgram Build(ProgramNode program)
    {
        var mir = new MirProgram { Name = program.Imports.Count > 0 ? "imported" : "main" };

        foreach (var state in program.States)
            BuildBlock(mir, state);

        foreach (var state in program.States)
            BuildEdges(mir, state);

        ComputeLiveness(mir);
        return mir;
    }

    private static void BuildBlock(MirProgram mir, StateDefNode state)
    {
        var block = new MirBlock
        {
            Name = state.Name,
            Source = state,
            Depth = state.Depth
        };

        foreach (var v in state.Variables)
            block.Instructions.Add(new MirInst
            {
                Opcode = MirOpcode.Alloc,
                Dest = v.Name,
                Attrs = { ["type"] = v.Type, ["fast_path"] = v.IsFastPath.ToString() }
            });

        foreach (var a in state.Actions.Where(a => a.Type == ActionType.Enter))
            block.Instructions.Add(new MirInst
            {
                Opcode = MirOpcode.Enter,
                Args = { a.Body }
            });

        foreach (var t in state.Transitions)
        {
            if (t.Guard != null)
            {
                block.Instructions.Add(new MirInst
                {
                    Opcode = MirOpcode.Guard,
                    Args = { t.Guard, t.Target }
                });
            }

            if (t.Body != null)
            {
                block.Instructions.Add(new MirInst
                {
                    Opcode = MirOpcode.Call,
                    Args = { t.Body }
                });
            }

            if (t.IsFallible)
            {
                block.Instructions.Add(new MirInst
                {
                    Opcode = MirOpcode.Error,
                    Args = { t.ErrorTarget ?? t.Target },
                    Attrs = { ["error_type"] = t.ErrorType ?? "string" }
                });
            }
        }

        // Error transitions
        foreach (var et in state.ErrorTransitions)
        {
            block.Instructions.Add(new MirInst
            {
                Opcode = MirOpcode.Error,
                Dest = et.OkTarget,
                Args = { et.ErrorTarget, et.ErrorBody ?? "" },
                Attrs = { ["event"] = et.EventName, ["error_type"] = et.ErrorType ?? "string" }
            });
        }

        foreach (var a in state.Actions.Where(a => a.Type == ActionType.Exit))
            block.Instructions.Add(new MirInst
            {
                Opcode = MirOpcode.Exit,
                Args = { a.Body }
            });

        foreach (var ns in state.NestedStates)
            BuildBlock(mir, ns);

        mir.Blocks.Add(block);
    }

    private static void BuildEdges(MirProgram mir, StateDefNode state)
    {
        foreach (var t in state.Transitions)
        {
            mir.Edges.Add(new MirEdge
            {
                From = state.Name,
                To = t.Target,
                Guard = t.Guard,
                HotWeight = t.HotWeight,
                EventName = t.EventName,
                IsError = t.IsFallible
            });

            if (t.IsFallible && t.ErrorTarget != null)
            {
                mir.Edges.Add(new MirEdge
                {
                    From = state.Name,
                    To = t.ErrorTarget,
                    Guard = null,
                    HotWeight = 0.01,
                    IsError = true
                });
            }
        }

        foreach (var et in state.ErrorTransitions)
        {
            mir.Edges.Add(new MirEdge
            {
                From = state.Name,
                To = et.OkTarget,
                Guard = et.Guard,
                EventName = et.EventName,
                IsError = false
            });
            mir.Edges.Add(new MirEdge
            {
                From = state.Name,
                To = et.ErrorTarget,
                IsError = true
            });
        }

        foreach (var ns in state.NestedStates)
            BuildEdges(mir, ns);
    }

    // Rust: NLL-style liveness analysis on CFG
    public static void ComputeLiveness(MirProgram mir)
    {
        var liveness = new Dictionary<string, HashSet<string>>();
        var blockIndex = mir.Blocks.ToDictionary(b => b.Name, b => b);

        foreach (var block in mir.Blocks)
        {
            var live = new HashSet<string>();
            foreach (var edge in mir.Edges.Where(e => e.From == block.Name))
                if (blockIndex.ContainsKey(edge.To))
                    live.UnionWith(blockIndex[edge.To].LiveIn);

            block.LiveOut = live.ToList();

            var liveIn = new HashSet<string>(live);
            for (int i = block.Instructions.Count - 1; i >= 0; i--)
            {
                var inst = block.Instructions[i];
                if (inst.Dest != null)
                    liveIn.Remove(inst.Dest);
                foreach (var arg in inst.Args)
                    if (!arg.StartsWith("\"") && !int.TryParse(arg, out _))
                        liveIn.Add(arg);
            }
            block.LiveIn = liveIn.ToList();
            liveness[block.Name] = liveIn;
        }

    mir.Liveness = liveness;
    }
}

// Rust: NLL liveness result per state
public class LivenessResult
{
    public string StateName { get; set; } = "";
    public HashSet<string> LiveVars { get; } = new();
    public HashSet<string> DeadOnExit { get; } = new();
    public List<LivenessPoint> Points { get; } = new();
}

public class LivenessPoint
{
    public int InstructionIndex { get; set; }
    public MirOpcode Opcode { get; set; }
    public HashSet<string> LiveBefore { get; } = new();
    public HashSet<string> LiveAfter { get; } = new();
    public HashSet<string> Born { get; } = new();
    public HashSet<string> Die { get; } = new();
}

// Go: escape analysis result
public enum EscapeKind { Stack, Pool, Heap }

// Haskell: demand signature
public class DemandSignature
{
    public bool IsStrict { get; set; }         // definitely evaluated
    public bool IsUsed { get; set; }           // definitely used
    public bool IsCalled { get; set; }         // definitely called (functions)
    public int CallCount { get; set; }          // how many times (0=absent, 1=once, 2+=many)
    public bool IsPoly { get; set; }            // polymorphic demand
}

// Vale: region info
public class RegionInfo
{
    public string Name { get; set; } = "";
    public HashSet<string> OwnedStates { get; } = new();
    public HashSet<string> OwnedVars { get; } = new();
    public List<string> Transfers { get; } = new(); // state names this region transfers to
}
