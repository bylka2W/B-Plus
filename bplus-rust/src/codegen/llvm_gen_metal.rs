use crate::ast::nodes::*;
use crate::optimizer::tier_classifier::TierClassifier;
use crate::optimizer::microarch_profile::MicroArchProfile;

/// LLVM IR code generator for B+ Metal Stack.
/// Generates LLVM IR directly instead of emitting C++.
pub struct LlvmGenMetal;

impl LlvmGenMetal {
    /// Generate LLVM IR module for a B+ program.
    pub fn generate<'a>(program: &ProgramNode, profile: &MicroArchProfile) -> String {
        let mut ir = String::new();

        // Module header
        ir.push_str("; B+ compiled LLVM IR\n");
        ir.push_str("target triple = \"x86_64-unknown-linux-gnu\"\n");
        ir.push_str("target datalayout = \"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128\"\n\n");

        // External declarations
        ir.push_str("declare void @llvm.prefetch.p0i8(i8*, i32, i32, i32)\n");
        ir.push_str("declare void @llvm.assume(i1)\n");
        ir.push_str(&format!("declare void @llvm.donothing() nounwind readnone\n\n"));

        // Generate each state as an LLVM function
        for state in &program.states {
            Self::generate_state(&mut ir, state, profile);
        }

        // Generate kernels
        for kernel in &program.kernels {
            Self::generate_kernel(&mut ir, kernel, profile);
        }

        ir
    }

    fn generate_state(ir: &mut String, state: &StateDefNode, profile: &MicroArchProfile) {
        ir.push_str(&format!("define dso_local void @state_{}(i64 %context) {{\n", state.name));
        ir.push_str("entry:\n");

        // Allocate registers for variables
        for var in &state.variables {
            let tier = TierClassifier::classify(var, &MetalConfig {
                hot_path: true, ..MetalConfig::new()
            });
            let bw = TierClassifier::bit_width(&tier);
            match bw {
                512 => ir.push_str(&format!("  %{} = alloca i64, align 64\n", var.name)),
                256 => ir.push_str(&format!("  %{} = alloca i64, align 32\n", var.name)),
                128 => ir.push_str(&format!("  %{} = alloca i64, align 16\n", var.name)),
                _ => ir.push_str(&format!("  %{} = alloca i64, align 8\n", var.name)),
            }
        }

        // Generate transitions as switch-like dispatches
        for trans in &state.transitions {
            ir.push_str(&format!(
                "  ; transition {} -> {}\n",
                trans.event, trans.target
            ));
            ir.push_str(&format!(
                "  call void @state_{}(i64 %context)\n",
                trans.target
            ));
        }

        // Insert prefetch hints
        if let Some(pref) = state.variables.first() {
            ir.push_str(&format!(
                "  call void @llvm.prefetch.p0i8(i8* %{}, i32 0, i32 3, i32 1)\n",
                pref.name
            ));
        }

        ir.push_str("  ret void\n}\n\n");
    }

    fn generate_kernel(ir: &mut String, kernel: &KernelDecl, profile: &MicroArchProfile) {
        ir.push_str(&format!(
            "define dso_local void @kernel_{}(i64 %ctx, {} {}",
            kernel.name,
            kernel.params.first().map(|p| format!("i64 %{}", p.name)).unwrap_or_default(),
            if kernel.params.is_empty() { "" } else { "" }
        ));

        // Remaining params
        for p in kernel.params.iter().skip(1) {
            ir.push_str(&format!(", i64 %{}", p.name));
        }
        ir.push_str(") {\n");
        ir.push_str("entry:\n");
        ir.push_str("  ret void\n}\n\n");
    }

    /// Generate a prefetch intrinsic call for a variable.
    pub fn emit_prefetch(var: &str, locality: u32) -> String {
        format!("call void @llvm.prefetch.p0i8(i8* %{}, i32 0, i32 {}, i32 1)",
                var, locality.min(3))
    }

    /// Generate an llvm.assume for alignment.
    pub fn emit_assume(ptr: &str, alignment: u32) -> String {
        format!("call void @llvm.assume(i1 icmp eq (i64 and (i64 ptrtoint (i8* %{} to i64), i64 {}), i64 0))",
                ptr, alignment - 1)
    }

    /// Generate store fence for store-forwarding protection.
    pub fn emit_store_fence() -> &'static str { "fence seq_cst" }
}
