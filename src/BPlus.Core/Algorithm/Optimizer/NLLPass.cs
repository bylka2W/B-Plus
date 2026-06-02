using BPlus.Core.Ast;
using BPlus.Core.Mir;

namespace BPlus.Core.Algorithm.Optimizer;

// Rust: NLL (Non-Lexical Liveness) — track variable liveness by CFG edges
// A slot dies exactly at the last use, not at end of block.
// This enables tighter register allocation and earlier slot reuse.

public class NLLPoint
{
    public int Index { get; set; }
    public MirOpcode Opcode { get; set; }
    public HashSet<string> LiveBefore { get; set; } = new();
    public HashSet<string> LiveAfter { get; set; } = new();
    public HashSet<string> Born { get; set; } = new();
    public HashSet<string> Die { get; set; } = new();
}

public static class NLLPass
{
    public static List<LivenessResult> Run(ProgramNode program)
    {
        var results = new List<LivenessResult>();
        var mir = MirBuilder.Build(program);

        foreach (var block in mir.Blocks)
        {
            var state = program.States.Find(s => s.Name == block.Name);
            if (state == null) continue;

            var lr = new LivenessResult { StateName = block.Name };
            lr.LiveVars.UnionWith(block.LiveIn);

            var live = new HashSet<string>(block.LiveIn);

            for (int i = 0; i < block.Instructions.Count; i++)
            {
                var inst = block.Instructions[i];
                var pt = new NLLPoint { Index = i, Opcode = inst.Opcode };

                pt.LiveBefore = new HashSet<string>(live);

                // Variables born here (defined)
                if (inst.Dest != null && !live.Contains(inst.Dest))
                {
                    pt.Born.Add(inst.Dest);
                    live.Add(inst.Dest);
                }

                // Variables that die here (last use)
                foreach (var arg in inst.Args)
                {
                    if (!arg.StartsWith("\"") && !long.TryParse(arg, out _))
                    {
                        bool isLastUse = true;
                        for (int j = i + 1; j < block.Instructions.Count; j++)
                        {
                            var later = block.Instructions[j];
                            if (later.Args.Contains(arg) || later.Dest == arg)
                            { isLastUse = false; break; }
                        }
                        if (isLastUse && live.Contains(arg))
                        {
                            pt.Die.Add(arg);
                        }
                    }
                }

                // Remove dead vars
                foreach (var d in pt.Die)
                    live.Remove(d);

                // Also mark variables as dead on exit if they're not live out
                if (i == block.Instructions.Count - 1)
                {
                    foreach (var v in live)
                        if (!block.LiveOut.Contains(v))
                            lr.DeadOnExit.Add(v);
                }

                pt.LiveAfter = new HashSet<string>(live);
                lr.Points.Add(new LivenessPoint
                {
                    InstructionIndex = pt.Index,
                    Opcode = pt.Opcode,
                    LiveBefore = pt.LiveBefore,
                    LiveAfter = pt.LiveAfter,
                    Born = pt.Born,
                    Die = pt.Die
                });
            }

            results.Add(lr);
        }

        // Apply NLL results to AST
        foreach (var lr in results)
        {
            var state = program.States.Find(s => s.Name == lr.StateName);
            if (state != null)
                state.Liveness = lr;
        }

        return results;
    }
}
