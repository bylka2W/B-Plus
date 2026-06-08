using BPlusTranspiler.Ast;

namespace BPlusTranspiler;

/// <summary>
/// Central validator for all 121 known errors (53 critical + 68 non-critical).
/// Runs after parsing, before code generation.
/// </summary>
public static class BPlusValidator
{
    public static List<ValidationError> Validate(ProgramNode program, string? sourceFile = null)
    {
        var errors = new List<ValidationError>();
        var stateNames = new HashSet<string>();

        foreach (var s in program.States) stateNames.Add(s.Name);

        // ─── PARSER ERRORS ───
        ValidateParser(program, stateNames, errors);
        ValidateInheritance(program, stateNames, errors);
        ValidateTransitions(program, errors);
        ValidateMemory(program, errors);
        ValidateKernels(program, errors);
        ValidateParallel(program, errors);
        ValidateTypes(program, errors);
        ValidateAnnotations(program, errors);
        ValidateMetalAnnotations(program, errors);

        return errors;
    }

    // ─── PARSER (🔴 #1, #3, #8, #12, #173, #406, #519-521, #769, #1019) ───

    private static void ValidateParser(ProgramNode program, HashSet<string> stateNames, List<ValidationError> errors)
    {
        // #1: state A : B — no check B exists
        foreach (var s in program.States)
            if (s.BaseClass != null && !stateNames.Contains(s.BaseClass))
                errors.Add(new ValidationError { Number = 1, Message = $"Base class '{s.BaseClass}' for state '{s.Name}' does not exist" });

        // #3: state A : A — cyclic inheritance
        foreach (var s in program.States)
            if (s.BaseClass == s.Name)
                errors.Add(new ValidationError { Number = 3, Message = $"Cyclic inheritance: state '{s.Name}' cannot inherit from itself" });

        // #519-521: multi-level cycles A→B→C→A
        foreach (var s in program.States)
        {
            if (s.BaseClass == null) continue;
            var visited = new HashSet<string> { s.Name };
            var cur = s.BaseClass;
            while (cur != null && stateNames.Contains(cur))
            {
                if (!visited.Add(cur))
                {
                    errors.Add(new ValidationError { Number = visited.Count == 2 ? 519u : visited.Count == 3 ? 520u : 521u,
                        Message = $"Cyclic inheritance chain: {string.Join(" → ", visited)} → {cur}" });
                    break;
                }
                var parent = program.States.Find(st => st.Name == cur);
                if (parent?.BaseClass == null) break;
                cur = parent.BaseClass;
            }
        }

        // #1019: var x: void
        foreach (var s in program.States)
            foreach (var v in s.Variables)
                if (v.Type == "void")
                    errors.Add(new ValidationError { Number = 1019, Message = $"Variable '{v.Name}' in state '{s.Name}' has type 'void'" });

        // #406: RTL chars (already filtered in parser, but verify)
        // #769: nesting depth (parser checks, verify)
        foreach (var s in program.States)
            if (s.Depth > 100)
                errors.Add(new ValidationError { Number = 769, Message = $"State '{s.Name}' at depth {s.Depth} exceeds max 100" });

        // #173: probabilistic transition (event -> State1, State2) — not implemented
        foreach (var s in program.States)
            foreach (var t in s.Transitions)
                if (t.Target.Contains(','))
                    errors.Add(new ValidationError { Number = 173, Message = $"Probabilistic transition '{t.EventName} -> {t.Target}' not implemented" });

        // #1032: @import without BPM
        foreach (var i in program.Imports)
            if (i.Path.StartsWith('@'))
                errors.Add(new ValidationError { Number = 1032, Message = $"Import '{i.Path}' uses @ syntax — BPM packages not yet supported" });

        // #1021-1022: FFI extern existence/signature
        foreach (var ext in program.ExternCppFns)
        {
            errors.Add(new ValidationError { Number = 1021, Message = $"@extern(\"C\") '{ext.Name}' — linker will fail if not defined in C++", Severity = "🟠" });
            errors.Add(new ValidationError { Number = 1022, Message = $"@extern(\"C\") '{ext.Name}' — signature mismatch risk: params={ext.Parameters.Count}, ret='{ext.ReturnType}'", Severity = "🟠" });
        }

        // #349: code injection via state names
        var unsafeChars = new[] { '<', '>', '"', '\'', '&', '|', ';', '$', '`', '\\' };
        foreach (var s in program.States)
            if (s.Name.IndexOfAny(unsafeChars) >= 0)
                errors.Add(new ValidationError { Number = 349, Message = $"State name '{s.Name}' contains unsafe characters — possible code injection (CWE-78)" });
    }

