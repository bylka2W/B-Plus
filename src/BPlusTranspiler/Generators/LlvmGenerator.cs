using BPlusTranspiler.Ast;

namespace BPlusTranspiler.Generators;

public class LlvmGenerator : ICodeGenerator
{
    readonly string _platform;
    readonly string _arch;
    readonly bool _pgoCollect;
    readonly string? _pgoUse;
    readonly string? _ltoMode;
    readonly bool _cAbi;
    int _labelId;
    int? _ppw;           // pixels per work group
    int? _tileStride;    // tile stride = _ppw + 2
    int? _simdWidth;     // @simd_width from kernel annotation
    int? _simdUnroll;    // @simd_unroll from kernel annotation
    bool _simdGather;    // @simd_gather from kernel annotation

    public LlvmGenerator(
        string platform = "native",
        string arch = "auto",
        bool pgoCollect = false,
        string? pgoUse = null,
        string? ltoMode = null,
        bool cAbi = false)
    {
        _platform = platform;
        _arch = arch;
        _pgoCollect = pgoCollect;
        _pgoUse = pgoUse;
        _ltoMode = ltoMode;
        _cAbi = cAbi;
    }

    int NextLabel() => _labelId++;

    public string GetLanguageName() => _platform switch
    {
        "wasm" => "WASM",
        "arm64" or "ios" or "android" => "ARM64",
        _ => "LLVM"
    };

    public string GetFileExtension() => ".ll";

    // Architecture-specific work group sizes for auto-tuning
    (int x, int y) LocalSize => _arch switch
    {
        "nvidia" => (16, 16),
        "amd"    => (16, 8),
        "intel"  => (16, 16),
        "apple"  => (8, 8),
        _        => (16, 16)
    };

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var files = new Dictionary<string, string>();
        var ll = new LlvmIrBuilder(_platform, _pgoCollect, _ltoMode);

        var kernelNames = new List<string>();

        foreach (var k in program.Kernels)
        {
            EmitKernel(ll, k);
            kernelNames.Add($"kernel_{k.Name}");
        }

        if (_pgoCollect || _ltoMode != null)
            EmitModuleFooter(ll, kernelNames);

        foreach (var e in program.Entries)
            EmitEntry(ll, e);

        files.Add("kernels.ll", ll.ToString());

        if (program.Kernels.Count == 0) return files;

        var names = program.Kernels.Select(k => $"kernel_{k.Name}").ToList();

        files.Add("BPlusBridge.cs", Gen.CSharp(names));
        files.Add("bplus_bridge.py", Gen.Python(names));
        files.Add("bplus_bridge.h", Gen.C(names, _cAbi));
        files.Add("bplus_bridge.rs", Gen.Rust(names));
        files.Add("bplus_bridge_swift.swift", Gen.Swift(names));
        files.Add("bplus_bridge_kt.kt", Gen.Kotlin(names));

        // C ABI export definition file for Windows .dll
        if (_cAbi)
        {
            var def = "EXPORTS\n";
            foreach (var n in names)
                def += $"  {n}\n";
            files.Add("bplus_kernels.def", def);
        }

