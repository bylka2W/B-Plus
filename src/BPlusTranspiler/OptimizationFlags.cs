namespace BPlusTranspiler;

public class OptimizationFlags
{
    // Level 1: Basic
    public bool Optimize { get; set; }
    public bool InlineStates { get; set; }
    public bool ConstFold { get; set; }
    public bool DeadElim { get; set; }

    // Level 2: Vectorize
    public VectorizeMode Vectorize { get; set; } = VectorizeMode.None;

    // Level 3: Memory & Cache
    public bool CacheFriendly { get; set; }
    public PrefetchMode Prefetch { get; set; } = PrefetchMode.None;
    public int AlignBytes { get; set; }
    public bool HugePages { get; set; }
    public bool ZeroCopy { get; set; }
    public bool NoAlloc { get; set; }

    // Level 4: Branching
    public bool Branchless { get; set; }
    public bool LikelyHints { get; set; }
    public bool UnlikelyHints { get; set; }
    public bool FlattenSwitch { get; set; }

    // Level 5: Multi-threading
    public bool ParallelDispatch { get; set; }
    public int ThreadPool { get; set; }
    public bool LockFree { get; set; }
    public bool WorkStealing { get; set; }

    // Level 6: Platform
    public TargetArch Arch { get; set; } = TargetArch.None;
    public TargetOs Os { get; set; } = TargetOs.None;

    // Level 7: Special
    public bool Eco { get; set; }
    public EcoMode EcoMode { get; set; } = EcoMode.Auto;
    public bool LowLatency { get; set; }
    public bool HighThroughput { get; set; }
    public bool SmallCode { get; set; }
    public bool FastMath { get; set; }
    public bool NoExceptions { get; set; }
    public bool NoRtti { get; set; }
    public bool Lto { get; set; }
    public bool Pgo { get; set; }
    public bool Bolt { get; set; }

    // Level 8: Combined
    public bool Turbo { get; set; }
    public bool TurboEco { get; set; }
    public bool TurboEmbed { get; set; }
    public bool DebugOpt { get; set; }
    public bool ProfileGen { get; set; }
    public bool ProfileUse { get; set; }

    // Smart optimizations
    public bool Auto { get; set; }
    public bool Pool { get; set; }
    public bool HotCold { get; set; }
    public bool Dedup { get; set; }
    public bool Predict { get; set; }
    public bool Devirt { get; set; }
    public bool Lazy { get; set; }
    public bool DataOriented { get; set; }
    public bool SelfBench { get; set; }
    public bool Pack { get; set; }
    public bool MultiPath { get; set; }
    public bool PinRegs { get; set; }
    public int PinRegsCount { get; set; }

    // Benchmark
    public bool Benchmark { get; set; }
    public int BenchmarkIterations { get; set; } = 1_000_000;

    public bool HasAny => Turbo || TurboEco || TurboEmbed || DebugOpt || ProfileGen || ProfileUse
        || Auto || Optimize || InlineStates || ConstFold || DeadElim
        || Vectorize != VectorizeMode.None || CacheFriendly || Prefetch != PrefetchMode.None
        || AlignBytes > 0 || HugePages || ZeroCopy || NoAlloc
        || Branchless || LikelyHints || UnlikelyHints || FlattenSwitch
        || ParallelDispatch || ThreadPool > 0 || LockFree || WorkStealing
        || Arch != TargetArch.None || Os != TargetOs.None
        || Eco || LowLatency || HighThroughput || SmallCode || FastMath
        || NoExceptions || NoRtti || Lto || Pgo || Bolt
        || Pool || HotCold || Dedup || Predict || Devirt || Lazy || DataOriented
        || SelfBench || Pack || MultiPath || PinRegs || Benchmark;

