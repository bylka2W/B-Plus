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

    // Critical size hint
    public int? CriticalSize { get; set; }

    // NUMA node
    public int? NumaNode { get; set; }
    public bool StoreForwardSafe { get; set; }
    public string? MuarchProfile { get; set; }
    public int? IlpMax { get; set; }

    // L3-heap / L1-heap allocation
    public HeapType? Heap { get; set; }

    // Field packing
    public int? FieldIndex { get; set; }
    public List<byte> BytePack { get; } = new();
    public string? NumaPolicy { get; set; }

    public MetalConfig ShallowCopy()
    {
        var c = new MetalConfig
        {
            Enabled = Enabled, Tier = Tier, Register = Register,
            Zmm = Zmm, Mask = Mask, Section = Section,
            Gateway = Gateway, PrefetchHint = PrefetchHint,
            Alignment = Alignment, Packed = Packed,
            DataTier = DataTier, HotPath = HotPath,
            CriticalSize = CriticalSize, NumaNode = NumaNode,
            StoreForwardSafe = StoreForwardSafe,
            MuarchProfile = MuarchProfile, IlpMax = IlpMax,
            Heap = Heap
        };
        c.FusionPairs.AddRange(FusionPairs);
        return c;
    }

    public double[] ToFeatures()
    {
        var feat = new List<double>
        {
            Enabled ? 1 : 0,
            Tier.HasValue ? (int)Tier.Value : 4,
            Register != null ? 1 : 0,
            Zmm ?? -1,
            Mask != null ? 1 : 0,
            FusionPairs.Count > 0 ? 1 : 0,
            Section != null ? 1 : 0,
            Gateway.HasValue ? (int)Gateway.Value : 4,
            PrefetchHint != null ? 1 : 0,
            Alignment ?? 0,
            Packed ? 1 : 0,
            DataTier.HasValue ? (int)DataTier.Value : 4,
            HotPath ? 1 : 0,
            CriticalSize ?? 0,
            NumaNode ?? -1,
            StoreForwardSafe ? 1 : 0,
            MuarchProfile != null ? 1 : 0,
            IlpMax ?? 0,
            Heap.HasValue ? (int)Heap.Value : 0,
        };
        return feat.ToArray();
    }

    public static MetalConfig Random()
    {
        var rng = new Random(42);
        var tiers = new[] { MemoryTier.L0, MemoryTier.L1, MemoryTier.L2, MemoryTier.L3, MemoryTier.Ram };
        var heaps = new[] { HeapType.L1, HeapType.L3, (HeapType)(-1) };
        return new MetalConfig
        {
            Enabled = true,
            Tier = tiers[rng.Next(tiers.Length)],
            Register = rng.Next(2) == 0 ? null : "r" + (8 + rng.Next(8)),
            Zmm = rng.Next(2) == 0 ? null : rng.Next(32),
            PrefetchHint = rng.Next(3) switch { 0 => null, 1 => "t0", _ => "nontemporal" },
            Alignment = rng.Next(3) switch { 0 => null, 1 => 16, _ => 64 },
            Packed = rng.Next(2) == 0,
            HotPath = rng.Next(2) == 0,
            NumaNode = rng.Next(2) == 0 ? null : rng.Next(4),
            MuarchProfile = rng.Next(2) == 0 ? null : "intel_adl",
            Heap = rng.Next(3) == 0 ? (HeapType?)(rng.Next(2) == 0 ? HeapType.L1 : HeapType.L3) : null
        };
    }
}

public enum HeapType
{
    L1 = 1,  // L1 cache (~32KB)
    L3 = 2   // L3 cache (~2MB per core)
}

public class MetalBlock
{
    public MetalConfig Config { get; set; } = new();
    public string? TargetState { get; set; }
    public string? TargetKernel { get; set; }
}