        return files;
    }

    static long HashPGO(string name)
    {
        // Simple stable hash for PGO function name
        long h = 0;
        foreach (char c in name)
            h = h * 97 + c;
        return h & 0x7FFFFFFFFFFFFFFF;
    }

    void EmitModuleFooter(LlvmIrBuilder ll, List<string> kernelNames)
    {
        // PGO: profile name globals + counter arrays (one per instrumented function)
        if (_pgoCollect)
        {
            var allNames = new List<string>(kernelNames) { "main" };
            foreach (var fn in allNames)
            {
                var nameStr = fn + "\0";
                var len = nameStr.Length;
                ll.RawLine($"@__profn_{fn} = private constant [{len} x i8] c\"{nameStr}\"");
                ll.RawLine($"@__profc_{fn} = private global [1 x i64] zeroinitializer");
            }
        }

        // LTO: @llvm.used for exported kernel symbols
        if (_ltoMode != null && kernelNames.Count > 0)
        {
            var entries = string.Join(", ", kernelNames.Select(n => $"ptr @{n}"));
            ll.RawLine($"@llvm.used = appending global [{kernelNames.Count} x ptr] [{entries}]");
        }

        // LTO module flags
        if (_ltoMode == "thin")
        {
            ll.RawLine("!llvm.module.flags = !{!0}");
            ll.RawLine("!0 = !{i32 1, !\"ThinLTO\", i32 0}");
        }
        else if (_ltoMode == "full")
        {
            ll.RawLine("!llvm.module.flags = !{!0}");
            ll.RawLine("!0 = !{i32 1, !\"LTO\", i32 1}");
        }

        if (_pgoCollect)
        {
            ll.RawLine("");
        }
    }

    void EmitKernel(LlvmIrBuilder ll, KernelDecl k)
    {
        // Apply kernel SIMD annotations
        _simdWidth = k.SimdWidth;
        _simdUnroll = k.SimdUnroll;
        _simdGather = k.SimdGather;

        int h = Dim(k.Parameters.FirstOrDefault()?.Type, "H", 1080);
        int w = Dim(k.Parameters.FirstOrDefault()?.Type, "W", 1920);
        int total = h * w * 4;

        bool gpu = k.Annotations.Any(a => a.Name == "region" &&
                     a.Args.GetValueOrDefault("_val") is "frame" or "scene");

        // Check for C ABI export — @export("C") annotation or global --c-abi flag
        bool exportC = k.Annotations.Any(a => a.Name == "export" &&
                        a.Args.GetValueOrDefault("_val") is "C");
        if (_cAbi) exportC = true;

        var pars = new List<string>();
        foreach (var p in k.Parameters) pars.Add($"ptr %{p.Name}");
        if (k.OutputParam != null) pars.Add($"ptr %{k.OutputParam.Name}");

        string cc = gpu ? "spir_kernel " : "";
        string attr = gpu ? " [nounwind]" : "";
        string exportAttr = (!gpu && exportC) ? "dllexport " : "";

        ll.Line($"; Kernel: {k.Name}");
        ll.Line($"; Image: {w}x{h}x4 = {total}px");
        ll.Line($"; Pipeline: {Desc(k.Body)}");
        if (gpu) ll.Line($"; GPU arch: {_arch}, work group: {LocalSize.x}x{LocalSize.y}");
        foreach (var a in k.Annotations)
            ll.Line($"; @{a.Name}({string.Join(" ", a.Args.Select(kv => $"{kv.Key}={kv.Value}"))})");

        ll.Line($"define {exportAttr}{cc}void @kernel_{k.Name}({string.Join(", ", pars)}){attr} {{");
        ll.Indent();
        ll.Line("entry:");

        // SIMD metadata from annotations
        if (k.SimdWidth.HasValue || k.SimdUnroll.HasValue || k.SimdGather)
        {
            ll.Line("  ; SIMD directives from annotations");
            if (k.SimdWidth.HasValue)
                ll.Line($"  ; simd_width: {k.SimdWidth.Value}");
            if (k.SimdUnroll.HasValue)
                ll.Line($"  ; simd_unroll: {k.SimdUnroll.Value}");
            if (k.SimdGather)
                ll.Line("  ; simd_gather: enabled");
        }

        if (_pgoCollect)
        {
            var nameBytes = $"kernel_{k.Name}\0";
            ll.Line($"  call void @llvm.instrprof.increment(ptr @__profn_kernel_{k.Name}, i64 {HashPGO(k.Name)}, i32 1, i32 0)");
        }

        var src = k.Parameters.Count > 0 ? k.Parameters[0].Name : "src";
        var dst = k.OutputParam?.Name ?? "out";

        if (gpu)
        {
            ll.GpuMode = true;
            EmitGpuBody(ll, k, total, h, w, src, dst);
            return;
        }

        ll.Line($"  %sp = load ptr, ptr %{src}");
        ll.Line($"  %dp = load ptr, ptr %{dst}");
        ll.Line($"  %b0 = alloca float, i64 {total}");
        ll.Line($"  %b1 = alloca float, i64 {total}");
        ll.Line($"  call void @llvm.memcpy.p0.p0.i64(ptr %b0, ptr %sp, i64 {total * 4}, i1 false)");
        ll.Line("  br label %op0");

        if (k.Body != null)
        {
            int idx = 0, n = k.Body.Operations.Count;
            bool useB0 = true;
            string last = "b0";
            foreach (var op in k.Body.Operations)
            {
                var ib = useB0 ? "b0" : "b1";
                var ob = useB0 ? "b1" : "b0";
                last = ob;
                EmitOp(ll, op, idx++, total, h, w, ib, ob, idx == n);
                useB0 = !useB0;
            }
            ll.Line($"  call void @llvm.memcpy.p0.p0.i64(ptr %dp, ptr %{last}, i64 {total * 4}, i1 false)");
        }

        ll.Line("  ret void");
        ll.Dedent();
        ll.Line("}");

        // SIMD loop metadata (emitted after kernel function)
        if (k.Body != null && (_simdWidth.HasValue || _simdUnroll.HasValue || _simdGather))
        {
            var mdLines = new List<string>();
            mdLines.Add($"!0 = !{{!\"llvm.loop.vectorize.enable\", i1 true}}");
            int mi = 1;
            if (_simdWidth.HasValue)
                mdLines.Add($"!{mi++} = !{{!\"llvm.loop.vectorize.width\", i32 {_simdWidth.Value}}}");
            if (_simdUnroll.HasValue)
                mdLines.Add($"!{mi++} = !{{!\"llvm.loop.unroll.count\", i32 {_simdUnroll.Value}}}");
            if (_simdGather)
                mdLines.Add($"!{mi++} = !{{!\"llvm.loop.mustprogress\", i1 true}}");
            // Loop metadata itself: 0.llvm.loop = !{!0, !1, ...}
            var refs = string.Join(", ", Enumerable.Range(0, mi).Select(i => $"!{i}"));
            mdLines.Add($"!0.loop = !{{{refs}}}");
            foreach (var md in mdLines)
                ll.RawLine(md);
        }
        ll.Line("");
    }

    void EmitGpuBody(LlvmIrBuilder ll, KernelDecl k, int total, int h, int w, string src, string dst)
    {
        bool needsConvolve = k.Body != null && k.Body.Operations.Any(o => o.Name == "convolve");
        bool needsShuffle  = k.Body != null && k.Body.Operations.Any(o => o.Name == "shuffle");

        ll.Line("  ; work-group size hints");
        ll.Line($"  !{k.Name}.wg = !{{!\"{LocalSize.x},{LocalSize.y},1\"}}");
        ll.Line("");
        ll.Line($"  %gid = call i64 @__bpc_global_id(i32 0)");
        ll.Line($"  %ok = icmp ult i64 %gid, {total}");
        ll.Line($"  br i1 %ok, label %work, label %exit");
        ll.Line("work:");

        // Allocate shared memory tile for convolution (3 rows × (ppw+2) cols × 4 ch)
        // Center row: work group's pixels; left/right halo for edge neighbors
        // Top/bottom rows loaded cooperatively from global, 1-pixel vertical halo
        int ppw = 0, tileStride = 0, tileSize = 0;
        if (needsConvolve)
        {
            ppw = (LocalSize.x * LocalSize.y) / 4;
            tileStride = ppw + 2;
            tileSize = 3 * tileStride * 4;
            _ppw = ppw;
            _tileStride = tileStride;
            ll.Line("  ; shared memory tile for convolution (3 rows × (ppw+2) × 4ch)");
            ll.Line($"  %sm_base = alloca [{tileSize} x float], addrspace(3)");
        }

        ll.Line($"  %g0 = getelementptr float, ptr addrspace(1) %{src}, i64 %gid");
        ll.Line($"  %g1 = load float, ptr addrspace(1) %g0");

        int gi = 2;
        if (needsConvolve)
            gi = EmitGpuTileLoad(ll, gi, ppw, tileStride, w, h, total, src);

        string storeIdx = "%gid";
        if (k.Body != null)
            foreach (var op in k.Body.Operations)
            {
                string? storeOverride;
                (gi, storeOverride) = GpuOp(ll, op, gi, h, w, total, src, dst);
                if (storeOverride != null) storeIdx = storeOverride;
            }

        bool skipStore = storeIdx == "__skip";
        if (!skipStore)
        {
            ll.Line($"  %go = getelementptr float, ptr addrspace(1) %{dst}, i64 {storeIdx}");
            ll.Line($"  store float %g{gi - 1}, ptr addrspace(1) %go");
        }
        ll.Line($"  br label %exit");
        ll.Line("exit:");
        ll.Line("  ret void");
        ll.Dedent();
        ll.Line("}");
        ll.Line("declare i64 @__bpc_global_id(i32) nounwind");
        ll.Line("declare float @llvm.fabs.f32(float) nounwind readnone");
        ll.Line("declare void @__bpc_barrier() nounwind");
        ll.Line("");

        if (needsConvolve && (_arch == "nvidia" || _arch == "amd" || _arch == "intel"))
            EmitWmmaDeclarations(ll);
    }

    void EmitWmmaDeclarations(LlvmIrBuilder ll)
    {
        if (_arch == "nvidia" || _arch == "auto")
        {
            ll.Line("; NVIDIA Tensor Core (WMMA) intrinsics");
            ll.Line("declare <4 x float> @llvm.nvvm.wmma.m16n16k16.load.c.row.stride.f32(ptr nocapture readonly, i32)");
            ll.Line("declare <2 x i32> @llvm.nvvm.wmma.m16n16k16.load.a.row.stride.s32(ptr nocapture readonly, i32)");
            ll.Line("declare <2 x i32> @llvm.nvvm.wmma.m16n16k16.load.b.row.stride.s32(ptr nocapture readonly, i32)");
            ll.Line("declare <4 x float> @llvm.nvvm.wmma.m16n16k16.mma.row.row.f32.f32(<2 x i32>, <2 x i32>, <4 x float>)");
            ll.Line("declare void @llvm.nvvm.wmma.m16n16k16.store.d.row.stride.f32(ptr nocapture writeonly, <4 x float>, i32)");
            ll.Line("");
        }
        if (_arch == "amd")
        {
            ll.Line("; AMD CDNA (MFMA) intrinsics");
            ll.Line("declare <4 x float> @llvm.amdgcn.mfma.f32.16x16x4f64(<4 x double>, <4 x double>, <4 x float>, i32, i32, i32)");
            ll.Line("declare <16 x float> @llvm.amdgcn.mfma.f32.32x32x4f64(<4 x double>, <4 x double>, <16 x float>, i32, i32, i32)");
            ll.Line("declare <4 x float> @llvm.amdgcn.mfma.f32.16x16x1f32(<4 x float>, <4 x float>, <4 x float>, i32, i32, i32)");
            ll.Line("");
        }
        if (_arch == "intel")
        {
            ll.Line("; Intel XMX (Xe Matrix Extensions) intrinsics");
            ll.Line("declare <8 x float> @llvm.genx.GenX.WMMA.8x8x16(<8 x i32>, <8 x i32>, <8 x float>)");
            ll.Line("declare <16 x float> @llvm.genx.GenX.WMMA.16x16x16(<16 x i32>, <16 x i32>, <16 x float>)");
            ll.Line("");
        }
    }

    (int next, string? storeIdx) GpuOp(LlvmIrBuilder ll, PipelineOp op, int gi, int h, int w, int total, string src, string dst)
    {
        switch (op.Name)
        {
            case "relu":
                ll.Line($"  %g{gi} = fcmp olt float %g{gi - 1}, 0.0");
                ll.Line($"  %g{gi + 1} = select i1 %g{gi}, float 0.0, float %g{gi - 1}");
                return (gi + 2, null);

            case "clamp":
                string clo = op.Args.Count > 0 ? op.Args[0] : "0.0";
                string chi = op.Args.Count > 1 ? op.Args[1] : "1.0";
                ll.Line($"  %g{gi} = fcmp ogt float %g{gi - 1}, {chi}");
                ll.Line($"  %g{gi + 1} = select i1 %g{gi}, float {chi}, float %g{gi - 1}");
                ll.Line($"  %g{gi + 2} = fcmp olt float %g{gi + 1}, {clo}");
                ll.Line($"  %g{gi + 3} = select i1 %g{gi + 2}, float {clo}, float %g{gi + 1}");
                return (gi + 4, null);

            case "convolve":
                return EmitGpuConvolve(ll, gi, h, w, total, src);

            case "shuffle":
                return EmitGpuShuffle(ll, gi, h, w, dst);

            case "motion_vectors":
                return EmitGpuMotionVectors(ll, op, gi, src);

            case "warp":
                return EmitGpuWarp(ll, op, gi, h, w, total, src);

            case "atomic_add":
                ll.Line($"  %g{gi} = atomicrmw add ptr addrspace(1) %{dst}, float %g{gi - 1} monotonic");
                ll.Line($"  %g{gi + 1} = fadd float %g{gi}, %g{gi - 1}  ; old + val");
                return (gi + 2, "__skip");

            case "atomic_sub":
                ll.Line($"  %g{gi} = atomicrmw sub ptr addrspace(1) %{dst}, float %g{gi - 1} monotonic");
                ll.Line($"  %g{gi + 1} = fsub float %g{gi}, %g{gi - 1}  ; old - val");
                return (gi + 2, "__skip");

            case "atomic_max":
                ll.Line($"  %g{gi} = atomicrmw max ptr addrspace(1) %{dst}, float %g{gi - 1} monotonic");
                return (gi + 1, "__skip");

            case "atomic_min":
                ll.Line($"  %g{gi} = atomicrmw min ptr addrspace(1) %{dst}, float %g{gi - 1} monotonic");
                return (gi + 1, "__skip");

            case "if":
                return EmitGpuIf(ll, op, gi, h, w, total, src, dst);

            case "for":
                return EmitGpuFor(ll, op, gi, h, w, total, src, dst);

            case "while":
                return EmitGpuWhile(ll, op, gi, h, w, total, src, dst);

            default:
                ll.Line($"  %g{gi} = fadd float %g{gi - 1}, 0.0  ; {op.Name} stub");
                return (gi + 1, null);
        }
    }

    int EmitGpuTileLoad(LlvmIrBuilder ll, int gi, int ppw, int tileStride, int w, int h, int total, string src)
    {
        // Cooperative tile load: store center row, then barrier
        // Each thread stores its own pixel at tile position (t+1, ch)
        // where t = (gid/4) % ppw (position within work group strip)
        int pix = gi, ch = gi + 1, t = gi + 2, tc = gi + 3, ti = gi + 4;
        ll.Line("  ; tile load: store center row into shared memory");
        ll.Line($"  %g{pix} = udiv i64 %gid, 4");
        ll.Line($"  %g{ch} = urem i64 %gid, 4");
        ll.Line($"  %g{t} = urem i64 %g{pix}, {ppw}");
        ll.Line($"  %g{tc} = add i64 %g{t}, 1");
        ll.Line($"  %g{ti} = mul i64 %g{tc}, 4");
        ll.Line($"  %g{ti + 1} = add i64 %g{ti}, %g{ch}");
        ll.Line($"  %g{ti + 2} = getelementptr float, ptr addrspace(3) %sm_base, i64 %g{ti + 1}");
        ll.Line($"  store float %g1, ptr addrspace(3) %g{ti + 2}");
        ll.Line("  call void @__bpc_barrier()");
        return gi + 6;
    }

    (int next, string? storeIdx) EmitGpuConvolve(LlvmIrBuilder ll, int gi, int h, int w, int total, string src)
    {
        // Real 3×3 box blur with shared memory tile for left/right neighbors
        // Top/bottom/diagonal neighbors still read from global memory with bounds clamping
        // gid is the current pixel index (0..total-1)

        int ppw = _ppw ?? 0;
        bool useTile = ppw > 0;

        ll.Line("  ; 3×3 convolution with shared memory tile (left/right)");
        ll.Line($"  %g{gi} = udiv i64 %gid, 4        ; pixel index");
        ll.Line($"  %g{gi + 1} = urem i64 %gid, 4      ; channel");
        ll.Line($"  %g{gi + 2} = urem i64 %g{gi}, {w}  ; x");
        ll.Line($"  %g{gi + 3} = udiv i64 %g{gi}, {w}  ; y");
        int ch = gi + 1;
        int xR = gi + 2, yR = gi + 3;
        int tR = gi + 4, tcR = gi + 5;

        if (useTile)
        {
            ll.Line($"  %g{tR} = urem i64 %g{gi}, {ppw}  ; t = pixel % ppw");
            ll.Line($"  %g{tcR} = add i64 %g{tR}, 1       ; tile_col = t + 1");
        }

        // Neighbor offsets for 3×3: TL, T, TR, L, R, BL, B, BR
        var offsets = new[] { (-1,-1), (0,-1), (1,-1), (-1,0), (1,0), (-1,1), (0,1), (1,1) };
        int[] nReg = new int[8];
        int o = useTile ? gi + 6 : gi + 4;

        // Load each neighbor — left/right use tile when available, rest use global
        for (int i = 0; i < 8; i++)
        {
            (int dx, int dy) = offsets[i];

            if (useTile && dy == 0 && (dx == -1 || dx == 1))
            {
                // Left/right neighbor: try tile, fallback to global
                // In-tile check: left (dx=-1) → t > 0; right (dx=1) → t < ppw-1
                bool isLeft = dx == -1;
                int inTile = o++;
                if (isLeft)
                    ll.Line($"  %g{inTile} = icmp ugt i64 %g{tR}, 0  ; left in tile?");
                else
                    ll.Line($"  %g{inTile} = icmp ult i64 %g{tR}, {ppw - 1}  ; right in tile?");

                // Tile read: position = (tcR +/- 1) * 4 + ch
                int tileCol = o++;
                if (isLeft)
                    ll.Line($"  %g{tileCol} = add i64 %g{tcR}, -1  ; tile col = t");
                else
                    ll.Line($"  %g{tileCol} = add i64 %g{tcR}, 1   ; tile col = t+2");
                int tileIdx = o++;
                ll.Line($"  %g{tileIdx} = mul i64 %g{tileCol}, 4");
                int tileIdx2 = o++;
                ll.Line($"  %g{tileIdx2} = add i64 %g{tileIdx}, %g{ch}");
                int tilePtr = o++;
                ll.Line($"  %g{tilePtr} = getelementptr float, ptr addrspace(3) %sm_base, i64 %g{tileIdx2}");
                int tileVal = o++;
                ll.Line($"  %g{tileVal} = load float, ptr addrspace(3) %g{tilePtr}");

                // Global fallback: clamp x to [0, w), no y change
                int gx = o++;
                ll.Line($"  %g{gx} = add i64 %g{xR}, {dx}");
                int gxLt = o++;
                ll.Line($"  %g{gxLt} = icmp slt i64 %g{gx}, 0");
                int gxGe = o++;
                ll.Line($"  %g{gxGe} = icmp sge i64 %g{gx}, {w}");
                int gxOob = o++;
                ll.Line($"  %g{gxOob} = or i1 %g{gxLt}, %g{gxGe}");
                int gxClamp = o++;
                ll.Line($"  %g{gxClamp} = select i1 %g{gxOob}, i64 %g{xR}, i64 %g{gx}");
                int gpixel = o++;
                ll.Line($"  %g{gpixel} = mul i64 %g{yR}, {w}");
                int gpixel2 = o++;
                ll.Line($"  %g{gpixel2} = add i64 %g{gpixel}, %g{gxClamp}");
                int gpixel3 = o++;
                ll.Line($"  %g{gpixel3} = mul i64 %g{gpixel2}, 4");
                int gpixel4 = o++;
                ll.Line($"  %g{gpixel4} = add i64 %g{gpixel3}, %g{ch}");
                int gPtr = o++;
                ll.Line($"  %g{gPtr} = getelementptr float, ptr addrspace(1) %{src}, i64 %g{gpixel4}");
                int gVal = o++;
                ll.Line($"  %g{gVal} = load float, ptr addrspace(1) %g{gPtr}");

                // Select tile vs global
                int sel = o++;
                ll.Line($"  %g{sel} = select i1 %g{inTile}, float %g{tileVal}, float %g{gVal}");
                nReg[i] = sel;
            }
            else
            {
                // Global neighbor with full bounds clamping (x + y)
                int c = o;
                ll.Line($"  %g{c} = add i64 %g{xR}, {dx}");
                ll.Line($"  %g{c + 1} = icmp slt i64 %g{c}, 0");
                ll.Line($"  %g{c + 2} = icmp sge i64 %g{c}, {w}");
                ll.Line($"  %g{c + 3} = or i1 %g{c + 1}, %g{c + 2}");
                ll.Line($"  %g{c + 4} = select i1 %g{c + 3}, i64 %g{xR}, i64 %g{c}  ; clamp x");
                ll.Line($"  %g{c + 5} = add i64 %g{yR}, {dy}");
                ll.Line($"  %g{c + 6} = icmp slt i64 %g{c + 5}, 0");
                ll.Line($"  %g{c + 7} = icmp sge i64 %g{c + 5}, {h}");
                ll.Line($"  %g{c + 8} = or i1 %g{c + 6}, %g{c + 7}");
                ll.Line($"  %g{c + 9} = select i1 %g{c + 8}, i64 %g{yR}, i64 %g{c + 5}  ; clamp y");
                ll.Line($"  %g{c + 10} = mul i64 %g{c + 9}, {w}");
                ll.Line($"  %g{c + 11} = add i64 %g{c + 10}, %g{c + 4}");
                ll.Line($"  %g{c + 12} = mul i64 %g{c + 11}, 4");
                ll.Line($"  %g{c + 13} = add i64 %g{c + 12}, %g{ch}");
                ll.Line($"  %g{c + 14} = getelementptr float, ptr addrspace(1) %{src}, i64 %g{c + 13}");
                ll.Line($"  %g{c + 15} = load float, ptr addrspace(1) %g{c + 14}");
                nReg[i] = c + 15;
                o = c + 16;
            }
        }

        // Accumulate weighted sum (unchanged)
        // Neighbor order: TL, T, TR, L, R, BL, B, BR
        // Weighted sum: center ×4, cardinal (T,L,R,B) ×2, diagonal (TL,TR,BL,BR) ×1, /16
        int a = o;
        ll.Line($"  %g{a} = fmul float %g{gi - 1}, 4.0  ; center ×4");
        ll.Line($"  %g{a + 1} = fadd float %g{nReg[1]}, %g{nReg[3]}  ; T + L");
        ll.Line($"  %g{a + 2} = fadd float %g{nReg[4]}, %g{nReg[6]}  ; R + B");
        ll.Line($"  %g{a + 3} = fadd float %g{a + 1}, %g{a + 2}");
        ll.Line($"  %g{a + 4} = fmul float %g{a + 3}, 2.0  ; cardinal ×2");
        ll.Line($"  %g{a + 5} = fadd float %g{a}, %g{a + 4}");
        ll.Line($"  %g{a + 6} = fadd float %g{nReg[0]}, %g{nReg[2]}  ; TL + TR");
        ll.Line($"  %g{a + 7} = fadd float %g{nReg[5]}, %g{nReg[7]}  ; BL + BR");
        ll.Line($"  %g{a + 8} = fadd float %g{a + 6}, %g{a + 7}");
        ll.Line($"  %g{a + 9} = fadd float %g{a + 5}, %g{a + 8}");
        ll.Line($"  %g{a + 10} = fdiv float %g{a + 9}, 16.0  ; normalize");

        return (a + 11, null);
    }

    (int next, string? storeIdx) EmitGpuShuffle(LlvmIrBuilder ll, int gi, int h, int w, string dst)
    {
        // ESPCN pixel shuffle 2× on GPU — scatter store position
        // Compute output position, pass input value through at end
        int outW = w * 2;

        ll.Line("  ; ESPCN pixel shuffle 2× — scatter");
        ll.Line($"  %g{gi} = udiv i64 %gid, 4          ; pixel index");
        ll.Line($"  %g{gi + 1} = urem i64 %gid, 4        ; channel (0=R,1=G,2=B,3=A)");
        ll.Line($"  %g{gi + 2} = udiv i64 %g{gi}, {w}    ; in_y");
        ll.Line($"  %g{gi + 3} = urem i64 %g{gi}, {w}    ; in_x");
        ll.Line($"  %g{gi + 4} = udiv i64 %g{gi + 1}, 2  ; dy (0 for R/G, 1 for B/A)");
        ll.Line($"  %g{gi + 5} = urem i64 %g{gi + 1}, 2  ; dx (0 for R/B, 1 for G/A)");
        ll.Line($"  %g{gi + 6} = mul i64 %g{gi + 2}, 2");
        ll.Line($"  %g{gi + 7} = add i64 %g{gi + 6}, %g{gi + 4}  ; out_y = in_y*2 + dy");
        ll.Line($"  %g{gi + 8} = mul i64 %g{gi + 3}, 2");
        ll.Line($"  %g{gi + 9} = add i64 %g{gi + 8}, %g{gi + 5}  ; out_x = in_x*2 + dx");
        ll.Line($"  %g{gi + 10} = mul i64 %g{gi + 7}, {outW}");
        ll.Line($"  %g{gi + 11} = add i64 %g{gi + 10}, %g{gi + 9}  ; out_gid");
        // Pass through value after shuffle computation (value stays at %g{gi+12})
        ll.Line($"  %g{gi + 12} = fadd float %g{gi - 1}, 0.0  ; pass through value");
        ll.Line($"  ; shuffle: value at %g{gi + 12} -> store at out_gid=%g{gi + 11}");

        return (gi + 13, $"%g{gi + 11}");
    }

    (int next, string? storeIdx) EmitGpuMotionVectors(LlvmIrBuilder ll, PipelineOp op, int gi, string src)
    {
        // Motion estimation: compare current pixel with reference frame
        // Pipeline: value = current pixel value (may be from previous op)
        // Reference frame is the same buffer src at same position
        // Computes per-pixel SAD-like metric: |current - ref|
        string refFrame = op.Args.Count > 0 ? op.Args[0] : src;

        ll.Line("  ; motion_vectors: per-pixel SAD");
        ll.Line($"  %g{gi} = getelementptr float, ptr addrspace(1) %{refFrame}, i64 %gid");
        ll.Line($"  %g{gi + 1} = load float, ptr addrspace(1) %g{gi}");
        ll.Line($"  %g{gi + 2} = fsub float %g{gi - 1}, %g{gi + 1}  ; current - ref");
        ll.Line($"  %g{gi + 3} = call float @llvm.fabs.f32(float %g{gi + 2})  ; |diff|");
        return (gi + 4, null);
    }

    (int next, string? storeIdx) EmitGpuIf(LlvmIrBuilder ll, PipelineOp op, int gi, int h, int w, int total, string src, string dst)
    {
        // if (threshold) { then_body } else { else_body }
        string threshold = op.Args.Count > 0 ? op.Args[0] : "0.0";
        int tId = NextLabel();
        string thenL = $"if_then_{tId}";
        string elseL = $"if_else_{tId}";
        string mergeL = $"if_merge_{tId}";

        // Save the current pipeline value at %g{gi}, then compute condition at %g{gi+1}
        ll.Line($"  %g{gi} = fadd float %g{gi - 1}, 0.0  ; save val");
        // Temporarily set aside registers: value at %g{gi}, we'll use gi+2 as base for branches
        int valReg = gi;        // register holding the value
        int condReg = gi + 1;   // register holding the condition
        ll.Line($"  %g{condReg} = fcmp ogt float %g{valReg}, {threshold}");
        ll.Line($"  br i1 %g{condReg}, label %{thenL}, label %{elseL}");
        ll.Line($"{thenL}:");
        int giThen = condReg + 1;
        // Make a copy of the value at giThen so GpuOp sees %g{giThen-1} = value
        ll.Line($"  %g{giThen} = fadd float %g{valReg}, 0.0  ; then input");
        giThen++;
        if (op.NestedBody != null)
            foreach (var sub in op.NestedBody.Operations)
            {
                string? so;
                (giThen, so) = GpuOp(ll, sub, giThen, h, w, total, src, dst);
            }
        ll.Line($"  br label %{mergeL}");

        ll.Line($"{elseL}:");
        int giElse = giThen;
        // Make a copy of the value at giElse so GpuOp sees %g{giElse-1} = value
        ll.Line($"  %g{giElse} = fadd float %g{valReg}, 0.0  ; else input");
        giElse++;
        if (op.ElseBody != null)
            foreach (var sub in op.ElseBody.Operations)
            {
                string? so;
                (giElse, so) = GpuOp(ll, sub, giElse, h, w, total, src, dst);
            }
        ll.Line($"  br label %{mergeL}");

        ll.Line($"{mergeL}:");
        int maxGi = Math.Max(giThen, giElse);
        ll.Line($"  %g{maxGi} = phi float [ %g{giThen - 1}, %{thenL} ], [ %g{giElse - 1}, %{elseL} ]");
        return (maxGi + 1, null);
    }

    (int next, string? storeIdx) EmitGpuFor(LlvmIrBuilder ll, PipelineOp op, int gi, int h, int w, int total, string src, string dst)
    {
        // for (iterations) { body } — unroll N times
        string iterations = op.Args.Count > 0 ? op.Args[0] : "1";
        if (!int.TryParse(iterations, out int n)) n = 1;

        ll.Line($"  ; for loop: {n} iterations (unrolled)");
        int cur = gi;
        for (int i = 0; i < n; i++)
        {
            ll.Line($"  ; iteration {i}");
            if (op.NestedBody != null)
                foreach (var sub in op.NestedBody.Operations)
                {
                    string? so;
                    (cur, so) = GpuOp(ll, sub, cur, h, w, total, src, dst);
                }
            else
            {
                ll.Line($"  %g{cur} = fadd float %g{cur - 1}, 0.0  ; pass through");
                cur++;
            }
        }
        return (cur, null);
    }

    (int next, string? storeIdx) EmitGpuWhile(LlvmIrBuilder ll, PipelineOp op, int gi, int h, int w, int total, string src, string dst)
    {
        // while (threshold) { body } — dynamic loop with phi at cond header
        // Body block emitted before cond so phi can reference body result
        string threshold = op.Args.Count > 0 ? op.Args[0] : "0.0";
        int tId = NextLabel();
        string entryL = $"while_entry_{tId}";
        string condL = $"while_cond_{tId}";
        string bodyL = $"while_body_{tId}";
        string exitL = $"while_exit_{tId}";
        int valReg = gi, phiReg = gi + 1, condReg = gi + 2;

        ll.Line($"  ; while (val > {threshold})");
        ll.Line($"{entryL}:");
        ll.Line($"  %g{valReg} = fadd float %g{gi - 1}, 0.0  ; saved input");
        ll.Line($"  br label %{condL}");

        // Body block (before cond so phi can reference body result)
        ll.Line($"{bodyL}:");
        int giBody = condReg + 1;
        ll.Line($"  %g{giBody} = fadd float %g{phiReg}, 0.0  ; body input");
        giBody++;
        if (op.NestedBody != null)
            foreach (var sub in op.NestedBody.Operations)
            {
                string? so;
                (giBody, so) = GpuOp(ll, sub, giBody, h, w, total, src, dst);
            }
        int bodyResult = giBody - 1;
        ll.Line($"  br label %{condL}");

        // Cond block with phi
        ll.Line($"{condL}:");
        ll.Line($"  %g{phiReg} = phi float [ %g{valReg}, %{entryL} ], [ %g{bodyResult}, %{bodyL} ]");
        ll.Line($"  %g{condReg} = fcmp ogt float %g{phiReg}, {threshold}");
        ll.Line($"  br i1 %g{condReg}, label %{bodyL}, label %{exitL}");

        // Exit (use giBody — past body ops — to avoid SSA collisions)
        ll.Line($"{exitL}:");
        int exitReg = giBody;
        ll.Line($"  %g{exitReg} = fadd float %g{phiReg}, 0.0  ; while result");
        return (exitReg + 1, null);
    }

    (int next, string? storeIdx) EmitGpuWarp(LlvmIrBuilder ll, PipelineOp op, int gi, int h, int w, int total, string src)
    {
        // Warp: displace read position by (dx, dy)
        // Args: dx, dy (float or int offsets)
        // Loads from src at displaced position
        string dx = op.Args.Count > 0 ? op.Args[0] : "0";
        string dy = op.Args.Count > 1 ? op.Args[1] : "0";

        ll.Line("  ; warp: displaced read");
        ll.Line($"  %g{gi} = udiv i64 %gid, 4        ; pixel index");
        ll.Line($"  %g{gi + 1} = urem i64 %gid, 4      ; channel");
        ll.Line($"  %g{gi + 2} = urem i64 %g{gi}, {w}  ; x");
        ll.Line($"  %g{gi + 3} = udiv i64 %g{gi}, {w}  ; y");
        ll.Line($"  %g{gi + 4} = add i64 %g{gi + 2}, {dx}  ; x + dx");
        ll.Line($"  %g{gi + 5} = icmp slt i64 %g{gi + 4}, 0");
        ll.Line($"  %g{gi + 6} = icmp sge i64 %g{gi + 4}, {w}");
        ll.Line($"  %g{gi + 7} = or i1 %g{gi + 5}, %g{gi + 6}");
        ll.Line($"  %g{gi + 8} = select i1 %g{gi + 7}, i64 %g{gi + 2}, i64 %g{gi + 4}  ; clamp x");
        ll.Line($"  %g{gi + 9} = add i64 %g{gi + 3}, {dy}  ; y + dy");
        ll.Line($"  %g{gi + 10} = icmp slt i64 %g{gi + 9}, 0");
        ll.Line($"  %g{gi + 11} = icmp sge i64 %g{gi + 9}, {h}");
        ll.Line($"  %g{gi + 12} = or i1 %g{gi + 10}, %g{gi + 11}");
        ll.Line($"  %g{gi + 13} = select i1 %g{gi + 12}, i64 %g{gi + 3}, i64 %g{gi + 9}  ; clamp y");
        ll.Line($"  %g{gi + 14} = mul i64 %g{gi + 13}, {w}");
        ll.Line($"  %g{gi + 15} = add i64 %g{gi + 14}, %g{gi + 8}");
        ll.Line($"  %g{gi + 16} = mul i64 %g{gi + 15}, 4");
        ll.Line($"  %g{gi + 17} = add i64 %g{gi + 16}, %g{gi + 1}  ; displaced channel index");
        ll.Line($"  %g{gi + 18} = getelementptr float, ptr addrspace(1) %{src}, i64 %g{gi + 17}");
        ll.Line($"  %g{gi + 19} = load float, ptr addrspace(1) %g{gi + 18}  ; displaced value");
        return (gi + 20, null);
    }

    void EmitOp(LlvmIrBuilder ll, PipelineOp op, int idx, long total,
                int h, int w, string bi, string bo, bool last)
    {
        string L = $"L{idx}", B = $"B{idx}", D = $"D{idx}";
        string from = idx == 0 ? "entry" : $"D{idx - 1}";

        ll.Line($"  ; {op.Name}({string.Join(",", op.Args)})");
        ll.Line($"{L}:");
        ll.Line($"  %i{idx} = phi i64 [ 0, %{from} ], [ %j{idx}, %{B} ]");
        ll.Line($"  %c{idx} = icmp slt i64 %i{idx}, {total}");
        ll.Line($"  br i1 %c{idx}, label %{B}, label %{D}");
        // SIMD loop metadata for first op (carries kernel annotations)
        if (idx == 0 && (_simdWidth.HasValue || _simdUnroll.HasValue || _simdGather))
        {
            ll.RawLine($"  !{idx}.llvm.loop = !{{!{idx}.loop}}");
        }
        ll.Line($"{B}:");
        ll.Line($"  %p{idx} = getelementptr float, ptr %{bi}, i64 %i{idx}");
        ll.Line($"  %v{idx} = load float, ptr %p{idx}");

        switch (op.Name)
        {
            case "relu":
                ll.Line($"  %z{idx} = fcmp olt float %v{idx}, 0.0");
                ll.Line($"  %w{idx} = select i1 %z{idx}, float 0.0, float %v{idx}");
                break;
            case "clamp":
                string lo = op.Args.Count > 0 ? op.Args[0] : "0.0";
                string hi = op.Args.Count > 1 ? op.Args[1] : "1.0";
                ll.Line($"  %l{idx} = fcmp olt float %v{idx}, {lo}");
                ll.Line($"  %s{idx} = select i1 %l{idx}, float {lo}, float %v{idx}");
                ll.Line($"  %h{idx} = fcmp ogt float %s{idx}, {hi}");
                ll.Line($"  %w{idx} = select i1 %h{idx}, float {hi}, float %s{idx}");
                break;
            case "convolve":
                ll.Line($"  %m{idx} = sub i64 %i{idx}, 1");
                ll.Line($"  %n{idx} = add i64 %i{idx}, 1");
                ll.Line($"  %pa{idx} = getelementptr float, ptr %{bi}, i64 %m{idx}");
                ll.Line($"  %pb{idx} = getelementptr float, ptr %{bi}, i64 %n{idx}");
                ll.Line($"  %va{idx} = load float, ptr %pa{idx}");
                ll.Line($"  %vb{idx} = load float, ptr %pb{idx}");
                ll.Line($"  %s1{idx} = fadd float %va{idx}, %v{idx}");
                ll.Line($"  %s2{idx} = fadd float %s1{idx}, %v{idx}");
                ll.Line($"  %s3{idx} = fadd float %s2{idx}, %vb{idx}");
                ll.Line($"  %w{idx} = fdiv float %s3{idx}, 4.0");
                break;
            case "shuffle":
                int outW = w * 2;
                ll.Line($"  %q{idx} = udiv i64 %i{idx}, 4");
                ll.Line($"  %r{idx} = urem i64 %i{idx}, 4");
                ll.Line($"  %y{idx} = udiv i64 %q{idx}, {w}");
                ll.Line($"  %x{idx} = urem i64 %q{idx}, {w}");
                ll.Line($"  %y2{idx} = mul i64 %y{idx}, 2");
                ll.Line($"  %x2{idx} = mul i64 %x{idx}, 2");
                ll.Line($"  %dy{idx} = udiv i64 %r{idx}, 2");
                ll.Line($"  %dx{idx} = urem i64 %r{idx}, 2");
                ll.Line($"  %oy{idx} = add i64 %y2{idx}, %dy{idx}");
                ll.Line($"  %ox{idx} = add i64 %x2{idx}, %dx{idx}");
                ll.Line($"  %oi{idx} = mul i64 %oy{idx}, {outW}");
                ll.Line($"  %oj{idx} = add i64 %oi{idx}, %ox{idx}");
                ll.Line($"  %o{idx} = getelementptr float, ptr %{bo}, i64 %oj{idx}");
                ll.Line($"  store float %v{idx}, ptr %o{idx}");
                ll.Line($"  %j{idx} = add i64 %i{idx}, 1");
                ll.Line($"  br label %{L}");
                ll.Line($"{D}:");
                if (!last) ll.Line($"  br label %L{idx + 1}");
                ll.Line("");
                return;
            case "motion_vectors":
                // CPU motion estimation: compare with neighbor
                ll.Line($"  %mv0{idx} = sub i64 %i{idx}, 4  ; load ref from -4 offset");
                ll.Line($"  %mv1{idx} = getelementptr float, ptr %{bi}, i64 %mv0{idx}");
                ll.Line($"  %mv2{idx} = load float, ptr %mv1{idx}");
                ll.Line($"  %mv3{idx} = fsub float %v{idx}, %mv2{idx}  ; diff");
                ll.Line($"  %w{idx} = call float @llvm.fabs.f32(float %mv3{idx})  ; |diff|");
                break;
            case "warp":
                // CPU warp: read from displaced position
                string wdx = op.Args.Count > 0 ? op.Args[0] : "0";
                string wdy = op.Args.Count > 1 ? op.Args[1] : "0";
                ll.Line($"  %wa{idx} = sub i64 %i{idx}, {wdx}  ; displace");
                ll.Line($"  %wb{idx} = getelementptr float, ptr %{bi}, i64 %wa{idx}");
                ll.Line($"  %w{idx} = load float, ptr %wb{idx}");
                break;
            case "atomic_add":
            case "atomic_sub":
            case "atomic_max":
            case "atomic_min":
                // CPU: no atomic needed, just pass through
                ll.Line($"  %w{idx} = fadd float %v{idx}, 0.0  ; {op.Name} (CPU nop)");
                break;
            case "if":
                {
                    string thr = op.Args.Count > 0 ? op.Args[0] : "0.0";
                    int tId = NextLabel();
                    // Compute then result
                    int curT = idx * 1000 + 1;
                    if (op.NestedBody != null)
                        foreach (var sub in op.NestedBody.Operations)
                        {
                            ll.Line($"  %cv{curT} = fadd float %v{idx}, 0.0  ; then: {sub.Name}");
                            curT++;
                        }
                    else
                        ll.Line($"  %cv{curT} = fadd float %v{idx}, 0.0  ; then pass");
                    string thenReg = $"%cv{curT - 1}";
                    // Compute else result
                    int curE = curT + 1000;
                    if (op.ElseBody != null)
                        foreach (var sub in op.ElseBody.Operations)
                        {
                            ll.Line($"  %cv{curE} = fadd float %v{idx}, 0.0  ; else: {sub.Name}");
                            curE++;
                        }
                    else
                        ll.Line($"  %cv{curE} = fadd float %v{idx}, 0.0  ; else pass");
                    string elseReg = $"%cv{curE - 1}";
                    // Select based on condition
                    ll.Line($"  %z{idx} = fcmp ogt float %v{idx}, {thr}");
                    ll.Line($"  %w{idx} = select i1 %z{idx}, float {thenReg}, float {elseReg}");
                }
                break;
            case "for":
                {
                    string iters = op.Args.Count > 0 ? op.Args[0] : "1";
                    if (!int.TryParse(iters, out int n)) n = 1;
                    ll.Line($"  ; for {n} iterations (unrolled)");
                    int cur = idx * 1000 + 1;
                    ll.Line($"  %cv{cur} = fadd float %v{idx}, 0.0  ; iter 0");
                    cur++;
                    for (int i = 1; i < n; i++)
                    {
                        if (op.NestedBody != null)
                            foreach (var sub in op.NestedBody.Operations)
                            {
                                ll.Line($"  %cv{cur} = fadd float %cv{cur - 1}, 0.0  ; iter {i}: {sub.Name}");
                                cur++;
                            }
                        else
                        {
                            ll.Line($"  %cv{cur} = fadd float %cv{cur - 1}, 0.0  ; iter {i} pass");
                            cur++;
                        }
                    }
                    ll.Line($"  %w{idx} = fadd float %cv{cur - 1}, 0.0  ; for result");
                }
                break;
            case "while":
                {
                    // CPU: single evaluation (like if) — GPU has dynamic loop
                    string thr = op.Args.Count > 0 ? op.Args[0] : "0.0";
                    int curW = idx * 1000 + 1;
                    if (op.NestedBody != null)
                        foreach (var sub in op.NestedBody.Operations)
                        {
                            ll.Line($"  %cv{curW} = fadd float %v{idx}, 0.0  ; while: {sub.Name}");
                            curW++;
                        }
                    else
                        ll.Line($"  %cv{curW} = fadd float %v{idx}, 0.0  ; while pass");
                    string whileReg = $"%cv{curW - 1}";
                    ll.Line($"  %z{idx} = fcmp ogt float %v{idx}, {thr}");
                    ll.Line($"  %w{idx} = select i1 %z{idx}, float {whileReg}, float %v{idx}");
                }
                break;
            default:
                ll.Line($"  %w{idx} = fadd float %v{idx}, 0.0");
                break;
        }

        ll.Line($"  %o{idx} = getelementptr float, ptr %{bo}, i64 %i{idx}");
        ll.Line($"  store float %w{idx}, ptr %o{idx}");
        ll.Line($"  %j{idx} = add i64 %i{idx}, 1");
        ll.Line($"  br label %{L}");
        ll.Line($"{D}:");
        if (!last) ll.Line($"  br label %L{idx + 1}");
        ll.Line("");
    }

    void EmitEntry(LlvmIrBuilder ll, EntryDecl e)
    {
        if (_pgoCollect)
        {
            ll.Line("define i32 @main() {");
            ll.Indent();
            ll.Line("entry:");
            ll.Line($"  call void @llvm.instrprof.increment(ptr @__profn_main, i64 {HashPGO("main")}, i32 1, i32 0)");
            ll.Line("  ret i32 0");
            ll.Dedent();
            ll.Line("}");
        }
        else
        {
            ll.Line($"define i32 @main() {{ entry: ret i32 0 }}");
        }
        ll.Line("");
    }

    static string Desc(PipelineExpr? p)
    {
        if (p == null) return "none";
        return string.Join(" |> ", p.Operations.Select(o =>
            o.Args.Count > 0 ? $"{o.Name}({string.Join(",", o.Args)})" : o.Name));
    }

    static int Dim(BPlusType? t, string d, int f) =>
        t is ImageType img && int.TryParse(d == "H" ? img.H : img.W, out var v) ? v : f;
}

