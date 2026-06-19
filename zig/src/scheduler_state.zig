const std = @import("std");
const latency = @import("latency.zig");

pub const DecisionOverride = enum(u8) {
    none = 0,
    force_steal = 1,
    force_migrate = 2,
    prefer_affinity = 3,
    balanced = 4,
};

pub const GlobalSchedulerState = struct {
    last_system_load: latency.SystemLoad = latency.SystemLoad{
        .avg_queue = 0,
        .max_queue = 0,
        .min_queue = 0,
        .imbalance_ratio = 0,
    },
    tick_counter: u64 = 0,

    pub fn computeAndStore(state: *GlobalSchedulerState, cores: []latency.CoreStats) void {
        state.last_system_load = latency.computeSystemLoad(cores);
        state.tick_counter += 1;
    }

    pub fn adjustDecision(
        state: *const GlobalSchedulerState,
        ctx: anytype,
        d: DecisionOverride,
    ) DecisionOverride {
        _ = ctx;
        const load = state.last_system_load;

        if (load.imbalance_ratio > 3.0) {
            return .force_steal;
        }

        if (load.imbalance_ratio > 2.0) {
            if (d == .prefer_affinity) {
                return .balanced;
            }
        }

        return d;
    }
};
