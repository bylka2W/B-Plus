using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

public record OwnershipResult(string StateName, bool IsReadOnly, bool IsMut, bool IsTrivial, int PoolBytes);

public static class BPlusOptimizer
{
    public static ProgramNode Optimize(ProgramNode program, bool preElab = true, bool postElab = false)
    {
        if (preElab)
        {
            // Pre-elaboration: global DCE, guard folding, semantic inline
            var liveStates = ComputeLiveStates(program);
            RemoveDeadStates(program, liveStates);
            FoldGuards(program);
            SemanticInline(program);
            MoveOnLastUse(program);
        }

        if (postElab)
        {
            // Post-elaboration: tier-specialized passes
            InlineHotStates(program);
            OwnershipPass(program);
        }

        return program;
    }

    // ─── Mojo: InlineHotStates — inline L0-tier enter{} into dispatch ───
    public static void InlineHotStates(ProgramNode program)
    {
        foreach (var s in program.States)
        {
            bool isHot = s.Transitions.Any(t => t.HotWeight.HasValue && t.HotWeight.Value >= 0.8);
            if (!isHot || s.Actions.Count == 0) continue;

            // Inline enter/exit actions into each transition body
            var enterActions = s.Actions.Where(a => a.Type == ActionType.Enter).ToList();
            var exitActions = s.Actions.Where(a => a.Type == ActionType.Exit).ToList();

            foreach (var t in s.Transitions)
            {
                if (t.Body == null) continue;
                // Prepend exit actions and append enter actions to transition body
                var exitBodies = string.Join("; ", exitActions.Select(a => a.Body));
                var enterBodies = string.Join("; ", enterActions.Select(a => a.Body));
                t.Body = $"{exitBodies}; {t.Body}; {enterBodies}";
            }
        }
    }

    // ─── Mojo: Ownership analysis — detect read vs mut states ───
    public static List<OwnershipResult> OwnershipPass(ProgramNode program)
    {
        var results = new List<OwnershipResult>();
        foreach (var s in program.States)
        {
            bool hasWrites = s.Variables.Any(v => v.IsMutable);
            bool hasFields = s.Variables.Count > 0;

            // If state has @borrowed annotation or no variables, it's read-only
            bool isReadOnly = s.Ownership == OwnershipHint.Borrowed || !hasFields || !hasWrites;

            // Trivial: no variables, no actions, no timers — can pass as i8
            bool isTrivial = s.Variables.Count == 0 && s.Actions.Count == 0 && s.Timers.Count == 0;

            int poolBytes = s.Variables.Sum(v => v.Type.ToLower() switch
            {
                "int" or "i32" or "u32" or "float" => 4,
                "i64" or "u64" or "double" or "f64" => 8,
                "bool" => 1,
                _ => 4
            });

            results.Add(new OwnershipResult(s.Name, isReadOnly, hasWrites, isTrivial, poolBytes));
        }
        return results;
    }

    // ─── Mojo: MoveOnLastUse — reuse slot after transition ───
    public static void MoveOnLastUse(ProgramNode program)
    {
        foreach (var s in program.States)
        {
            // If a state transitions to another and has no more incoming refs,
            // mark all its variables as movable (register reuse)
            bool lastUse = s.Transitions.Any() && s.NestedStates.Count == 0;
            if (!lastUse) continue;

            // Mark all variables as fast-path candidates for register reuse
            foreach (var v in s.Variables)
            {
                if (!v.IsFastPath)
                {
                    v.IsFastPath = true; // promote to register
                }
            }
        }
    }

    // ─── Existing: SemanticInline ───
    public static void SemanticInline(ProgramNode program)
    {
        int chainId = 0;
        foreach (var startState in program.States)
            DetectChainFrom(program, startState, ref chainId);
    }

