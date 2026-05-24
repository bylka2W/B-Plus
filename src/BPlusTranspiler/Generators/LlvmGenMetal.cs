using System.Text;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Optimizer;

namespace BPlusTranspiler.Generators;

public class LlvmGenMetal
{
    private readonly StringBuilder _ir = new();
    private int _metadataId;

    public string Generate(ProgramNode program, List<MetalBlock> metalBlocks, List<TierResult> tiers,
                           List<RegisterAssignment> registers)
    {
        _ir.Clear();
        _metadataId = 0;

        EmitHeader();

        foreach (var state in program.States)
        {
            var tier = tiers.Find(t => t.StateName == state.Name);
            var regs = registers.Where(r => r.Variable.StartsWith(state.Name)).ToList();
            var block = metalBlocks.Find(b => b.TargetState == state.Name);

            EmitStateFunction(state, tier, regs, block);
        }

        // Haskell: pointer tagging — encode state ID in low bits of state pointer
        EmitPointerTaggedDispatch(program);

        // LLVM: PGO devirtualization — devirtualize hottest transitions
        EmitPgoDevirt(program, metalBlocks);

        EmitTransitionTable(registers);

        return _ir.ToString();
    }

    private void EmitHeader()
    {
        _ir.AppendLine("; B+ v4.0.0 BETA Metal — LLVM IR with intrinsics");
        _ir.AppendLine("; Haskell-style pointer tagging + PGO devirtualization");
        _ir.AppendLine("target triple = \"x86_64-unknown-unknown\"");
        _ir.AppendLine("target datalayout = \"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128\"");
        _ir.AppendLine();

        // Declare LLVM intrinsics
        _ir.AppendLine("declare void @llvm.prefetch(i8*, i32, i32, i32)");
        _ir.AppendLine("declare i64 @llvm.readcyclecounter()");
        _ir.AppendLine("declare <16 x float> @llvm.x86.avx512.vpermq.512(<8 x i64>, i32)");
        _ir.AppendLine("declare <8 x i64> @llvm.x86.avx512.gather.dpq.512(<8 x i64>, i8*, i32)");
        _ir.AppendLine("declare i32 @llvm.x86.avx512.kortest.w(i16, i16)");
        _ir.AppendLine();
    }

    private void EmitStateFunction(StateDefNode state, TierResult? tier, List<RegisterAssignment> regs, MetalBlock? block)
    {
        string section = tier?.Section ?? ".text";
        int align = tier?.Alignment ?? 16;
        bool hot = tier?.IsHot ?? false;

        _ir.AppendLine($"; --- {state.Name} ---");

        if (hot)
        {
            string md = EmitMetadata("branch_weights", "i32 99, i32 1");
            _ir.AppendLine($"; hot path, branch_weights metadata: !{{{md}}}");
        }

        _ir.AppendLine($"define void @state_{state.Name}(i64 %state_ptr, i64 %event_id) section \"{section}\" align {align} {{");

        foreach (var r in regs)
        {
            _ir.AppendLine($"  ; register {r.Register} = {r.Variable}");
        }

        // Haskell-style: store state tag in low 3 bits of state_ptr (always aligned)
        // Low bits encode: 000=Idle, 001=processing, 010=error, 011=done
        int tag = hot ? 1 : (tier?.Section?.Contains("cold") == true ? 2 : 0);
        _ir.AppendLine($"  ; Haskell-style pointer tag: {tag} (0=warm, 1=hot, 2=cold)");
        _ir.AppendLine($"  %tagged = or i64 %state_ptr, {tag}");
        _ir.AppendLine($"  ; Branch on tag without load: and+icmp");
        _ir.AppendLine($"  %tag_bits = and i64 %tagged, 7");
        _ir.AppendLine($"  %is_hot = icmp eq i64 %tag_bits, 1");
        _ir.AppendLine($"  br i1 %is_hot, label %hot_path, label %cold_path, !prof !{{!\"branch_weights\", i32 99, i32 1}}");
        _ir.AppendLine();
        _ir.AppendLine("hot_path:");
        _ir.AppendLine("  ; fast path — already hot");
        _ir.AppendLine("  br label %merge");
        _ir.AppendLine();
        _ir.AppendLine("cold_path:");
        _ir.AppendLine("  ; slow path — need to warm up");
        _ir.AppendLine("  br label %merge");
        _ir.AppendLine();
        _ir.AppendLine("merge:");

        if (block?.Config.FusionPairs.Count > 0)
        {
            foreach (var pair in block.Config.FusionPairs)
            {
                _ir.AppendLine($"  ; fusion pair: {pair}");
            }
        }

        if (block?.Config.PrefetchHint != null)
        {
            string hint = block.Config.PrefetchHint switch
            {
                "nta" => "0",
                "t0" => "1",
                "t1" => "2",
                "t2" => "3",
                _ => "1"
            };
            _ir.AppendLine($"  call void @llvm.prefetch(i8* null, i32 0, i32 {hint}, i32 1)");
        }

        _ir.AppendLine("  ret void");
        _ir.AppendLine("}");
        _ir.AppendLine();
    }

