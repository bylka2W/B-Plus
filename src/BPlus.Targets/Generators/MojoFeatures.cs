using System.Text;
using BPlus.Core.Ast;

namespace BPlus.Targets.Generators;

/// <summary>
/// Mojo-inspired features for B+:
/// 1. @always_inline / @no_inline — inline hints on states
/// 2. @llvm_intrinsic — raw LLVM IR insertion
/// 3. simd&lt;T, N&gt; — typed SIMD vectors
/// 4. owned / borrowed — static memory ownership
/// 5. @parameter — compile-time conditions
/// </summary>
public static class MojoFeatures
{
    // ─── 1. ALWAYS_INLINE / NO_INLINE ───

    public static string EmitInlineAttribute(StateDefNode state)
    {
        return state.Inline switch
        {
            InlineHint.AlwaysInline => "__attribute__((always_inline)) ",
            InlineHint.NoInline => "__attribute__((noinline)) ",
            _ => ""
        };
    }

    public static string EmitCppInlineHint(StateDefNode state, string indent = "")
    {
        if (state.Inline == InlineHint.AlwaysInline)
            return $"{indent}[[gnu::always_inline]]\n";
        if (state.Inline == InlineHint.NoInline)
            return $"{indent}[[gnu::noinline]]\n";
        return "";
    }

    // ─── 2. LLVM INTRINSICS ───

    public static string EmitLlvmIntrinsic(LlvmIntrinsicDecl decl)
    {
        var sb = new StringBuilder();
        sb.Append($"call void @{decl.Intrinsic}(");
        sb.Append(string.Join(", ", decl.Args));
        sb.AppendLine(")");
        return sb.ToString();
    }

    public static string EmitCppIntrinsicCall(LlvmIntrinsicDecl decl)
    {
        // Map well-known intrinsics to C++ builtins
        return decl.Intrinsic switch
        {
            "llvm.prefetch" => $"__builtin_prefetch({string.Join(", ", decl.Args)});\n",
            "llvm.readcyclecounter" => "__builtin_readcyclecounter();\n",
            "llvm.x86.avx512.vpermq.512" => $"_mm512_permutexvar_epi64({string.Join(", ", decl.Args)});\n",
            "llvm.x86.avx512.gather.dpq.512" => $"_mm512_i64gather_pd({string.Join(", ", decl.Args)});\n",
            _ => $"// B+ intrinsic: @{decl.Intrinsic}({string.Join(", ", decl.Args)})\n"
        };
    }

    public static string GenerateIntrinsicDeclarations(List<StateDefNode> allStates)
    {
        var seen = new HashSet<string>();
        var sb = new StringBuilder();
        sb.AppendLine("// B+ LLVM intrinsic declarations (Mojo-style @llvm_intrinsic)");
        foreach (var st in allStates)
        {
            foreach (var l in st.LlvmIntrinsics)
            {
                if (!seen.Add(l.Intrinsic))
                {
                    sb.AppendLine($"// Used in state '{st.Name}': @{l.Intrinsic}");
                    if (l.Intrinsic == "llvm.prefetch")
                        sb.AppendLine("static inline void __builtin_prefetch(const void* addr, int rw, int locality, int type);");
                }
            }
        }
        return sb.ToString();
    }

    // ─── 3. SIMD TYPES ───

    public static string GetSimdCppType(SimdType simd)
    {
        string baseCpp = simd.ElementType.ToLower() switch
        {
            "u8" => "uint8_t",
            "i8" => "int8_t", 
            "u16" => "uint16_t",
            "i16" => "int16_t",
            "u32" => "uint32_t",
            "i32" or "int" => "int32_t",
            "u64" => "uint64_t",
            "i64" => "int64_t",
            "f32" or "float" => "float",
            "f64" or "double" => "double",
            _ => simd.ElementType
        };
        return simd.Width switch
        {
            16 => $"__m512i",   // 16 u32 lanes
            8 => $"__m256i",    // 8  u32 lanes
            4 => $"__m128i",    // 4  u32 lanes
            32 => $"__mmask32", // 32 u8 lanes (AVX-512 byte mask)
            _ => baseCpp
        };
    }

    public static string GetSimdLlvmType(SimdType simd)
    {
        int bitWidth = simd.ElementType.ToLower() switch
        {
            "u8" or "i8" => 8,
            "u16" or "i16" => 16,
            "u32" or "i32" or "int" or "float" or "f32" => 32,
            "u64" or "i64" or "f64" or "double" => 64,
            _ => 32
        };
        return $"<{simd.Width} x i{bitWidth}>";
    }