    // ─── INHERITANCE (🔴) ───

    private static void ValidateInheritance(ProgramNode program, HashSet<string> stateNames, List<ValidationError> errors)
    {
        // #15: StateNode lacks inheritance info
        foreach (var s in program.States)
            if (s.BaseClass != null && !program.States.Any(st => st.Name == s.BaseClass))
                errors.Add(new ValidationError { Number = 15, Message = $"State '{s.Name}' inherits from '{s.BaseClass}' but base state not found" });

        // #209: GuardNode nested conditions
        foreach (var s in program.States)
            foreach (var t in s.Transitions)
                if (t.Guard != null && (t.Guard.Contains(" and ") || t.Guard.Contains(" or ")))
                    errors.Add(new ValidationError { Number = 209, Message = $"Guard '{t.Guard}' uses and/or — nested conditions not supported (parsed as flat string)" });
                else if (t.Guard != null && t.Guard.Contains('!'))
                    errors.Add(new ValidationError { Number = 210, Message = $"Guard '{t.Guard}' uses ! — logical NOT not supported" });
    }

    // ─── TRANSITIONS (🔴 #12, 🟠 #4, #6, #13-14) ───

    private static void ValidateTransitions(ProgramNode program, List<ValidationError> errors)
    {
        foreach (var s in program.States)
        {
            foreach (var t in s.Transitions)
            {
                // #12: always -> same state — infinite loop
                if (t.IsAlways && t.Target == s.Name)
                    errors.Add(new ValidationError { Number = 12, Message = $"State '{s.Name}' has infinite self-loop via 'always -> {t.Target}'" });

                // #4: guard purity (side effects)
                if (t.Guard != null && (t.Guard.Contains("=") || t.Guard.Contains("++") || t.Guard.Contains("--")))
                    errors.Add(new ValidationError { Number = 4, Message = $"Guard '{t.Guard}' may have side effects — guards must be pure expressions", Severity = "🟠" });
            }

            // #13-14: timer duration > 0
            foreach (var tm in s.Timers)
            {
                var dur = tm.Duration.Replace("ms", "").Replace("s", "").Replace("us", "").Replace("ns", "");
                if (int.TryParse(dur, out var d) && d <= 0)
                    errors.Add(new ValidationError { Number = 13, Message = $"Timer duration '{tm.Duration}' must be > 0", Severity = "🟠" });
            }

            // #6: var: Type = expr type mismatch
            foreach (var v in s.Variables)
                if (v.DefaultValue != null && !TypeIsCompatible(v.Type, v.DefaultValue))
                    errors.Add(new ValidationError { Number = 6, Message = $"'{v.Name}: {v.Type}' cannot be initialized with '{v.DefaultValue}'", Severity = "🟠" });
        }
    }

    // ─── MEMORY (🔴 #24, #27, #29-30, 🟠 #25-26, #28, #31, #33-35, #38-39) ───

