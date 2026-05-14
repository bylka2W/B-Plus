// B+ AST nodes — ported from C# AstNodes.cs + MetalNodes.cs

#[derive(Debug, Clone, PartialEq)]
pub enum MemoryTier { L0, L1, L2, L3, Ram }

#[derive(Debug, Clone)]
pub struct ProgramNode {
    pub states: Vec<StateDefNode>,
    pub kernels: Vec<KernelDecl>,
    pub imports: Vec<ImportNode>,
}

#[derive(Debug, Clone)]
pub struct StateDefNode {
    pub name: String,
    pub variables: Vec<VariableNode>,
    pub transitions: Vec<TransitionNode>,
    pub actions: Vec<ActionNode>,
}

#[derive(Debug, Clone)]
pub struct VariableNode {
    pub name: String,
    pub var_type: String,
    pub is_fast_path: bool,
}

#[derive(Debug, Clone)]
pub struct TransitionNode {
    pub event: String,
    pub target: String,
    pub hot_weight: Option<f64>,
    pub guard: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ActionNode {
    pub body: String,
}

#[derive(Debug, Clone)]
pub struct KernelDecl {
    pub name: String,
    pub params: Vec<KernelParam>,
}

#[derive(Debug, Clone)]
pub struct KernelParam {
    pub name: String,
    pub param_type: String,
}

#[derive(Debug, Clone)]
pub struct ImportNode {
    pub path: String,
}

// ─── Metal Stack ───

#[derive(Debug, Clone)]
pub struct MetalConfig {
    pub enabled: bool,
    pub tier: Option<MemoryTier>,
    pub register: Option<String>,
    pub zmm: Option<u32>,
    pub mask: Option<String>,
    pub fusion_pairs: Vec<String>,
    pub section: Option<String>,
    pub gateway: Option<MemoryTier>,
    pub prefetch_hint: Option<String>,
    pub alignment: Option<u32>,
    pub packed: bool,
    pub data_tier: Option<MemoryTier>,
    pub hot_path: bool,
    pub critical_size: Option<u32>,
    pub numa_node: Option<u32>,
    pub store_forward_safe: bool,
    pub muarch_profile: Option<String>,
    pub ilp_max: Option<u32>,
}

impl MetalConfig {
    pub fn new() -> Self {
        Self {
            enabled: true,
            tier: None,
            register: None,
            zmm: None,
            mask: None,
            fusion_pairs: Vec::new(),
            section: None,
            gateway: None,
            prefetch_hint: None,
            alignment: None,
            packed: false,
            data_tier: None,
            hot_path: false,
            critical_size: None,
            numa_node: None,
            store_forward_safe: false,
            muarch_profile: None,
            ilp_max: None,
        }
    }

    pub fn to_features(&self) -> Vec<f64> {
        vec![
            if self.enabled { 1.0 } else { 0.0 },
            self.tier.as_ref().map(|t| match t {
                MemoryTier::L0 => 0.0, MemoryTier::L1 => 1.0,
                MemoryTier::L2 => 2.0, MemoryTier::L3 => 3.0,
                MemoryTier::Ram => 4.0,
            }).unwrap_or(4.0),
            if self.register.is_some() { 1.0 } else { 0.0 },
            self.zmm.map(|z| z as f64).unwrap_or(-1.0),
            if self.mask.is_some() { 1.0 } else { 0.0 },
            if !self.fusion_pairs.is_empty() { 1.0 } else { 0.0 },
            if self.section.is_some() { 1.0 } else { 0.0 },
            self.gateway.as_ref().map(|t| match t {
                MemoryTier::L0 => 0.0, MemoryTier::L1 => 1.0,
                MemoryTier::L2 => 2.0, MemoryTier::L3 => 3.0,
                MemoryTier::Ram => 4.0,
            }).unwrap_or(4.0),
            if self.prefetch_hint.is_some() { 1.0 } else { 0.0 },
            self.alignment.unwrap_or(0) as f64,
            if self.packed { 1.0 } else { 0.0 },
            self.data_tier.as_ref().map(|t| match t {
                MemoryTier::L0 => 0.0, MemoryTier::L1 => 1.0,
                MemoryTier::L2 => 2.0, MemoryTier::L3 => 3.0,
                MemoryTier::Ram => 4.0,
            }).unwrap_or(4.0),
            if self.hot_path { 1.0 } else { 0.0 },
            self.critical_size.unwrap_or(0) as f64,
            self.numa_node.map(|n| n as f64).unwrap_or(-1.0),
            if self.store_forward_safe { 1.0 } else { 0.0 },
            if self.muarch_profile.is_some() { 1.0 } else { 0.0 },
            self.ilp_max.unwrap_or(0) as f64,
        ]
    }
}

#[derive(Debug, Clone)]
pub struct MetalBlock {
    pub config: MetalConfig,
    pub target_state: Option<String>,
    pub target_kernel: Option<String>,
}

// ─── AI ───

#[derive(Debug, Clone)]
pub struct DataPoint {
    pub input: Vec<f64>,
    pub target_ipc: f64,
    pub is_real: bool,
}
