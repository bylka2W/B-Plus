const std = @import("std");
const frame_graph = @import("frame_graph.zig");
const gpu_execution = @import("gpu_execution.zig");

/// Cost classification of a single GPU pass.
pub const CostClass = enum(u32) {
    lightweight,
    medium,
    heavy,
    critical,
};

/// Cost estimate breakdown for a single GPU pass.
pub const PassCost = struct {
    gpu_us: u32,
    bandwidth_mb: u32,
    wave_occupancy: f32,
    class: CostClass,

    /// Estimate pass cost from dispatch dimensions and intrinsic cost.
    pub fn estimateFromGrid(grid: frame_graph.GPUPassDesc) PassCost {
        const total_groups = @as(u64, grid.grid.x) * grid.grid.y * grid.grid.z;
        const gpu_us: u32 = @intCast(@max(@as(u64, 1), total_groups * 2));
        const class: CostClass = if (total_groups >= 64 * 64)
            .heavy
        else if (total_groups >= 16 * 16)
            .medium
        else
            .lightweight;
        return .{
            .gpu_us = gpu_us,
            .bandwidth_mb = @intCast(total_groups * 4 / 1024),
            .wave_occupancy = 1.0,
            .class = class,
        };
    }
};

/// Whether a pass should execute or be skipped.
pub const SchedulingDecision = enum(u32) {
    execute,
    skip,
};

/// Result of scheduling: an ordered list of pass indices to execute.
pub const ScheduleResult = struct {
    order: []usize,
    total_cost_us: u32,
    total_skipped: u32,
    budget_us: u32,
};

/// Priority helper struct for sorting.
const PassPriority = struct {
    idx: usize,
    priority: u32,
    cost_us: u32,
    critical: bool,
    fsr3_pass: bool,
};

/// Schedule GPU passes by budget + frame mode.
///
/// Real mode:     full set, sorted by criticality, non-critical skipped when over budget.
/// Generated mode: FSR3 passes prioritized, render passes deprioritized.
/// Pass_through:  only critical passes execute.
pub fn scheduleGpuPasses(
    allocator: std.mem.Allocator,
    gpu_passes: []const frame_graph.GPUPassDesc,
    ctx: gpu_execution.ExecutionContext,
) !ScheduleResult {
    const n = gpu_passes.len;
    if (n == 0) {
        return .{
            .order = try allocator.alloc(usize, 0),
            .total_cost_us = 0,
            .total_skipped = 0,
            .budget_us = ctx.budget_us,
        };
    }

    const budget_us = ctx.budget_us;
    const mode = ctx.frame_mode;

    // Phase 1: classify and compute priority
    var priorities = try allocator.alloc(PassPriority, n);
    defer allocator.free(priorities);

    for (gpu_passes, 0..) |gp, i| {
        const cost = PassCost.estimateFromGrid(gp);
        // FSR3 pass IDs: 100-103 (matches FSR3Pass enum in fsr3_runtime)
        const is_fsr3 = gp.pass_id >= 100 and gp.pass_id <= 103;
        const is_critical = switch (mode) {
            .real => cost.class == .critical,
            .generated => is_fsr3,
            .pass_through => false,
        };

        // Compute priority: lower = earlier execution
        const priority: u32 = blk: {
            switch (mode) {
                .real => {
                    // Critical passes always first, then by cost (cheaper first)
                    if (is_critical) break :blk 0;
                    if (cost.class == .heavy) break :blk 40;
                    if (cost.class == .medium) break :blk 30;
                    break :blk 20;
                },
                .generated => {
                    // FSR3 passes first (optical flow → disocclusion → gen → post)
                    if (is_fsr3) {
                        const base: u32 = @intCast(gp.pass_id - 100);
                        break :blk base;
                    }
                    // Non-FSR3 render passes get deprioritized
                    break :blk 60 + cost.gpu_us / 100;
                },
                .pass_through => {
                    // All passes get max priority → skipped
                    break :blk std.math.maxInt(u32);
                },
            }
        };

        priorities[i] = .{
            .idx = i,
            .priority = priority,
            .cost_us = cost.gpu_us,
            .critical = is_critical,
            .fsr3_pass = is_fsr3,
        };
    }

    // Phase 2: sort by priority (stable for equal priorities)
    std.mem.sort(PassPriority, priorities, {}, struct {
        fn less(_: void, a: PassPriority, b: PassPriority) bool {
            if (a.priority != b.priority) return a.priority < b.priority;
            return a.idx < b.idx;
        }
    }.less);

    // Phase 3: single-pass accumulation — build ordered list in one pass
    var order = std.ArrayList(usize).init(allocator);
    var total_used: u32 = 0;
    var skipped: u32 = 0;

    for (priorities) |pp| {
        if (pp.priority == std.math.maxInt(u32)) {
            skipped += 1;
            continue;
        }
        const fits = pp.critical or (total_used + pp.cost_us <= budget_us);
        if (fits) {
            try order.append(pp.idx);
            if (!pp.critical) total_used += pp.cost_us;
        } else {
            skipped += 1;
        }
    }

    return ScheduleResult{
        .order = try order.toOwnedSlice(),
        .total_cost_us = total_used,
        .total_skipped = skipped,
        .budget_us = budget_us,
    };
}
