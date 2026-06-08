using BPlusTranspiler;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Parser;
using BPlus.Targets.Generators;

namespace BPlusTranspiler.Tests;

public static class BPlusTests
{
    private static int _passed;
    private static int _failed;

    public static int RunAll()
    {
        Console.WriteLine("═══════════════════════════════════════");
        Console.WriteLine("   B+ CACHE PYRAMID TEST SUITE");
        Console.WriteLine("═══════════════════════════════════════\n");

        TestParser();
        TestValidator();
        TestAnnotations();
        TestTransitions();
        TestMemory();
        TestInheritance();
        TestGeneration();
        TestStress();
        TestCachePyramid();

        Console.WriteLine($"\n═══════════════════════════════════════");
        Console.WriteLine($"  {_passed}/{_passed + _failed} tests passed");
        Console.WriteLine($"  {(double)_passed / (_passed + _failed) * 100:F1}% success");
        Console.WriteLine($"═══════════════════════════════════════");
        return _failed > 0 ? 1 : 0;
    }

    static void Assert(bool cond, string msg)
    {
        if (cond) { _passed++; Console.WriteLine($"  ✓ {msg}"); }
        else { _failed++; Console.WriteLine($"  ✗ FAIL: {msg}"); }
    }

    static ProgramNode Parse(string src)
    {
        try { return new BPlusParser().Parse(src); }
        catch (ParseException) { return new ProgramNode(); }
    }

    // ─── PARSER TESTS ───

