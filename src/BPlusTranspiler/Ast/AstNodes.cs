using BPlusTranspiler.Optimizer;

namespace BPlusTranspiler.Ast;

public enum ActionType { Enter, Exit }

// Mojo-inspired features
public enum InlineHint { Default, AlwaysInline, NoInline }
public enum OwnershipHint { Default, Owned, Borrowed }

public class SimdType : BPlusType
{
    public string ElementType { get; set; } = "u8";
    public int Width { get; set; } = 32; // lanes (16 for AVX-256, 32 for AVX-512, etc.)
}

public class LlvmIntrinsicDecl
{
    public string Intrinsic { get; set; } = "";  // e.g. "llvm.prefetch"
    public string? Target { get; set; }           // optional: state/kernel this applies to
    public List<string> Args { get; } = new();
}

public class ParameterCondition
{
    public string Key { get; set; } = "";   // e.g. "target", "arch"
    public string Value { get; set; } = ""; // e.g. "avx512", "metal"
    public string? Body { get; set; }       // conditional code
}

public class ProgramNode
{
    public List<ImportNode> Imports { get; } = new();
    public ContextNode? Context { get; set; }
    public List<EnumNode> Enums { get; } = new();
    public List<StateDefNode> States { get; } = new();
    public List<ParallelBlockNode> ParallelBlocks { get; } = new();
    public List<NetworkNode> Networks { get; } = new();

    // Streaming mode (#parser directive or --stream flag)
    public BPlusStreamMode StreamMode { get; set; }

    // v2.2+ new constructs
    public List<Directive> Directives { get; } = new();
    public List<UseCxxDecl> UseCxxDecls { get; } = new();
    public List<ExternCppFnDecl> ExternCppFns { get; } = new();
    public List<KernelDecl> Kernels { get; } = new();
    public List<PipelineDecl> Pipelines { get; } = new();
    public List<EntryDecl> Entries { get; } = new();
    public List<StructDecl> Structs { get; } = new();

    // v2.3 Memory system
    public MemoryConfig? Memory { get; set; }
    public List<VarDecl> VarDecls { get; } = new();
    public List<Annotation> StandaloneAnnotations { get; } = new();

    // v3.3 Blockchain/Defi networks
    public List<BlockchainNetworkNode> BlockchainNetworks { get; } = new();

    // v3.4 Graphics types for GPU compute and upscaling
    public List<GraphicsKernelDecl> GraphicsKernels { get; } = new();
    public List<ComputeShaderDecl> ComputeShaders { get; } = new();
    public List<FragmentShaderDecl> FragmentShaders { get; } = new();
    public List<VertexShaderDecl> VertexShaders { get; } = new();
    public List<RayTracingShaderDecl> RayTracingShaders { get; } = new();
    public List<LocalGroupDecl> LocalGroups { get; } = new();

    // v3.5 Scientific computing types
    public List<ScientificKernelDecl> ScientificKernels { get; } = new();
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
    private Lazy<string>? _resolvedType;
    public string ResolvedType => _resolvedType?.Value ?? Type;
    public void SetInferredType(Func<string> resolver) => _resolvedType = new Lazy<string>(resolver);
    // @fast_path — keep in CPU registers
    public bool IsFastPath { get; set; }
    public bool IsMutable { get; set; } = true;
    public bool IsAtomic { get; set; }
    public bool IsNullable { get; set; }
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
    public bool IsStream { get; set; }
    public List<VariableNode> Variables { get; } = new();
    public List<TransitionNode> Transitions { get; } = new();
    public List<ActionNode> Actions { get; } = new();
    public List<TimerNode> Timers { get; } = new();
    public List<StateDefNode> NestedStates { get; } = new();
    // Semantic Inline chain ID (set by optimizer)
    public string? ChainId { get; set; }
    public int Depth { get; set; }
    public int ParseLine { get; set; }
    // Mojo-inspired
    public InlineHint Inline { get; set; } = InlineHint.Default;
    public OwnershipHint Ownership { get; set; } = OwnershipHint.Default;
    public List<LlvmIntrinsicDecl> LlvmIntrinsics { get; } = new();
    public List<ParameterCondition> ParameterConditions { get; } = new();
    // Zig: Error transitions
    public List<ErrorTransitionNode> ErrorTransitions { get; } = new();
    // Rust: NLL liveness results
    public LivenessResult? Liveness { get; set; }
    // Julia: inferred types per variable
    public Dictionary<string, string> InferredTypes { get; } = new();
    // Go: escape analysis result per variable
    public Dictionary<string, EscapeKind> EscapeResults { get; } = new();
    // Haskell: demand analysis result
    public DemandSignature? Demand { get; set; }

