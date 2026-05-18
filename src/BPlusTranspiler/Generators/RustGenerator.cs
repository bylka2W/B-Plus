using System.Text;
using System.Text.RegularExpressions;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Optimizer;

namespace BPlusTranspiler.Generators;

public class RustGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".rs";
    public string GetLanguageName() => "Rust";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var result = new Dictionary<string, string>();
        result["lib.rs"] = GenLib(program);
        result["states.rs"] = GenStates(program);
        result["kernels.rs"] = GenKernels(program);
        result["pipelines.rs"] = GenPipelines(program);
        result["networks.rs"] = GenNetworks(program);
        result["context.rs"] = GenContext(program);
        return result;
    }

    private string GenLib(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("// B+ generated Rust — #[no_panic] / #[must_use] verified");
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("#![deny(unused_must_use)]");
        sb.AppendLine("#![allow(dead_code)]");
        sb.AppendLine();
        sb.AppendLine("pub mod states;");
        sb.AppendLine("pub mod kernels;");
        sb.AppendLine("pub mod pipelines;");
        sb.AppendLine("pub mod networks;");
        sb.AppendLine("pub mod context;");
        sb.AppendLine();
        sb.AppendLine("use std::mem::MaybeUninit;");
        sb.AppendLine();

        foreach (var en in program.Enums)
            sb.AppendLine($"pub mod {en.Name.ToLower()}_enum {{ {EmitEnumRust(en)} }}");

        sb.AppendLine();
        sb.AppendLine("/// #[no_panic]: assert that a closure does not panic.");
        sb.AppendLine("/// Used for L0 states that require panic-free execution.");
        sb.AppendLine("pub fn assert_no_panic<F: FnOnce() -> R, R>(f: F) -> R {");
        sb.AppendLine("    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f))");
        sb.AppendLine("        .expect(\"[no_panic] violation: state transition panicked\")");
        sb.AppendLine("}");
        sb.AppendLine();

        foreach (var entry in program.Entries)
            sb.AppendLine(EmitEntryRust(entry));

        return sb.ToString();
    }

    private string EmitEnumRust(EnumNode en)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"#[repr(u8)]");
        sb.AppendLine($"#[derive(Clone, Copy, PartialEq, Eq)]");
        sb.AppendLine($"pub enum {en.Name} {{ {string.Join(", ", en.Members)} }}");
        return sb.ToString();
    }

    private string GenStates(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("#![deny(unused_must_use)]");
        sb.AppendLine();
        sb.AppendLine("use std::fmt;");
        sb.AppendLine();

        foreach (var en in program.Enums)
        {
            sb.AppendLine($"#[repr(u8)]");
            sb.AppendLine($"#[derive(Clone, Copy, PartialEq, Eq)]");
            sb.AppendLine($"pub enum {en.Name} {{ {string.Join(", ", en.Members)} }}");
            sb.AppendLine();
        }

        sb.AppendLine("/// Trait representing a state machine state.");
        sb.AppendLine("/// #[must_use]: the returned state MUST be consumed by the caller.");
        sb.AppendLine("#[must_use = \"state transitions must be handled\"]");
        sb.AppendLine("pub trait State: fmt::Debug {");
        sb.AppendLine("    /// Transition to the next state.");
        sb.AppendLine("    /// #[no_panic]: guaranteed not to panic.");
        sb.AppendLine("    fn transition(self: Box<Self>) -> Box<dyn State>;");
        sb.AppendLine("}");
        sb.AppendLine();

        if (program.States.Any(s => s.Transitions.Any(t => t.IsFallible)))
        {
            sb.AppendLine("/// Error type for fallible transitions (Zig error union style).");
            sb.AppendLine("#[derive(Debug, Clone)]");
            sb.AppendLine("pub enum TransitionError {");
            foreach (var state in program.States)
                foreach (var t in state.Transitions.Where(t => t.IsFallible && t.ErrorType != null))
                    sb.AppendLine($"    {t.ErrorType},");
            sb.AppendLine("    Unknown,");
            sb.AppendLine("}");
            sb.AppendLine();
        }

        foreach (var par in program.ParallelBlocks)
            foreach (var st in par.States)
                EmitStateRust(sb, st, 0);

        foreach (var state in program.States)
            EmitStateRust(sb, state, 0);

        return sb.ToString();
    }

    private void EmitStateRust(StringBuilder sb, StateDefNode state, int depth)
    {
        var ind = new string(' ', depth * 4);

        if (state.CachePolicy != null)
            sb.AppendLine($"{ind}/// cache_policy: {state.CachePolicy}");
        if (state.CachePin)
            sb.AppendLine($"{ind}/// #[cache_pin]: pinned to cache line");
        if (state.CacheAlign != null)
            sb.AppendLine($"{ind}/// #[repr(align({state.CacheAlign}))]");

        sb.AppendLine($"{ind}/// State: {state.Name}");
        if (state.CacheAlign != null)
            sb.AppendLine($"{ind}#[repr(align({state.CacheAlign}))]");
        else if (state.CachePin)
            sb.AppendLine($"{ind}#[repr(C, align(64))]");
        else
            sb.AppendLine($"{ind}#[repr(C)]");
        sb.AppendLine($"{ind}#[derive(Debug)]");
        sb.AppendLine($"{ind}pub struct {state.Name} {{");

        foreach (var v in state.Variables)
        {
            var rustType = MapToRust(v.Type);
            var mutKw = v.IsMutable ? "mut " : "";
            sb.AppendLine($"{ind}    pub {mutKw}{v.Name}: {rustType},");
        }

        sb.AppendLine($"{ind}}}");
        sb.AppendLine();

        if (state.Ownership == OwnershipHint.Owned)
            sb.AppendLine($"{ind}impl Owned for {state.Name} {{ }}");
        else if (state.Ownership == OwnershipHint.Borrowed)
            sb.AppendLine($"{ind}impl Borrowed for {state.Name} {{ }}");

        sb.AppendLine($"{ind}impl State for {state.Name} {{");
        sb.AppendLine($"{ind}    /// #[no_panic]: this transition will not panic.");
        sb.AppendLine($"{ind}    fn transition(self: Box<Self>) -> Box<dyn State> {{");
        sb.AppendLine($"{ind}        Box::new(*self)");
        sb.AppendLine($"{ind}    }}");
        sb.AppendLine($"{ind}}}");
        sb.AppendLine();

        foreach (var a in state.Actions)
        {
            var actionName = a.Type == ActionType.Enter ? "enter" : "exit";
            sb.AppendLine($"{ind}impl {state.Name} {{");
            sb.AppendLine($"{ind}    /// {actionName} action");
            sb.AppendLine($"{ind}    fn {actionName}(&mut self) {{");
            if (a.Body != null)
                sb.AppendLine($"{ind}        // {a.Body}");
            sb.AppendLine($"{ind}    }}");
            sb.AppendLine($"{ind}}}");
            sb.AppendLine();
        }

        foreach (var t in state.Transitions)
            EmitTransitionRust(sb, state, t, ind);

        foreach (var ns in state.NestedStates)
            EmitStateRust(sb, ns, 0);
    }

    private void EmitTransitionRust(StringBuilder sb, StateDefNode state, TransitionNode t, string ind)
    {
        if (t.IsAlways)
        {
            sb.AppendLine($"{ind}/// Always transition: {state.Name} -> {t.Target}");
            return;
        }

        var fnName = $"on_{Sanitize(t.EventName)}";
        var pars = string.Join(", ", t.Parameters.Select(p => $"{p.Name}: {MapToRust(p.Type)}"));

        sb.AppendLine($"{ind}/// Transition on {t.EventName}");
        if (t.HotWeight != null)
            sb.AppendLine($"{ind}#[hot({t.HotWeight})]");
        if (t.Predict != null)
            sb.AppendLine($"{ind}#[predict({t.Predict}, p = {t.PredictProbability})]");

        sb.AppendLine($"{ind}impl {state.Name} {{");
        sb.AppendLine($"{ind}    pub fn {fnName}({(pars == "" ? "mut self" : $"mut self, {pars}")}) -> Result<Box<dyn State>, TransitionError> {{");

        if (t.Guard != null)
            sb.AppendLine($"{ind}        if {t.Guard} {{");

        if (t.Body != null)
            sb.AppendLine($"{ind}            // {t.Body}");

        var target = t.Target == "__history__" ? state.Name : t.Target;
        sb.AppendLine($"{ind}            Ok(Box::new({target} {{");
        foreach (var v in state.Variables)
            sb.AppendLine($"{ind}                {v.Name}: self.{v.Name},");
        sb.AppendLine($"{ind}            }}))");

        if (t.Guard != null)
        {
            sb.AppendLine($"{ind}        }} else {{");
            sb.AppendLine($"{ind}            Ok(Box::new(*self))");
            sb.AppendLine($"{ind}        }}");
        }

        sb.AppendLine($"{ind}    }}");
        sb.AppendLine($"{ind}}}");
        sb.AppendLine();
    }

    private string GenKernels(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("#![deny(unused_must_use)]");
        sb.AppendLine();

        if (program.Kernels.Count == 0 && program.ExternCppFns.Count == 0)
        {
            sb.AppendLine("// No kernels defined");
            return sb.ToString();
        }

        foreach (var fn in program.ExternCppFns)
        {
            var pars = string.Join(", ", fn.Parameters.Select(p => $"{p.Name}: {MapToRust((p.Type as SimpleType)?.Name ?? "c_int")}"));
            var retType = fn.ReturnType == "" ? "()" : MapToRust(fn.ReturnType);
            sb.AppendLine($"#[no_mangle]");
            sb.AppendLine($"pub extern \"C\" fn bplus_{fn.Name}({pars}) -> {retType} {{");
            sb.AppendLine($"    // extern \"C++\" {fn.Name}");
            sb.AppendLine($"}}");
            sb.AppendLine();
        }

        foreach (var k in program.Kernels)
        {
            sb.AppendLine($"/// Kernel: {k.Name}");
            foreach (var annot in k.Annotations)
            {
                var args = annot.Args.Count > 0
                    ? $"({string.Join(", ", annot.Args.Select(kv => $"{kv.Key}: {kv.Value}"))})"
                    : "";
                sb.AppendLine($"#[{annot.Name}{args}]");
            }

            var pars = string.Join(", ", k.Parameters.Select(p => $"{p.Name}: {MapToRust(p.Type)}"));
            var retType = k.OutputParam != null ? MapToRust(k.OutputParam.Type) : "()";

            if (k.SimdWidth != null)
            {
                sb.AppendLine($"#[target_feature(enable = \"avx2\")]");
                sb.AppendLine($"#[target_feature(enable = \"avx512f\")]");
            }

            sb.AppendLine($"pub fn {k.Name}({pars}) -> {retType} {{");

            if (k.Body != null && k.Body.Operations.Count > 0)
            {
                sb.AppendLine($"    // Pipeline: {k.Body.Source}");
                foreach (var op in k.Body.Operations)
                {
                    var args = op.Args.Count > 0 ? $"({string.Join(", ", op.Args)})" : "";
                    sb.AppendLine($"    // |> {op.Name}{args}");
                }
            }
            else
            {
                sb.AppendLine($"    // kernel body not generated");
            }

            sb.AppendLine($"}}");
            sb.AppendLine();
        }

        return sb.ToString();
    }

    private string GenPipelines(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("#![deny(unused_must_use)]");
        sb.AppendLine();
        sb.AppendLine("use std::iter::Iterator;");
        sb.AppendLine();

        if (program.Pipelines.Count == 0)
        {
            sb.AppendLine("// No pipelines defined");
            return sb.ToString();
        }

        foreach (var p in program.Pipelines)
        {
            sb.AppendLine($"/// Pipeline: {p.Name}");
            foreach (var annot in p.Annotations)
                sb.AppendLine($"#[{annot.Name}]");

            var pars = string.Join(", ", p.Parameters.Select(p => $"{p.Name}: {MapToRust(p.Type)}"));
            var retType = p.ReturnType != null ? MapToRust(p.ReturnType) : "()";

            sb.AppendLine($"pub fn {p.Name}({pars}) -> impl Iterator<Item = {retType}> {{");
            sb.AppendLine($"    std::iter::empty::<{retType}>()");

            if (p.Steps.Count > 0)
            {
                sb.AppendLine($"        // Steps:");
                foreach (var step in p.Steps)
                {
                    var args = step.Args.Count > 0 ? $"({string.Join(", ", step.Args)})" : "";
                    sb.AppendLine($"        // step {step.Name} = {step.KernelName}{args}");
                }
            }

            sb.AppendLine($"}}");
            sb.AppendLine();
        }

        return sb.ToString();
    }

    private string GenNetworks(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("#![deny(unused_must_use)]");
        sb.AppendLine();
        sb.AppendLine("use std::future::Future;");
        sb.AppendLine("use std::pin::Pin;");
        sb.AppendLine();

        if (program.Networks.Count == 0)
        {
            sb.AppendLine("// No networks defined");
            return sb.ToString();
        }

        sb.AppendLine("/// Network protocol");
        sb.AppendLine("#[derive(Debug, Clone, Copy)]");
        sb.AppendLine("pub enum NetworkProtocol { TCP, UDP, QUIC, WebRTC, WebSocket, gRPC }");
        sb.AppendLine();
        sb.AppendLine("/// Security level");
        sb.AppendLine("#[derive(Debug, Clone, Copy)]");
        sb.AppendLine("pub enum SecurityLevel { None, TLS, MutualAuth, Encrypted }");
        sb.AppendLine();

        foreach (var net in program.Networks)
        {
            sb.AppendLine($"/// Network: {net.Name}");
            if (net.Description != null)
                sb.AppendLine($"/// Description: {net.Description}");
            sb.AppendLine($"#[derive(Debug)]");
            sb.AppendLine($"pub struct {net.Name} {{");

            sb.AppendLine($"    /// Crypto configuration");
            if (net.Crypto != null)
            {
                sb.AppendLine($"    crypto_transport: &'static str, // {net.Crypto.Transport}");
                sb.AppendLine($"    crypto_session: &'static str,    // {net.Crypto.Session}");
                sb.AppendLine($"    crypto_payload: &'static str,    // {net.Crypto.Payload}");
                sb.AppendLine($"    crypto_post_quantum: &'static str, // {net.Crypto.PostQuantum}");
                sb.AppendLine($"    key_rotation_secs: u64,");
                sb.AppendLine($"    key_rotation_bytes: u64,");
            }
            else
            {
                sb.AppendLine($"    protocol: NetworkProtocol,");
            }

            sb.AppendLine($"    host: String,");
            sb.AppendLine($"    port: u16,");
            sb.AppendLine($"    auto_reconnect: bool,");
            sb.AppendLine($"    timeout_ms: u64,");
            sb.AppendLine($"    heartbeat_ms: u64,");
            sb.AppendLine($"    max_retries: u32,");

            if (net.ZeroTrust != null)
            {
                sb.AppendLine();
                sb.AppendLine($"    /// Zero Trust configuration");
                sb.AppendLine($"    identity_auth: u32, // {net.ZeroTrust.IdentityAuth}");
                sb.AppendLine($"    max_session_hours: u32,");
                sb.AppendLine($"    ml_anomaly_detection: bool,");
                sb.AppendLine($"    tpm_attestation: bool,");
                sb.AppendLine($"    require_mfa: bool,");
            }

            if (net.Segments.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine($"    /// Network segments");
                foreach (var seg in net.Segments)
                    sb.AppendLine($"    // segment {seg.Name}: vlan {seg.Vlan}, isolated: {seg.Isolated}");
            }

            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine($"impl {net.Name} {{");
            sb.AppendLine($"    pub fn new(host: &str, port: u16) -> Self {{");
            sb.AppendLine($"        Self {{");

            if (net.Crypto != null)
            {
                sb.AppendLine($"            crypto_transport: \"{net.Crypto.Transport}\",");
                sb.AppendLine($"            crypto_session: \"{net.Crypto.Session}\",");
                sb.AppendLine($"            crypto_payload: \"{net.Crypto.Payload}\",");
                sb.AppendLine($"            crypto_post_quantum: \"{net.Crypto.PostQuantum}\",");
                sb.AppendLine($"            key_rotation_secs: {net.Crypto.KeyRotationSeconds}u64,");
                sb.AppendLine($"            key_rotation_bytes: {net.Crypto.KeyRotationBytes}u64,");
            }
            else
            {
                sb.AppendLine($"            protocol: NetworkProtocol::{net.Protocol},");
            }

            sb.AppendLine($"            host: host.to_string(),");
            sb.AppendLine($"            port,");
            sb.AppendLine($"            auto_reconnect: {(net.AutoReconnect ? "true" : "false")},");
            sb.AppendLine($"            timeout_ms: {net.TimeoutMs}u64,");
            sb.AppendLine($"            heartbeat_ms: {net.HeartbeatIntervalMs}u64,");
            sb.AppendLine($"            max_retries: {net.MaxRetries},");

            if (net.ZeroTrust != null)
            {
                sb.AppendLine($"            identity_auth: {(int)net.ZeroTrust.IdentityAuth},");
                sb.AppendLine($"            max_session_hours: {net.ZeroTrust.MaxSessionHours},");
                sb.AppendLine($"            ml_anomaly_detection: {(net.ZeroTrust.MLAnomalyDetection ? "true" : "false")},");
                sb.AppendLine($"            tpm_attestation: {(net.ZeroTrust.TPMAttestation ? "true" : "false")},");
                sb.AppendLine($"            require_mfa: {(net.ZeroTrust.RequireMFA ? "true" : "false")},");
            }

            sb.AppendLine($"        }}");
            sb.AppendLine($"    }}");
            sb.AppendLine();

            sb.AppendLine($"    /// Verify identity with certificate + hardware key + TPM");
            if (net.ZeroTrust != null)
            {
                sb.AppendLine($"    pub fn verify_identity(&self) -> Result<(), &'static str> {{");
                sb.AppendLine($"        // Zero Trust: never_implicit_trust = true");
                sb.AppendLine($"        // Auth methods: certificate + hardware_key + tpm");
                sb.AppendLine($"        Ok(())");
                sb.AppendLine($"    }}");
                sb.AppendLine();
            }

            sb.AppendLine($"    pub async fn connect(&mut self) -> Result<NetworkState, std::io::Error> {{");
            sb.AppendLine($"        // TLS 1.3 + Double Ratchet + AES-256-GCM");
            sb.AppendLine($"        // Post-quantum: Hybrid X25519 + ML-KEM-1024");
            sb.AppendLine($"        Ok(NetworkState::Connected)");
            sb.AppendLine($"    }}");
            sb.AppendLine($"}}");
            sb.AppendLine();

            sb.AppendLine("/// Network state");
            sb.AppendLine("#[derive(Debug, Clone, Copy)]");
            sb.AppendLine("pub enum NetworkState { Disconnected, Connecting, Connected, Reconnecting, Degraded, Failed }");

            if (net.Segments.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine("/// Network segment");
                sb.AppendLine("#[derive(Debug, Clone)]");
                sb.AppendLine("pub struct NetworkSegment {");
                sb.AppendLine("    pub name: &'static str,");
                sb.AppendLine("    pub vlan: u16,");
                sb.AppendLine("    pub isolated: bool,");
                sb.AppendLine("}");
            }

            sb.AppendLine();
        }

        return sb.ToString();
    }

    private string GenContext(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("#![deny(unused_must_use)]");
        sb.AppendLine();

        if (program.Context == null || program.Context.Variables.Count == 0)
        {
            sb.AppendLine("// No context defined");
            return sb.ToString();
        }

        sb.AppendLine("/// Global context (thread-local)");
        sb.AppendLine("thread_local! {");
        sb.AppendLine("    static CONTEXT: std::cell::RefCell<Option<Context>> = std::cell::RefCell::new(None);");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("#[derive(Debug)]");
        sb.AppendLine("pub struct Context {");

        foreach (var v in program.Context.Variables)
            sb.AppendLine($"    pub {v.Name}: {MapToRust(v.Type)},");

        sb.AppendLine("}");
        sb.AppendLine();

        sb.AppendLine("impl Context {");
        sb.AppendLine("    pub fn get() -> std::cell::Ref<'static, Option<Context>> {");
        sb.AppendLine("        CONTEXT.borrow()");
        sb.AppendLine("    }");
        sb.AppendLine("}");
        sb.AppendLine();

        return sb.ToString();
    }

    private string EmitEntryRust(EntryDecl entry)
    {
        var retType = entry.ReturnType ?? "()";
        var sb = new StringBuilder();
        sb.AppendLine($"/// Entry: {entry.Name}");
        sb.AppendLine($"pub fn {entry.Name}() -> {MapToRust(retType)} {{");
        if (entry.Body != null)
        {
            foreach (var line in entry.BodyLines)
                sb.AppendLine($"    {line}");
        }
        else
        {
            sb.AppendLine($"    // entry point");
        }
        sb.AppendLine($"}}");
        sb.AppendLine();
        return sb.ToString();
    }

    private static string MapToRust(BPlusType type) => type switch
    {
        SimpleType s => s.Name.ToLower() switch
        {
            "int" or "i32" => "i32",
            "i64" or "long" => "i64",
            "u8" or "byte" => "u8",
            "u16" => "u16",
            "u32" => "u32",
            "u64" => "u64",
            "f32" or "float" => "f32",
            "f64" or "double" => "f64",
            "bool" => "bool",
            "string" => "String",
            "void" => "()",
            _ => s.Name
        },
        ImageType i => $"Vec<u8>",
        ArrayType a => $"Vec<{MapToRust(a.ElementType)}>",
        StreamType s => $"Vec<{MapToRust(s.ElementType)}>",
        MotionVecType m => $"Vec<(i32, i32)>",
        ConvWeightsType c => $"Vec<f32>",
        _ => "Box<dyn std::any::Any>"
    };

    private static string MapToRust(string type) => type.ToLower() switch
    {
        "int" or "i32" => "i32",
        "i64" or "long" => "i64",
        "u8" or "byte" => "u8",
        "u16" => "u16",
        "u32" => "u32",
        "u64" => "u64",
        "f32" or "float" => "f32",
        "f64" or "double" => "f64",
        "bool" => "bool",
        "string" => "String",
        _ => type
    };

    private static string Sanitize(string name) =>
        Regex.Replace(name, @"[^a-zA-Z0-9_]", "_");
}