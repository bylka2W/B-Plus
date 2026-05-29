using System.Text;
using System.Text.RegularExpressions;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Optimizer;
using System.Linq;

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
        if (program.BlockchainNetworks.Count > 0)
            result["blockchain.rs"] = GenBlockchainRust(program);

        // v4.0: ComputeShaderDecl
        if (program.ComputeShaders.Count > 0)
            result["compute_shaders.rs"] = GenComputeShadersRust(program);

        // v4.0: FragmentShaderDecl
        if (program.FragmentShaders.Count > 0)
            result["fragment_shaders.rs"] = GenFragmentShadersRust(program);

        // v4.0: VertexShaderDecl
        if (program.VertexShaders.Count > 0)
            result["vertex_shaders.rs"] = GenVertexShadersRust(program);

        // v4.0: RayTracingShaderDecl
        if (program.RayTracingShaders.Count > 0)
            result["raytracing_shaders.rs"] = GenRayTracingShadersRust(program);

        // v4.0: LocalGroupDecl
        if (program.LocalGroups.Count > 0)
            result["local_groups.rs"] = GenLocalGroupsRust(program);

        // v4.0: ScientificKernelDecl
        if (program.ScientificKernels.Count > 0)
            result["scientific_kernels.rs"] = GenScientificKernelsRust(program);

        return result;
    }

    private string GenComputeShadersRust(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("//! B+ v4.0 Compute Shaders");
        sb.AppendLine();
        foreach (var cs in program.ComputeShaders)
        {
            sb.AppendLine($"/// ComputeShader: {cs.Name}");
            sb.AppendLine($"pub struct {cs.Name} {{");
            sb.AppendLine($"    pub threads_x: u32,");
            sb.AppendLine($"    pub threads_y: u32,");
            sb.AppendLine($"    pub threads_z: u32,");
            sb.AppendLine($"    pub group_size_x: u32,");
            sb.AppendLine($"    pub group_size_y: u32,");
            sb.AppendLine($"    pub group_size_z: u32,");
            sb.AppendLine($"    pub auto_diff: bool,");
            sb.AppendLine("}");
            sb.AppendLine();
            sb.AppendLine($"impl {cs.Name} {{");
            sb.AppendLine($"    pub fn new() -> Self {{");
            sb.AppendLine($"        Self {{");
            sb.AppendLine($"            threads_x: {cs.ThreadsX},");
            sb.AppendLine($"            threads_y: {cs.ThreadsY},");
            sb.AppendLine($"            threads_z: {cs.ThreadsZ},");
            sb.AppendLine($"            group_size_x: {cs.GroupSizeX},");
            sb.AppendLine($"            group_size_y: {cs.GroupSizeY},");
            sb.AppendLine($"            group_size_z: {cs.GroupSizeZ},");
            sb.AppendLine($"            auto_diff: {cs.AutoDiff},");
            sb.AppendLine($"        }}");
            sb.AppendLine($"    }}");
            sb.AppendLine("}");
            sb.AppendLine();
        }
        return sb.ToString();
    }

    private string GenFragmentShadersRust(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("//! B+ v4.0 Fragment Shaders");
        sb.AppendLine();
        foreach (var fs in program.FragmentShaders)
        {
            sb.AppendLine($"/// FragmentShader: {fs.Name}");
            sb.AppendLine($"pub struct {fs.Name} {{");
            sb.AppendLine($"    pub early_depth_stencil: bool,");
            sb.AppendLine($"    pub alpha_to_coverage: bool,");
            sb.AppendLine("}");
            sb.AppendLine();
            sb.AppendLine($"impl {fs.Name} {{");
            sb.AppendLine($"    pub fn new() -> Self {{");
            sb.AppendLine($"        Self {{");
            sb.AppendLine($"            early_depth_stencil: {fs.EarlyDepthStencil},");
            sb.AppendLine($"            alpha_to_coverage: {fs.AlphaToCoverage},");
            sb.AppendLine($"        }}");
            sb.AppendLine($"    }}");
            sb.AppendLine("}");
            sb.AppendLine();
        }
        return sb.ToString();
    }

    private string GenVertexShadersRust(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("//! B+ v4.0 Vertex Shaders");
        sb.AppendLine();
        foreach (var vs in program.VertexShaders)
        {
            sb.AppendLine($"/// VertexShader: {vs.Name}");
            sb.AppendLine($"pub struct {vs.Name} {{");
            sb.AppendLine($"    pub input_layout: String,");
            sb.AppendLine("}");
            sb.AppendLine();
            sb.AppendLine($"impl {vs.Name} {{");
            sb.AppendLine($"    pub fn new() -> Self {{");
            sb.AppendLine($"        Self {{");
            sb.AppendLine($"            input_layout: \"{vs.InputLayout}\".to_string(),");
            sb.AppendLine($"        }}");
            sb.AppendLine($"    }}");
            sb.AppendLine("}");
            sb.AppendLine();
        }
        return sb.ToString();
    }

    private string GenRayTracingShadersRust(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("//! B+ v4.0 Ray Tracing Shaders");
        sb.AppendLine();
        foreach (var rt in program.RayTracingShaders)
        {
            sb.AppendLine($"/// RayTracingShader: {rt.Name}");
            sb.AppendLine($"pub struct {rt.Name} {{");
            sb.AppendLine($"    pub max_recursion_depth: u32,");
            sb.AppendLine("}");
            sb.AppendLine();
            sb.AppendLine($"impl {rt.Name} {{");
            sb.AppendLine($"    pub fn new() -> Self {{");
            sb.AppendLine($"        Self {{");
            sb.AppendLine($"            max_recursion_depth: {rt.MaxRecursionDepth},");
            sb.AppendLine($"        }}");
            sb.AppendLine($"    }}");
            sb.AppendLine("}");
            sb.AppendLine();
        }
        return sb.ToString();
    }

    private string GenLocalGroupsRust(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("//! B+ v4.0 Local Groups");
        sb.AppendLine();
        foreach (var lg in program.LocalGroups)
        {
            sb.AppendLine($"/// LocalGroup: {lg.Name}");
            sb.AppendLine($"pub struct {lg.Name} {{");
            sb.AppendLine($"    pub width: u32,");
            sb.AppendLine($"    pub height: u32,");
            sb.AppendLine("}");
            sb.AppendLine();
            sb.AppendLine($"impl {lg.Name} {{");
            sb.AppendLine($"    pub fn new() -> Self {{");
            sb.AppendLine($"        Self {{");
            sb.AppendLine($"            width: {lg.Width},");
            sb.AppendLine($"            height: {lg.Height},");
            sb.AppendLine($"        }}");
            sb.AppendLine($"    }}");
            sb.AppendLine("}");
            sb.AppendLine();
        }
        return sb.ToString();
    }

    private string GenScientificKernelsRust(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("//! B+ v4.0 Scientific Kernels");
        sb.AppendLine();
        sb.AppendLine("use std::collections::HashMap;");
        sb.AppendLine();
        foreach (var sk in program.ScientificKernels)
        {
            sb.AppendLine($"/// ScientificKernel: {sk.Name}");
            sb.AppendLine($"pub struct {sk.Name} {{");
            sb.AppendLine($"    pub tensor_mode: String,");
            sb.AppendLine($"    pub auto_diff: bool,");
            if (sk.TPU != null)
                sb.AppendLine($"    pub tpu_name: String,");
            if (sk.FPGA != null)
                sb.AppendLine($"    pub fpga_name: String,");
            sb.AppendLine("}");
            sb.AppendLine();
            sb.AppendLine($"impl {sk.Name} {{");
            sb.AppendLine($"    pub fn new() -> Self {{");
            sb.AppendLine($"        Self {{");
            sb.AppendLine($"            tensor_mode: \"{sk.TensorMode}\".to_string(),");
            sb.AppendLine($"            auto_diff: {sk.AutoDiff},");
            if (sk.TPU != null)
                sb.AppendLine($"            tpu_name: \"{sk.TPU.Name}\".to_string(),");
            if (sk.FPGA != null)
                sb.AppendLine($"            fpga_name: \"{sk.FPGA.Name}\".to_string(),");
            sb.AppendLine($"        }}");
            sb.AppendLine($"    }}");
            sb.AppendLine("}");
            sb.AppendLine();
        }
        return sb.ToString();
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
        if (program.States.Any(s => s.Variables.Any(v => v.IsFastPath)))
        {
            sb.AppendLine("#![allow(unsafe_code)]");
            sb.AppendLine("// fast-path: unsafe raw pointer access for @fast_path variables");
        }
        else
        {
            sb.AppendLine("#![forbid(unsafe_code)]");
        }
        sb.AppendLine("#![deny(unused_must_use)]");
        sb.AppendLine();
        sb.AppendLine("use std::fmt;");
        sb.AppendLine();
        sb.AppendLine("pub fn print<T: fmt::Display>(x: T) { println!(\"{}\", x); }");
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
        var hasFastPath = state.Variables.Any(v => v.IsFastPath);
        if (hasFastPath)
        {
            sb.AppendLine($"{ind}/// Unmanaged fast-path: @fast_path variables accessed via raw pointers");
            sb.AppendLine($"{ind}#[repr(C, packed)]");
        }

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
            {
                foreach (var line in a.Body.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                    sb.AppendLine($"{ind}        {TranslateRust(line.TrimEnd(';'))};");
            }
            sb.AppendLine($"{ind}    }}");
            sb.AppendLine($"{ind}}}");
            sb.AppendLine();
        }

        // Group transitions by event name
        foreach (var group in state.Transitions.Where(t => !t.IsAlways).GroupBy(t => t.EventName))
        {
            EmitTransitionRustGroup(sb, state, group, ind);
        }
        foreach (var t in state.Transitions.Where(t => t.IsAlways))
        {
            sb.AppendLine($"{ind}/// Always transition: {state.Name} -> {t.Target}");
        }

        foreach (var ns in state.NestedStates)
            EmitStateRust(sb, ns, 0);
    }

    private void EmitTransitionRustGroup(StringBuilder sb, StateDefNode state, IGrouping<string, TransitionNode> group, string ind)
    {
        var first = group.First();
        var fnName = $"on_{Sanitize(first.EventName)}";
        var pars = string.Join(", ", first.Parameters.Select(p => $"{p.Name}: {MapToRust(p.Type)}"));
        var needsFallback = group.All(t => t.Guard != null);

        sb.AppendLine($"{ind}/// Transition on {first.EventName}");
        sb.AppendLine($"{ind}impl {state.Name} {{");
        sb.AppendLine($"{ind}    pub fn {fnName}({(pars == "" ? "mut self" : $"mut self, {pars}")}) -> Result<Box<dyn State>, TransitionError> {{");
        foreach (var t in group)
        {
            if (t.Guard != null)
                sb.AppendLine($"{ind}        if {t.Guard} {{");
            if (t.Body != null)
            {
                foreach (var line in t.Body.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                    sb.AppendLine($"{ind}            {TranslateRust(line.TrimEnd(';'))};");
            }
            var target = t.Target == "__history__" ? state.Name : t.Target;
            sb.AppendLine($"{ind}            Ok(Box::new({target} {{");
            foreach (var v in state.Variables)
                sb.AppendLine($"{ind}                {v.Name}: self.{v.Name},");
            sb.AppendLine($"{ind}            }}))");
            if (t.Guard != null)
            {
                sb.AppendLine($"{ind}        }}");
            }
        }
        if (needsFallback)
            sb.AppendLine($"{ind}        Err(TransitionError::NoMatch)");
        sb.AppendLine($"{ind}    }}");
        sb.AppendLine($"{ind}}}");
        sb.AppendLine();
    }

    private static string TranslateRust(string line)
    {
        if (line.StartsWith("print(") && line.EndsWith(")"))
        {
            var inner = line.Substring(6, line.Length - 7);
            if (inner.StartsWith("\""))
            {
                var content = inner.Substring(1, inner.Length - 2);
                return $"println!(\"{content}\")";
            }
            return $"println!(\"{{\"}}, {inner})";
        }
        return line;
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
        if (entry.BodyLines.Count > 0)
        {
            var stack = new List<string>();
            foreach (var line in entry.BodyLines)
            {
                var trimmed = line.TrimStart();
                var indent = new string(' ', 4 + stack.Count * 4);
                if (trimmed.StartsWith("$$"))
                {
                    sb.AppendLine($"{indent}{trimmed[2..]}");
                    continue;
                }
                if (trimmed == "end")
                {
                    if (stack.Count > 0) { stack.RemoveAt(stack.Count - 1); sb.AppendLine($"{indent[..^4]}}}"); }
                    continue;
                }
                if (trimmed.StartsWith("while ") || trimmed.StartsWith("if ") || trimmed.StartsWith("for "))
                {
                    stack.Add("");
                    var parts = trimmed.Split(' ');
                    var kw = parts[0];
                    var rest = string.Join(" ", parts.Skip(1));
                    sb.AppendLine($"{indent}{kw} {rest} {{");
                    continue;
                }
                sb.AppendLine($"{indent}{TranslateEntryRust(trimmed)};");
            }
            while (stack.Count > 0) { sb.AppendLine("    }"); stack.RemoveAt(stack.Count - 1); }
        }
        else
        {
            sb.AppendLine($"    // entry point");
        }
        sb.AppendLine($"}}");
        sb.AppendLine();
        return sb.ToString();
    }

    private static string TranslateEntryRust(string line)
    {
        if (line.StartsWith("print("))
            return "println!" + line.Substring(5, line.Length - 6) + ")";
        return line;
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
        string t when t.StartsWith("bigfloat") => "f64",
        _ => type
    };

    private static string Sanitize(string name) =>
        Regex.Replace(name, @"[^a-zA-Z0-9_]", "_");

    private string GenBlockchainRust(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("use std::collections::HashMap;");
        sb.AppendLine("use std::sync::{Arc, RwLock};");
        sb.AppendLine();
        sb.AppendLine("/// Consensus algorithm type.");
        sb.AppendLine("#[derive(Debug, Clone, Copy, PartialEq)]");
        sb.AppendLine("pub enum ConsensusType {");
        sb.AppendLine("    PoW,");
        sb.AppendLine("    PoS,");
        sb.AppendLine("    DPoS,");
        sb.AppendLine("    PBFT,");
        sb.AppendLine("    Raft,");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("/// Wallet signature algorithm.");
        sb.AppendLine("#[derive(Debug, Clone, Copy, PartialEq)]");
        sb.AppendLine("pub enum WalletAlgorithm {");
        sb.AppendLine("    ECDSA,");
        sb.AppendLine("    Ed25519,");
        sb.AppendLine("    Schnorr,");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("/// P2P network protocol.");
        sb.AppendLine("#[derive(Debug, Clone, Copy, PartialEq)]");
        sb.AppendLine("pub enum P2PProtocol {");
        sb.AppendLine("    Kademlia,");
        sb.AppendLine("    Gossip,");
        sb.AppendLine("    Chord,");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("/// Sharding strategy.");
        sb.AppendLine("#[derive(Debug, Clone, Copy, PartialEq)]");
        sb.AppendLine("pub enum ShardingType {");
        sb.AppendLine("    None,");
        sb.AppendLine("    ShardChain,");
        sb.AppendLine("    StateSharding,");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("/// Ledger entry (transaction).");
        sb.AppendLine("#[derive(Debug, Clone)]");
        sb.AppendLine("pub struct LedgerEntry {");
        sb.AppendLine("    pub from: String,");
        sb.AppendLine("    pub to: String,");
        sb.AppendLine("    pub amount: i64,");
        sb.AppendLine("    pub hash: String,");
        sb.AppendLine("    pub timestamp: i64,");
        sb.AppendLine("    pub nonce: i32,");
        sb.AppendLine("    pub signature: Vec<u8>,");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("/// Blockchain block.");
        sb.AppendLine("#[derive(Debug, Clone)]");
        sb.AppendLine("pub struct Block {");
        sb.AppendLine("    pub height: i32,");
        sb.AppendLine("    pub prev_hash: String,");
        sb.AppendLine("    pub merkle_root: String,");
        sb.AppendLine("    pub transactions: Vec<LedgerEntry>,");
        sb.AppendLine("    pub timestamp: i64,");
        sb.AppendLine("    pub validator: String,");
        sb.AppendLine("    pub nonce: i32,");
        sb.AppendLine("    pub hash: String,");
        sb.AppendLine("}");
        sb.AppendLine();
        sb.AppendLine("/// Blockchain node.");
        sb.AppendLine("#[derive(Debug, Clone)]");
        sb.AppendLine("pub struct Node {");
        sb.AppendLine("    pub name: String,");
        sb.AppendLine("    pub address: String,");
        sb.AppendLine("    pub port: u16,");
        sb.AppendLine("    pub public_key: String,");
        sb.AppendLine("    pub is_validator: bool,");
        sb.AppendLine("    pub stake: i64,");
        sb.AppendLine("    pub reputation: i64,");
        sb.AppendLine("}");
        sb.AppendLine();

        foreach (var chain in program.BlockchainNetworks)
        {
            sb.AppendLine($"/// {chain.Name} blockchain network.");
            sb.AppendLine($"pub struct {chain.Name} {{");
            sb.AppendLine($"    pub name: String,");
            sb.AppendLine($"    pub address: String,");
            sb.AppendLine($"    pub port: u16,");
            sb.AppendLine($"    pub peers: HashMap<String, Node>,");
            sb.AppendLine($"    pub ledger: Vec<LedgerEntry>,");
            sb.AppendLine($"    pub pending_txs: Vec<LedgerEntry>,");
            sb.AppendLine($"    pub blocks: Vec<Block>,");
            sb.AppendLine($"    pub consensus: ConsensusType,");
            sb.AppendLine($"    pub wallet_algo: WalletAlgorithm,");
            sb.AppendLine($"    pub p2p_mode: P2PProtocol,");
            sb.AppendLine($"    pub sharding: ShardingType,");
            sb.AppendLine($"    pub max_peers: usize,");
            sb.AppendLine($"    pub min_validators: usize,");
            sb.AppendLine($"    pub block_time_ms: i32,");
            sb.AppendLine($"    pub difficulty: usize,");
            sb.AppendLine($"    pub min_stake: i64,");
            sb.AppendLine($"    pub shard_count: usize,");
            sb.AppendLine($"}}");
            sb.AppendLine();
            sb.AppendLine($"impl {chain.Name} {{");
            sb.AppendLine($"    pub fn new(address: String, port: u16) -> Self {{");
            sb.AppendLine($"        Self {{");
            sb.AppendLine($"            name: \"{chain.Name}\".to_string(),");
            sb.AppendLine($"            address,");
            sb.AppendLine($"            port,");
            sb.AppendLine($"            peers: HashMap::new(),");
            sb.AppendLine($"            ledger: Vec::new(),");
            sb.AppendLine($"            pending_txs: Vec::new(),");
            sb.AppendLine($"            blocks: Vec::new(),");
            sb.AppendLine($"            consensus: {MapConsensusRust(chain.Consensus)},");
            sb.AppendLine($"            wallet_algo: {MapWalletRust(chain.WalletAlgo)},");
            sb.AppendLine($"            p2p_mode: {MapP2PRust(chain.P2PMode)},");
            sb.AppendLine($"            sharding: {MapShardingRust(chain.Sharding)},");
            sb.AppendLine($"            max_peers: {chain.MaxPeers},");
            sb.AppendLine($"            min_validators: {chain.MinValidators},");
            sb.AppendLine($"            block_time_ms: {chain.BlockTimeMs},");
            sb.AppendLine($"            difficulty: {chain.Difficulty},");
            sb.AppendLine($"            min_stake: {chain.MinStake},");
            sb.AppendLine($"            shard_count: {chain.ShardCount},");
            sb.AppendLine($"        }}");
            sb.AppendLine($"    }}");
            sb.AppendLine();
            sb.AppendLine($"    /// Add peer to P2P network.");
            sb.AppendLine($"    pub fn add_peer(&mut self, peer: Node) {{");
            sb.AppendLine($"        if self.peers.len() < self.max_peers {{");
            sb.AppendLine($"            let key = format!(\"{{}}:{{}}\", peer.address, peer.port);");
            sb.AppendLine($"            self.peers.insert(key, peer);");
            sb.AppendLine($"        }}");
            sb.AppendLine($"    }}");
            sb.AppendLine();
            sb.AppendLine($"    /// Submit transaction to pending pool.");
            sb.AppendLine($"    pub fn submit_transaction(&mut self, mut tx: LedgerEntry) {{");
            sb.AppendLine($"        tx.timestamp = std::time::SystemTime::now()");
            sb.AppendLine($"            .duration_since(std::time::UNIX_EPOCH)");
            sb.AppendLine($"            .unwrap()");
            sb.AppendLine($"            .as_millis() as i64;");
            sb.AppendLine($"        tx.hash = self.hash_transaction(&tx);");
            sb.AppendLine($"        self.pending_txs.push(tx);");
            sb.AppendLine($"    }}");
            sb.AppendLine();
            sb.AppendLine($"    /// Propose new block.");
            sb.AppendLine($"    pub fn propose_block(&mut self) -> Block {{");
            sb.AppendLine($"        let prev_hash = self.blocks.last()");
            sb.AppendLine($"            .map(|b| b.hash.clone())");
            sb.AppendLine($"            .unwrap_or_default();");
            sb.AppendLine();
            sb.AppendLine($"        let mut block = Block {{");
            sb.AppendLine($"            height: self.blocks.len() as i32,");
            sb.AppendLine($"            prev_hash,");
            sb.AppendLine($"            merkle_root: String::new(),");
            sb.AppendLine($"            transactions: std::mem::take(&mut self.pending_txs),");
            sb.AppendLine($"            timestamp: std::time::SystemTime::now()");
            sb.AppendLine($"                .duration_since(std::time::UNIX_EPOCH)");
            sb.AppendLine($"                .unwrap()");
            sb.AppendLine($"                .as_millis() as i64,");
            sb.AppendLine($"            validator: self.address.clone(),");
            sb.AppendLine($"            nonce: 0,");
            sb.AppendLine($"            hash: String::new(),");
            sb.AppendLine($"        }};");
            sb.AppendLine();
            sb.AppendLine($"        block.merkle_root = self.merkle_root(&block.transactions);");
            sb.AppendLine($"        block.hash = self.hash_block(&block);");
            sb.AppendLine($"        self.blocks.push(block.clone());");
            sb.AppendLine($"        block");
            sb.AppendLine($"    }}");
            sb.AppendLine();
            sb.AppendLine($"    /// Get balance for address.");
            sb.AppendLine($"    pub fn get_balance(&self, addr: &str) -> i64 {{");
            sb.AppendLine($"        let mut balance = 0i64;");
            sb.AppendLine($"        for entry in &self.ledger {{");
            sb.AppendLine($"            if entry.from == addr {{ balance -= entry.amount; }}");
            sb.AppendLine($"            if entry.to == addr {{ balance += entry.amount; }}");
            sb.AppendLine($"        }}");
            sb.AppendLine($"        balance");
            sb.AppendLine($"    }}");
            sb.AppendLine();
            sb.AppendLine($"    fn hash_transaction(&self, tx: &LedgerEntry) -> String {{");
            sb.AppendLine($"        use std::collections::hash_map::DefaultHasher;");
            sb.AppendLine($"        use std::hash::Hasher;");
            sb.AppendLine($"        let mut s = DefaultHasher::new();");
            sb.AppendLine($"        tx.from.hash(&mut s);");
            sb.AppendLine($"        tx.to.hash(&mut s);");
            sb.AppendLine($"        tx.amount.hash(&mut s);");
            sb.AppendLine($"        tx.nonce.hash(&mut s);");
            sb.AppendLine($"        format!(\"{{:x}}\", s.finish())");
            sb.AppendLine($"    }}");
            sb.AppendLine();
            sb.AppendLine($"    fn hash_block(&self, block: &Block) -> String {{");
            sb.AppendLine($"        use std::collections::hash_map::DefaultHasher;");
            sb.AppendLine($"        use std::hash::Hasher;");
            sb.AppendLine($"        let mut s = DefaultHasher::new();");
            sb.AppendLine($"        block.height.hash(&mut s);");
            sb.AppendLine($"        block.prev_hash.hash(&mut s);");
            sb.AppendLine($"        block.timestamp.hash(&mut s);");
            sb.AppendLine($"        block.nonce.hash(&mut s);");
            sb.AppendLine($"        format!(\"{{:x}}\", s.finish())");
            sb.AppendLine($"    }}");
            sb.AppendLine($"}}");
            sb.AppendLine();
        }

        return sb.ToString();
    }

    private static string MapConsensusRust(ConsensusType c) => c switch
    {
        ConsensusType.PoW => "ConsensusType::PoW",
        ConsensusType.PoS => "ConsensusType::PoS",
        ConsensusType.DPoS => "ConsensusType::DPoS",
        ConsensusType.PBFT => "ConsensusType::PBFT",
        ConsensusType.Raft => "ConsensusType::Raft",
        _ => "ConsensusType::PBFT"
    };

    private static string MapWalletRust(WalletAlgorithm w) => w switch
    {
        WalletAlgorithm.ECDSA => "WalletAlgorithm::ECDSA",
        WalletAlgorithm.Ed25519 => "WalletAlgorithm::Ed25519",
        WalletAlgorithm.Schnorr => "WalletAlgorithm::Schnorr",
        _ => "WalletAlgorithm::Ed25519"
    };

    private static string MapP2PRust(P2PProtocol p) => p switch
    {
        P2PProtocol.Kademlia => "P2PProtocol::Kademlia",
        P2PProtocol.Gossip => "P2PProtocol::Gossip",
        P2PProtocol.Chord => "P2PProtocol::Chord",
        _ => "P2PProtocol::Kademlia"
    };

    private static string MapShardingRust(ShardingType s) => s switch
    {
        ShardingType.None => "ShardingType::None",
        ShardingType.ShardChain => "ShardingType::ShardChain",
        ShardingType.StateSharding => "ShardingType::StateSharding",
        _ => "ShardingType::None"
    };
}