    // Cache control
    public string? CachePolicy { get; set; }
    public bool CachePin { get; set; }
    public int? CacheAlign { get; set; }
    public bool NonTemporal { get; set; }

    // Branch prediction
    public string? Predict { get; set; }
    public double? PredictProbability { get; set; }

    // Deadline
    public long? DeadlineUs { get; set; }
    public bool DeadlineHard { get; set; } = true;

    // Inline asm
    public string? AsmBlock { get; set; }
    public List<FunctionDecl> Functions { get; } = new();
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
    public bool IsHistory { get; set; }
    public double? HotWeight { get; set; }
    public string? ChainId { get; set; }
    public string? Predict { get; set; }
    public double? PredictProbability { get; set; }
    public bool IsFallible { get; set; }
    public string? ErrorType { get; set; }
    public string? ErrorTarget { get; set; }
    public string? ErrorBody { get; set; }
}

// Zig: ErrorTransitionNode — fallible transition with explicit error handling
public class ErrorTransitionNode
{
    public string EventName { get; set; } = "";
    public List<ParamNode> Parameters { get; } = new();
    public string? Guard { get; set; }
    public string OkTarget { get; set; } = "";
    public string? OkBody { get; set; }
    public string? ErrorType { get; set; }
    public string ErrorTarget { get; set; } = "";
    public string? ErrorBody { get; set; }
    public double? HotWeight { get; set; }
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
    public List<string> SharedVariables { get; } = new();
    public Dictionary<string, HashSet<string>> DepGraph { get; set; } = new();
    public List<string> BodyLines { get; } = new();
}

public class NetworkNode
{
    public string Name { get; set; } = "";
    public List<StateDefNode> States { get; } = new();
    public NetworkProtocol Protocol { get; set; } = NetworkProtocol.TCP;
    public string? Host { get; set; }
    public int Port { get; set; }
    public bool AutoReconnect { get; set; }
    public int MaxRetries { get; set; } = 5;
    public int TimeoutMs { get; set; } = 30000;
    public int HeartbeatIntervalMs { get; set; } = 5000;
    public int PacketLossThreshold { get; set; } = 30;
    public SecurityLevel Security { get; set; } = SecurityLevel.None;

    public CorporateCryptoConfig? Crypto { get; set; }
    public ZeroTrustConfig? ZeroTrust { get; set; }
    public List<NetworkSegment> Segments { get; } = new();
    public List<NetworkSite> Sites { get; } = new();
    public ResilienceConfig? Resilience { get; set; }
    public string? Description { get; set; }
}

public class CorporateCryptoConfig
{
    public CryptoTransportMode Transport { get; set; } = CryptoTransportMode.TLS13;
    public CryptoSessionMode Session { get; set; } = CryptoSessionMode.DoubleRatchet;
    public CryptoPayloadMode Payload { get; set; } = CryptoPayloadMode.AES256GCM;
    public PostQuantumMode PostQuantum { get; set; } = PostQuantumMode.HybridX25519MLKEM;
    public int KeyRotationSeconds { get; set; } = 60;
    public int KeyRotationBytes { get; set; } = 100_000_000;
    public List<string> Ciphers { get; } = new() { "chacha20_poly1305", "aes_256_gcm" };
}

