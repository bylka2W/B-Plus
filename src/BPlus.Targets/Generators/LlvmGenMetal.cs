using System.Text;
using BPlus.Core.Ast;
using BPlus.Core.Algorithm.Optimizer;

namespace BPlus.Targets.Generators;

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

        // Emit entry point (main) from entry declarations
        foreach (var entry in program.Entries)
            EmitEntry(entry);

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
        _ir.AppendLine("declare i32 @puts(ptr)");
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

        // ── State variable initialisation ──
        if (state.Variables.Count > 0)
        {
            _ir.AppendLine("  ; ── state variables ──");
            _ir.AppendLine("  %base = inttoptr i64 %state_ptr to i8*");
            int off = 0;
            foreach (var v in state.Variables)
            {
                int size = LlvmTypeSize(v.Type);
                int asz = LlvmTypeAlign(v.Type);
                off = ((off + asz - 1) / asz) * asz;
                string llvmTy = ToLlvmType(v.Type);
                string safeName = SanitizeIdent(v.Name);
                long val = ParseDefaultInt(v.DefaultValue);
                _ir.AppendLine($"  %{safeName}_ptr = getelementptr i8, i8* %base, i32 {off}");
                _ir.AppendLine($"  store {llvmTy} {val}, {llvmTy}* %{safeName}_ptr");
                off += size;
            }
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

        // Load transition table into ZMM register via pure LLVM IR
        // bitcast [64 x i64]* → <8 x i64>* to match ZMM width (512 bit)
        // volatile load prevents DCE of the dead SSA value
        _ir.AppendLine("define void @load_transition_table() {");
        _ir.AppendLine("  %vec_ptr = bitcast [64 x i64]* @transition_table to <8 x i64>*");
        _ir.AppendLine("  %zmm_val = load volatile <8 x i64>, <8 x i64>* %vec_ptr, align 64");
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

    private void EmitEntry(EntryDecl e)
    {
        _ir.AppendLine("; ─── Entry Point ───");
        string retType = e.ReturnType ?? "i32";
        bool needsPrintf = false;

        // First pass: collect string constants and detect printf needs
        var stringConsts = new List<(int id, string val, int len)>();
        foreach (var line in e.BodyLines)
        {
            var trimmed = line.TrimStart();
            if (trimmed.StartsWith("print(") && trimmed.EndsWith(")"))
            {
                var arg = trimmed[6..^1].Trim();
                int id = stringConsts.Count;
                if (arg.StartsWith("\"") && arg.EndsWith("\""))
                {
                    var strVal = arg[1..^1];
                    string escaped = strVal.Replace("\\", "\\5C").Replace("\"", "\\22")
                                           .Replace("\n", "\\0A").Replace("\r", "\\0D")
                                           .Replace("\t", "\\09");
                    stringConsts.Add((id, $"c\"{escaped}\\00\"", strVal.Length + 1));
                }
                else
                {
                    needsPrintf = true;
                    stringConsts.Add((id, "c\"%d\\0A\\00\"", 4));
                }
            }
        }

        // Emit string constants at module level
        foreach (var (id, val, len) in stringConsts)
            _ir.AppendLine($"@.str{id} = private unnamed_addr constant [{len} x i8] {val}");

        // Declare printf only if needed
        if (needsPrintf)
            _ir.AppendLine("declare i32 @printf(ptr, ...)");

        // Emit main function body
        _ir.AppendLine($"define {retType} @main() {{");
        bool hasRet = false;
        int strIdx = 0;

        foreach (var line in e.BodyLines)
        {
            var trimmed = line.TrimStart();

            if (trimmed.StartsWith("$$"))
            {
                _ir.AppendLine($"  {trimmed[2..]}");
                continue;
            }

            if (trimmed == "end")
                continue;

            if (trimmed.StartsWith("while ") || trimmed.StartsWith("if ") || trimmed.StartsWith("for "))
                continue;

            if (trimmed.StartsWith("return "))
            {
                _ir.AppendLine($"  ret {retType} {trimmed[7..].Trim()}");
                hasRet = true;
                continue;
            }

            if (trimmed.StartsWith("print(") && trimmed.EndsWith(")"))
            {
                var arg = trimmed[6..^1].Trim();
                int id = strIdx++;
                if (arg.StartsWith("\"") && arg.EndsWith("\""))
                    _ir.AppendLine($"  %call{id} = call i32 @puts(ptr @.str{id})");
                else
                    _ir.AppendLine($"  %call{id} = call i32 (ptr, ...) @printf(ptr @.str{id}, i32 {arg})");
                continue;
            }

            _ir.AppendLine($"  ; {trimmed}");
        }

        if (!hasRet)
            _ir.AppendLine("  ret i32 0");
        _ir.AppendLine("}");
        _ir.AppendLine();
    }

    // ── Type helpers for LLVM IR ──
    private static int LlvmTypeSize(string type) => type.ToLowerInvariant() switch
    {
        "int8" or "byte" or "u8" or "bool" => 1,
        "int16" or "short" or "half" or "u16" => 2,
        "int32" or "int" or "uint" or "float" => 4,
        "int64" or "long" or "double" or "uint64" => 8,
        _ => 8
    };

    private static int LlvmTypeAlign(string type)
    {
        int s = LlvmTypeSize(type);
        return s <= 4 ? s : 8;
    }

    private static string ToLlvmType(string type) => type.ToLowerInvariant() switch
    {
        "int8" or "byte" or "u8" or "bool" => "i8",
        "int16" or "short" or "half" or "u16" => "i16",
        "int32" or "int" or "uint" or "float" => "i32",
        "int64" or "long" or "double" or "uint64" => "i64",
        _ => "i64"
    };

    private static string SanitizeIdent(string name)
    {
        var sb = new StringBuilder(name.Length);
        foreach (char c in name)
        {
            if (char.IsAsciiLetterOrDigit(c) || c == '_')
                sb.Append(c);
            else
                sb.Append('_');
        }
        if (sb.Length == 0 || char.IsDigit(sb[0]))
            sb.Insert(0, '_');
        return sb.ToString();
    }

    private static long ParseDefaultInt(string? val)
    {
        if (string.IsNullOrEmpty(val)) return 0;
        val = val.Trim().ToLowerInvariant();
        if (val.StartsWith("0x"))
            return long.TryParse(val[2..], System.Globalization.NumberStyles.HexNumber, null, out long h) ? h : 0;
        return long.TryParse(val, out long d) ? d : 0;
    }

    public string GenerateFusionAsm(string instr1, string instr2)
    {
        return $"; fusion pair: {instr1}, {instr2}" + "\n" +
               $"call void asm sideeffect \"{instr1}\\0A{instr2}\", \"~{{dirflag}},~{{fpsr}},~{{flags}}\"()";
    }
}
