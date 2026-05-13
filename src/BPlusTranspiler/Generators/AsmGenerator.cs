using System.Text;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Optimizer;

namespace BPlusTranspiler.Generators;

public class AsmGenerator
{
    public string GenerateAssembly(ProgramNode program, List<TierResult> tiers, List<RegisterAssignment> regs)
    {
        var sb = new StringBuilder();
        sb.AppendLine("; B+ v3.0.2L1 Metal — x86-64 assembly");
        sb.AppendLine("section .text");
        sb.AppendLine();

        foreach (var state in program.States)
        {
            EmitState(sb, state, tiers, regs);
        }

        return sb.ToString();
    }

    private void EmitState(StringBuilder sb, StateDefNode state, List<TierResult> tiers, List<RegisterAssignment> regs)
    {
        var tier = tiers.Find(t => t.StateName == state.Name);

        if (tier != null)
        {
            sb.AppendLine($"section {tier.Section}");
            sb.AppendLine($"align {tier.Alignment}");
        }

        bool hot = tier?.IsHot ?? false;
        bool hasGateway = tier?.NeedsGateway ?? false;
        string gatewayTier = tier?.GatewayTier ?? "L3";

        sb.AppendLine($"state_{state.Name}:");

        if (hot)
        {
            // Dispatch in 3 fused µops
            // 1. vpermq from ZMM table (1 µop)
            // 2. kortest mask check (1 µop, fused with jnz)
            // 3. jmp to handler (1 µop)
            sb.AppendLine("    ; L0 µop dispatch (3 fused µops)");
            sb.AppendLine("    vpermq  zmm1, zmm0, r8          ; extract address by state_id");

            var maskReg = regs.Find(r => r.Class == RegisterClass.Mask)?.Register ?? "k1";
            sb.AppendLine($"    kortest {maskReg}, {maskReg}        ; check L1-resident mask");
            sb.AppendLine("    jnz .hot_entry                  ; fused: kortest+jnz = 1 µop");
            sb.AppendLine();
            sb.AppendLine(".hot_entry:");

            // Fusion pairs if specified
            var fusionPairs = GetFusionPairs(state);
            foreach (var pair in fusionPairs)
                sb.AppendLine($"    ; fusion pair: {pair}");
        }

        if (hasGateway)
        {
            sb.AppendLine($"    ; gateway to {gatewayTier}");
            sb.AppendLine($"    prefetchnta [rax + {gatewayTier switch { "L2" => 256, "L3" => 512, _ => 1024 }}]");
            sb.AppendLine("    ; 10-15 cycles of work while prefetch completes");
        }

        // State body
        foreach (var t in state.Transitions)
        {
            sb.AppendLine($"    cmp rdx, {GetEventId(t.EventName)}");

            if (t.HotWeight.HasValue && t.HotWeight.Value >= 0.8)
                sb.AppendLine("    je .L_" + t.Target + "  ; hot path");
            else if (t.HotWeight.HasValue && t.HotWeight.Value <= 0.1)
                sb.AppendLine("    je .L_" + t.Target + "  ; cold path");
            else
                sb.AppendLine("    je .L_" + t.Target);
        }

        // Prefetch next if known
        if (state.Transitions.Count == 1)
        {
            sb.AppendLine("    ; single target — prefetch next state data");
            sb.AppendLine("    prefetcht0 [rsi + 64]");
        }

        sb.AppendLine("    ret");
        sb.AppendLine();
    }

    private static int _eventCounter;
    private static readonly Dictionary<string, int> EventIds = new();

    private static int GetEventId(string name)
    {
        if (!EventIds.ContainsKey(name))
            EventIds[name] = _eventCounter++;
        return EventIds[name];
    }

    private static List<string> GetFusionPairs(StateDefNode state)
    {
        var pairs = new List<string>();
        var transitions = state.Transitions;

        for (int i = 0; i < transitions.Count; i++)
        {
            var t = transitions[i];
            if (i + 1 < transitions.Count)
            {
                string evt1 = t.EventName, evt2 = transitions[i + 1].EventName;
                if ((evt1 == evt2) || (t.HotWeight.HasValue && transitions[i + 1].HotWeight.HasValue))
                {
                    if (pairs.Count < 2)
                        pairs.Add("cmp+je");
                }
            }
        }

        return pairs;
    }
}