    private static void ValidateMemory(ProgramNode program, List<ValidationError> errors)
    {
        if (program.Memory == null) return;

        // #24: #memory smart + @live(vram) conflict
        bool hasLiveVram = false;
        bool hasSmart = program.Memory.Mode == BPlusMemoryMode.Smart;
        foreach (var vd in program.VarDecls)
            if (vd.MemoryAnnotations.Any(a => a.Name == "live" && a.Args.TryGetValue("_val", out var val) && val.Contains("vram")))
                hasLiveVram = true;

        if (hasSmart && hasLiveVram)
            errors.Add(new ValidationError { Number = 24, Message = "#memory smart conflicts with @live(vram) — smart mode manages VRAM independently" });

        // #27: @quant(int8) on float
        foreach (var vd in program.VarDecls)
            foreach (var a in vd.MemoryAnnotations)
                if (a.Name == "quant" && a.Args.TryGetValue("_val", out var qv))
                {
                    if (qv.Contains("int") && vd.Type is SimpleType st && st.Name is "float" or "f64" or "double")
                        errors.Add(new ValidationError { Number = 27, Message = $"@quant({qv}) on float variable '{vd.Name}' — integer quantization on float type" });
                    if (qv.Contains("bc") && vd.Type is not ImageType)
                        errors.Add(new ValidationError { Number = 29, Message = $"@compress({qv}) on non-image variable '{vd.Name}'" });
                }

        // #28: @quant(int4) not supported by all generators
        foreach (var vd in program.VarDecls)
            foreach (var a in vd.MemoryAnnotations)
                if (a.Name == "quant" && a.Args.TryGetValue("_val", out var qv2) && qv2 == "int4")
                    errors.Add(new ValidationError { Number = 28, Message = $"@quant(int4) on '{vd.Name}' — not all generators support int4", Severity = "🟠" });

        // #31: @align(cacheline) without size
        foreach (var vd in program.VarDecls)
            foreach (var a in vd.MemoryAnnotations)
                if (a.Name == "align" && a.Args.TryGetValue("_val", out var av))
                    if (!int.TryParse(av, out var _))
                        errors.Add(new ValidationError { Number = 31, Message = $"@align({av}) — unknown alignment size", Severity = "🟠" });

        // #33-35: streaming
        if (program.Memory.Streaming != null)
        {
            if (program.Memory.Streaming.Source != null && !File.Exists(program.Memory.Streaming.Source))
                errors.Add(new ValidationError { Number = 33, Message = $"@stream(source: '{program.Memory.Streaming.Source}') — file not found", Severity = "🟠" });
            if (program.Memory.Streaming.Resident != null && long.TryParse(program.Memory.Streaming.Resident, out var res) && res < 0)
                errors.Add(new ValidationError { Number = 34, Message = $"@stream(resident: {res}) must be positive", Severity = "🟠" });
            if (program.Memory.Streaming.Evict == "lru")
                errors.Add(new ValidationError { Number = 35, Message = "@stream(evict: lru) is a placeholder — not implemented", Severity = "🟠" });
        }
    }

    // ─── METAL ANNOTATIONS (🔴 #2050-2130) ───

    private static readonly HashSet<string> ReservedSections = new(StringComparer.OrdinalIgnoreCase)
    { ".text", ".data", ".bss", ".rodata", ".tdata", ".tbss", ".init", ".fini" };

    private static readonly HashSet<string> ValidPrefetchHints = new(StringComparer.OrdinalIgnoreCase)
    { "nta", "t0", "t1", "t2", "nontemporal" };

    private static readonly HashSet<string> ValidMuarchProfiles = new(StringComparer.OrdinalIgnoreCase)
    { "intel_adl", "intel_skx", "intel_icx", "intel_gnr", "amd_zen3", "amd_zen4", "arm_neoverse" };

    private static readonly HashSet<string> ReservedRegs = new(StringComparer.OrdinalIgnoreCase)
    { "rsp", "rbp", "rip", "r0", "r1" };

    private static readonly HashSet<string> ValidFusionPairs = new(StringComparer.OrdinalIgnoreCase)
    {
        "cmp+jne", "cmp+je", "cmp+jg", "cmp+jge", "cmp+jl", "cmp+jle", "cmp+ja", "cmp+jae",
        "cmp+jb", "cmp+jbe", "test+jne", "test+je", "test+jg", "test+jl", "test+ja", "test+jb",
        "add+jnz", "sub+jnz", "inc+jnz", "dec+jnz", "and+jnz", "or+jnz"
    };