// ─── BRIDGE GENERATORS ──────────────────────────────────────

static class Gen
{
    static string Hdr => "// B+ v2.5.0GH — Auto-generated bridge\n";

    public static string CSharp(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine(Hdr + "// Copy into Assets/ alongside .dll");
        sb.AppendLine("using System.Runtime.InteropServices;");
        sb.AppendLine("public static class BPlusBridge {");
        foreach (var k in kernels)
        {
            sb.AppendLine($"  [DllImport(\"bplus_kernels\", CallingConvention=CallingConvention.Cdecl)]");
            sb.AppendLine($"  static extern void {k}(System.IntPtr i, System.IntPtr o);");
            sb.AppendLine($"  public static unsafe void {k}_safe(float[] i, float[] o) {{");
            sb.AppendLine($"    fixed(float* pi=i, po=o) {k}((IntPtr)pi,(IntPtr)po); }}");
        }
        sb.AppendLine("}");
        return sb.ToString();
    }

    public static string Python(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("# " + Hdr);
        sb.AppendLine("import ctypes,numpy as np,os");
        sb.AppendLine("_dll=None");
        sb.AppendLine("for _n in['bplus_kernels.dll','libbplus_kernels.so','bplus_kernels.dylib']:");
        sb.AppendLine("  _p=os.path.join(os.path.dirname(__file__),_n)");
        sb.AppendLine("  if os.path.exists(_p): _dll=ctypes.CDLL(_p); break");
        foreach (var k in kernels)
        {
            sb.AppendLine($"_{k}=_dll.{k} if _dll else None");
            sb.AppendLine($"if _{k}: _{k}.argtypes=[ctypes.c_void_p,ctypes.c_void_p]; _{k}.restype=None");
            sb.AppendLine($"def {k}(i:np.ndarray,o:np.ndarray): _{k}(i.ctypes.data,o.ctypes.data)");
        }
        return sb.ToString();
    }

