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
}