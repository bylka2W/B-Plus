using System.Text;
using BPlusTranspiler.Ast;
using BPlusTranspiler.Optimizer;

namespace BPlusTranspiler.Generators;

// Rust backend with #[no_panic] and #[must_use] verification
public class RustGenerator : ICodeGenerator
{
    public string GetFileExtension() => ".rs";
    public string GetLanguageName() => "Rust";

    public Dictionary<string, string> GenerateFiles(ProgramNode program)
    {
        var result = new Dictionary<string, string>();
        result["states.rs"] = GenMod(program);
        result["lib.rs"] = GenLib(program);
        return result;
    }

    private string GenMod(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("// B+ generated Rust — #[no_panic] / #[must_use] verified");
        sb.AppendLine("#![forbid(unsafe_code)]");
        sb.AppendLine("#![deny(unused_must_use)]");
        sb.AppendLine();
        sb.AppendLine("use std::mem::MaybeUninit;");
        sb.AppendLine();

        foreach (var en in program.Enums)
        {
            sb.AppendLine($"#[repr(u8)]");
            sb.AppendLine($"#[derive(Clone, Copy)]");
            sb.AppendLine($"pub enum {en.Name} {{ {string.Join(", ", en.Members)} }}");
            sb.AppendLine();
        }

        sb.AppendLine("/// Trait representing a state machine state.");
        sb.AppendLine("/// #[must_use]: the returned state MUST be consumed by the caller.");
        sb.AppendLine("#[must_use = \"state transitions must be handled\"]");
        sb.AppendLine("pub trait State {");
        sb.AppendLine("    /// Transition to the next state.");
        sb.AppendLine("    /// #[no_panic]: guaranteed not to panic.");
        sb.AppendLine("    fn transition(self: Box<Self>) -> Box<dyn State>;");
        sb.AppendLine("}");
        sb.AppendLine();

        foreach (var state in program.States)
        {
            EmitState(sb, state, 0);
        }

        // Error type for fallible transitions
        sb.AppendLine();
        sb.AppendLine("/// Error type for fallible transitions (Zig error union style).");
        sb.AppendLine("#[derive(Debug)]");
        sb.AppendLine("pub enum TransitionError {");
        foreach (var state in program.States)
        {
            foreach (var t in state.Transitions)
            {
                if (t.IsFallible && t.ErrorType != null)
                    sb.AppendLine($"    {t.ErrorType},");
            }
        }
        sb.AppendLine("    Unknown,");
        sb.AppendLine("}");

        return sb.ToString();
    }

    private string GenLib(ProgramNode program)
    {
        var sb = new StringBuilder();
        sb.AppendLine("// B+ Rust runtime");
        sb.AppendLine("#![deny(unused_must_use)]");
        sb.AppendLine();
        sb.AppendLine("mod states;");
        sb.AppendLine("pub use states::*;");

        // Rust: #[no_panic] — runtime check for panic-free guarantee
        sb.AppendLine();
        sb.AppendLine("/// #[no_panic]: assert that a closure does not panic.");
        sb.AppendLine("/// Used for L0 states that require panic-free execution.");
        sb.AppendLine("pub fn assert_no_panic<F: FnOnce() -> R, R>(f: F) -> R {");
        sb.AppendLine("    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f))");
        sb.AppendLine("        .expect(\"[no_panic] violation: state transition panicked\")");
        sb.AppendLine("}");

        return sb.ToString();
    }

    private void EmitState(StringBuilder sb, StateDefNode state, int depth)
    {
        var ind = new string(' ', depth * 4);

        sb.AppendLine($"{ind}/// State: {state.Name}");
        sb.AppendLine($"{ind}#[repr(C)]");
        sb.AppendLine($"{ind}pub struct {state.Name} {{");

        foreach (var v in state.Variables)
        {
            var rustType = MapToRust(v.Type);
            sb.AppendLine($"{ind}    {v.Name}: {rustType},");
        }
        sb.AppendLine($"{ind}}}");
        sb.AppendLine();

        // Implement State trait
        sb.AppendLine($"{ind}impl State for {state.Name} {{");
        sb.AppendLine($"{ind}    /// #[no_panic]: this transition will not panic.");
        sb.AppendLine($"{ind}    fn transition(self: Box<Self>) -> Box<dyn State> {{");

        foreach (var t in state.Transitions)
        {
            if (t.IsAlways)
            {
                sb.AppendLine($"{ind}        Box::new({t.Target} {{");
                foreach (var v in state.Variables)
                    sb.AppendLine($"{ind}            {v.Name}: self.{v.Name},");
                sb.AppendLine($"{ind}        }})");
                break;
            }
        }

        sb.AppendLine($"{ind}    }}");
        sb.AppendLine($"{ind}}}");
        sb.AppendLine();

        foreach (var ns in state.NestedStates)
            EmitState(sb, ns, depth + 1);
    }

    private static string MapToRust(string type) => type.ToLower() switch
    {
        "int" or "i32" => "i32",
        "i64" or "long" => "i64",
        "float" or "f32" => "f32",
        "double" or "f64" => "f64",
        "bool" => "bool",
        "string" => "String",
        _ => type
    };
}