    private static void DetectChainFrom(ProgramNode program, StateDefNode start, ref int chainId)
    {
        if (start.ChainId != null) return;

        var hotTargets = start.Transitions
            .Where(t => t.HotWeight.HasValue && t.HotWeight.Value >= 0.5
                        && !string.IsNullOrEmpty(t.Target)
                        && FindState(program, t.Target) != null)
            .Select(t => t.Target)
            .Distinct()
            .ToList();

        if (hotTargets.Count != 1) return;

        var cid = $"chain_{chainId++}";
        start.ChainId = cid;

        var nextName = hotTargets[0];
        var next = FindState(program, nextName)!;
        next.ChainId = cid;
        ExtendChain(program, next, cid);
    }

    private static void ExtendChain(ProgramNode program, StateDefNode current, string cid)
    {
        var hotTargets = current.Transitions
            .Where(t => t.HotWeight.HasValue && t.HotWeight.Value >= 0.5
                        && !string.IsNullOrEmpty(t.Target)
                        && FindState(program, t.Target) is { ChainId: null })
            .Select(t => t.Target)
            .Distinct()
            .ToList();

        if (hotTargets.Count != 1) return;

        var next = FindState(program, hotTargets[0])!;
        next.ChainId = cid;
        ExtendChain(program, next, cid);
    }

    // ─── Existing helpers ───

    public static HashSet<string> ComputeLiveStates(ProgramNode program)
    {
        var defined = new HashSet<string>();
        void Collect(StateDefNode s)
        {
            defined.Add(s.Name);
            foreach (var ns in s.NestedStates) Collect(ns);
        }
        foreach (var s in program.States) Collect(s);
        foreach (var pb in program.ParallelBlocks)
            foreach (var s in pb.States) Collect(s);

        var live = new HashSet<string>();
        var queue = new Queue<string>();

        if (program.States.Count > 0)
            Enqueue(program.States[0].Name);

        foreach (var pb in program.ParallelBlocks)
            foreach (var s in pb.States)
                Enqueue(s.Name);

        while (queue.Count > 0)
        {
            var cur = queue.Dequeue();
            var node = FindState(program, cur);
            if (node == null) continue;
            foreach (var t in node.Transitions) Enqueue(t.Target);
            foreach (var t in node.Timers) Enqueue(t.Target);
        }

        return live;

        void Enqueue(string name)
        {
            if (!string.IsNullOrEmpty(name) && live.Add(name))
                queue.Enqueue(name);
        }
    }

    public static StateDefNode? FindState(ProgramNode program, string name)
    {
        StateDefNode? Find(IEnumerable<StateDefNode> states)
        {
            foreach (var s in states)
            {
                if (s.Name == name) return s;
                var found = Find(s.NestedStates);
                if (found != null) return found;
            }
            return null;
        }
        var r = Find(program.States);
        if (r != null) return r;
        foreach (var pb in program.ParallelBlocks)
        {
            r = Find(pb.States);
            if (r != null) return r;
        }
        return null;
    }

    private static void RemoveDeadStates(ProgramNode program, HashSet<string> live)
    {
        program.States.RemoveAll(s => !live.Contains(s.Name));
        foreach (var s in program.States) PruneNested(s, live);
        foreach (var s in program.States)
        {
            s.Transitions.RemoveAll(t => !string.IsNullOrEmpty(t.Target) && !live.Contains(t.Target));
            s.Timers.RemoveAll(t => !string.IsNullOrEmpty(t.Target) && !live.Contains(t.Target));
        }
    }

    private static void PruneNested(StateDefNode state, HashSet<string> live)
    {
        state.NestedStates.RemoveAll(s => !live.Contains(s.Name));
        state.Transitions.RemoveAll(t => !string.IsNullOrEmpty(t.Target) && !live.Contains(t.Target));
        state.Timers.RemoveAll(t => !string.IsNullOrEmpty(t.Target) && !live.Contains(t.Target));
        foreach (var ns in state.NestedStates) PruneNested(ns, live);
    }

    private static void FoldGuards(ProgramNode program)
    {
        foreach (var s in program.States) FoldState(s);
        foreach (var pb in program.ParallelBlocks)
            foreach (var s in pb.States) FoldState(s);
    }