    // Haskell: pointer tagging — dispatch on low bits of state pointer, no memory load
    private void EmitPointerTaggedDispatch(ProgramNode program)
    {
        int stateCount = program.States.Count;
        if (stateCount == 0 || stateCount > 8) return; // 3 bits → max 8 tags

        _ir.AppendLine("; ─── Haskell-style Pointer Tagged Dispatch ───");
        _ir.AppendLine("; State ID encoded in low 3 bits of pointer (always 8-byte aligned)");
        _ir.AppendLine("; Branch on tag directly — no memory load");
        _ir.AppendLine($"define void @dispatch_tagged(i64 %state_ptr) {{");
        _ir.AppendLine("  %tag = and i64 %state_ptr, 7");
        _ir.AppendLine("  switch i64 %tag, label %default [");

        for (int i = 0; i < stateCount; i++)
        {
            string stateName = program.States[i].Name;
            _ir.AppendLine($"    i64 {i}, label %state_{stateName}");
        }

        _ir.AppendLine("  ]");
        _ir.AppendLine();

        for (int i = 0; i < stateCount; i++)
        {
            string stateName = program.States[i].Name;
            _ir.AppendLine($"state_{stateName}:");
            _ir.AppendLine($"  call void @state_{stateName}(i64 %state_ptr, i64 0)");
            _ir.AppendLine("  ret void");
            _ir.AppendLine();
        }

        _ir.AppendLine("default:");
        _ir.AppendLine("  ret void");
        _ir.AppendLine("}");
        _ir.AppendLine();
    }

    // LLVM: PGO devirtualization — devirtualize hottest transitions based on PGO data
    private void EmitPgoDevirt(ProgramNode program, List<MetalBlock> metalBlocks)
    {
        var hotStates = program.States
            .Where(s => s.Transitions.Any(t => t.HotWeight.HasValue && t.HotWeight.Value >= 0.9))
            .ToList();

        if (hotStates.Count == 0) return;

        _ir.AppendLine("; ─── PGO Devirtualization ───");
        _ir.AppendLine("; Hot transitions devirtualized to direct calls (PGO data)");

        foreach (var state in hotStates)
        {
            var hotTrans = state.Transitions
                .Where(t => t.HotWeight.HasValue && t.HotWeight.Value >= 0.9)
                .ToList();

            foreach (var t in hotTrans)
            {
                _ir.AppendLine($"; {state.Name}[{t.EventName}] → {t.Target} (weight={t.HotWeight:F2})");
                _ir.AppendLine($"define void @devirt_{state.Name}_{t.EventName}(i64 %state_ptr) {{");
                _ir.AppendLine($"  call void @state_{t.Target}(i64 %state_ptr, i64 0)");
                _ir.AppendLine("  ret void");
                _ir.AppendLine("}");
                _ir.AppendLine();
            }
        }
    }

    private void EmitTransitionTable(List<RegisterAssignment> regs)
    {
        var zmmTable = regs.Find(r => r.Class == RegisterClass.ZMM && r.Register.StartsWith("zmm"));
        if (zmmTable == null) return;

        _ir.AppendLine("; Transition table (packed in ZMM)");
        _ir.AppendLine("@transition_table = internal constant [64 x i64] zeroinitializer, align 64");
        _ir.AppendLine();

        // Emit example: load transition table into ZMM0
        _ir.AppendLine("define void @load_transition_table() {");
        _ir.AppendLine("  %table = load [64 x i64], [64 x i64]* @transition_table");
        _ir.AppendLine("  ; vmovdqa64 loads 512 bits into ZMM0");
        _ir.AppendLine("  call void asm sideeffect \"vmovdqa64 $0, %zmm0\", \"=X,~{zmm0}\"()");
        _ir.AppendLine("  ret void");
        _ir.AppendLine("}");
        _ir.AppendLine();
    }

    private string EmitMetadata(string name, string value)
    {
        int id = _metadataId++;
        _ir.AppendLine($"!{id} = !{{!\"{name}\", {value}}}");
        return $"!{id}";
    }

    public string GenerateFusionAsm(string instr1, string instr2)
    {
        return $"; fusion pair: {instr1}, {instr2}" + "\n" +
               $"call void asm sideeffect \"{instr1}\\0A{instr2}\", \"~{{dirflag}},~{{fpsr}},~{{flags}}\"()";
    }
}