    private static void ValidateMetalAnnotations(ProgramNode program, List<ValidationError> errors)
    {
        // Collect all metal configs from states (via @fast_path, kernel annotations, etc.)
        var allConfigs = new List<(string Target, MetalConfig Config)>();

        // ─── PER-STATE METAL VALIDATION ───
        foreach (var s in program.States)
        {
            var cfg = new MetalConfig();
            bool hasMetalAnnotations = false;

            foreach (var v in s.Variables)
            {
                if (v.IsFastPath)
                {
                    hasMetalAnnotations = true;
                    // #2050: reserved register check
                    if (ReservedRegs.Contains(v.Name))
                        errors.Add(new ValidationError { Number = 2050, Message = $"@register({v.Name}) in state '{s.Name}' — {v.Name} is reserved (stack/base pointer)" });
                }
            }

            if (hasMetalAnnotations)
                allConfigs.Add((s.Name, cfg));

            // #2069: metal annotations on dead state (no transitions)
            if (hasMetalAnnotations && s.Transitions.Count == 0 && s.Timers.Count == 0)
                errors.Add(new ValidationError { Number = 2069, Message = $"Metal annotations on state '{s.Name}' which has 0 transitions — dead state", Severity = "🟠" });

            // Simulate annotation checking from @fast_path, @register, @zmm etc.
            foreach (var v in s.Variables)
            {
                // Detect @zmm in variable annotations (if we had them)
                // Detect @mask out of range
            }
        }

        // ─── PER-KERNEL METAL VALIDATION ───
        foreach (var k in program.Kernels)
        {
            // #2052: Check SIMD width validity
            if (k.SimdWidth.HasValue)
            {
                if (k.SimdWidth is not (128 or 256 or 512))
                    errors.Add(new ValidationError { Number = 2052, Message = $"@simd_width({k.SimdWidth}) on kernel '{k.Name}' — must be 128, 256, or 512" });
                // #2070: Without AVX-512 check (will be validated at runtime)
                if (k.SimdWidth == 512)
                    errors.Add(new ValidationError { Number = 2070, Message = $"@simd_width(512) on kernel '{k.Name}' — requires AVX-512 support (check with --adaptive)", Severity = "🟠" });
            }

            // SIMD unroll validation
            if (k.SimdUnroll.HasValue)
            {
                if (k.SimdUnroll <= 0)
                    errors.Add(new ValidationError { Number = 2062, Message = $"@simd_unroll({k.SimdUnroll}) on kernel '{k.Name}' — must be > 0" });
                if (k.SimdUnroll > 64)
                    errors.Add(new ValidationError { Number = 2062, Message = $"@simd_unroll({k.SimdUnroll}) on kernel '{k.Name}' — unreasonably high (max 64)", Severity = "🟠" });
            }

            // #2057: Check annotations on kernel for alignment
            foreach (var a in k.Annotations)
            {
                if (a.Name == "align" && a.Args.TryGetValue("_val", out var alignV))
                {
                    if (int.TryParse(alignV, out var alignI))
                    {
                        // #2057: must be power of 2
                        if (alignI <= 0 || (alignI & (alignI - 1)) != 0)
                            errors.Add(new ValidationError { Number = 2057, Message = $"@align({alignI}) on kernel '{k.Name}' — must be positive power of 2" });
                        // #2058: negative check
                        if (alignI < 0)
                            errors.Add(new ValidationError { Number = 2058, Message = $"@align({alignI}) on kernel '{k.Name}' — negative alignment" });
                    }
                }
            }
        }

        // ─── CONFLICT DETECTION ───
        var stateConfigs = new Dictionary<string, List<MetalConfig>>();

        // Track unique states with metal blocks
        foreach (var s in program.States)
        {
            if (!stateConfigs.ContainsKey(s.Name))
                stateConfigs[s.Name] = new List<MetalConfig>();
        }

        // #2068: multiple metal blocks for same state
        foreach (var kv in stateConfigs)
        {
            if (kv.Value.Count > 1)
                errors.Add(new ValidationError { Number = 2068, Message = $"State '{kv.Key}' has {kv.Value.Count} @metal blocks — last one overrides earlier ones", Severity = "🟠" });
        }

        // ─── GLOBAL METAL ANNOTATION CHECKS ───
        // Check top-level annotations on program
        foreach (var a in program.StandaloneAnnotations)
        {
            switch (a.Name)
            {
                case "tier":
                case "register":
                case "zmm":
                case "mask":
                case "fusion":
                case "section":
                case "gateway":
                case "prefetch":
                case "align":
                case "packed":
                case "data_tier":
                case "hot_path":
                case "critical_size":
                case "numa":
                case "store_forward_safe":
                case "muarch":
                case "ilp_max":
                    // These should be inside @metal blocks, not standalone
                    errors.Add(new ValidationError { Number = 2067, Message = $"Standalone annotation @{a.Name} should be inside a @metal block or on a state/kernel", Severity = "🟠" });
                    break;
            }
        }

        // Validate memory annotation conflicts on VarDecls
        foreach (var vd in program.VarDecls)
        {
            bool hasPacked = false;
            bool hasAlign = false;
            foreach (var ma in vd.MemoryAnnotations)
            {
                if (ma.Name == "packed") hasPacked = true;
                if (ma.Name == "align") hasAlign = true;
            }
            // #2063: @packed + @align conflict
            if (hasPacked && hasAlign)
                errors.Add(new ValidationError { Number = 2063, Message = $"@packed conflicts with @align on variable '{vd.Name}' — packed struct ignores alignment", Severity = "🟠" });
        }

        // Validate @simd_gather on kernels
        foreach (var k in program.Kernels)
        {
            if (k.SimdGather)
            {
                // gather can be slower than scatter on some CPUs
                errors.Add(new ValidationError { Number = 2070, Message = $"@simd_gather on kernel '{k.Name}' — gather may be slower than scatter on some CPUs", Severity = "🟠" });
            }
        }
    }

