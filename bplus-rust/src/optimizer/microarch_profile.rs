// µarch profiles — Agner Fog data ported from C# MicroArchProfile.cs

#[derive(Debug, Clone)]
pub struct MicroArchProfile {
    pub name: &'static str,
    pub lsd_size: u32,        // uop cache / LSD (0 = loop buffer)
    pub lfb_entries: u32,     // Line Fill Buffers
    pub tlb_l1_entries: u32,
    pub tlb_l2_entries: u32,
    pub store_buffer: u32,
    pub load_buffer: u32,
    pub rob_size: u32,
    pub reservation_stations: u32,
    pub simd_registers: u32,
    pub gp_registers: u32,
    pub max_prefetch_distance: u32,
    pub fusion_capable: bool,  // macro-fusion
    pub cache_line: u32,       // bytes
}

pub struct Profiles;

impl Profiles {
    pub fn all() -> Vec<MicroArchProfile> {
        vec![
            Self::intel_adl(),
            Self::intel_skx(),
            Self::intel_icx(),
            Self::intel_gni(),
            Self::amd_zen4(),
            Self::amd_zen3(),
            Self::arm_neoverse(),
            Self::generic(),
        ]
    }

    pub fn get(name: &str) -> MicroArchProfile {
        let name_lower = name.to_lowercase();
        Self::all().into_iter().find(|p| p.name == name_lower)
            .unwrap_or_else(Self::generic)
    }

    pub fn intel_adl() -> MicroArchProfile {
        MicroArchProfile {
            name: "intel_adl", lsd_size: 0, lfb_entries: 14,
            tlb_l1_entries: 64, tlb_l2_entries: 2048,
            store_buffer: 12, load_buffer: 12, rob_size: 512,
            reservation_stations: 280, simd_registers: 32, gp_registers: 16,
            max_prefetch_distance: 256, fusion_capable: true, cache_line: 64,
        }
    }

    pub fn intel_skx() -> MicroArchProfile {
        MicroArchProfile {
            name: "intel_skx", lsd_size: 64, lfb_entries: 12,
            tlb_l1_entries: 64, tlb_l2_entries: 1536,
            store_buffer: 8, load_buffer: 10, rob_size: 224,
            reservation_stations: 180, simd_registers: 32, gp_registers: 16,
            max_prefetch_distance: 192, fusion_capable: true, cache_line: 64,
        }
    }

    pub fn intel_icx() -> MicroArchProfile {
        MicroArchProfile {
            name: "intel_icx", lsd_size: 0, lfb_entries: 14,
            tlb_l1_entries: 64, tlb_l2_entries: 2048,
            store_buffer: 12, load_buffer: 12, rob_size: 512,
            reservation_stations: 280, simd_registers: 32, gp_registers: 16,
            max_prefetch_distance: 256, fusion_capable: true, cache_line: 64,
        }
    }

    pub fn intel_gni() -> MicroArchProfile {
        MicroArchProfile {
            name: "intel_gni", lsd_size: 0, lfb_entries: 16,
            tlb_l1_entries: 96, tlb_l2_entries: 4096,
            store_buffer: 16, load_buffer: 16, rob_size: 576,
            reservation_stations: 320, simd_registers: 32, gp_registers: 16,
            max_prefetch_distance: 320, fusion_capable: true, cache_line: 64,
        }
    }

    pub fn amd_zen4() -> MicroArchProfile {
        MicroArchProfile {
            name: "amd_zen4", lsd_size: 0, lfb_entries: 12,
            tlb_l1_entries: 64, tlb_l2_entries: 2048,
            store_buffer: 10, load_buffer: 10, rob_size: 320,
            reservation_stations: 200, simd_registers: 32, gp_registers: 16,
            max_prefetch_distance: 192, fusion_capable: true, cache_line: 64,
        }
    }

    pub fn amd_zen3() -> MicroArchProfile {
        MicroArchProfile {
            name: "amd_zen3", lsd_size: 0, lfb_entries: 10,
            tlb_l1_entries: 48, tlb_l2_entries: 1536,
            store_buffer: 8, load_buffer: 10, rob_size: 256,
            reservation_stations: 180, simd_registers: 32, gp_registers: 16,
            max_prefetch_distance: 192, fusion_capable: true, cache_line: 64,
        }
    }

    pub fn arm_neoverse() -> MicroArchProfile {
        MicroArchProfile {
            name: "arm_neoverse", lsd_size: 0, lfb_entries: 8,
            tlb_l1_entries: 48, tlb_l2_entries: 1024,
            store_buffer: 8, load_buffer: 8, rob_size: 128,
            reservation_stations: 100, simd_registers: 32, gp_registers: 31,
            max_prefetch_distance: 128, fusion_capable: false, cache_line: 64,
        }
    }

    pub fn generic() -> MicroArchProfile {
        MicroArchProfile {
            name: "generic", lsd_size: 0, lfb_entries: 12,
            tlb_l1_entries: 64, tlb_l2_entries: 2048,
            store_buffer: 10, load_buffer: 10, rob_size: 256,
            reservation_stations: 180, simd_registers: 32, gp_registers: 16,
            max_prefetch_distance: 128, fusion_capable: true, cache_line: 64,
        }
    }
}
