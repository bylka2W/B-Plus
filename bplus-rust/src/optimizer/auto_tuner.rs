use crate::ast::nodes::MetalConfig;
use crate::ai::neural_predictor::NeuralPredictor;
use crate::ai::data_collector::DataCollector;
use rand::Rng;

pub struct AutoTuner;

impl AutoTuner {
    /// Auto-tune loop: generate candidate configs → measure → retrain → repeat.
    pub fn tune(predictor: &mut NeuralPredictor, collector: &mut DataCollector,
                iterations: u32, candidates: u32) -> Vec<AutoTuneIteration> {
        let mut history = Vec::new();
        let mut rng = rand::thread_rng();

        for iter in 0..iterations {
            let mut best_config = MetalConfig::new();
            let mut best_ipc = 0.0f64;

            // Generate and score candidates
            for _ in 0..candidates {
                let config = Self::random_config(&mut rng);
                let features = config.to_features();
                let ipc = predictor.predict(&features);

                if ipc > best_ipc {
                    best_ipc = ipc;
                    best_config = config;
                }
            }

            // Try to measure with real perf counters (simulate for now)
            let measured_ipc = collector.measure_config(&best_config);

            // Retrain NN with real measurement
            let features = best_config.to_features();
            let _ = predictor.train(&features, measured_ipc);

            history.push(AutoTuneIteration {
                iteration: iter + 1,
                predicted_ipc: best_ipc,
                measured_ipc,
                config_features: features,
            });
        }
        history
    }

    fn random_config(rng: &mut impl Rng) -> MetalConfig {
        let mut cfg = MetalConfig::new();
        cfg.tier = Some(match rng.gen_range(0..5) {
            0 => crate::ast::nodes::MemoryTier::L0,
            1 => crate::ast::nodes::MemoryTier::L1,
            2 => crate::ast::nodes::MemoryTier::L2,
            3 => crate::ast::nodes::MemoryTier::L3,
            _ => crate::ast::nodes::MemoryTier::Ram,
        });
        cfg.alignment = Some(if rng.gen_bool(0.5) { 64 } else { 16 });
        cfg.hot_path = rng.gen_bool(0.3);
        cfg.packed = rng.gen_bool(0.5);
        cfg.prefetch_hint = Some(if rng.gen_bool(0.5) { "t0".into() } else { "nontemporal".into() });
        cfg.store_forward_safe = rng.gen_bool(0.5);
        cfg
    }
}

#[derive(Debug, Clone)]
pub struct AutoTuneIteration {
    pub iteration: u32,
    pub predicted_ipc: f64,
    pub measured_ipc: f64,
    pub config_features: Vec<f64>,
}