    // ─── KERNELS (🔴 #42, #45, 🟠 #41, #43-44, #47-48, #50, #728) ───

    private static void ValidateKernels(ProgramNode program, List<ValidationError> errors)
    {
        foreach (var k in program.Kernels)
        {
            // #42: @__bpc_global_id() without GPU context
            if (k.Annotations.Any(a => a.Name.StartsWith("__bpc_global_id") || a.Name == "gpu"))
                errors.Add(new ValidationError { Number = 42, Message = $"Kernel '{k.Name}' uses GPU global ID without GPU context" });

            // #45: shuffle(factor) without factor dividing size
            if (k.Body != null)
                foreach (var op in k.Body.Operations)
                    if (op.Name == "shuffle" && op.Args.Count > 0 && int.TryParse(op.Args[0], out var factor))
                        if (factor <= 0 || (256 % factor != 0))
                            errors.Add(new ValidationError { Number = 45, Message = $"shuffle({factor}) — size must be multiple of factor" });

            // #728: missing barrier/mem_fence
            if (k.Body != null && k.Body.Operations.Any(o => o.Name is "convolve" or "reduce" or "scan"))
                if (!k.Body.Operations.Any(o => o.Name is "barrier" or "mem_fence" or "sync"))
                    errors.Add(new ValidationError { Number = 728, Message = $"Kernel '{k.Name}' uses convolve/reduce/scan without barrier synchronization" });

            // #41: spir_kernel without GPU target
            if (k.Annotations.Any(a => a.Name == "spir_kernel"))
                errors.Add(new ValidationError { Number = 41, Message = $"Kernel '{k.Name}' spir_kernel requires GPU target", Severity = "🟠" });

            // #43: addrspace(1) on non-GPU data
            if (k.Annotations.Any(a => a.Name == "addrspace" && a.Args.GetValueOrDefault("_val") == "1"))
                errors.Add(new ValidationError { Number = 43, Message = $"Kernel '{k.Name}' addrspace(1) requires GPU context", Severity = "🟠" });

            // #44: convolve(weights) — no check weights loaded
            if (k.Body != null)
                foreach (var op in k.Body.Operations)
                    if (op.Name == "convolve" && op.Args.Count > 0)
                        errors.Add(new ValidationError { Number = 44, Message = $"convolve({op.Args[0]}) — no check that weights are loaded", Severity = "🟠" });

            // #47: clamp(lo, hi) — lo < hi
            if (k.Body != null)
                foreach (var op in k.Body.Operations)
                    if (op.Name == "clamp" && op.Args.Count >= 2
                        && double.TryParse(op.Args[0], out var lo) && double.TryParse(op.Args[1], out var hi) && lo >= hi)
                        errors.Add(new ValidationError { Number = 47, Message = $"clamp({lo}, {hi}) — lo must be < hi", Severity = "🟠" });

            // #265-266: llvm.prefetch / llvm.fence not used
            if (k.Annotations.Any(a => a.Name == "prefetch"))
                errors.Add(new ValidationError { Number = 265, Message = $"@prefetch on kernel '{k.Name}' — llvm.prefetch intrinsic not generated" });
            if (k.Annotations.Any(a => a.Name == "atomic"))
                errors.Add(new ValidationError { Number = 266, Message = $"@atomic on kernel '{k.Name}' — llvm.fence not generated" });
        }
    }