public class ZeroTrustConfig
{
    public bool NeverImplicitTrust { get; set; } = true;
    public AuthMethod IdentityAuth { get; set; } = AuthMethod.Certificate | AuthMethod.HardwareKey;
    public int MaxSessionHours { get; set; } = 4;
    public bool MLAnomalyDetection { get; set; } = true;
    public bool TPMAttestation { get; set; } = true;
    public bool RequireMFA { get; set; } = true;
    public double AnomalyThreshold { get; set; } = 0.8;
}

public class NetworkSegment
{
    public string Name { get; set; } = "";
    public int Vlan { get; set; }
    public List<string> AllowedResources { get; } = new();
    public bool Isolated { get; set; }
}

public enum ConsensusType { PoW, PoS, DPoS, PBFT, Raft }
public enum WalletAlgorithm { ECDSA, Ed25519, Schnorr }
public enum P2PProtocol { Kademlia, Gossip, Chord }
public enum ShardingType { None, ShardChain, StateSharding }

public class BlockchainNetworkNode
{
    public string Name { get; set; } = "";
    public string Address { get; set; } = "";
    public int Port { get; set; }
    public string PublicKey { get; set; } = "";
    public bool IsValidator { get; set; }
    public long Stake { get; set; }
    public long Reputation { get; set; }
    public ConsensusType Consensus { get; set; } = ConsensusType.PBFT;
    public WalletAlgorithm WalletAlgo { get; set; } = WalletAlgorithm.Ed25519;
    public P2PProtocol P2PMode { get; set; } = P2PProtocol.Kademlia;
    public ShardingType Sharding { get; set; } = ShardingType.None;
    public List<StateDefNode> States { get; } = new();
    public List<NetworkSegment> Segments { get; } = new();
    public List<BlockchainNetworkNode> BootNodes { get; } = new();
    public List<LedgerEntry> GenesisLedger { get; } = new();
    public int MaxPeers { get; set; } = 100;
    public int MinValidators { get; set; } = 4;
    public int BlockTimeMs { get; set; } = 1000;
    public int Difficulty { get; set; } = 4;
    public long MinStake { get; set; } = 1000;
    public int ShardCount { get; set; } = 16;
}

public class LedgerEntry
{
    public string From { get; set; } = "";
    public string To { get; set; } = "";
    public long Amount { get; set; }
    public string Hash { get; set; } = "";
    public long Timestamp { get; set; }
    public int Nonce { get; set; }
    public byte[] Signature { get; set; } = Array.Empty<byte>();
}

public class Block
{
    public int Height { get; set; }
    public string PrevHash { get; set; } = "";
    public string MerkleRoot { get; set; } = "";
    public List<LedgerEntry> Transactions { get; } = new();
    public long Timestamp { get; set; }
    public string Validator { get; set; } = "";
    public int Nonce { get; set; }
    public string Hash { get; set; } = "";
}

public enum ShaderStage { Vertex, Fragment, Compute, RayTrace }
public enum TextureFormat { R8G8B8A8, R16G16B16A16, R32G32B32, R32G32B32A32, BC7, ASTC }

public class TextureDecl
{
    public string Name { get; set; } = "";
    public TextureFormat Format { get; set; } = TextureFormat.R8G8B8A8;
    public int Width { get; set; }
    public int Height { get; set; }
    public int Depth { get; set; } = 1;
    public bool IsRenderTarget { get; set; }
    public bool IsDepthStencil { get; set; }
    public int Slot { get; set; }
}

public class BufferDecl
{
    public string Name { get; set; } = "";
    public string ElementType { get; set; } = "float";
    public int Count { get; set; }
    public int Slot { get; set; }
    public bool IsRw { get; set; }
}

public class SamplerDecl
{
    public string Name { get; set; } = "";
    public int Slot { get; set; }
    public string Filter { get; set; } = "linear";
    public string AddressMode { get; set; } = "clamp";
}

