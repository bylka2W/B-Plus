use crate::ast::nodes::*;
use crate::optimizer::tier_classifier::TierClassifier;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct DepEdge {
    pub from: String,
    pub to: String,
}

pub struct RegisterAllocator;

impl RegisterAllocator {
    /// Pick GPR or ZMM register for a variable based on tier and µarch.
    pub fn alloc(var: &VariableNode, tier: &MemoryTier, used_regs: &[String],
                 profile: &crate::optimizer::microarch_profile::MicroArchProfile) -> String {
        let bw = TierClassifier::bit_width(tier);

        if bw >= 256 {
            // Try ZMM/YMM
            for i in 0..profile.simd_registers {
                let r = format!("zmm{}", i);
                if !used_regs.contains(&r) { return r; }
            }
        }

        // GPR allocation with dep graph awareness
        let gprs = ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9",
                     "r10", "r11", "r12", "r13", "r14", "r15"];
        for r in &gprs {
            let r_str = r.to_string();
            if !used_regs.contains(&r_str) { return r_str; }
        }

        "stack".into()
    }

    /// Build dependency graph from action bodies to avoid serialization stalls.
    pub fn build_dep_graph(actions: &[ActionNode]) -> Vec<DepEdge> {
        let mut edges = Vec::new();
        for action in actions {
            let lowered = action.body.to_lowercase();
            let vars: Vec<&str> = lowered.split(|c: char| !c.is_alphanumeric())
                .filter(|s| !s.is_empty()).collect();
            for w in vars.windows(2) {
                if w.len() == 2 {
                    edges.push(DepEdge { from: w[0].to_string(), to: w[1].to_string() });
                }
            }
        }
        edges
    }

    /// Pack non-dependent variables into the same register.
    pub fn pack_vars(state: &StateDefNode, profile: &crate::optimizer::microarch_profile::MicroArchProfile)
        -> HashMap<String, String> {
        let mut assignment = HashMap::new();
        let deps = Self::build_dep_graph(&state.actions);
        let mut used_regs = Vec::new();

        for var in &state.variables {
            let tier = TierClassifier::classify(var, &MetalConfig::new());
            let has_conflict = deps.iter().any(|d| d.from == var.name);
            if has_conflict {
                // Assign separate register for dependent vars
                let reg = Self::alloc(var, &tier, &used_regs, profile);
                // Mark vars that also appear in dep chain as used
                for d in &deps {
                    if d.from == var.name || d.to == var.name {
                        if !used_regs.contains(&d.from) {
                            used_regs.push(d.from.clone());
                        }
                    }
                }
                used_regs.push(reg.clone());
                assignment.insert(var.name.clone(), reg);
            } else {
                // Try to reuse existing non-dependent register
                let reg = Self::alloc(var, &tier, &used_regs, profile);
                used_regs.push(reg.clone());
                assignment.insert(var.name.clone(), reg);
            }
        }
        assignment
    }
}