    public static string C(List<string> kernels, bool exportC = false)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// " + Hdr);
        if (exportC)
        {
            sb.AppendLine("// C ABI export — compile DLL with: -DBPLUS_BUILD_DLL");
            sb.AppendLine("#pragma once");
            sb.AppendLine("#include <stdint.h>");
            sb.AppendLine("#ifdef _WIN32");
            sb.AppendLine("#  ifdef BPLUS_BUILD_DLL");
            sb.AppendLine("#    define BPLUS_API __declspec(dllexport)");
            sb.AppendLine("#  else");
            sb.AppendLine("#    define BPLUS_API __declspec(dllimport)");
            sb.AppendLine("#  endif");
            sb.AppendLine("#else");
            sb.AppendLine("#  define BPLUS_API __attribute__((visibility(\"default\")))");
            sb.AppendLine("#endif");
            sb.AppendLine("#ifdef __cplusplus");
            sb.AppendLine("extern \"C\" {");
            sb.AppendLine("#endif");
            foreach (var k in kernels)
                sb.AppendLine($"BPLUS_API void {k}(float* input, float* output);");
        }
        else
        {
            sb.AppendLine("// Include this header and link bplus_kernels.obj");
            sb.AppendLine("#pragma once");
            sb.AppendLine("#include <stdint.h>");
            sb.AppendLine("#ifdef __cplusplus");
            sb.AppendLine("extern \"C\" {");
            sb.AppendLine("#endif");
            foreach (var k in kernels)
                sb.AppendLine($"void {k}(float* input, float* output);");
        }
        sb.AppendLine("#ifdef __cplusplus");
        sb.AppendLine("}");
        sb.AppendLine("#endif");
        return sb.ToString();
    }

    public static string Rust(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// " + Hdr);
        sb.AppendLine("// Add to build.rs: println!(\"cargo:rustc-link-search=.\");");
        sb.AppendLine("//                  println!(\"cargo:rustc-link-lib=bplus_kernels\");");
        sb.AppendLine("#![allow(non_snake_case)]");
        sb.AppendLine("extern \"C\" {");
        foreach (var k in kernels)
            sb.AppendLine($"  fn {k}(input: *const f32, output: *mut f32);");
        sb.AppendLine("}");
        sb.AppendLine("pub struct BPlusKernels;");
        sb.AppendLine("impl BPlusKernels {");
        foreach (var k in kernels)
        {
            var safe = k.Replace("kernel_", "");
            sb.AppendLine($"  pub unsafe fn {safe}(input: &[f32], output: &mut [f32]) {{");
            sb.AppendLine($"    {k}(input.as_ptr(), output.as_mut_ptr()); }}");
        }
        sb.AppendLine("}");
        return sb.ToString();
    }

    public static string Swift(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// " + Hdr + "// Add bplus_kernels.a to Xcode project");
        sb.AppendLine("import Foundation");
        foreach (var k in kernels)
            sb.AppendLine($"@_silgen_name(\"{k}\")");
        sb.AppendLine("func bplus_kernel(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>)");
        sb.AppendLine("");
        sb.AppendLine("class BPlusBridge {");
        foreach (var k in kernels)
        {
            var s = k.Replace("kernel_", "");
            sb.AppendLine($"  class func {s}(input: [Float], output: inout [Float]) {{");
            sb.AppendLine($"    input.withUnsafeBufferPointer {{ i in");
            sb.AppendLine($"      output.withUnsafeMutableBufferPointer {{ o in");
            sb.AppendLine($"        {k}(i.baseAddress!, o.baseAddress!) }} }} }}");
        }
        sb.AppendLine("}");
        return sb.ToString();
    }

    public static string Kotlin(List<string> kernels)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("// " + Hdr + "// Add bplus_kernels.so to jniLibs/");
        sb.AppendLine("object BPlusBridge {");
        sb.AppendLine("  init { System.loadLibrary(\"bplus_kernels\") }");
        foreach (var k in kernels)
        {
            var s = k.Replace("kernel_", "").Replace("_", "");
            sb.AppendLine($"  external fun {s}(input: FloatArray, output: FloatArray)");
            sb.AppendLine($"  fun {s}Safe(input: FloatArray, output: FloatArray) {{");
            sb.AppendLine($"    {s}(input, output) }}");
        }
        sb.AppendLine("}");
        return sb.ToString();
    }
}

