pub struct RooflineAnalyzer;

#[derive(Debug, Clone)]
pub struct RooflineReport {
    pub arithmetic_intensity: f64,  // FLOPs / byte
    pub peak_flops: f64,            // GFLOPs/s
    pub peak_bandwidth: f64,        // GB/s
    pub ridge_point: f64,           // FLOPs/byte
    pub is_compute_bound: bool,
    pub estimated_performance: f64, // GFLOPs/s
    pub warnings: Vec<String>,
}

impl RooflineAnalyzer {
    pub fn analyze(flops: u64, bytes_moved: u64, peak_flops: f64,
                   peak_bw: f64) -> RooflineReport {
        let mut warnings = Vec::new();
        let ai = if bytes_moved == 0 { peak_flops / peak_bw * 2.0 } else {
            flops as f64 / bytes_moved as f64
        };
        let ridge = peak_flops / peak_bw;
        let is_compute_bound = ai > ridge;
        let perf = if is_compute_bound { peak_flops } else { ai * peak_bw };

        if ai < 0.5 {
            warnings.push("Low arithmetic intensity — memory bound, consider tiling".into());
        }
        if ai > ridge * 10.0 {
            warnings.push("Very high AI — compute bound, check vectorization".into());
        }

        RooflineReport {
            arithmetic_intensity: ai,
            peak_flops,
            peak_bandwidth: peak_bw,
            ridge_point: ridge,
            is_compute_bound,
            estimated_performance: perf,
            warnings,
        }
    }

    pub fn auto_tile_size(ai: f64, cache_size: u64) -> u32 {
        if ai < 1.0 {
            (cache_size as f64 / 3.0).sqrt() as u32
        } else {
            (cache_size as f64 / (ai * 2.0)).sqrt() as u32
        }
    }
}
