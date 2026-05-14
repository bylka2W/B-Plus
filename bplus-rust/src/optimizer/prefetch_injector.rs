use crate::ast::nodes::*;
use crate::optimizer::microarch_profile::MicroArchProfile;

pub struct PrefetchInjector;

impl PrefetchInjector {
    /// Determine optimal prefetch distance based on µarch profile and memory latency.
    pub fn optimal_distance(profile: &MicroArchProfile, latency_ns: u32, cycle_ns: f64) -> u32 {
        let latency_cycles = (latency_ns as f64 / cycle_ns) as u32;
        let distance = latency_cycles.saturating_add(8);
        distance.min(profile.max_prefetch_distance)
    }

    /// Generate prefetch hints for a variable based on its access pattern.
    pub fn generate_hints(var: &str, access_type: &str, distance: u32) -> Vec<String> {
        let mut hints = Vec::new();
        match access_type {
            "sequential" => {
                hints.push(format!("llvm.prefetch({} + {}, 0, 0, 1)", var, distance));
                hints.push(format!("llvm.prefetch({} + {}, 0, 0, 2)", var, distance * 2));
            }
            "strided" => {
                hints.push(format!("llvm.prefetch({} + stride * {}, 0, 0, 1)", var, distance));
            }
            "random" => {
                hints.push(format!("__builtin_prefetch({}, 0, 0)", var));
            }
            _ => {}
        }
        hints
    }
}