// ─── LLVM IR BUILDER ────────────────────────────────────────

internal class LlvmIrBuilder
{
    readonly string _platform;
    readonly bool _pgoCollect;
    readonly string? _ltoMode;
    readonly List<string> _lines = new();
    int _indent;
    public bool GpuMode;

    public LlvmIrBuilder(string platform = "native", bool pgoCollect = false, string? ltoMode = null)
    {
        _platform = platform;
        _pgoCollect = pgoCollect;
        _ltoMode = ltoMode;
    }

    public void Line(string l) => _lines.Add(new string(' ', _indent * 2) + l);
    public void RawLine(string l) => _lines.Add(l);
    public void Indent() => _indent++;
    public void Dedent() => _indent = Math.Max(0, _indent - 1);

    public override string ToString()
    {
        string triple;
        var (baseTriple, layout) = GpuMode
            ? ("spirv64-unknown-unknown", "e-m:e-p:64:64-i64:64-n32:64-S128")
            : _platform switch
            {
                "wasm" => ("wasm32-unknown-unknown", "e-m:e-p:32:32-i64:64-n32:64-S128"),
                "arm64" or "ios" => ("arm64-apple-ios", "e-m:o-i64:64-i128:128-n32:64-S128"),
                "android" => ("aarch64-linux-android", "e-m:e-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128"),
                _ => ("x86_64-pc-windows-msvc", "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128")
            };

        // LTO target triple suffix
        triple = _ltoMode switch
        {
            "thin" => baseTriple + "-thinlto",
            "full" => baseTriple + "-lto",
            _ => baseTriple
        };

        var h = $@"; ModuleID = 'bplus_module'
source_filename = ""bplus.bp""
target datalayout = ""{layout}""
target triple = ""{triple}""

";
        if (!GpuMode)
            h += "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)\n\n";

        // PGO collect declarations
        if (_pgoCollect)
        {
            h += @"@__llvm_profile_runtime = external global i32
declare void @llvm.instrprof.increment(ptr, i64, i32, i32)
declare void @llvm.instrprof.value_profile(ptr, i64, i64, i32, i32)

";
        }

        return h + string.Join("\n", _lines);
    }
}
