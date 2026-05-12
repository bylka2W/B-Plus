using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Optimizer;

public static class BPlusOptimizer
{
    public static ProgramNode Optimize(ProgramNode program)
    {
        var liveStates = ComputeLiveStates(program);
        RemoveDeadStates(program, liveStates);
        FoldGuards(program);
        SemanticInline(program);
        return program;
    }

    /// <summary>
    /// B+ Semantic Inline — detect common transition chains and mark them
    /// so the code generator can emit a single fused function.
    /// Only follows transitions with explicit @hot(weight >= 0.5) annotations.
    /// Stops at branch points (multiple hot transitions from same state).
    /// </summary>
    public static void SemanticInline(ProgramNode program)
    {
        int chainId = 0;
        foreach (var startState in program.States)
            DetectChainFrom(program, startState, ref chainId);
    }

    private static void DetectChainFrom(ProgramNode program, StateDefNode start, ref int chainId)
    {
        if (start.ChainId != null) return; // already in a chain

        // Find the single hot (weight >= 0.5) transition from this state
        var hotTargets = start.Transitions
            .Where(t => t.HotWeight.HasValue && t.HotWeight.Value >= 0.5
                        && !string.IsNullOrEmpty(t.Target)
                        && FindState(program, t.Target) != null)
            .Select(t => t.Target)
            .Distinct()
            .ToList();

        if (hotTargets.Count != 1) return; // no chain start

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

        if (hotTargets.Count != 1) return; // branch point or chain end

        var next = FindState(program, hotTargets[0])!;
        next.ChainId = cid;
        ExtendChain(program, next, cid);
    }

    private static HashSet<string> ComputeLiveStates(ProgramNode program)
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

    private static StateDefNode? FindState(ProgramNode program, string name)
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
}
