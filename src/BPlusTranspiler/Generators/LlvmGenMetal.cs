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

        EmitTransitionTable(registers);

        return _ir.ToString();
    }

    private void EmitHeader()
    {
        _ir.AppendLine("; B+ v3.0.2L1 Metal — LLVM IR with intrinsics");
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
        _ir.AppendLine($"$section = !{{i32 1, !\"{section}\", !\"{state.Name}\"}}");

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
