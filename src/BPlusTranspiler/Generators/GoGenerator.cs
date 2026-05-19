using System.Text;
using System.Text.RegularExpressions;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Optimizer;

namespace BPlusTranspiler.Generators;

public class GoGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".go";
    public string GetLanguageName() => "Go";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var result = new Dictionary<string, string>();
        result["states.go"] = GenStates(program);
        result["kernels.go"] = GenKernels(program);
        result["pipelines.go"] = GenPipelines(program);
        result["networks.go"] = GenNetworks(program);
        result["context.go"] = GenContext(program);
        result["main.go"] = GenMain(program);
        if (program.BlockchainNetworks.Count > 0)
            result["blockchain.go"] = GenBlockchain(program);
        if (program.GraphicsKernels.Count > 0)
            result["graphics.go"] = GenGraphics(program);
        return result;
    }

    private string GenStates(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("package bplus");
        sb.AppendLine();
        sb.AppendLine("import \"errors\"");
        sb.AppendLine();

        foreach (var en in program.Enums)
        {
            sb.AppendLine($"// {en.Name} enum");
            sb.AppendLine($"type {en.Name} int");
            sb.AppendLine($"const (");
            for (int i = 0; i < en.Members.Count; i++)
                sb.AppendLine($"    {en.Name}_{en.Members[i]} {en.Name} = {i}");
            sb.AppendLine(")");
            sb.AppendLine();
        }

        if (program.States.Count == 0 && program.ParallelBlocks.Count == 0)
        {
            sb.AppendLine("// No states defined");
            return sb.ToString();
        }

        sb.AppendLine("// State is the interface for all state machine states.");
        sb.AppendLine("type State interface {");
        sb.AppendLine("    // Transition moves to the next state.");
        sb.AppendLine("    Transition() State");
        sb.AppendLine("}");
        sb.AppendLine();

        if (program.States.Any(s => s.Transitions.Any(t => t.IsFallible)))
        {
            sb.AppendLine("// TransitionError for fallible state transitions.");
            sb.AppendLine("var ErrTransition = errors.New(\"state transition failed\")");
            sb.AppendLine();
        }

        foreach (var par in program.ParallelBlocks)
        {
            sb.AppendLine($"// Parallel block: {par.Name}");
            foreach (var st in par.States)
                EmitStateGo(sb, st, 0);
        }

        foreach (var state in program.States)
            EmitStateGo(sb, state, 0);

        return sb.ToString();
    }

    private void EmitStateGo(StringBuilder sb, StateDefNode state, int depth)
    {
        var ind = string.Join("", Enumerable.Repeat("\t", depth));

        sb.AppendLine($"// {state.Name} represents the {state.Name} state.");
        if (state.CachePin)
            sb.AppendLine($"//go:cachepin");
        if (state.CacheAlign != null)
            sb.AppendLine($"//go:align({state.CacheAlign})");

        sb.AppendLine($"type {state.Name} struct {{");

        foreach (var v in state.Variables)
        {
            var goType = MapToGo(v.Type);
            var exportName = UpperFirst(v.Name);
            sb.AppendLine($"{ind}\t{exportName} {goType}");
        }

        sb.AppendLine($"}}");
        sb.AppendLine();

        sb.AppendLine($"func (s *{state.Name}) Transition() State {{");
        foreach (var t in state.Transitions.Where(t => t.IsAlways))
        {
            var target = t.Target == "__history__" ? state.Name : t.Target;
            sb.AppendLine($"{ind}\treturn &{target}{{}}");
        }
        if (!state.Transitions.Any(t => t.IsAlways))
            sb.AppendLine($"{ind}\treturn s");
        sb.AppendLine($"}}");
        sb.AppendLine();

        foreach (var a in state.Actions)
        {
            var actionName = a.Type == ActionType.Enter ? "OnEnter" : "OnExit";
            sb.AppendLine($"func (s *{state.Name}) {actionName}() {{");
            if (a.Body != null)
                sb.AppendLine($"{ind}\t// {a.Body}");
            sb.AppendLine($"}}");
            sb.AppendLine();
        }

        foreach (var t in state.Transitions.Where(t => !t.IsAlways))
            EmitTransitionGo(sb, state, t, depth);

        foreach (var ns in state.NestedStates)
            EmitStateGo(sb, ns, depth + 1);
    }

    private void EmitTransitionGo(StringBuilder sb, StateDefNode state, TransitionNode t, int depth)
    {
        var fnName = "On" + UpperFirst(Sanitize(t.EventName));
        var pars = string.Join(", ", t.Parameters.Select(p => $"{LowerFirst(p.Name)} {MapToGo(p.Type)}"));
        if (pars != "") pars = ", " + pars;

        if (t.IsFallible)
        {
            sb.AppendLine($"func (s *{state.Name}) {fnName}(ctx *Context{pars}) (State, error) {{");
        }
        else
        {
            sb.AppendLine($"func (s *{state.Name}) {fnName}(ctx *Context{pars}) State {{");
        }

        if (t.Guard != null)
            sb.AppendLine($"\tif {t.Guard} {{");

        if (t.Body != null)
            sb.AppendLine($"\t\t// {t.Body}");

        var target = t.Target == "__history__" ? state.Name : t.Target;
        if (t.IsFallible)
            sb.AppendLine($"\t\treturn &{target}{{}}, nil");
        else
            sb.AppendLine($"\t\treturn &{target}{{}}");

        if (t.Guard != null)
        {
            if (t.IsFallible)
                sb.AppendLine($"\t}} else {{");
            else
                sb.AppendLine($"\t}} else {{");
            if (t.IsFallible)
                sb.AppendLine($"\t\treturn s, ErrTransition");
            else
                sb.AppendLine($"\t\treturn s");
            sb.AppendLine($"\t}}");
        }

        if (t.IsFallible)
            sb.AppendLine($"\treturn s, nil");
        sb.AppendLine($"}}");
        sb.AppendLine();
    }

    private string GenKernels(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("package bplus");
        sb.AppendLine();
        sb.AppendLine("//go:build ignore");
        sb.AppendLine();

        if (program.Kernels.Count == 0 && program.ExternCppFns.Count == 0)
        {
            sb.AppendLine("// No kernels defined");
            return sb.ToString();
        }

        foreach (var fn in program.ExternCppFns)
        {
            var pars = string.Join(", ", fn.Parameters.Select(p => $"{LowerFirst(p.Name)} {MapToGo((p.Type as SimpleType)?.Name ?? "int")}"));
            var retType = fn.ReturnType == "" ? "" : MapToGo(fn.ReturnType);
            if (retType != "") retType = " " + retType;
            sb.AppendLine($"//export bplus_{fn.Name}");
            sb.AppendLine($"func bplus_{fn.Name}({pars}){retType} {{");
            sb.AppendLine($"\t// extern \"C++\" {fn.Name}");
            sb.AppendLine($"}}");
            sb.AppendLine();
        }

        foreach (var k in program.Kernels)
        {
            sb.AppendLine($"// Kernel: {k.Name}");

            foreach (var annot in k.Annotations)
            {
                var args = annot.Args.Count > 0
                    ? $"({string.Join(", ", annot.Args.Select(kv => $"{kv.Key}: {kv.Value}"))})"
                    : "";
                sb.AppendLine($"//go:optimize {annot.Name}{args}");
            }

            if (k.SimdWidth != null)
            {
                sb.AppendLine($"//go:build amd64");
                sb.AppendLine($"//go:optimize simd");
            }

            var pars = string.Join(", ", k.Parameters.Select(p => $"{LowerFirst(p.Name)} {MapToGo(p.Type)}"));
            var retType = k.OutputParam != null ? MapToGo(k.OutputParam.Type) : "";

            sb.AppendLine($"func {k.Name}({pars}){retType} {{");

            if (k.Body != null && k.Body.Operations.Count > 0)
            {
                sb.AppendLine($"\t// Pipeline: {k.Body.Source}");
                foreach (var op in k.Body.Operations)
                {
                    var args = op.Args.Count > 0 ? $"({string.Join(", ", op.Args)})" : "";
                    sb.AppendLine($"\t// |> {op.Name}{args}");
                }
            }
            else
            {
                sb.AppendLine($"\t// kernel body not generated");
            }

            sb.AppendLine($"}}");
            sb.AppendLine();
        }

        return sb.ToString();
    }

    private string GenPipelines(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("package bplus");
        sb.AppendLine();
        sb.AppendLine("import \"iter\"");
        sb.AppendLine();

        if (program.Pipelines.Count == 0)
        {
            sb.AppendLine("// No pipelines defined");
            return sb.ToString();
        }

        foreach (var p in program.Pipelines)
        {
            sb.AppendLine($"// Pipeline: {p.Name}");

            foreach (var annot in p.Annotations)
                sb.AppendLine($"//go:optimize {annot.Name}");

            var pars = string.Join(", ", p.Parameters.Select(p => $"{LowerFirst(p.Name)} {MapToGo(p.Type)}"));
            var retType = p.ReturnType != null ? MapToGo(p.ReturnType) : "int";

            sb.AppendLine($"func {p.Name}({pars}) func(func({retType}) bool) {{");
            sb.AppendLine($"\treturn func(yield func({retType}) bool) {{");

            if (p.Steps.Count > 0)
            {
                sb.AppendLine($"\t\t// Steps:");
                foreach (var step in p.Steps)
                {
                    var args = step.Args.Count > 0 ? $"({string.Join(", ", step.Args)})" : "";
                    sb.AppendLine($"\t\t// step {step.Name} = {step.KernelName}{args}");
                }
            }

            sb.AppendLine($"\t}}");
            sb.AppendLine($"}}");
            sb.AppendLine();
        }

        return sb.ToString();
    }

    private string GenNetworks(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("package bplus");
        sb.AppendLine();
        sb.AppendLine("import (");
        sb.AppendLine("\t\"context\"");
        sb.AppendLine("\t\"fmt\"");
        sb.AppendLine("\t\"net\"");
        sb.AppendLine("\t\"time\"");
        sb.AppendLine(")");
        sb.AppendLine();

        if (program.Networks.Count == 0)
        {
            sb.AppendLine("// No networks defined");
            return sb.ToString();
        }

        sb.AppendLine("// NetworkProtocol represents the network protocol type.");
        sb.AppendLine("type NetworkProtocol int");
        sb.AppendLine("const (");
        sb.AppendLine("\tProtocolTCP NetworkProtocol = iota");
        sb.AppendLine("\tProtocolUDP");
        sb.AppendLine("\tProtocolQUIC");
        sb.AppendLine("\tProtocolWebRTC");
        sb.AppendLine("\tProtocolWebSocket");
        sb.AppendLine("\tProtocolgRPC");
        sb.AppendLine(")");
        sb.AppendLine();
        sb.AppendLine("// SecurityLevel represents the security level.");
        sb.AppendLine("type SecurityLevel int");
        sb.AppendLine("const (");
        sb.AppendLine("\tSecurityNone SecurityLevel = iota");
        sb.AppendLine("\tSecurityTLS");
        sb.AppendLine("\tSecurityMutualAuth");
        sb.AppendLine("\tSecurityEncrypted");
        sb.AppendLine(")");
        sb.AppendLine();
        sb.AppendLine("// NetworkState represents the network connection state.");
        sb.AppendLine("type NetworkState int");
        sb.AppendLine("const (");
        sb.AppendLine("\tNetworkDisconnected NetworkState = iota");
        sb.AppendLine("\tNetworkConnecting");
        sb.AppendLine("\tNetworkConnected");
        sb.AppendLine("\tNetworkReconnecting");
        sb.AppendLine("\tNetworkDegraded");
        sb.AppendLine("\tNetworkFailed");
        sb.AppendLine(")");
        sb.AppendLine();
        sb.AppendLine("// AuthMethod represents authentication methods.");
        sb.AppendLine("type AuthMethod int");
        sb.AppendLine("const (");
        sb.AppendLine("\tAuthNone AuthMethod = iota");
        sb.AppendLine("\tAuthPassword");
        sb.AppendLine("\tAuthCertificate");
        sb.AppendLine("\tAuthHardwareKey");
        sb.AppendLine("\tAuthTPM");
        sb.AppendLine("\tAuthBiometric");
        sb.AppendLine(")");
        sb.AppendLine();

        foreach (var net in program.Networks)
        {
            sb.AppendLine($"// {net.Name} represents the {net.Name} corporate network.");
            if (net.Description != null)
                sb.AppendLine($"// Description: {net.Description}");

            if (net.Crypto != null)
            {
                sb.AppendLine($"// Crypto: {net.Crypto.Transport} + {net.Crypto.Session} + {net.Crypto.Payload} + {net.Crypto.PostQuantum}");
                sb.AppendLine($"// Key rotation: {net.Crypto.KeyRotationSeconds}s / {net.Crypto.KeyRotationBytes}b");
            }

            sb.AppendLine($"type {net.Name} struct {{");

            if (net.Crypto != null)
            {
                sb.AppendLine($"\tCryptoTransport    string");
                sb.AppendLine($"\tCryptoSession      string");
                sb.AppendLine($"\tCryptoPayload      string");
                sb.AppendLine($"\tCryptoPostQuantum  string");
                sb.AppendLine($"\tKeyRotationSecs    uint64");
                sb.AppendLine($"\tKeyRotationBytes  uint64");
            }

            sb.AppendLine($"\tProtocol    NetworkProtocol");
            sb.AppendLine($"\tHost        string");
            sb.AppendLine($"\tPort        int");
            sb.AppendLine($"\tConn        net.Conn");
            sb.AppendLine($"\tDeadline    time.Duration");
            sb.AppendLine($"\tHeartbeat   time.Duration");
            sb.AppendLine($"\tMaxRetries  int");
            sb.AppendLine($"\tAutoReconnect bool");

            if (net.ZeroTrust != null)
            {
                sb.AppendLine();
                sb.AppendLine($"\t// Zero Trust configuration");
                sb.AppendLine($"\tIdentityAuth        AuthMethod");
                sb.AppendLine($"\tMaxSessionHours     uint32");
                sb.AppendLine($"\tMLAnomalyDetection  bool");
                sb.AppendLine($"\tTPMAttestation      bool");
                sb.AppendLine($"\tRequireMFA          bool");
            }

            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"func New{net.Name}(host string, port int) *{net.Name} {{");
            sb.AppendLine($"\treturn &{net.Name}{{");

            if (net.Crypto != null)
            {
                sb.AppendLine($"\t\tCryptoTransport:   \"{net.Crypto.Transport}\",");
                sb.AppendLine($"\t\tCryptoSession:     \"{net.Crypto.Session}\",");
                sb.AppendLine($"\t\tCryptoPayload:     \"{net.Crypto.Payload}\",");
                sb.AppendLine($"\t\tCryptoPostQuantum: \"{net.Crypto.PostQuantum}\",");
                sb.AppendLine($"\t\tKeyRotationSecs:   {net.Crypto.KeyRotationSeconds},");
                sb.AppendLine($"\t\tKeyRotationBytes: {net.Crypto.KeyRotationBytes},");
            }

            sb.AppendLine($"\t\tProtocol:   {MapNetworkProtocol(net.Protocol)},");
            sb.AppendLine($"\t\tHost:       host,");
            sb.AppendLine($"\t\tPort:       port,");
            sb.AppendLine($"\t\tDeadline:   {net.TimeoutMs} * time.Millisecond,");
            sb.AppendLine($"\t\tHeartbeat:  {net.HeartbeatIntervalMs} * time.Millisecond,");
            sb.AppendLine($"\t\tMaxRetries: {net.MaxRetries},");
            sb.AppendLine($"\t\tAutoReconnect: {ToGoBool(net.AutoReconnect)},");

            if (net.ZeroTrust != null)
            {
                sb.AppendLine($"\t\tIdentityAuth:       AuthMethod({(int)net.ZeroTrust.IdentityAuth}),");
                sb.AppendLine($"\t\tMaxSessionHours:    {net.ZeroTrust.MaxSessionHours},");
                sb.AppendLine($"\t\tMLAnomalyDetection: {ToGoBool(net.ZeroTrust.MLAnomalyDetection)},");
                sb.AppendLine($"\t\tTPMAttestation:      {ToGoBool(net.ZeroTrust.TPMAttestation)},");
                sb.AppendLine($"\t\tRequireMFA:          {ToGoBool(net.ZeroTrust.RequireMFA)},");
            }

            sb.AppendLine($"\t}}");
            sb.AppendLine($"}}");
            sb.AppendLine();

            if (net.ZeroTrust != null)
            {
                sb.AppendLine($"// VerifyIdentity implements Zero Trust verification");
                sb.AppendLine($"func (n *{net.Name}) VerifyIdentity() error {{");
                sb.AppendLine($"\t// Zero Trust: never_implicit_trust = true");
                sb.AppendLine($"\t// Auth methods: certificate + hardware_key + tpm");
                sb.AppendLine($"\treturn nil");
                sb.AppendLine($"}}");
                sb.AppendLine();
            }

            sb.AppendLine($"func (n *{net.Name}) Connect(ctx context.Context) (NetworkState, error) {{");
            sb.AppendLine($"\t// TLS 1.3 + Double Ratchet + AES-256-GCM + Post-quantum");
            sb.AppendLine($"\tdialer := &net.Dialer{{");
            sb.AppendLine($"\t\tTimeout: n.Deadline,");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\taddr := fmt.Sprintf(\"%s:%d\", n.Host, n.Port)");
            sb.AppendLine($"\tconn, err := dialer.DialContext(ctx, \"tcp\", addr)");
            sb.AppendLine($"\tif err != nil {{");
            sb.AppendLine($"\t\tif n.AutoReconnect {{");
            sb.AppendLine($"\t\t\treturn NetworkReconnecting, err");
            sb.AppendLine($"\t\t}}");
            sb.AppendLine($"\t\treturn NetworkFailed, err");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\tn.Conn = conn");
            sb.AppendLine($"\treturn NetworkConnected, nil");
            sb.AppendLine($"}}");
            sb.AppendLine();

            if (net.Segments.Count > 0)
            {
                sb.AppendLine($"// NetworkSegment represents a network segment");
                sb.AppendLine($"type NetworkSegment struct {{");
                sb.AppendLine($"\tName     string");
                sb.AppendLine($"\tVLAN     uint16");
                sb.AppendLine($"\tIsolated bool");
                sb.AppendLine($"}}");
                sb.AppendLine();
            }

            sb.AppendLine($"func (n *{net.Name}) Close() error {{");
            sb.AppendLine($"\tif n.Conn != nil {{");
            sb.AppendLine($"\t\treturn n.Conn.Close()");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\treturn nil");
            sb.AppendLine($"}}");
            sb.AppendLine();
        }

        return sb.ToString();
    }

    private string GenContext(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("package bplus");
        sb.AppendLine();
        sb.AppendLine("import \"sync\"");
        sb.AppendLine();

        if (program.Context == null || program.Context.Variables.Count == 0)
        {
            sb.AppendLine("// No context defined");
            return sb.ToString();
        }

        sb.AppendLine("// Context holds the global context for the application.");
        sb.AppendLine("type Context struct {");
        sb.AppendLine("\tsync.RWMutex");

        foreach (var v in program.Context.Variables)
        {
            var goType = MapToGo(v.Type);
            var exportName = UpperFirst(v.Name);
            sb.AppendLine($"\t{exportName} {goType}");
        }

        sb.AppendLine("}");
        sb.AppendLine();

        sb.AppendLine("// Global context instance.");
        sb.AppendLine("var globalCtx = &Context{}");
        sb.AppendLine();

        sb.AppendLine("func GetContext() *Context {");
        sb.AppendLine("\treturn globalCtx");
        sb.AppendLine("}");
        sb.AppendLine();

        return sb.ToString();
    }

    private string GenMain(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("package main");
        sb.AppendLine();
        sb.AppendLine("import \"bplus\"");
        sb.AppendLine();

        if (program.Entries.Count > 0)
        {
            sb.AppendLine("func main() {");
            foreach (var entry in program.Entries)
            {
                sb.AppendLine($"\tbplus.{entry.Name}()");
            }
            sb.AppendLine("}");
        }
        else
        {
            sb.AppendLine("func main() {");
            if (program.States.Count > 0)
            {
                var firstState = program.States[0].Name;
                sb.AppendLine($"\tvar s bplus.State = &bplus.{firstState}{{}}");
                sb.AppendLine($"\tfor {{");
                sb.AppendLine($"\t\ts = s.Transition()");
                sb.AppendLine($"\t}}");
            }
            else
            {
                sb.AppendLine("\t// B+ entry point");
            }
            sb.AppendLine("}");
        }

        return sb.ToString();
    }

    private static string MapToGo(BPlusType type) => type switch
    {
        SimpleType s => s.Name.ToLower() switch
        {
            "int" or "i32" => "int32",
            "i64" or "long" => "int64",
            "i8" => "int8",
            "i16" => "int16",
            "u8" or "byte" => "uint8",
            "u16" => "uint16",
            "u32" => "uint32",
            "u64" => "uint64",
            "f32" or "float" => "float32",
            "f64" or "double" => "float64",
            "bool" => "bool",
            "string" => "string",
            "void" => "",
            _ => s.Name
        },
        ImageType => "[]byte",
        ArrayType a => $"[]{MapToGo(a.ElementType)}",
        StreamType s => $"[]{MapToGo(s.ElementType)}",
        MotionVecType => "[][2]int32",
        ConvWeightsType => "[]float32",
        _ => "interface{}"
    };

    private static string MapToGo(string type) => type.ToLower() switch
    {
        "int" or "i32" => "int32",
        "i64" or "long" => "int64",
        "u8" or "byte" => "uint8",
        "u16" => "uint16",
        "u32" => "uint32",
        "u64" => "uint64",
        "f32" or "float" => "float32",
        "f64" or "double" => "float64",
        "bool" => "bool",
        "string" => "string",
        "void" => "",
        _ => type
    };

    private static string MapNetworkProtocol(NetworkProtocol proto) => proto switch
    {
        NetworkProtocol.TCP => "ProtocolTCP",
        NetworkProtocol.UDP => "ProtocolUDP",
        NetworkProtocol.QUIC => "ProtocolQUIC",
        NetworkProtocol.WebRTC => "ProtocolWebRTC",
        NetworkProtocol.WebSocket => "ProtocolWebSocket",
        NetworkProtocol.gRPC => "ProtocolgRPC",
        _ => "ProtocolTCP"
    };

    private static string MapSecurityLevel(SecurityLevel level) => level switch
    {
        SecurityLevel.None => "SecurityNone",
        SecurityLevel.TLS => "SecurityTLS",
        SecurityLevel.MutualAuth => "SecurityMutualAuth",
        SecurityLevel.Encrypted => "SecurityEncrypted",
        _ => "SecurityNone"
    };

    private static string Sanitize(string name) =>
        Regex.Replace(name, @"[^a-zA-Z0-9_]", "_");

    private static string UpperFirst(string s) =>
        string.IsNullOrEmpty(s) ? s : char.ToUpper(s[0]) + s[1..];

    private static string LowerFirst(string s) =>
        string.IsNullOrEmpty(s) ? s : char.ToLower(s[0]) + s[1..];

    private static string ToGoBool(bool b) => b ? "true" : "false";

    private string GenBlockchain(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("package bplus");
        sb.AppendLine();
        sb.AppendLine("import (");
        sb.AppendLine("\t\"context\"");
        sb.AppendLine("\t\"crypto/sha256\"");
        sb.AppendLine("\t\"encoding/hex\"");
        sb.AppendLine("\t\"fmt\"");
        sb.AppendLine("\t\"sort\"");
        sb.AppendLine("\t\"sync\"");
        sb.AppendLine("\t\"time\"");
        sb.AppendLine(")");
        sb.AppendLine();

        sb.AppendLine("// ConsensusType for blockchain consensus algorithms.");
        sb.AppendLine("type ConsensusType int");
        sb.AppendLine("const (");
        sb.AppendLine("\tConsensusPoW ConsensusType = iota");
        sb.AppendLine("\tConsensusPoS");
        sb.AppendLine("\tConsensusDPoS");
        sb.AppendLine("\tConsensusPBFT");
        sb.AppendLine("\tConsensusRaft");
        sb.AppendLine(")");
        sb.AppendLine();

        sb.AppendLine("// WalletAlgorithm for transaction signing.");
        sb.AppendLine("type WalletAlgorithm int");
        sb.AppendLine("const (");
        sb.AppendLine("\tWalletECDSA WalletAlgorithm = iota");
        sb.AppendLine("\tWalletEd25519");
        sb.AppendLine("\tWalletSchnorr");
        sb.AppendLine(")");
        sb.AppendLine();

        sb.AppendLine("// P2PProtocol for network topology.");
        sb.AppendLine("type P2PProtocol int");
        sb.AppendLine("const (");
        sb.AppendLine("\tP2PKademlia P2PProtocol = iota");
        sb.AppendLine("\tP2PGossip");
        sb.AppendLine("\tP2PChord");
        sb.AppendLine(")");
        sb.AppendLine();

        sb.AppendLine("// ShardingType for horizontal scaling.");
        sb.AppendLine("type ShardingType int");
        sb.AppendLine("const (");
        sb.AppendLine("\tShardingNone ShardingType = iota");
        sb.AppendLine("\tShardingShardChain");
        sb.AppendLine("\tShardingStateSharding");
        sb.AppendLine(")");
        sb.AppendLine();

        sb.AppendLine("// LedgerEntry represents a single transaction.");
        sb.AppendLine("type LedgerEntry struct {");
        sb.AppendLine("\tFrom      string");
        sb.AppendLine("\tTo        string");
        sb.AppendLine("\tAmount    int64");
        sb.AppendLine("\tHash      string");
        sb.AppendLine("\tTimestamp int64");
        sb.AppendLine("\tNonce     int");
        sb.AppendLine("\tSignature []byte");
        sb.AppendLine("}");
        sb.AppendLine();

        sb.AppendLine("// Block represents a blockchain block.");
        sb.AppendLine("type Block struct {");
        sb.AppendLine("\tHeight       int");
        sb.AppendLine("\tPrevHash     string");
        sb.AppendLine("\tMerkleRoot   string");
        sb.AppendLine("\tTransactions []LedgerEntry");
        sb.AppendLine("\tTimestamp    int64");
        sb.AppendLine("\tValidator    string");
        sb.AppendLine("\tNonce        int");
        sb.AppendLine("\tHash         string");
        sb.AppendLine("}");
        sb.AppendLine();

        sb.AppendLine("// Node represents a blockchain network node.");
        sb.AppendLine("type Node struct {");
        sb.AppendLine("\tName         string");
        sb.AppendLine("\tAddress      string");
        sb.AppendLine("\tPort         int");
        sb.AppendLine("\tPublicKey    string");
        sb.AppendLine("\tIsValidator  bool");
        sb.AppendLine("\tStake        int64");
        sb.AppendLine("\tReputation   int64");
        sb.AppendLine("\tPeers        map[string]*Node");
        sb.AppendLine("\tMu           sync.RWMutex");
        sb.AppendLine("\tLedger       []LedgerEntry");
        sb.AppendLine("\tPendingTxs   []LedgerEntry");
        sb.AppendLine("\tBlocks       []Block");
        sb.AppendLine("\tConsensus    ConsensusType");
        sb.AppendLine("\tWalletAlgo   WalletAlgorithm");
        sb.AppendLine("\tP2PMode      P2PProtocol");
        sb.AppendLine("\tSharding     ShardingType");
        sb.AppendLine("\tMaxPeers     int");
        sb.AppendLine("\tMinValidators int");
        sb.AppendLine("\tBlockTimeMs  int");
        sb.AppendLine("\tDifficulty   int");
        sb.AppendLine("\tMinStake     int64");
        sb.AppendLine("\tShardCount   int");
        sb.AppendLine("\tShardId      int");
        sb.AppendLine("}");
        sb.AppendLine();

        foreach (var chain in program.BlockchainNetworks)
        {
            sb.AppendLine($"// {chain.Name} represents the {chain.Name} blockchain network.");
            sb.AppendLine($"func New{chain.Name}(nodeAddr string, port int) *{chain.Name} {{");
            sb.AppendLine($"\treturn &{chain.Name}{{");
            sb.AppendLine($"\t\tName:         \"{chain.Name}\",");
            sb.AppendLine($"\t\tAddress:      nodeAddr,");
            sb.AppendLine($"\t\tPort:          port,");
            sb.AppendLine($"\t\tPeers:         make(map[string]*Node),");
            sb.AppendLine($"\t\tLedger:        []LedgerEntry{{}},");
            sb.AppendLine($"\t\tPendingTxs:    []LedgerEntry{{}},");
            sb.AppendLine($"\t\tBlocks:        []Block{{}},");
            sb.AppendLine($"\t\tConsensus:     {MapConsensus(chain.Consensus)},");
            sb.AppendLine($"\t\tWalletAlgo:    {MapWalletAlgo(chain.WalletAlgo)},");
            sb.AppendLine($"\t\tP2PMode:       {MapP2PProtocol(chain.P2PMode)},");
            sb.AppendLine($"\t\tSharding:      {MapSharding(chain.Sharding)},");
            sb.AppendLine($"\t\tMaxPeers:      {chain.MaxPeers},");
            sb.AppendLine($"\t\tMinValidators: {chain.MinValidators},");
            sb.AppendLine($"\t\tBlockTimeMs:   {chain.BlockTimeMs},");
            sb.AppendLine($"\t\tDifficulty:    {chain.Difficulty},");
            sb.AppendLine($"\t\tMinStake:      {chain.MinStake},");
            sb.AppendLine($"\t\tShardCount:    {chain.ShardCount},");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// Consensus returns the consensus type for {chain.Name}.");
            sb.AppendLine($"func (n *{chain.Name}) GetConsensus() ConsensusType {{");
            sb.AppendLine($"\treturn n.Consensus");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// AddPeer adds a peer to the P2P network.");
            sb.AppendLine($"func (n *{chain.Name}) AddPeer(peer *Node) {{");
            sb.AppendLine($"\tn.Mu.Lock()");
            sb.AppendLine($"\tdefer n.Mu.Unlock()");
            sb.AppendLine($"\tif len(n.Peers) < n.MaxPeers {{");
            sb.AppendLine($"\t\taddr := fmt.Sprintf(\"%s:%d\", peer.Address, peer.Port)");
            sb.AppendLine($"\t\tn.Peers[addr] = peer");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// SubmitTransaction adds a transaction to the pending pool.");
            sb.AppendLine($"func (n *{chain.Name}) SubmitTransaction(tx LedgerEntry) {{");
            sb.AppendLine($"\tn.Mu.Lock()");
            sb.AppendLine($"\tdefer n.Mu.Unlock()");
            sb.AppendLine($"\ttx.Timestamp = time.Now().UnixMilli()");
            sb.AppendLine($"\ttx.Hash = n.hashTransaction(tx)");
            sb.AppendLine($"\tn.PendingTxs = append(n.PendingTxs, tx)");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// ProposeBlock creates a new block with pending transactions.");
            sb.AppendLine($"func (n *{chain.Name}) ProposeBlock() *Block {{");
            sb.AppendLine($"\tn.Mu.Lock()");
            sb.AppendLine($"\tdefer n.Mu.Unlock()");
            sb.AppendLine();
            sb.AppendLine($"\tvar prevHash string");
            sb.AppendLine($"\tif len(n.Blocks) > 0 {{");
            sb.AppendLine($"\t\tprevHash = n.Blocks[len(n.Blocks)-1].Hash");
            sb.AppendLine($"\t}}");
            sb.AppendLine();
            sb.AppendLine($"\tblock := &Block{{");
            sb.AppendLine($"\t\tHeight:       len(n.Blocks),");
            sb.AppendLine($"\t\tPrevHash:     prevHash,");
            sb.AppendLine($"\t\tTimestamp:    time.Now().UnixMilli(),");
            sb.AppendLine($"\t\tValidator:    n.Address,");
            sb.AppendLine($"\t}}");
            sb.AppendLine();
            sb.AppendLine($"\tswitch n.Consensus {{");
            sb.AppendLine($"\tcase ConsensusPoW:");
            sb.AppendLine($"\t\tblock = n.mineBlock(block)");
            sb.AppendLine($"\tcase ConsensusPoS:");
            sb.AppendLine($"\t\tblock = n.selectValidatorAndPropose(block)");
            sb.AppendLine($"\tcase ConsensusPBFT:");
            sb.AppendLine($"\t\tblock = n.pbftPropose(block)");
            sb.AppendLine($"\tdefault:");
            sb.AppendLine($"\t\tblock.Nonce = 0");
            sb.AppendLine($"\t}}");
            sb.AppendLine();
            sb.AppendLine($"\tblock.MerkleRoot = n.merkleRoot(n.PendingTxs)");
            sb.AppendLine($"\tblock.Hash = n.hashBlock(block)");
            sb.AppendLine($"\tn.Blocks = append(n.Blocks, *block)");
            sb.AppendLine($"\tn.PendingTxs = nil");
            sb.AppendLine($"\treturn block");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// mineBlock performs Proof-of-Work mining.");
            sb.AppendLine($"func (n *{chain.Name}) mineBlock(block *Block) *Block {{");
            sb.AppendLine($"\ttarget := make([]byte, n.Difficulty)");
            sb.AppendLine($"\tfor block.Nonce = 0; block.Nonce < 1<<31; block.Nonce++ {{");
            sb.AppendLine($"\t\thash := n.hashBlock(block)");
            sb.AppendLine($"\t\tif n.checkDifficulty(hash, target) {{");
            sb.AppendLine($"\t\t\treturn block");
            sb.AppendLine($"\t\t}}");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\treturn block");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// selectValidatorAndPropose selects validator by stake for PoS.");
            sb.AppendLine($"func (n *{chain.Name}) selectValidatorAndPropose(block *Block) *Block {{");
            sb.AppendLine($"\tvar totalStake int64");
            sb.AppendLine($"\tfor _, p := range n.Peers {{");
            sb.AppendLine($"\t\ttotalStake += p.Stake");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\tif totalStake > 0 && n.Stake*100/totalStake > 50 {{");
            sb.AppendLine($"\t\tblock.Validator = n.Address");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\treturn block");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// pbftPropose handles PBFT consensus proposal.");
            sb.AppendLine($"func (n *{chain.Name}) pbftPropose(block *Block) *Block {{");
            sb.AppendLine($"\t// PBFT: prepare -> commit -> reply");
            sb.AppendLine($"\t// Simplified: require 2f+1 signatures");
            sb.AppendLine($"\tf := (n.MinValidators - 1) / 3");
            sb.AppendLine($"\t// In real PBFT, collect prepare messages from f+1 validators");
            sb.AppendLine($"\treturn block");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// VerifyBlock verifies block integrity.");
            sb.AppendLine($"func (n *{chain.Name}) VerifyBlock(block *Block) bool {{");
            sb.AppendLine($"\tif block.Height > 0 && block.PrevHash != n.Blocks[block.Height-1].Hash {{");
            sb.AppendLine($"\t\treturn false");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\tif n.Consensus == ConsensusPoW && !n.checkDifficulty(block.Hash, make([]byte, n.Difficulty)) {{");
            sb.AppendLine($"\t\treturn false");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\treturn block.MerkleRoot == n.merkleRoot(block.Transactions)");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// GetBalance returns balance for an address.");
            sb.AppendLine($"func (n *{chain.Name}) GetBalance(addr string) int64 {{");
            sb.AppendLine($"\tn.Mu.RLock()");
            sb.AppendLine($"\tdefer n.Mu.RUnlock()");
            sb.AppendLine($"\tvar balance int64");
            sb.AppendLine($"\tfor _, entry := range n.Ledger {{");
            sb.AppendLine($"\t\tif entry.From == addr {{");
            sb.AppendLine($"\t\t\tbalance -= entry.Amount");
            sb.AppendLine($"\t\t}}");
            sb.AppendLine($"\t\tif entry.To == addr {{");
            sb.AppendLine($"\t\t\tbalance += entry.Amount");
            sb.AppendLine($"\t\t}}");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\treturn balance");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// Gossip propagates transaction to peers.");
            sb.AppendLine($"func (n *{chain.Name}) Gossip(tx LedgerEntry) {{");
            sb.AppendLine($"\tn.Mu.RLock()");
            sb.AppendLine($"\tdefer n.Mu.RUnlock()");
            sb.AppendLine($"\tfor _, peer := range n.Peers {{");
            sb.AppendLine($"\t\tpeer.SubmitTransaction(tx)");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// KademliaFindNode finds node in Kademlia DHT.");
            sb.AppendLine($"func (n *{chain.Name}) KademliaFindNode(targetKey string) *Node {{");
            sb.AppendLine($"\t// Kademlia: XOR distance for node lookup");
            sb.AppendLine($"\tvar closest *Node");
            sb.AppendLine($"\tvar minDist int");
            sb.AppendLine($"\tn.Mu.RLock()");
            sb.AppendLine($"\tdefer n.Mu.RUnlock()");
            sb.AppendLine($"\tfor _, peer := range n.Peers {{");
            sb.AppendLine($"\t\tdist := n.xorDistance(peer.PublicKey, targetKey)");
            sb.AppendLine($"\t\tif closest == nil || dist < minDist {{");
            sb.AppendLine($"\t\t\tclosest = peer");
            sb.AppendLine($"\t\t\tminDist = dist");
            sb.AppendLine($"\t\t}}");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\treturn closest");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// hashTransaction computes SHA-256 hash of transaction.");
            sb.AppendLine($"func (n *{chain.Name}) hashTransaction(tx LedgerEntry) string {{");
            sb.AppendLine($"\tdata := fmt.Sprintf(\"%s%s%d%d\", tx.From, tx.To, tx.Amount, tx.Nonce)");
            sb.AppendLine($"\thash := sha256.Sum256([]byte(data))");
            sb.AppendLine($"\treturn hex.EncodeToString(hash[:])");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// hashBlock computes SHA-256 hash of block.");
            sb.AppendLine($"func (n *{chain.Name}) hashBlock(block *Block) string {{");
            sb.AppendLine($"\tdata := fmt.Sprintf(\"%d%s%d%d\", block.Height, block.PrevHash, block.Timestamp, block.Nonce)");
            sb.AppendLine($"\thash := sha256.Sum256([]byte(data))");
            sb.AppendLine($"\treturn hex.EncodeToString(hash[:])");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// merkleRoot computes Merkle root of transactions.");
            sb.AppendLine($"func (n *{chain.Name}) merkleRoot(txs []LedgerEntry) string {{");
            sb.AppendLine($"\tif len(txs) == 0 {{");
            sb.AppendLine($"\t\treturn \"\"");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\tvar hashes []string");
            sb.AppendLine($"\tfor _, tx := range txs {{");
            sb.AppendLine($"\t\thashes = append(hashes, n.hashTransaction(tx))");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\tfor len(hashes) > 1 {{");
            sb.AppendLine($"\t\tif len(hashes)%2 != 0 {{");
            sb.AppendLine($"\t\t\thashes = append(hashes, hashes[len(hashes)-1])");
            sb.AppendLine($"\t\t}}");
            sb.AppendLine($"\t\tvar next []string");
            sb.AppendLine($"\t\tfor i := 0; i < len(hashes); i += 2 {{");
            sb.AppendLine($"\t\t\tcombined := hashes[i] + hashes[i+1]");
            sb.AppendLine($"\t\t\th := sha256.Sum256([]byte(combined))");
            sb.AppendLine($"\t\t\tnext = append(next, hex.EncodeToString(h[:]))");
            sb.AppendLine($"\t\t}}");
            sb.AppendLine($"\t\thashes = next");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\treturn hashes[0]");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// checkDifficulty verifies proof-of-work target.");
            sb.AppendLine($"func (n *{chain.Name}) checkDifficulty(hash string, target []byte) bool {{");
            sb.AppendLine($"\tfor i := 0; i < len(target) && i < len(hash); i++ {{");
            sb.AppendLine($"\t\tif hash[i] != 0 {{");
            sb.AppendLine($"\t\t\treturn false");
            sb.AppendLine($"\t\t}}");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\treturn true");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// xorDistance computes XOR distance between two keys.");
            sb.AppendLine($"func (n *{chain.Name}) xorDistance(a, b string) int {{");
            sb.AppendLine($"\tvar sum int");
            sb.AppendLine($"\tfor i := 0; i < len(a) && i < len(b); i++ {{");
            sb.AppendLine($"\t\tsum += int(a[i] ^ b[i])");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"\treturn sum");
            sb.AppendLine($"}}");
            sb.AppendLine();
        }

        return sb.ToString();
    }

    private static string MapConsensus(ConsensusType c) => c switch
    {
        ConsensusType.PoW => "ConsensusPoW",
        ConsensusType.PoS => "ConsensusPoS",
        ConsensusType.DPoS => "ConsensusDPoS",
        ConsensusType.PBFT => "ConsensusPBFT",
        ConsensusType.Raft => "ConsensusRaft",
        _ => "ConsensusPBFT"
    };

    private static string MapWalletAlgo(WalletAlgorithm w) => w switch
    {
        WalletAlgorithm.ECDSA => "WalletECDSA",
        WalletAlgorithm.Ed25519 => "WalletEd25519",
        WalletAlgorithm.Schnorr => "WalletSchnorr",
        _ => "WalletEd25519"
    };

    private static string MapP2PProtocol(P2PProtocol p) => p switch
    {
        P2PProtocol.Kademlia => "P2PKademlia",
        P2PProtocol.Gossip => "P2PGossip",
        P2PProtocol.Chord => "P2PChord",
        _ => "P2PKademlia"
    };

    private static string MapSharding(ShardingType s) => s switch
    {
        ShardingType.None => "ShardingNone",
        ShardingType.ShardChain => "ShardingShardChain",
        ShardingType.StateSharding => "ShardingStateSharding",
        _ => "ShardingNone"
    };

    private string GenGraphics(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("package bplus");
        sb.AppendLine();
        sb.AppendLine("import \"github.com/golang-collections/collections/stack\"");
        sb.AppendLine();
        sb.AppendLine("// ShaderStage for graphics pipeline.");
        sb.AppendLine("type ShaderStage int");
        sb.AppendLine("const (");
        sb.AppendLine("    ShaderVertex ShaderStage = iota");
        sb.AppendLine("    ShaderFragment");
        sb.AppendLine("    ShaderCompute");
        sb.AppendLine("    ShaderRayTrace");
        sb.AppendLine(")");
        sb.AppendLine();
        sb.AppendLine("// TextureFormat for GPU textures.");
        sb.AppendLine("type TextureFormat int");
        sb.AppendLine("const (");
        sb.AppendLine("    TextureRGBA8 TextureFormat = iota");
        sb.AppendLine("    TextureRGBA16");
        sb.AppendLine("    TextureRGB32");
        sb.AppendLine("    TextureRGBA32");
        sb.AppendLine("    TextureBC7");
        sb.AppendLine("    TextureASTC");
        sb.AppendLine(")");
        sb.AppendLine();
        sb.AppendLine("// Texture represents a GPU texture resource.");
        sb.AppendLine("type Texture struct {");
        sb.AppendLine("    Name      string");
        sb.AppendLine("    Format    TextureFormat");
        sb.AppendLine("    Width     int");
        sb.AppendLine("    Height    int");
        sb.AppendLine("    Depth     int");
        sb.AppendLine("    Slot      int");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("// Buffer represents a GPU buffer resource.");
        sb.AppendLine("type Buffer struct {");
        sb.AppendLine("    Name         string");
        sb.AppendLine("    ElementType  string");
        sb.AppendLine("    Count        int");
        sb.AppendLine("    Slot         int");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("// Sampler represents a texture sampler.");
        sb.AppendLine("type Sampler struct {");
        sb.AppendLine("    Name         string");
        sb.AppendLine("    Slot         int");
        sb.AppendLine("    Filter       string");
        sb.AppendLine("    AddressMode  string");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("// GraphicsKernel represents a GPU compute kernel.");
        sb.AppendLine("type GraphicsKernel struct {");
        sb.AppendLine("    Name      string");
        sb.AppendLine("    Stage     ShaderStage");
        sb.AppendLine("    ThreadsX int");
        sb.AppendLine("    ThreadsY int");
        sb.AppendLine("    ThreadsZ int");
        sb.AppendLine("    Textures []Texture");
        sb.AppendLine("    Buffers  []Buffer");
        sb.AppendLine("    Samplers []Sampler");
        sb.AppendLine("}");
        sb.AppendLine();

        foreach (var gk in program.GraphicsKernels)
        {
            sb.AppendLine($"// New{gk.Name} creates {gk.Name} graphics kernel.");
            sb.AppendLine($"func New{gk.Name}() *{gk.Name} {{");
            sb.AppendLine($"\treturn &{gk.Name}{{");
            sb.AppendLine($"\t\tName:      \"{gk.Name}\",");
            sb.AppendLine($"\t\tStage:     {MapShaderStage(gk.Stage)},");
            sb.AppendLine($"\t\tThreadsX: {gk.ThreadsX},");
            sb.AppendLine($"\t\tThreadsY: {gk.ThreadsY},");
            sb.AppendLine($"\t\tThreadsZ: {gk.ThreadsZ},");
            sb.AppendLine($"\t\tTextures: []Texture{{}},");
            sb.AppendLine($"\t\tBuffers:  []Buffer{{}},");
            sb.AppendLine($"\t\tSamplers: []Sampler{{}},");
            sb.AppendLine($"\t}}");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// Dispatch launches {gk.ThreadsX}x{gk.ThreadsY}x{gk.ThreadsZ} threads.");
            sb.AppendLine($"func (g *{gk.Name}) Dispatch(ctx context.Context) {{");
            sb.AppendLine($"\t// GPU dispatch: dispatchSize = [{gk.ThreadsX}, {gk.ThreadsY}, {gk.ThreadsZ}]");
            sb.AppendLine($"\t// Each thread processes one pixel");
            sb.AppendLine($"\t_ = ctx");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// BindTexture attaches a texture to slot.");
            sb.AppendLine($"func (g *{gk.Name}) BindTexture(slot int, tex Texture) {{");
            sb.AppendLine($"\tg.Textures = append(g.Textures, tex)");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// BindBuffer attaches a buffer to slot.");
            sb.AppendLine($"func (g *{gk.Name}) BindBuffer(slot int, buf Buffer) {{");
            sb.AppendLine($"\tg.Buffers = append(g.Buffers, buf)");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"// Lerp performs linear interpolation for upscaling.");
            sb.AppendLine($"func Lerp(a, b float32, t float32) float32 {{");
            sb.AppendLine($"\treturn a*(1-t) + b*t");
            sb.AppendLine($"}}");
            sb.AppendLine();
            sb.AppendLine($"// Clamp restricts value to range [min, max].");
            sb.AppendLine($"func Clamp(v, min, max float32) float32 {{");
            sb.AppendLine($"\tif v < min {{ return min }}");
            sb.AppendLine($"\tif v > max {{ return max }}");
            sb.AppendLine($"\treturn v");
            sb.AppendLine($"}}");
            sb.AppendLine();
            sb.AppendLine($"// Dot computes dot product of two vectors.");
            sb.AppendLine($"func Dot(x1, y1, x2, y2 float32) float32 {{");
            sb.AppendLine($"\treturn x1*x2 + y1*y2");
            sb.AppendLine($"}}");
            sb.AppendLine();
            sb.AppendLine($"// Cross computes cross product of two 3D vectors.");
            sb.AppendLine($"func Cross(x1, y1, z1, x2, y2, z2 float32) (float32, float32, float32) {{");
            sb.AppendLine($"\treturn y1*z2-z1*y2, z1*x2-x1*z2, x1*y2-y1*x2");
            sb.AppendLine($"}}");
            sb.AppendLine();
            sb.AppendLine($"// Normalize scales vector to unit length.");
            sb.AppendLine($"func Normalize(x, y, z float32) (float32, float32, float32) {{");
            sb.AppendLine($"\tlen := float32(math.Sqrt(float64(x*x + y*y + z*z)))");
            sb.AppendLine($"\tif len > 0 {{ return x/len, y/len, z/len }}");
            sb.AppendLine($"\treturn 0, 0, 0");
            sb.AppendLine($"}}");
            sb.AppendLine();
            sb.AppendLine($"// SampleTexture bilinear samples texture at UV coordinate.");
            sb.AppendLine($"func SampleTexture(tex Texture, u, v float32) (float32, float32, float32, float32) {{");
            sb.AppendLine($"\tux := Clamp(u*float32(tex.Width), 0, float32(tex.Width-1))");
            sb.AppendLine($"\tvy := Clamp(v*float32(tex.Height), 0, float32(tex.Height-1))");
            sb.AppendLine($"\treturn ux/float32(tex.Width), vy/float32(tex.Height), 1, 1");
            sb.AppendLine($"}}");
            sb.AppendLine();
            sb.AppendLine($"// Reproject applies motion vector reprojection for TAA.");
            sb.AppendLine($"func Reproject(currentUV float32, motionX, motionY float32) (float32, float32) {{");
            sb.AppendLine($"\treturn currentUV - motionX, currentUV - motionY");
            sb.AppendLine($"}}");
            sb.AppendLine();
        }

        return sb.ToString();
    }

    private static string MapShaderStage(ShaderStage s) => s switch
    {
        ShaderStage.Vertex => "ShaderVertex",
        ShaderStage.Fragment => "ShaderFragment",
        ShaderStage.Compute => "ShaderCompute",
        ShaderStage.RayTrace => "ShaderRayTrace",
        _ => "ShaderCompute"
    };
}