namespace BPlusTranspiler.Ast;

public enum MemoryTier { L0, L1, L2, L3, Ram }

public class MetalAnnotation
{
    public string Name { get; set; } = "";
    public string? Value { get; set; }
    public Dictionary<string, string> Args { get; } = new();
}

public class MetalConfig
{
    public bool Enabled { get; set; }

    // Tier assignment
    public MemoryTier? Tier { get; set; }

    // Register pins
    public string? Register { get; set; }

    // ZMM register assignments
    public int? Zmm { get; set; }

    // Mask register assignments
    public string? Mask { get; set; }

    // Fusion pairs: e.g. "cmp+jne"
    public List<string> FusionPairs { get; } = new();

    // Section name (linker section)
    public string? Section { get; set; }

    // Gateway tier
    public MemoryTier? Gateway { get; set; }

    // Prefetch hint: nta, t0, t1, t2
    public string? PrefetchHint { get; set; }

    // Alignment in bytes
    public int? Alignment { get; set; }

    // Packed struct
    public bool Packed { get; set; }

    // Data tier
    public MemoryTier? DataTier { get; set; }

    // Hot path hint
    public bool HotPath { get; set; }

    // Critical size in bytes
    public int? CriticalSize { get; set; }

    // Byte pack sequence
    public List<byte> BytePack { get; } = new();

    // Field ordering index
    public int? FieldIndex { get; set; }

    // NUMA node (default: any)
    public int? NumaNode { get; set; }
    // NUMA policy: local|bind|interleave
    public string? NumaPolicy { get; set; }

    // Store forwarding guard (auto-pad to prevent misalign)
    public bool StoreForwardSafe { get; set; }

    // Microarchitecture profile: intel_adl|amd_zen4|arm_neoverse|...
    public string? MuarchProfile { get; set; }

    // ILP dependency chain max length
    public int? IlpMax { get; set; }

    // Random config generation for AI
    public static MetalConfig Random()
    {
        var rng = new Random();
        return new MetalConfig
        {
            Enabled = true,
            Tier = (MemoryTier)rng.Next(0, 4),
            Register = rng.Next(2) == 0 ? null : new[] { "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9" }[rng.Next(8)],
            Zmm = rng.Next(2) == 0 ? null : rng.Next(8),
            Mask = rng.Next(2) == 0 ? null : $"k{rng.Next(8)}",
            FusionPairs = { rng.Next(2) == 0 ? "cmp+jne" : "dec+jnz" },
            Section = rng.Next(2) == 0 ? null : new[] { ".text.hot.L1", ".text.hot.L2", ".data.hot.L1" }[rng.Next(3)],
            Gateway = rng.Next(2) == 0 ? null : (MemoryTier)rng.Next(1, 4),
            PrefetchHint = rng.Next(2) == 0 ? null : new[] { "nta", "t0", "t1", "t2" }[rng.Next(4)],
            Alignment = rng.Next(2) == 0 ? null : (int?)new[] { 16, 32, 64, 128 }[rng.Next(4)],
            Packed = rng.Next(2) == 0,
            DataTier = rng.Next(2) == 0 ? null : (MemoryTier)rng.Next(1, 4),
            HotPath = rng.Next(2) == 0,
            CriticalSize = rng.Next(2) == 0 ? null : (int?)new[] { 4096, 8192, 16384, 32768 }[rng.Next(4)],
            FieldIndex = rng.Next(2) == 0 ? null : (int?)rng.Next(16),
            NumaNode = rng.Next(2) == 0 ? null : (int?)rng.Next(0, 4),
            NumaPolicy = rng.Next(3) switch { 0 => null, 1 => "local", _ => "bind" },
            StoreForwardSafe = rng.Next(2) == 0,
            MuarchProfile = rng.Next(2) == 0 ? null : new[] { "intel_icx", "amd_zen4", "arm_neoverse" }[rng.Next(3)],
            IlpMax = rng.Next(2) == 0 ? null : (int?)rng.Next(2, 8)
        };
    }

    // Serialize to feature vector for AI
    public double[] ToFeatures()
    {
        return new double[]
        {
            Enabled ? 1.0 : 0.0,
            (double)(Tier ?? MemoryTier.Ram),
            Register != null ? 1.0 : 0.0,
            Zmm ?? -1,
            Mask != null ? 1.0 : 0.0,
            FusionPairs.Count > 0 ? 1.0 : 0.0,
            Section != null ? 1.0 : 0.0,
            (double)(Gateway ?? MemoryTier.Ram),
            PrefetchHint != null ? 1.0 : 0.0,
            Alignment ?? 0,
            Packed ? 1.0 : 0.0,
            (double)(DataTier ?? MemoryTier.Ram),
            HotPath ? 1.0 : 0.0,
            CriticalSize ?? 0,
            FieldIndex ?? 0,
            BytePack.Count > 0 ? 1.0 : 0.0,
            NumaNode ?? -1,
            StoreForwardSafe ? 1.0 : 0.0,
            MuarchProfile != null ? 1.0 : 0.0,
            IlpMax ?? 0
        };
    }
}

public class MetalBlock
{
    public MetalConfig Config { get; set; } = new();
    public string? TargetState { get; set; }
    public string? TargetKernel { get; set; }
}