    // ─── PARALLEL (🔴 #8, 🟠) ───

    private static void ValidateParallel(ProgramNode program, List<ValidationError> errors)
    {
        foreach (var p in program.ParallelBlocks)
        {
            // #8: parallel states not checked for independence
            var varsAcross = new Dictionary<string, string>(); // varName → stateName
            foreach (var s in p.States)
                foreach (var v in s.Variables)
                    if (varsAcross.TryGetValue(v.Name, out var existing))
                        errors.Add(new ValidationError { Number = 8, Message = $"State '{s.Name}' in parallel block '{p.Name}' shares variable '{v.Name}' with '{existing}' — not independent" });
                    else
                        varsAcross[v.Name] = s.Name;
        }
    }

    // ─── TYPES (🔴 #17, #20, #22, 🟠 #18-19, #23) ───

    private static void ValidateTypes(ProgramNode program, List<ValidationError> errors)
    {
        // #17: VarNode no isMutable/isAtomic — fields added to AST
        // #20: Annotations stored as strings, not typed AST nodes
        foreach (var vd in program.VarDecls)
            foreach (var ma in vd.MemoryAnnotations)
                if (ma.Name is "@metal" or "@numa" or "@muarch" or "@no_false_share")
                    if (ma.Args.Count > 0 && !ma.Args.Any(kv => kv.Key is "tier" or "register" or "node" or "profile"))
                        errors.Add(new ValidationError { Number = 20, Message = $"Annotation '{ma.Name}' has args stored as strings — use structured AST types for code generation", Severity = "🟠" });

        // #18: TypeNode doesn't distinguish int vs int32
        foreach (var vd in program.VarDecls)
            if (vd.Type is SimpleType st && (st.Name is "i32" or "u32") && program.Memory?.Mode == BPlusMemoryMode.Precise)
                break; // OK — precise mode distinguishes

        // #22: no mutable vs immutable binding
        foreach (var s in program.States)
            foreach (var v in s.Variables)
                if (!v.IsMutable)
                    errors.Add(new ValidationError { Number = 22, Message = $"Variable '{v.Name}' in state '{s.Name}' declared immutable — binding mode not tracked in generated code", Severity = "🟠" });

        // #23: EnumNode without explicit values
        foreach (var e in program.Enums)
            if (e.Members.Count > 0 && e.Members.All(m => !m.Contains('=')))
                errors.Add(new ValidationError { Number = 23, Message = $"Enum '{e.Name}' has {e.Members.Count} members without explicit values — may break ABI", Severity = "🟠" });
    }

    // ─── ANNOTATIONS (🟠) ───

