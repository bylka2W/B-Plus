namespace BPlusTranspiler.Ast;

public enum ActionType { Enter, Exit }

public class ProgramNode
{
    public List<ImportNode> Imports { get; } = new();
    public ContextNode? Context { get; set; }
    public List<EnumNode> Enums { get; } = new();
    public List<StateDefNode> States { get; } = new();
    public List<ParallelBlockNode> ParallelBlocks { get; } = new();

    // v2.2+ new constructs
    public List<Directive> Directives { get; } = new();
    public List<UseCxxDecl> UseCxxDecls { get; } = new();
    public List<ExternCppFnDecl> ExternCppFns { get; } = new();
    public List<KernelDecl> Kernels { get; } = new();
    public List<PipelineDecl> Pipelines { get; } = new();
    public List<EntryDecl> Entries { get; } = new();

    // v2.3 Memory system
    public MemoryConfig? Memory { get; set; }
    public List<VarDecl> VarDecls { get; } = new();
    public List<Annotation> StandaloneAnnotations { get; } = new();
}

public class ImportNode
{
    public string Path { get; set; } = "";
}

public class VariableNode
{
    public string Name { get; set; } = "";
    public string Type { get; set; } = "";
    public string? DefaultValue { get; set; }
}

public class ContextNode
{
    public List<VariableNode> Variables { get; } = new();
}

public class EnumNode
{
    public string Name { get; set; } = "";
    public List<string> Members { get; } = new();
}

public class StateDefNode
{
    public string Name { get; set; } = "";
    public string? BaseClass { get; set; }
    public string? GenericParam { get; set; }
    public bool IsBaseClass { get; set; }
    public List<VariableNode> Variables { get; } = new();
    public List<TransitionNode> Transitions { get; } = new();
    public List<ActionNode> Actions { get; } = new();
    public List<TimerNode> Timers { get; } = new();
    public List<StateDefNode> NestedStates { get; } = new();
}

public class TransitionNode
{
    public string EventName { get; set; } = "";
    public bool IsSignal { get; set; }
    public string? SignalName { get; set; }
    public List<ParamNode> Parameters { get; } = new();
    public string? Guard { get; set; }
    public string Target { get; set; } = "";
    public string? Body { get; set; }
    public bool IsAsync { get; set; }
    public bool IsAlways { get; set; }
    public bool IsEnterAuto { get; set; }
}

public class ParamNode
{
    public string Name { get; set; } = "";
    public string Type { get; set; } = "";
}

public class TimerNode
{
    public string Duration { get; init; } = "";
    public string? Guard { get; init; }
    public string Target { get; init; } = "";
}

public class ActionNode
{
    public ActionType Type { get; init; }
    public string Body { get; init; } = "";
}

public class ParallelBlockNode
{
    public string Name { get; set; } = "";
    public List<StateDefNode> States { get; } = new();
}

// ════════════════════════════════════════
// NEW v2.2: Kernel / FSR / Pipeline AST
// ════════════════════════════════════════

public class Annotation
{
    public string Name { get; set; } = "";
    public Dictionary<string, string> Args { get; } = new();
}

public class KernelParam
{
    public string Name { get; set; } = "";
    public BPlusType Type { get; set; } = null!;
    public bool IsOutput { get; set; }
}

public abstract class BPlusType { }

public class SimpleType : BPlusType
{
    public string Name { get; set; } = "";
}

public class ImageType : BPlusType
{
    public string H { get; set; } = "";
    public string W { get; set; } = "";
    public int? Channels { get; set; }
}

public class ConvWeightsType : BPlusType
{
    public List<int> Dimensions { get; } = new();
    public string? Quant { get; set; }
}

public class StreamType : BPlusType
{
    public BPlusType ElementType { get; set; } = null!;
}

public class MotionVecType : BPlusType
{
    public string H { get; set; } = "";
    public string W { get; set; } = "";
}

public class ArrayType : BPlusType
{
    public BPlusType ElementType { get; set; } = null!;
    public string Size { get; set; } = "";
}

public class PipelineOp
{
    public string Name { get; set; } = "";
    public List<string> Args { get; } = new();
    public PipelineExpr? NestedBody { get; set; }
    public PipelineExpr? ElseBody { get; set; }
}

public class PipelineExpr
{
    public string Source { get; set; } = "";
    public List<PipelineOp> Operations { get; } = new();
    public string? OutputTarget { get; set; }
}

public class TouchesBlock
{
    public List<string> Reads { get; } = new();
    public List<string> Writes { get; } = new();
    public string? Dx12 { get; set; }
}

public class KernelDecl
{
    public string Name { get; set; } = "";
    public List<Annotation> Annotations { get; } = new();
    public List<KernelParam> Parameters { get; } = new();
    public KernelParam? OutputParam { get; set; }
    public List<string> Needs { get; } = new();
    public List<string> Gives { get; } = new();
    public TouchesBlock? Touches { get; set; }
    public PipelineExpr? Body { get; set; }
}

public class PipelineStep
{
    public string Name { get; set; } = "";
    public string KernelName { get; set; } = "";
    public List<string> Args { get; } = new();
}

public class TelemetryEntry
{
    public string LogSource { get; set; } = "";
    public string FilePath { get; set; } = "";
}

public class TelemetryBlock
{
    public List<TelemetryEntry> Entries { get; } = new();
}

public class PipelineDecl
{
    public string Name { get; set; } = "";
    public List<KernelParam> Parameters { get; } = new();
    public BPlusType? ReturnType { get; set; }
    public List<PipelineStep> Steps { get; } = new();
    public TelemetryBlock? Telemetry { get; set; }
    public List<Annotation> Annotations { get; } = new();
}

public class Directive
{
    public string Name { get; set; } = "";
    public string Value { get; set; } = "";
    public string? SubValue { get; set; }
}

public class UseCxxDecl
{
    public List<string> Headers { get; } = new();
}

public class ExternCppFnDecl
{
    public string Name { get; set; } = "";
    public string ReturnType { get; set; } = "";
    public List<KernelParam> Parameters { get; } = new();
}

public class EntryDecl
{
    public string Name { get; set; } = "";
    public string? Body { get; set; }
    public List<string> BodyLines { get; } = new();
    public string? ReturnType { get; set; }
}

// ════════════════════════════════════════
// v2.3: Memory System
// ════════════════════════════════════════

public enum BPlusMemoryMode { Smart, Precise, Ultra }

public class MemoryConfig
{
    public BPlusMemoryMode Mode { get; set; } = BPlusMemoryMode.Smart;
    public string? VramBudget { get; set; }
    public string? RamBudget { get; set; }
    public bool CacheAuto { get; set; } = true;
    public bool Defrag { get; set; }
    public StreamingConfig? Streaming { get; set; }
}

public class StreamingConfig
{
    public string? Source { get; set; }
    public string? Resident { get; set; }
    public string? Evict { get; set; }
    public int Prefetch { get; set; }
    public string? Priority { get; set; }
}

public class MemoryAnnotation
{
    public string Name { get; set; } = "";
    public Dictionary<string, string> Args { get; } = new();
}

public class VarDecl
{
    public string Name { get; set; } = "";
    public BPlusType Type { get; set; } = null!;
    public string? Init { get; set; }
    public List<MemoryAnnotation> MemoryAnnotations { get; } = new();
}