public class GraphicsKernelDecl
{
    public string Name { get; set; } = "";
    public ShaderStage Stage { get; set; } = ShaderStage.Compute;
    public int ThreadsX { get; set; } = 16;
    public int ThreadsY { get; set; } = 16;
    public int ThreadsZ { get; set; } = 1;
    public List<TextureDecl> Textures { get; } = new();
    public List<BufferDecl> Buffers { get; } = new();
    public List<SamplerDecl> Samplers { get; } = new();
    public List<StateDefNode> States { get; } = new();
}

public class NetworkSite
{
    public string Name { get; set; } = "";
    public SiteRole Role { get; set; } = SiteRole.Endpoint;
    public string? PrimaryAddress { get; set; }
    public List<string> SecondaryAddresses { get; } = new();
}

public class ResilienceConfig
{
    public MultipathMode Multipath { get; set; } = MultipathMode.ActiveActive;
    public int FailoverMs { get; set; } = 200;
    public int MeshNodes { get; set; } = 3;
    public ConsensusProtocol Consensus { get; set; } = ConsensusProtocol.Raft;
}

public enum CryptoTransportMode { TLS10, TLS11, TLS12, TLS13, WireGuard }
public enum CryptoSessionMode { Simple, DoubleRatchet, Signal }
public enum CryptoPayloadMode { AES128GCM, AES256GCM, ChaCha20Poly1305 }
public enum PostQuantumMode { None, MLKEM768, MLKEM1024, HybridX25519MLKEM, HybridBIKE }
public enum AuthMethod { Password, Certificate, HardwareKey, TPM, Biometric, None }
public enum SiteRole { Primary, Replica, Endpoint, Backup }
public enum MultipathMode { None, ActiveStandby, ActiveActive }
public enum ConsensusProtocol { None, Raft, Paxos, BFT }

public enum NetworkProtocol { TCP, UDP, QUIC, WebRTC, WebSocket, gRPC }
public enum SecurityLevel { None, TLS, MutualAuth, Encrypted }

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
    // SIMD annotations
    public int? SimdWidth { get; set; }
    public int? SimdUnroll { get; set; }
    public bool SimdGather { get; set; }
    // Memory comptime safety
    public bool MemoryComptime { get; set; }
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

public enum BPlusStreamMode { None, Parser }

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

public enum BPlusMemoryMode { Smart, Precise, Ultra, Comptime }

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

public enum QubitState { Zero, One, Superposition }
public enum TensorCoreMode { WMMA, DP4A, HMMA }
public enum MemoryArchitecture { UMA, NUMA, HCC }

public class QubitType
{
    public string Name { get; set; } = "";
    public List<QubitState> States { get; } = new();
    public int Slot { get; set; }
}

public class TensorOperand
{
    public string Name { get; set; } = "";
    public string Shape { get; set; } = "";
    public TensorCoreMode Mode { get; set; } = TensorCoreMode.WMMA;
    public int Slot { get; set; }
}

public class SparseMatrix
{
    public string Name { get; set; } = "";
    public string Format { get; set; } = "CSR";
    public int Rows { get; set; }
    public int Cols { get; set; }
    public int NonZeros { get; set; }
}

public class UnifiedMemoryBuffer
{
    public string Name { get; set; } = "";
    public int SizeBytes { get; set; }
    public bool CpuAccessible { get; set; }
    public bool GpuAccessible { get; set; }
    public MemoryArchitecture Architecture { get; set; } = MemoryArchitecture.UMA;
}