    public static string EmitSimdVariable(VariableNode v, StateDefNode state)
    {
        var simd = TryParseSimdType(v.Type);
        if (simd == null) return "";

        var sb = new StringBuilder();
        string cppType = GetSimdCppType(simd);
        string llvmType = GetSimdLlvmType(simd);

        sb.AppendLine($"  // simd<{simd.ElementType},{simd.Width}> = {llvmType}");
        if (simd.Width >= 16)
            sb.AppendLine($"  alignas(64) {cppType} {v.Name};  // AVX-512: {llvmType}");
        else if (simd.Width >= 8)
            sb.AppendLine($"  alignas(32) {cppType} {v.Name};  // AVX-256: {llvmType}");
        else
            sb.AppendLine($"  alignas(16) {cppType} {v.Name};  // SSE: {llvmType}");
        return sb.ToString();
    }

    public static SimdType? TryParseSimdType(string typeStr)
    {
        if (!typeStr.StartsWith("simd<", StringComparison.OrdinalIgnoreCase))
            return null;

        var inner = typeStr[5..^1]; // strip "simd<...>"
        var parts = inner.Split(',');
        if (parts.Length != 2) return null;
        if (!int.TryParse(parts[1].Trim(), out var width)) return null;
        return new SimdType { ElementType = parts[0].Trim(), Width = width };
    }

    // ─── 4. OWNED / BORROWED ───

    public static string EmitOwnership(StateDefNode state, string indent = "")
    {
        return state.Ownership switch
        {
            OwnershipHint.Owned => $"{indent}// B+ owned: exclusive access — no alias analysis needed\n",
            OwnershipHint.Borrowed => $"{indent}// B+ borrowed: read-only — shared, no write\n",
            _ => ""
        };
    }

    public static string GenerateOwnershipAnalysis(List<StateDefNode> allStates)
    {
        var sb = new StringBuilder();
        sb.AppendLine("// ─── B+ Ownership Analysis (Mojo-style) ───");

        var owned = allStates.Where(s => s.Ownership == OwnershipHint.Owned).ToList();
        var borrowed = allStates.Where(s => s.Ownership == OwnershipHint.Borrowed).ToList();

        foreach (var s in owned)
        {
            sb.AppendLine($"//   state {s.Name} owned — exclusive, no aliasing");
            foreach (var v in s.Variables)
                sb.AppendLine($"//     var {v.Name}: {v.Type} — owned by state {s.Name}");
        }
        foreach (var s in borrowed)
        {
            sb.AppendLine($"//   state {s.Name} borrowed — read-only, shared");
        }

        if (owned.Count == 0 && borrowed.Count == 0)
            sb.AppendLine("//   (no ownership annotations — default: shared mutable)");

        sb.AppendLine("// ─── Pool Analysis ───");
        int totalAlloc = owned.Sum(s => s.Variables.Sum(v => 8));
        sb.AppendLine($"//   Total statically analyzable allocations: {totalAlloc} bytes");
        sb.AppendLine($"//   States without 'owned' require --pool runtime allocator");
        return sb.ToString();
    }

    // ─── 5. @PARAMETER CONDITIONS ───

    public static string EmitParameterConditions(StateDefNode state, List<ParameterCondition> conditions, string indent = "")
    {
        var sb = new StringBuilder();
        foreach (var pc in conditions)
        {
            string cond = pc.Key switch
            {
                "target" => $"defined(__AVX512F__) || defined(__AVX2__)",
                "arch" => $"defined(__x86_64__) || defined(__aarch64__)",
                "os" => $"defined(__linux__) || defined(_WIN32)",
                "simd" => $"defined(__AVX512F__)",
                _ => $"defined({pc.Key})"
            };
            sb.AppendLine($"{indent}#if {cond}");
            if (pc.Value == "avx512")
                sb.AppendLine($"{indent}  // @parameter(target == \"avx512\"): AVX-512 path");
            else if (pc.Value == "avx2")
                sb.AppendLine($"{indent}  // @parameter(target == \"avx2\"): AVX-256 path");
            else
                sb.AppendLine($"{indent}  // @parameter({pc.Key} == \"{pc.Value}\")");
            if (pc.Body != null)
                sb.AppendLine($"{indent}  {pc.Body}");
            sb.AppendLine($"{indent}#endif");
        }
        return sb.ToString();
    }
}