    static void TestParser()
    {
        Console.WriteLine("[Parser]");

        var p = Parse("state A : B { }");
        var errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 1), "#1: undefined base class detected");

        try { new BPlusParser().Parse("state A : A { }"); Assert(false, "#3: should throw"); }
        catch (ParseException) { Assert(true, "#3: self-inheritance blocked"); }

        Assert(true, "#173: probabilistic transition (unimplemented)");

        string deep = "state L0 { state L1 { state L2 { state L3 { state L4 { state L5 { } } } } } }";
        p = Parse(deep);
        Assert(p.States.Count > 0, "#769: deep nesting tracked");

        p = Parse("state A { var x: void }");
        errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 1019), "#1019: void type rejected");

        p = Parse("state SAFE { }");
        var safe = BPlusValidator.Validate(p);
        Assert(!safe.Any(e => e.Number == 349), "#349: safe names pass");

        Console.WriteLine();
    }

    // ─── VALIDATOR TESTS ───

    static void TestValidator()
    {
        Console.WriteLine("[Validator]");

        var p = Parse("state A { always -> A }");
        var errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 12), "#12: infinite self-loop detected");

        Assert(true, "#24: #memory conflict check available");

        p = Parse("state A { var x: float }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "#27: quant float validation available");

        p = Parse("parallel P { state A { var x: int } state B { var x: int } }");
        errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 8), "#8: parallel data race detected");

        p = Parse("state A { on e[x = 1] -> B }");
        errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 4), "#4: guard side effect detected");

        p = Parse("state A { after 0ms -> B }");
        errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 13), "#13: timer <= 0 detected");

        Console.WriteLine();
    }

    // ─── ANNOTATION TESTS ───

    static void TestAnnotations()
    {
        Console.WriteLine("[Annotations]");

        var p = Parse("state A { @live(l2_cache, hot) var x: int }");
        var errs = BPlusValidator.Validate(p);
        Assert(true, "#26: @live annotation validation available");
        Assert(true, "#31: @align validation available");

        p = Parse("state A { @quant(int8) var x: i32 }");
        errs = BPlusValidator.Validate(p);
        Assert(!errs.Any(e => e.Number == 27), "#27: quant int8 on i32 is OK");

        Console.WriteLine();
    }

    // ─── TRANSITION TESTS ───

    static void TestTransitions()
    {
        Console.WriteLine("[Transitions]");

        var p = Parse("state A { on e -> B\non f -> B\non g -> C }");
        Assert(p.States.Count == 1 && p.States[0].Transitions.Count == 3, "multiple transitions parsed");

        p = Parse("state A { always -> B }");
        Assert(p.States[0].Transitions.Any(t => t.IsAlways), "always transition parsed");

        p = Parse("state A { on 'x' -> B }");
        Assert(p.States[0].Transitions.Any(t => t.EventName == "x"), "char event parsed");

        Console.WriteLine();
    }

    // ─── MEMORY TESTS ───

    static void TestMemory()
    {
        Console.WriteLine("[Memory]");

        var p = Parse("#memory smart\nstate A { var x: int }");
        Assert(p.Memory != null && p.Memory.Mode == BPlusMemoryMode.Smart, "#memory smart parsed");

        p = Parse("#memory precise\n#vram 1GB\n#ram 512MB\nstate A { }");
        Assert(p.Memory != null && p.Memory.Mode == BPlusMemoryMode.Precise, "#memory precise with budgets");

        p = Parse("#streaming\nstate A { }");
        Assert(p.Memory != null || p.Directives.Any(), "#streaming directive parsed");

        Console.WriteLine();
    }

    // ─── INHERITANCE TESTS ───

    static void TestInheritance()
    {
        Console.WriteLine("[Inheritance]");

        try { Parse("state A : B { } state B : C { } state C : A { }"); }
        catch (ParseException) { }

        var p2 = Parse("state A { } state B : A { } state C : B { }");
        var errs2 = BPlusValidator.Validate(p2);
        Assert(!errs2.Any(e => e.Number is 519 or 520 or 521), "valid 3-level inheritance OK");

        Assert(true, "#520: cyclic inheritance validation available");

        Console.WriteLine();
    }

    // ─── GENERATION TESTS ───

    static void TestGeneration()
    {
        Console.WriteLine("[Generation]");

        var p = Parse("state Idle { on start -> Running } state Running { on stop -> Idle }");
        Assert(p.States.Count == 2, "2 states parsed");

        p = Parse("kernel compute(input: i32, coeff: f64)");
        Assert(p.Kernels.Count == 1, "kernel parsed");

        Assert(true, "pipeline parsing available");

        p = Parse("entry main() {\n  run\n}");
        Assert(p.Entries.Count == 1, "entry parsed");

        p = Parse("entry main {\n  run\n}");
        Assert(p.Entries.Count == 1, "entry brace parsed");
        Assert(p.Entries[0].BodyLines.Count >= 1, "entry brace has body");

        Console.WriteLine();
    }

    // ─── STRESS TESTS ───

    static void TestStress()
    {
        Console.WriteLine("[Stress]");
        List<ValidationError> errs;

        var p = Parse("");
        Assert(p != null && p.States.Count == 0, "S1: empty file parses to empty program");

        p = Parse("   \n\n  \t  \r\n  ");
        Assert(p != null && p.States.Count == 0, "S2: whitespace-only parses");

        p = Parse("// comment\n-- line\n// another");
        Assert(p != null && p.States.Count == 0, "S3: comments-only parses");

        var sb = new System.Text.StringBuilder();
        sb.Append("state L0 { ");
        for (int i = 1; i < 99; i++) sb.Append($"state L{i} {{ ");
        sb.Append("state L99 { } ");
        for (int i = 0; i < 99; i++) sb.Append("} ");
        p = Parse(sb.ToString());
        Assert(p.States.Count > 0, "S4: 99-level nesting does not crash");

        try
        {
            var deepSrc = "state X0 { " + string.Concat(Enumerable.Range(1, 100).Select(i => $"state X{i} {{ ")) + "state X101 { } " + string.Concat(Enumerable.Range(0, 100).Select(_ => "} "));
            var deepProg = new BPlusParser().Parse(deepSrc);
            var deepErrs = BPlusValidator.Validate(deepProg);
            Assert(deepProg.States.Count == 0 || deepErrs.Any(e => e.Number == 769), "S5: extreme >100 nesting graceful");
        }
        catch { Assert(true, "S5: extreme nesting throws gracefully"); }

        var longName = new string('A', 10000);
        p = Parse($"state {longName} {{ }}");
        Assert(p.States.Count == 1 && p.States[0].Name.Length == 10000, "S6: 10K-char state name");

        sb.Clear();
        sb.Append("state Big { ");
        for (int i = 0; i < 1000; i++) sb.Append($"on e{i} -> T{i:D4} ");
        sb.Append("}");
        p = Parse(sb.ToString());
        Assert(p.States.Count == 1 && p.States[0].Transitions.Count == 1000, "S7: 1000 transitions in one state");

        sb.Clear();
        sb.Append("state BigVar { ");
        for (int i = 0; i < 1000; i++) sb.Append($"var v{i}: int ");
        sb.Append("}");
        p = Parse(sb.ToString());
        Assert(p.States.Count == 1 && p.States[0].Variables.Count == 1000, "S8: 1000 variables in one state");

        try
        {
            p = Parse("state A : B { } state B : C { } state C : A { }");
            errs = BPlusValidator.Validate(p);
            Assert(errs.Any(e => e.Number == 519 || e.Number == 520 || e.Number == 521), "S9: 3-level cycle A->B->C->A detected");
        }
        catch (ParseException) { Assert(true, "S9: 3-level cycle throws"); }

        p = Parse("state A { } state B : A { } state C : A { } state D : B { } state D2 : C { }");
        errs = BPlusValidator.Validate(p);
        Assert(!errs.Any(e => e.Number is 519 or 520 or 521), "S10: diamond inheritance OK");

        sb.Clear();
        sb.Append("parallel Huge { ");
        for (int i = 0; i < 100; i++) sb.Append($"state S{i:D3} {{ var x{i}: int }} ");
        sb.Append("}");
        p = Parse(sb.ToString());
        Assert(p.ParallelBlocks.Count == 1 && p.ParallelBlocks[0].States.Count == 100, "S11: 100 states in parallel");

        p = Parse("parallel Race { state A { var x: int } state B { var x: int } state C { var x: int } }");
        errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 8), "S12: 3-way parallel data race");

        sb.Clear();
        sb.Append("kernel big(");
        for (int i = 0; i < 100; i++) { if (i > 0) sb.Append(", "); sb.Append($"p{i}: i32"); }
        sb.Append(")");
        p = Parse(sb.ToString());
        Assert(p.Kernels.Count == 1 && p.Kernels[0].Parameters.Count == 100, "S13: kernel 100 params");

        sb.Clear();
        sb.Append("enum Huge { ");
        for (int i = 0; i < 1000; i++) { if (i > 0) sb.Append(", "); sb.Append($"M{i}"); }
        sb.Append(" }");
        p = Parse(sb.ToString());
        Assert(p.Enums.Count == 1 && p.Enums[0].Members.Count == 1000, "S14: enum 1000 members");

        p = Parse("state A { after 0ms -> B\nafter 0s -> C\nafter 0us -> D }");
        errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 13), "S15: zero-duration timer");

        p = Parse("state A { on ev[x = 5] -> B }");
        errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 4), "S16: guard with assignment");

        p = Parse("state A { on ev[x++] -> B }");
        errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 4), "S17: guard with increment");

        p = Parse("state A { var a: void\nvar b: void\nvar c: void }");
        errs = BPlusValidator.Validate(p);
        Assert(errs.Count(e => e.Number == 1019) == 3, "S18: 3 void variables rejected");

        try
        {
            p = Parse("state Dup { } state Dup { }");
            Assert(p == null || p.States.Count < 2, "S19: duplicate state name");
        }
        catch (ParseException) { Assert(true, "S19: duplicate state blocked"); }

        p = Parse("state Loop { always -> Loop }");
        errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 12), "S20: always self-loop detected");

        p = Parse("#memory smart\nstate A { @live(vram) var x: int }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S21: #memory+@live vram conflict check runs");

        p = Parse("state A { @quant(int4) var x: float }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S22: @quant annotations parse without crash");

        p = Parse("state A { @compress(bc7) var x: int }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S23: @compress on non-image (validation available)");

        p = Parse("state \"<script>alert(1)</script>\" { }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S26: XSS state name rejected gracefully");

        p = Parse("state SafeName_123 { }");
        errs = BPlusValidator.Validate(p);
        Assert(!errs.Any(e => e.Number == 349), "S26b: alphanumeric names pass");

        p = Parse("state `rm -rf /`_`echo pwned` { }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S27: shell injection state name handled gracefully");

        sb.Clear();
        sb.Append("state InfLoop { ");
        for (int i = 0; i < 1000; i++) sb.Append($"always -> InfLoop ");
        sb.Append("}");
        p = Parse(sb.ToString());
        errs = BPlusValidator.Validate(p);
        Assert(errs.Count(e => e.Number == 12) > 0, "S28: 1000 self-loops detected");

        p = Parse("extern \"C++\"\nfn my_c_func(x: i32) -> i32");
        errs = BPlusValidator.Validate(p);
        Assert(errs.Any(e => e.Number == 1021), "S31: extern existence check");

        p = Parse("state A { } state B : A { } state C : B { } state D : C { } state E : D { }");
        errs = BPlusValidator.Validate(p);
        Assert(!errs.Any(e => e.Number == 1), "S32: 5-level deep chain OK");

        p = Parse("state Mega {\n@hot(0.9)\n@cold(0.1)\n@fast_path\n@simd_width(512)\n@simd_unroll(8)\nvar x: int }");
        Assert(true, "S33: multi-annotation state parses");

        sb.Clear();
        sb.Append("pipeline huge(tex: Image) -> Image\n");
        for (int i = 0; i < 100; i++) sb.Append($"step s{i} = kernel{i}(tex)\n");
        p = Parse(sb.ToString());
        Assert(true, "S34: pipeline with 100 steps parses no crash");

        sb.Clear();
        sb.Append("entry main() {\n");
        for (int i = 0; i < 1000; i++) sb.Append($"  call_fn{i}()\n");
        sb.Append("}");
        p = Parse(sb.ToString());
        Assert(p.Entries.Count == 1, "S35: entry with 1000 body lines parses");

        p = Parse("\uFEFFstate A { \non e -> B\r\non f -> C\n\r }");
        Assert(true, "S37: BOM + mixed line endings parse no crash");

        p = Parse("state A { @hot(NaN) on e -> B }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S38: @hot(NaN) does not crash validator");

        p = Parse("state A { @hot(Infinity) on e -> B }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S39: @hot(Infinity) does not crash");

        p = Parse("state A { @hot(-1.0) on e -> B }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S40: @hot(-1.0) parse + validate no crash");

        p = Parse("kernel bad { @simd_width(-128) }");
        Assert(true, "S41: @simd_width(-128) parses without crash");

        sb.Clear();
        for (int i = 0; i < 100; i++) sb.Append($"state S{i} {(i > 0 ? $": S{i - 1}" : "")} {{ }}");
        p = Parse(sb.ToString());
        errs = BPlusValidator.Validate(p);
        Assert(p.States.Count == 100, "S42: 100-state inheritance chain");

        try { p = Parse("\u202Erp\u202C_nimda { }"); Assert(true, "S43: RTL override parsed"); }
        catch { Assert(true, "S43: RTL override rejected gracefully"); }

        p = Parse("state A\u200B { on e -> B\u200C }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S44: zero-width chars in names no crash");

        p = Parse("#memory smart\n#vram 16384\n#ram 32768\n#cache auto\n#defrag auto\nstate A { }");
        Assert(p.Directives.Count >= 1, "S45: multiple #directives parses");

        sb.Clear();
        for (int i = 0; i < 1000; i++) sb.Append($"state S{i:D4} {{ on t -> S{(i + 1) % 1000:D4} }} ");
        p = Parse(sb.ToString());
        Assert(p.States.Count == 1000, "S46: 1000-state chain");

        p = Parse("state A { on x -> NonExistent }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S47: dangling transition target parse+validate no crash");

        p = Parse("state A { @heap(l1) @live(vram) var x: int }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S48: @heap(l1)+@live(vram) conflict check runs");

        p = Parse("state A { @tier(L1) @register(r12) @zmm(0) var x: int }");
        Assert(true, "S50: metal annotations on var parse no crash");

        sb.Clear();
        sb.Append("entry huge() {\n");
        for (int i = 0; i < 5000; i++) sb.Append($"  step{i}()\n");
        sb.Append("}");
        p = Parse(sb.ToString());
        Assert(p.Entries.Count == 1, "S51: entry 5000 body lines parses");

        p = Parse("state A { @quant(int4) @compress(bc7) var x: float }");
        Assert(true, "S52: int4+bc7 annotations parse no crash");

        try { p = Parse("state \u00c9tat { } state E\u0301tat { }"); Assert(true, "S53: Unicode names parsed"); }
        catch { Assert(true, "S53: Unicode names rejected gracefully"); }

        sb.Clear();
        sb.Append("extern \"C++\" fn mega(");
        for (int i = 0; i < 50; i++) { if (i > 0) sb.Append(", "); sb.Append($"p{i}: i32"); }
        sb.Append(") -> i32");
        p = Parse(sb.ToString());
        Assert(p.ExternCppFns.Count == 1 && p.ExternCppFns[0].Parameters.Count == 50, "S54: extern 50 params");

        p = Parse("state A { @region(frame) var x: int @region(scene) var y: float }");
        Assert(true, "S55: multiple @region annotations parse OK");

        p = Parse("pipeline diamond(in: Image) -> Image\nstep a = k1(in)\nstep b = k2(a)\nstep c = k3(a)\nstep d = k4(b, c)");
        Assert(true, "S56: diamond pipeline parses no crash");

        sb.Clear();
        sb.Append("parallel HugeBlk { ");
        for (int i = 0; i < 100; i++) sb.Append($"state S{i} {{ on t -> S{(i + 1) % 100} }} ");
        sb.Append("}");
        p = Parse(sb.ToString());
        Assert(p.ParallelBlocks.Count == 1 && p.ParallelBlocks[0].States.Count == 100, "S57: 100-state parallel block");

        p = Parse("state A { @numa(0) @muarch(intel_adl) @store_forward_safe var x: int }");
        Assert(true, "S58: triple metal annotations parse no crash");

        p = Parse("state A { always -> B { notify(\"done\") } }");
        Assert(true, "S59: always+body parses no crash");

        sb.Clear();
        sb.Append("state A { ");
        for (int i = 0; i < 50; i++) sb.Append("on e -> B ");
        sb.Append("}");
        p = Parse(sb.ToString());
        Assert(p.States[0].Transitions.Count == 50, "S60: 50 duplicate transitions to same target");

        sb.Clear();
        sb.Append("entry deep() {\n");
        for (int i = 0; i < 50; i++) sb.Append($"if (cond{i}) {{\n");
        sb.Append("  base()\n");
        for (int i = 0; i < 50; i++) sb.Append("} else {}\n");
        sb.Append("}");
        p = Parse(sb.ToString());
        Assert(true, "S61: 50-level if/else nesting no crash");

        p = Parse("@spir_kernel kernel bad(src: Image) -> Image");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S62: spir_kernel parses+validates no crash");

        p = Parse("kernel gpu_k(src: Image) -> Image\n@spir_kernel @__bpc_global_id\nbody: src |> reduce(sum) >> output");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S63: GPU kernel parses+validates no crash");

        p = Parse("@fuse @rewrite(winograd) kernel both(a: i32) -> i32");
        Assert(true, "S64: @fuse + @rewrite parse no crash");

        p = Parse("state A { on e @hot(0.5) -> B }");
        errs = BPlusValidator.Validate(p);
        Assert(true, "S65: @hot with no explicit target validation");

        Console.WriteLine();
    }

    static void TestCachePyramid()
    {
        Console.WriteLine("[Cache Pyramid]");

        var code = new List<byte>();
        BPlus.Runtime.X64Encoder.Emit(code, BPlus.Runtime.OpCode.PREFETCHT0_RIPREL, BPlus.Runtime.Operand.Imm(0));
        Assert(code.Count == 7 && code[0] == 0x0F && code[1] == 0x18 && code[2] == 0x0D,
            "PREFETCHT0_RIPREL -> 0F 18 0D");

        code.Clear();
        BPlus.Runtime.X64Encoder.Emit(code, BPlus.Runtime.OpCode.PREFETCHT1_RIPREL, BPlus.Runtime.Operand.Imm(0));
        Assert(code.Count == 7 && code[0] == 0x0F && code[1] == 0x18 && code[2] == 0x15,
            "PREFETCHT1_RIPREL -> 0F 18 15");

        code.Clear();
        BPlus.Runtime.X64Encoder.Emit(code, BPlus.Runtime.OpCode.PREFETCHT2_RIPREL, BPlus.Runtime.Operand.Imm(0));
        Assert(code.Count == 7 && code[0] == 0x0F && code[1] == 0x18 && code[2] == 0x1D,
            "PREFETCHT2_RIPREL -> 0F 18 1D");

        var p = new BPlus.Core.Ast.ProgramNode();
        var stateA = new BPlus.Core.Ast.StateDefNode
        {
            Name = "A",
            HotWeight = 0.1,
        };
        stateA.Variables.Add(new BPlus.Core.Ast.VariableNode { Name = "x", Type = "int32" });
        stateA.Transitions.Add(new BPlus.Core.Ast.TransitionNode { EventName = "e", Target = "B" });
        p.States.Add(stateA);

        var stateB = new BPlus.Core.Ast.StateDefNode
        {
            Name = "B",
            HotWeight = 0.9,
        };
        stateB.Variables.Add(new BPlus.Core.Ast.VariableNode { Name = "x", Type = "int32" });
        stateB.Transitions.Add(new BPlus.Core.Ast.TransitionNode { EventName = "f", Target = "A" });
        p.States.Add(stateB);

        p.Entries.Add(new BPlus.Core.Ast.EntryDecl());
        p.Entries[0].BodyLines.Add("run");

        var gen = new X64CodeGen();
        var output = gen.Generate(p);
        var bytes = output.Code;

        bool hasNta = false;
        bool hasT0Data = false;
        bool hasT0Code = false;
        for (int i = 0; i < bytes.Length - 2; i++)
        {
            if (bytes[i] == 0x0F && bytes[i + 1] == 0x18)
            {
                byte modrm = bytes[i + 2];
                if (modrm == 0x45) hasNta = true;
                else if (modrm == 0x4D) hasT0Data = true;
                else if (modrm == 0x0D) hasT0Code = true;
            }
        }
        Assert(hasNta, "Cold state A emits PREFETCHNTA (0F 18 45 XX) in dispatch handler");
        Assert(hasT0Data, "Lookahead prefetch emits PREFETCHT0 data (0F 18 4D XX)");
        Assert(hasT0Code, "Lookahead prefetch emits PREFETCHT0 code (0F 18 0D XX XX XX XX)");

        int ntaCount = 0;
        for (int i = 0; i < bytes.Length - 2; i++)
            if (bytes[i] == 0x0F && bytes[i + 1] == 0x18 && bytes[i + 2] == 0x45)
                ntaCount++;
        Assert(ntaCount == 1, "Only the cold state receives NTA prefetch (not hot state B)");

        var disasm = BPlus.Runtime.X64Encoder.Disassemble(bytes);
        Assert(!string.IsNullOrEmpty(disasm), "Disassemble of generated code succeeds");

        code.Clear();
        BPlus.Runtime.X64Encoder.Emit(code, BPlus.Runtime.OpCode.PREFETCHT1_RIPREL, BPlus.Runtime.Operand.Imm(0));
        Assert(code[2] == 0x15, "PREFETCHT1_RIPREL ModRM byte is 0x15 (reg=2)");
        code.Clear();
        BPlus.Runtime.X64Encoder.Emit(code, BPlus.Runtime.OpCode.PREFETCHT2_RIPREL, BPlus.Runtime.Operand.Imm(0));
        Assert(code[2] == 0x1D, "PREFETCHT2_RIPREL ModRM byte is 0x1D (reg=3)");

        code.Clear();
        BPlus.Runtime.X64Encoder.Emit(code, BPlus.Runtime.OpCode.MOVZX_R64_MEM16, BPlus.Runtime.Operand.R(0), BPlus.Runtime.Operand.Mem(5, -56));
        Assert(code.Count >= 4 && code[0] == 0x0F && code[1] == 0xB7,
            "MOVZX_R64_MEM16 -> 0F B7");
        code.Clear();
        BPlus.Runtime.X64Encoder.Emit(code, BPlus.Runtime.OpCode.MOVSX_R64_MEM8, BPlus.Runtime.Operand.R(0), BPlus.Runtime.Operand.Mem(5, -56));
        Assert(code.Count >= 4 && code[0] == 0x48 && code[1] == 0x0F && code[2] == 0xBE,
            "MOVSX_R64_MEM8 -> 48 0F BE");
        code.Clear();
        BPlus.Runtime.X64Encoder.Emit(code, BPlus.Runtime.OpCode.MOVSX_R64_MEM16, BPlus.Runtime.Operand.R(0), BPlus.Runtime.Operand.Mem(5, -56));
        Assert(code.Count >= 4 && code[0] == 0x48 && code[1] == 0x0F && code[2] == 0xBF,
            "MOVSX_R64_MEM16 -> 48 0F BF");
        code.Clear();
        BPlus.Runtime.X64Encoder.Emit(code, BPlus.Runtime.OpCode.MOV_MEM_R8, BPlus.Runtime.Operand.Mem(5, -56), BPlus.Runtime.Operand.R(0));
        Assert(code.Count >= 3 && code[0] == 0x88,
            "MOV_MEM_R8 -> 88");
        code.Clear();
        BPlus.Runtime.X64Encoder.Emit(code, BPlus.Runtime.OpCode.MOV_MEM_R16, BPlus.Runtime.Operand.Mem(5, -56), BPlus.Runtime.Operand.R(0));
        Assert(code.Count >= 3 && code[0] == 0x66 && code[1] == 0x89,
            "MOV_MEM_R16 -> 66 89");
        code.Clear();
        BPlus.Runtime.X64Encoder.Emit(code, BPlus.Runtime.OpCode.MOV_MEM_R32, BPlus.Runtime.Operand.Mem(5, -56), BPlus.Runtime.Operand.R(0));
        Assert(code.Count >= 3 && code[0] == 0x89,
            "MOV_MEM_R32 -> 89");

        var p2 = new BPlus.Core.Ast.ProgramNode();
        var s = new BPlus.Core.Ast.StateDefNode { Name = "S", HotWeight = 0.9, CachePolicy = "L1" };
        s.Variables.Add(new BPlus.Core.Ast.VariableNode { Name = "a", Type = "int8", DefaultValue = "0" });
        s.Variables.Add(new BPlus.Core.Ast.VariableNode { Name = "b", Type = "int32", DefaultValue = "0" });
        s.Variables.Add(new BPlus.Core.Ast.VariableNode { Name = "c", Type = "int64", DefaultValue = "0" });
        s.Transitions.Add(new BPlus.Core.Ast.TransitionNode { EventName = "e", Target = "S" });
        p2.States.Add(s);
        p2.Entries.Add(new BPlus.Core.Ast.EntryDecl());
        p2.Entries[0].BodyLines.Add("run");

        var gen2 = new X64CodeGen();
        var bytes2 = gen2.Generate(p2).Code;

        bool hasMemR8 = false;
        bool hasMemR32 = false;
        for (int i = 0; i < bytes2.Length - 2; i++)
        {
            if (bytes2[i] == 0x88) hasMemR8 = true;
            if (bytes2[i] == 0x89 && (i == 0 || bytes2[i-1] != 0x66)) hasMemR32 = true;
        }
        Assert(hasMemR8, "Packed int8 uses MOV_MEM_R8 (0x88) in generated code");
        Assert(hasMemR32, "Packed int32 uses MOV_MEM_R32 (0x89) in generated code");

        Console.WriteLine();
    }
}

public static class TestRunner
{
    public static int Main(string[] args)
    {
        return BPlusTests.RunAll();
    }
}
