use crate::ast::nodes::*;

pub struct DataPacker;

impl DataPacker {
    /// Pack fields that share the same cache line to minimize false sharing.
    pub fn pack_fields(vars: &[VariableNode]) -> Vec<Vec<usize>> {
        let mut groups: Vec<Vec<usize>> = Vec::new();
        let mut used = vec![false; vars.len()];

        for i in 0..vars.len() {
            if used[i] { continue; }
            let mut group = vec![i];
            used[i] = true;
            let total_size = Self::var_size(&vars[i]);
            for j in i + 1..vars.len() {
                if used[j] { continue; }
                let s = Self::var_size(&vars[j]);
                if total_size + s <= 64 { // cache line
                    group.push(j);
                    used[j] = true;
                }
            }
            groups.push(group);
        }
        groups
    }

    fn var_size(var: &VariableNode) -> u32 {
        match var.var_type.as_str() {
            "i8" | "u8" | "bool" => 1,
            "i16" | "u16" | "half" => 2,
            "i32" | "u32" | "f32" => 4,
            "i64" | "u64" | "f64" | "double" => 8,
            "i128" | "u128" => 16,
            "vec4" | "vec8" | "ivec4" => 16,
            "mat4" => 64,
            _ => 8,
        }
    }
}
