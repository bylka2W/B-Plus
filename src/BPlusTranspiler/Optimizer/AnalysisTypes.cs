using BPlusTranspiler.Mir;

namespace BPlusTranspiler.Optimizer;

// Shared analysis result types used across AST, MIR, and optimizer passes

// Rust: NLL liveness result per state
public class LivenessResult
{
    public string StateName { get; set; } = "";
    public HashSet<string> LiveVars { get; } = new();
    public HashSet<string> DeadOnExit { get; } = new();
    public List<LivenessPoint> Points { get; } = new();
}

public class LivenessPoint
{
    public int InstructionIndex { get; set; }
    public MirOpcode Opcode { get; set; }
    public HashSet<string> LiveBefore { get; set; } = new();
    public HashSet<string> LiveAfter { get; set; } = new();
    public HashSet<string> Born { get; set; } = new();
    public HashSet<string> Die { get; set; } = new();
}

// Go: escape analysis result
public enum EscapeKind { Stack, Pool, Heap }

// Haskell: demand signature
public class DemandSignature
{
    public bool IsStrict { get; set; }
    public bool IsUsed { get; set; }
    public bool IsCalled { get; set; }
    public int CallCount { get; set; }
    public bool IsPoly { get; set; }
}

// Vale: region info
public class RegionInfo
{
    public string Name { get; set; } = "";
    public HashSet<string> OwnedStates { get; } = new();
    public HashSet<string> OwnedVars { get; } = new();
    public List<string> Transfers { get; } = new();
}