    private static void FoldState(StateDefNode state)
    {
        state.Transitions.RemoveAll(t => IsAlwaysFalse(t.Guard));
        foreach (var t in state.Transitions)
            if (IsAlwaysTrue(t.Guard)) t.Guard = null;

        state.Timers.RemoveAll(t => IsAlwaysFalse(t.Guard));
        for (int i = 0; i < state.Timers.Count; i++)
        {
            if (IsAlwaysTrue(state.Timers[i].Guard))
            {
                state.Timers[i] = new TimerNode
                {
                    Duration = state.Timers[i].Duration,
                    Guard = null,
                    Target = state.Timers[i].Target
                };
            }
        }

        foreach (var ns in state.NestedStates) FoldState(ns);
    }

    private static bool IsAlwaysTrue(string? g) =>
        g is "true" or "True" or "1";

    private static bool IsAlwaysFalse(string? g) =>
        g is "false" or "False" or "0" or "";

    // ─── Haskell: Worker/Wrapper — split public API (wrapper) from unboxed inner (worker) ───
    public static void WorkerWrapper(ProgramNode program)
    {
        foreach (var state in program.States)
        {
            if (state.Transitions.Count == 0) continue;

            // Worker: bare-metal dispatch with unboxed args
            var workerTransitions = new List<TransitionNode>();
            foreach (var t in state.Transitions)
            {
                // Create worker: strip boxing, use raw types
                var worker = new TransitionNode
                {
                    EventName = $"__worker_{t.EventName}",
                    Target = t.Target,
                    Body = t.Body,
                    Guard = t.Guard,
                    IsAlways = t.IsAlways,
                    HotWeight = t.HotWeight
                };
                workerTransitions.Add(worker);

                // Wrapper: public API → calls worker
                t.Body = $"return __worker_{t.EventName}();";
                t.Guard = null;
            }
            state.Transitions.AddRange(workerTransitions);

            // Add worker state counterpart if useful
            var workerState = new StateDefNode
            {
                Name = $"__{state.Name}_worker",
                Ownership = OwnershipHint.Borrowed,
                Inline = InlineHint.AlwaysInline,
                Depth = state.Depth + 1
            };
            foreach (var v in state.Variables)
            {
                workerState.Variables.Add(new VariableNode
                {
                    Name = v.Name,
                    Type = v.Type,
                    IsFastPath = true,
                    IsMutable = v.IsMutable
                });
            }
            foreach (var t in state.Transitions)
                workerState.Transitions.Add(t);

            state.NestedStates.Add(workerState);
        }
    }

    // ─── Julia: SpecializeDispatch — specialize dispatch loop per state machine ───
    public static void SpecializeDispatch(ProgramNode program)
    {
        foreach (var state in program.States)
        {
            var hotEvents = state.Transitions
                .Where(t => t.HotWeight.HasValue && t.HotWeight.Value >= 0.8)
                .Select(t => t.EventName)
                .Distinct()
                .ToList();

            if (hotEvents.Count == 0) continue;

            // Generate specialized dispatch: direct jump table for hot events
            var specState = new StateDefNode
            {
                Name = $"__{state.Name}_dispatch",
                Inline = InlineHint.AlwaysInline,
                Depth = state.Depth + 1
            };

            // Hot events get direct dispatch, cold events fall through to generic
            int eventIdx = 0;
            foreach (var ev in hotEvents)
            {
                var hotT = state.Transitions.Where(t => t.EventName == ev).ToList();
                foreach (var t in hotT)
                {
                    specState.Transitions.Add(new TransitionNode
                    {
                        EventName = $"dispatch_{ev}",
                        Target = t.Target,
                        Body = $"// specialized: event #{eventIdx} → {t.Target}",
                        HotWeight = t.HotWeight
                    });
                }
                eventIdx++;
            }

            state.NestedStates.Add(specState);
        }
    }
}
