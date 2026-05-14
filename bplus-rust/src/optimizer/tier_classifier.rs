use crate::ast::nodes::*;

pub struct TierClassifier;

impl TierClassifier {
    /// Classify memory tier: L0 = register, L1 = L1 cache, L2 = L2, L3 = LLC, Ram
    pub fn classify(var: &VariableNode, config: &MetalConfig) -> MemoryTier {
        if config.hot_path || config.register.is_some() {
            return MemoryTier::L0;
        }
        if config.data_tier.is_some() {
            return config.data_tier.clone().unwrap();
        }
        if var.is_fast_path {
            return MemoryTier::L1;
        }
        let size_hint = match var.var_type.as_str() {
            "i8" | "u8" | "bool" => 1,
            "i16" | "u16" | "half" => 2,
            "i32" | "u32" | "f32" => 4,
            "i64" | "u64" | "f64" | "double" => 8,
            "i128" | "u128" => 16,
            s if s.starts_with("vec") || s.starts_with("float") || s.starts_with("int") => 16,
            _ => 8,
        };
        match size_hint {
            1..=4 => MemoryTier::L1,
            5..=16 => MemoryTier::L2,
            17..=64 => MemoryTier::L3,
            _ => MemoryTier::Ram,
        }
    }

    pub fn bit_width(tier: &MemoryTier) -> u32 {
        match tier {
            MemoryTier::L0 => 64,
            MemoryTier::L1 => 512,
            MemoryTier::L2 => 256,
            MemoryTier::L3 => 128,
            MemoryTier::Ram => 64,
        }
    }
}