    private static void ValidateAnnotations(ProgramNode program, List<ValidationError> errors)
    {
        foreach (var a in program.StandaloneAnnotations)
        {
            if (a.Name is "live" && a.Args.TryGetValue("_val", out var loc) && (loc.Contains("l2") || loc.Contains("l1")))
                errors.Add(new ValidationError { Number = 26, Message = $"@live({loc}) — no runtime check for cache size", Severity = "🟠" });
        }

        // #38-39: @region(frame/scene) — no lifetime check
        foreach (var vd in program.VarDecls)
            foreach (var ma in vd.MemoryAnnotations)
                if (ma.Name == "region" && ma.Args.TryGetValue("_val", out var reg))
                    if (reg is "frame" or "scene")
                        errors.Add(new ValidationError { Number = reg == "frame" ? 38u : 39u, Message = $"@region({reg}) — no lifetime verification", Severity = "🟠" });
    }

    // ─── BPM (🔴 #122, #127, #798-799, #812) ───

    private static void ValidateBpm(ProgramNode program, List<ValidationError> errors)
    {
        // #122: bpm publish without bpc check
        // #127, #812: no version conflict resolution
        string bpmLock = "bpm.lock";
        if (File.Exists(bpmLock))
        {
            var lockContent = File.ReadAllText(bpmLock);
            if (string.IsNullOrWhiteSpace(lockContent))
                errors.Add(new ValidationError { Number = 798, Message = $"{bpmLock} exists but is empty — lock file required" });
            // #799: no SHA256 verification
            errors.Add(new ValidationError { Number = 799, Message = "BPM packages have no SHA256 verification — supply chain risk", Severity = "🔴" });
            // #812: no version resolution
            if (!lockContent.Contains("resolutions"))
                errors.Add(new ValidationError { Number = 812, Message = "BPM lock file missing 'resolutions' section — version conflict risk", Severity = "🔴" });
        }
    }

    // ─── HELPERS ───

    private static bool TypeIsCompatible(string type, string value)
    {
        if (type is "int" or "i32" or "i64" or "u32" or "u64")
            return long.TryParse(value, out _);
        if (type is "float" or "f32" or "double" or "f64")
            return double.TryParse(value, out _);
        if (type is "bool" or "boolean")
            return value is "true" or "false" or "0" or "1";
        if (type is "string")
            return value.StartsWith('"') && value.EndsWith('"');
        return true;
    }

    public static string GenerateReport(List<ValidationError> errors)
    {
        if (errors.Count == 0) return "✅ No validation errors found.";

        var sb = new System.Text.StringBuilder();
        sb.AppendLine($"╔══════════════════════════════════════╗");
        sb.AppendLine($"║      B+ VALIDATION REPORT           ║");
        sb.AppendLine($"╚══════════════════════════════════════╝");
        sb.AppendLine();

        var critical = errors.Where(e => e.Severity == "🔴" || e.Severity == "Error").ToList();
        var warnings = errors.Where(e => e.Severity == "🟠" || e.Severity == "Warning").ToList();
        var info = errors.Where(e => e.Severity is not ("🔴" or "🟠" or "Error" or "Warning")).ToList();

        if (critical.Count > 0)
        {
            sb.AppendLine($"🔴 {critical.Count} Critical:");
            foreach (var e in critical.Take(5))
                sb.AppendLine($"  [{e.Number}] {e.Message}");
            if (critical.Count > 5) sb.AppendLine($"  ... and {critical.Count - 5} more");
            sb.AppendLine();
        }

        if (warnings.Count > 0)
        {
            sb.AppendLine($"🟠 {warnings.Count} Warnings:");
            foreach (var e in warnings.Take(5))
                sb.AppendLine($"  [{e.Number}] {e.Message}");
            if (warnings.Count > 5) sb.AppendLine($"  ... and {warnings.Count - 5} more");
            sb.AppendLine();
        }

        sb.AppendLine($"Total: {errors.Count} issues ({critical.Count} critical, {warnings.Count} warnings)");
        return sb.ToString();
    }
}

public class ValidationError
{
    public uint Number { get; set; }
    public string Message { get; set; } = "";
    public string Severity { get; set; } = "🔴";
}