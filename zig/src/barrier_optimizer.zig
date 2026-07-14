const std = @import("std");
const gpu_types = @import("gpu_types.zig");
const frame_graph = @import("frame_graph.zig");
const lifetime_graph = @import("lifetime_graph.zig");

/// A single barrier slot: pass index + barrier descriptor.
pub const BarrierSlot = struct {
    pass_index: u32,
    barrier: gpu_types.BarrierDesc,
};

/// Barrier optimization statistics.
pub const OptimizationStats = struct {
    total_before: u32,
    total_after: u32,
    redundant_skipped: u32,
    noop_skipped: u32,
    coalesced: u32,
};

/// Barrier optimization pass — takes raw barriers and produces minimal set.
pub const BarrierOptimizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BarrierOptimizer {
        return .{ .allocator = allocator };
    }

    /// Infer and optimize barriers for a set of GPU passes.
    /// Deterministic: same gpu_passes + lifetimes → same barriers.
    pub fn optimize(
        self: *BarrierOptimizer,
        gpu_passes: []const frame_graph.GPUPassDesc,
        lifetimes: *const lifetime_graph.LifetimeGraph,
    ) !struct { barriers: []BarrierSlot, stats: OptimizationStats } {
        // Phase 1: collect raw barriers
        const raw = try self.collectRaw(gpu_passes, lifetimes);
        defer self.allocator.free(raw);

        // Phase 2: optimize — merge, dedup, eliminate no-ops
        const opt = try self.optimizeBarriers(raw);
        defer self.allocator.free(opt);

        // Phase 3: sort deterministically
        const sorted = try self.sortBarriers(opt);

        return .{
            .barriers = sorted,
            .stats = .{
                .total_before = @as(u32, @intCast(raw.len)),
                .total_after = @as(u32, @intCast(sorted.len)),
                .redundant_skipped = @as(u32, @intCast(raw.len - opt.len)),
                .noop_skipped = 0,
                .coalesced = @as(u32, @intCast(opt.len - sorted.len)),
            },
        };
    }

    /// Collect raw barriers: one barrier per resource state transition per pass.
    fn collectRaw(
        self: *BarrierOptimizer,
        gpu_passes: []const frame_graph.GPUPassDesc,
        lifetimes: *const lifetime_graph.LifetimeGraph,
    ) ![]BarrierSlot {
        var state_map = std.AutoHashMap(gpu_types.ResourceId, gpu_types.ResourceState).init(self.allocator);
        defer state_map.deinit();

        var list = std.ArrayList(BarrierSlot).init(self.allocator);

        for (gpu_passes, 0..) |gp, pi| {
            const pass_idx: u32 = @intCast(pi);
            const want_read = gpu_types.ResourceState.non_pixel_shader_resource;
            const want_write = gpu_types.ResourceState.unordered_access;

            for (gp.bindings.entries) |entry| {
                const alias_group = lifetimes.aliasGroup(entry.resource_id);
                const current_state = if (alias_group) |_|
                    gpu_types.ResourceState.common
                else
                    state_map.get(entry.resource_id) orelse gpu_types.ResourceState.common;

                const desired_state = switch (entry.key.kind) {
                    .srv => want_read,
                    .uav => want_write,
                    .cbv, .sampler => continue,
                };

                if (current_state != desired_state) {
                    try list.append(.{
                        .pass_index = pass_idx,
                        .barrier = .{
                            .resource_id = entry.resource_id,
                            .state_before = @intFromEnum(current_state),
                            .state_after = @intFromEnum(desired_state),
                        },
                    });
                    try state_map.put(entry.resource_id, desired_state);
                }
            }
        }

        return list.toOwnedSlice();
    }

    /// Optimize barriers: remove redundant consecutive transitions.
    /// E.g. UAV→SRV followed by SRV→UAV for same resource = unnecessary pair.
    fn optimizeBarriers(self: *BarrierOptimizer, barriers: []const BarrierSlot) ![]BarrierSlot {
        if (barriers.len == 0) return self.allocator.alloc(BarrierSlot, 0);

        // Build per-resource barrier sequences
        var res_map = std.AutoHashMap(gpu_types.ResourceId, std.ArrayList(BarrierSlot)).init(self.allocator);
        defer {
            var it = res_map.valueIterator();
            while (it.next()) |list| list.deinit();
            res_map.deinit();
        }

        for (barriers) |b| {
            const gop = try res_map.getOrPut(b.barrier.resource_id);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(BarrierSlot).init(self.allocator);
            try gop.value_ptr.*.append(b);
        }

        var result = std.ArrayList(BarrierSlot).init(self.allocator);

        var it = res_map.iterator();
        while (it.next()) |entry| {
            const seq = entry.value_ptr.*;
            if (seq.items.len == 0) continue;

            // For each resource, collapse: keep barrier only when direction changes
            var i: usize = 0;
            while (i < seq.items.len) {
                const current = seq.items[i];
                _ = current;

                // Look ahead: skip barriers that undo the previous transition
                // e.g., UAV→SRV in pass 2, then SRV→UAV in pass 3 for same resource
                if (i + 1 < seq.items.len) {
                    const a = seq.items[i];
                    const b = seq.items[i + 1];
                    if (a.barrier.state_before == b.barrier.state_after and
                        a.barrier.state_after == b.barrier.state_before and
                        a.pass_index + 1 == b.pass_index)
                    {
                        // The pair cancels out — skip both if resource is transient
                        i += 2;
                        continue;
                    }
                }

                try result.append(seq.items[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice();
    }

    /// Sort barriers deterministically by (pass_index, resource_id).
    fn sortBarriers(self: *BarrierOptimizer, barriers: []const BarrierSlot) ![]BarrierSlot {
        if (barriers.len == 0) return self.allocator.alloc(BarrierSlot, 0);

        const sorted = try self.allocator.dupe(BarrierSlot, barriers);
        std.mem.sort(BarrierSlot, sorted, {}, struct {
            fn less(_: void, a: BarrierSlot, b: BarrierSlot) bool {
                if (a.pass_index != b.pass_index) return a.pass_index < b.pass_index;
                return a.barrier.resource_id < b.barrier.resource_id;
            }
        }.less);
        return sorted;
    }
};