public class ScientificKernelDecl
{
    public string Name { get; set; } = "";
    public List<StateDefNode> States { get; } = new();
    public List<QubitType> Qubits { get; } = new();
    public List<TensorOperand> Tensors { get; } = new();
    public List<SparseMatrix> Matrices { get; } = new();
    public List<UnifiedMemoryBuffer> Buffers { get; } = new();
    public List<AsyncComputeQueue> AsyncQueues { get; } = new();
    public TensorCoreMode TensorMode { get; set; } = TensorCoreMode.WMMA;
    public IntervalArithmetic? IntervalConfig { get; set; }
    public TPUConfig? TPU { get; set; }
    public FPGAConfig? FPGA { get; set; }
    public OpticalFlowConfig? OpticalFlow { get; set; }
    public bool AutoDiff { get; set; }
}

public class IntervalArithmetic
{
    public double Lower { get; set; }
    public double Upper { get; set; }
    public double Precision { get; set; }
}

public class TPUConfig
{
    public string Name { get; set; } = "";
    public string Backend { get; set; } = "tpu";
    public int PodSlice { get; set; }
}

public class FPGAConfig
{
    public string Name { get; set; } = "";
    public string TargetLanguage { get; set; } = "verilog";
    public int ClockMhz { get; set; }
    public int LogicCells { get; set; }
}

public class AsyncComputeQueue
{
    public string Name { get; set; } = "";
    public int Priority { get; set; }
    public int MaxWorkItems { get; set; }
}

public class OpticalFlowConfig
{
    public string Name { get; set; } = "";
    public bool UseHardware { get; set; }
    public string Algorithm { get; set; } = "farneback";
}

public enum SamplerFilter { Point, Linear, Anisotropic, Cubic }
public enum SamplerAddress { Clamp, Repeat, Mirror, Border }
public enum ResourceDimension { Buffer, Texture1D, Texture2D, Texture3D, TextureCube }

public class ShaderResourceBinding
{
    public string Name { get; set; } = "";
    public string Register { get; set; } = "";
    public int Space { get; set; }
    public ResourceDimension Dimension { get; set; } = ResourceDimension.Buffer;
}

public class ComputeShaderDecl
{
    public string Name { get; set; } = "";
    public int ThreadsX { get; set; } = 16;
    public int ThreadsY { get; set; } = 16;
    public int ThreadsZ { get; set; } = 1;
    public int GroupSizeX { get; set; } = 16;
    public int GroupSizeY { get; set; } = 16;
    public int GroupSizeZ { get; set; } = 1;
    public List<ShaderResourceBinding> Resources { get; } = new();
    public List<StateDefNode> States { get; } = new();
    public bool AutoDiff { get; set; }
}

public class FragmentShaderDecl
{
    public string Name { get; set; } = "";
    public bool EarlyDepthStencil { get; set; }
    public bool AlphaToCoverage { get; set; }
    public List<ShaderResourceBinding> Resources { get; } = new();
    public List<StateDefNode> States { get; } = new();
}

public class VertexShaderDecl
{
    public string Name { get; set; } = "";
    public string InputLayout { get; set; } = "";
    public List<ShaderResourceBinding> Resources { get; } = new();
    public List<StateDefNode> States { get; } = new();
}

public class RayTracingShaderDecl
{
    public string Name { get; set; } = "";
    public int MaxRecursionDepth { get; set; } = 1;
    public List<ShaderResourceBinding> Resources { get; } = new();
    public List<StateDefNode> States { get; } = new();
}

public class FunctionDecl
{
    public string Name { get; set; } = "";
    public bool IsInline { get; set; }
    public string Body { get; set; } = "";
    public string ReturnType { get; set; } = "void";
    public List<(string Name, string Type)> Parameters { get; } = new();
}

public class StructDecl
{
    public string Name { get; set; } = "";
    public List<VariableNode> Fields { get; } = new();
}

public class SharedMemoryDecl
{
    public string Name { get; set; } = "";
    public int SizeBytes { get; set; }
    public int Alignment { get; set; } = 4;
}

public class LocalGroupDecl
{
    public string Name { get; set; } = "";
    public int Width { get; set; } = 16;
    public int Height { get; set; } = 16;
    public List<SharedMemoryDecl> SharedVariables { get; } = new();
}



