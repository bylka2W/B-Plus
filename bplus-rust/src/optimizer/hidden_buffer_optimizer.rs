use crate::optimizer::microarch_profile::MicroArchProfile;

pub struct HiddenBufferAnalysis {
    pub lsd_ok: bool,
    pub lfb_ok: bool,
    pub tlb_l1_ok: bool,
    pub tlb_l2_ok: bool,
    pub store_buffer_ok: bool,
    pub load_buffer_ok: bool,
    pub warnings: Vec<String>,
}

pub struct HiddenBufferOptimizer;

impl HiddenBufferOptimizer {
    /// Analyze hidden buffers against µarch profile and structural code size.
    pub fn analyze(profile: &MicroArchProfile, loop_uops: u32, mem_streams: u32,
                   working_set_pages: u32, stores: u32, loads: u32) -> HiddenBufferAnalysis {
        let mut warnings = Vec::new();

        let lsd_ok = if profile.lsd_size == 0 {
            warnings.push(format!("{}: no LSD/op cache — loop may recode", profile.name));
            false
        } else {
            loop_uops <= profile.lsd_size
        };

        let lfb_ok = if mem_streams > profile.lfb_entries {
            warnings.push(format!(
                "LFB: {} mem streams > {} entries — LFB thrashing",
                mem_streams, profile.lfb_entries
            ));
            false
        } else { true };

        let tlb_l1_ok = if working_set_pages > profile.tlb_l1_entries {
            warnings.push(format!(
                "TLB L1: {} pages > {} entries — TLB miss risk",
                working_set_pages, profile.tlb_l1_entries
            ));
            false
        } else { true };

        let tlb_l2_ok = if working_set_pages > profile.tlb_l2_entries {
            warnings.push(format!(
                "TLB L2: {} pages > {} entries — page walk overhead",
                working_set_pages, profile.tlb_l2_entries
            ));
            false
        } else { true };

        let store_buffer_ok = stores <= profile.store_buffer.saturating_mul(2);
        if !store_buffer_ok {
            warnings.push(format!(
                "Store buffer: {} stores > {} entries × 2 — drain stalls",
                stores, profile.store_buffer
            ));
        }

        let load_buffer_ok = loads <= profile.load_buffer.saturating_mul(2);
        if !load_buffer_ok {
            warnings.push(format!(
                "Load buffer: {} loads > {} entries × 2 — ROB stall risk",
                loads, profile.load_buffer
            ));
        }

        HiddenBufferAnalysis { lsd_ok, lfb_ok, tlb_l1_ok, tlb_l2_ok,
            store_buffer_ok, load_buffer_ok, warnings }
    }
}
