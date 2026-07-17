const std = @import("std");

pub const SchedulerConfig = struct {
    max_sticky_ns: u64 = 50_000_000,
    max_queue_len: u32 = 64,
    imbalance_soft: f32 = 2.0,
    imbalance_hard: f32 = 3.0,

    pub fn default() SchedulerConfig {
        return SchedulerConfig{};
    }
};