    public static OptimizationFlags Parse(string[] args)
    {
        var flags = new OptimizationFlags();
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--optimize": flags.Optimize = true; break;
                case "--inline-states": flags.InlineStates = true; break;
                case "--const-fold": flags.ConstFold = true; break;
                case "--dead-elim": flags.DeadElim = true; break;

                case "--vectorize": flags.Vectorize = VectorizeMode.Auto; break;
                case "--vectorize-512": flags.Vectorize = VectorizeMode.AVX512; break;
                case "--vectorize-256": flags.Vectorize = VectorizeMode.AVX2; break;
                case "--vectorize-128": flags.Vectorize = VectorizeMode.SSE; break;
                case "--no-vectorize": flags.Vectorize = VectorizeMode.None; break;

                case "--cache-friendly": flags.CacheFriendly = true; break;
                case "--prefetch":
                    flags.Prefetch = PrefetchMode.Aggressive;
                    if (i + 1 < args.Length && !args[i + 1].StartsWith("--"))
                    {
                        i++;
                        flags.Prefetch = args[i].ToLower() switch
                        {
                            "aggressive" => PrefetchMode.Aggressive,
                            "l1" => PrefetchMode.L1,
                            "l2" => PrefetchMode.L2,
                            "l3" => PrefetchMode.L3,
                            _ => PrefetchMode.Aggressive
                        };
                    }
                    break;
                case "--align-64": flags.AlignBytes = 64; break;
                case "--align-4096": flags.AlignBytes = 4096; break;
                case "--huge-pages": flags.HugePages = true; break;
                case "--zero-copy":
                case "--no-alloc":
                    flags.ZeroCopy = true;
                    flags.NoAlloc = true;
                    break;

                case "--branchless": flags.Branchless = true; break;
                case "--likely-hints": flags.LikelyHints = true; break;
                case "--unlikely-hints": flags.UnlikelyHints = true; break;
                case "--flatten-switch": flags.FlattenSwitch = true; break;

                case "--parallel-dispatch": flags.ParallelDispatch = true; break;
                case "--thread-pool":
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out var tp))
                    { flags.ThreadPool = tp; i++; }
                    else flags.ThreadPool = Environment.ProcessorCount;
                    break;
                case "--lock-free": flags.LockFree = true; break;
                case "--work-stealing": flags.WorkStealing = true; break;

                case "--target-arch":
                    if (i + 1 < args.Length)
                    {
                        i++;
                        flags.Arch = args[i].ToLower() switch
                        {
                            "native" => TargetArch.Native,
                            "zen4" or "zen-4" or "amd" => TargetArch.Zen4,
                            "raptor" or "raptor-lake" or "intel" => TargetArch.RaptorLake,
                            "m1" or "m2" or "apple" => TargetArch.AppleM1,
                            "cortex" or "cortex-a78" or "arm" => TargetArch.CortexA78,
                            _ => TargetArch.Native
                        };
                    }
                    break;
                case "--target-os":
                    if (i + 1 < args.Length)
                    {
                        i++;
                        flags.Os = args[i].ToLower() switch
                        {
                            "linux" => TargetOs.Linux,
                            "windows" => TargetOs.Windows,
                            "baremetal" or "bare-metal" or "embedded" => TargetOs.BareMetal,
                            _ => TargetOs.None
                        };
                    }
                    break;

                case "--eco":
                    flags.Eco = true;
                    flags.EcoMode = EcoMode.Auto;
                    if (i + 1 < args.Length && !args[i + 1].StartsWith("--"))
                    {
                        i++;
                        flags.EcoMode = args[i].ToLower() switch
                        {
                            "sse" => EcoMode.SSE,
                            "avx2" => EcoMode.AVX2,
                            "neon" => EcoMode.NEON,
                            "scalar" => EcoMode.Scalar,
                            _ => EcoMode.Auto
                        };
                    }
                    break;
                case "--low-latency": flags.LowLatency = true; break;
                case "--high-throughput": flags.HighThroughput = true; break;
                case "--small-code": flags.SmallCode = true; break;
                case "--fast-math": flags.FastMath = true; break;
                case "--no-exceptions": flags.NoExceptions = true; break;
                case "--no-rtti": flags.NoRtti = true; break;
                case "--lto": flags.Lto = true; break;
                case "--pgo": flags.Pgo = true; break;
                case "--bolt": flags.Bolt = true; break;

                case "--turbo": flags.Turbo = true; break;
                case "--turbo-eco": flags.TurboEco = true; break;
                case "--turbo-embed": flags.TurboEmbed = true; break;
                case "--debug-opt": flags.DebugOpt = true; break;
                case "--profile-gen": flags.ProfileGen = true; break;
                case "--profile-use": flags.ProfileUse = true; break;

                case "--auto": flags.Auto = true; break;
                case "--pool": flags.Pool = true; break;
                case "--hot-cold": flags.HotCold = true; break;
                case "--dedup": flags.Dedup = true; break;
                case "--predict": flags.Predict = true; break;
                case "--devirt": flags.Devirt = true; break;
                case "--lazy": flags.Lazy = true; break;
                case "--data-oriented": flags.DataOriented = true; break;
                case "--self-bench": flags.SelfBench = true; break;
                case "--pack": flags.Pack = true; break;
                case "--multi-path": flags.MultiPath = true; break;
                case "--pin-regs":
                    flags.PinRegs = true;
                    flags.PinRegsCount = 4;
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out var pr))
                    { flags.PinRegsCount = pr; i++; }
                    break;

                case "--benchmark":
                    flags.Benchmark = true;
                    if (i + 1 < args.Length && int.TryParse(args[i + 1], out var bi))
                    { flags.BenchmarkIterations = bi; i++; }
                    break;
            }
        }

        // Combined presets
        if (flags.Turbo)
        {
            flags.Optimize = true;
            flags.Vectorize = VectorizeMode.Auto;
            flags.CacheFriendly = true;
            flags.Branchless = true;
            flags.ZeroCopy = true;
            flags.LikelyHints = true;
            flags.FlattenSwitch = true;
            flags.Prefetch = PrefetchMode.Aggressive;
            flags.AlignBytes = 64;
            flags.Lto = true;
            flags.FastMath = true;
            flags.Dedup = true;
            flags.Devirt = true;
            flags.HotCold = true;
            flags.Predict = true;
            flags.Pack = true;
        }
        if (flags.TurboEco)
        {
            flags.Turbo = true;
            flags.Eco = true;
            flags.EcoMode = EcoMode.AVX2;
        }
        if (flags.TurboEmbed)
        {
            flags.Optimize = true;
            flags.Pool = true;
            flags.Pack = true;
            flags.Dedup = true;
            flags.SmallCode = true;
            flags.NoExceptions = true;
            flags.NoRtti = true;
            flags.Eco = true;
            flags.EcoMode = EcoMode.Scalar;
        }
        if (flags.Auto)
        {
            flags.Vectorize = DetectBestSIMD();
            flags.Arch = TargetArch.Native;
            flags.ThreadPool = Environment.ProcessorCount;
            flags.CacheFriendly = true;
            flags.Prefetch = PrefetchMode.Aggressive;
            flags.AlignBytes = 64;
        }

        return flags;
    }

    private static VectorizeMode DetectBestSIMD()
    {
        try
        {
            if (System.Runtime.Intrinsics.X86.Avx512F.IsSupported) return VectorizeMode.AVX512;
            if (System.Runtime.Intrinsics.X86.Avx2.IsSupported) return VectorizeMode.AVX2;
            if (System.Runtime.Intrinsics.X86.Sse.IsSupported) return VectorizeMode.SSE;
            if (System.Runtime.Intrinsics.Arm.Neon.IsSupported) return VectorizeMode.NEON;
        }
        catch { }
        return VectorizeMode.None;
    }
}

public enum VectorizeMode { None, Auto, SSE, AVX2, AVX512, NEON }
public enum PrefetchMode { None, L1, L2, L3, Aggressive }
public enum TargetArch { None, Native, Zen4, RaptorLake, AppleM1, CortexA78 }
public enum TargetOs { None, Linux, Windows, BareMetal }
public enum EcoMode { Auto, SSE, AVX2, NEON, Scalar }
