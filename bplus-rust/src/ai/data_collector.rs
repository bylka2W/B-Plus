use crate::ast::nodes::{MetalConfig, DataPoint};

pub struct DataCollector {
    pub samples: Vec<DataPoint>,
}

impl DataCollector {
    pub fn new() -> Self {
        Self { samples: Vec::with_capacity(2000) }
    }

    /// Generate training data from synthetic or real perf counter measurements.
    pub fn collect(&mut self, config: &MetalConfig, ipc: f64, is_real: bool) {
        if self.samples.len() >= 2000 { self.samples.remove(0); }
        self.samples.push(DataPoint {
            input: config.to_features(),
            target_ipc: ipc,
            is_real,
        });
    }

    /// Simulate IPC for a given config (fallback when perf counters unavailable).
    pub fn simulate_ipc(config: &MetalConfig) -> f64 {
        let mut base = 2.0;
        if config.hot_path { base += 1.0; }
        if config.packed { base += 0.3; }
        if config.store_forward_safe { base += 0.2; }
        if let Some(align) = config.alignment {
            if align >= 64 { base += 0.2; }
        }
        if let Some(tier) = &config.tier {
            base += match tier {
                crate::ast::nodes::MemoryTier::L0 => 2.0,
                crate::ast::nodes::MemoryTier::L1 => 1.0,
                crate::ast::nodes::MemoryTier::L2 => 0.5,
                crate::ast::nodes::MemoryTier::L3 => 0.2,
                crate::ast::nodes::MemoryTier::Ram => 0.0,
            };
        }
        base.min(6.0)
    }

    /// Measure IPC for a config — tries real counters, falls back to simulation.
    pub fn measure_config(&mut self, config: &MetalConfig) -> f64 {
        // TODO: integrate with perf_event_open via platform-specific code
        // For now: synthetic + noise
        let base = Self::simulate_ipc(config);
        let noise: f64 = (rand::random::<f64>() - 0.5) * 0.2;
        let ipc = (base + noise).max(0.1).min(6.0);
        self.collect(config, ipc, false);
        ipc
    }

    pub fn samples(&self) -> &[DataPoint] { &self.samples }

    pub fn clear(&mut self) { self.samples.clear(); }
}
