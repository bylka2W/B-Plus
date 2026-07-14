const std = @import("std");
const gpu_types = @import("gpu_types.zig");
const render_graph = @import("render_graph.zig");

pub const ResolvedPass = struct {
    pso: ?*anyopaque,
    root_signature: ?*anyopaque,
    root_table_gpu_handle: u64,
    descriptor_base_index: u32,
    descriptor_count: u32,
    grid: [3]u32,
};

pub const GPUBatch = struct {
    pass_indices: []const u32,
    resolved_passes: []ResolvedPass = &.{},
    queue: gpu_types.QueueType,
    barriers: []const render_graph.BarrierSlot,
};

pub const QueueBatches = struct {
    batches: []GPUBatch,
};

pub const ScheduleStats = struct {
    total_passes: u32,
    compute_passes: u32,
    graphics_passes: u32,
    barriers_in: u32,
    barriers_out: u32,
    compute_batches: u32,
    graphics_batches: u32,
};

pub const ScheduledFrame = struct {
    compute: QueueBatches,
    graphics: QueueBatches,
    stats: ScheduleStats,
};

pub const GPUScheduler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GPUScheduler {
        return .{ .allocator = allocator };
    }

    pub fn build(self: *GPUScheduler, plan: *const render_graph.RenderPlan) !ScheduledFrame {
        // Map pass_id → index into plan.gpu_passes
        var pass_id_to_idx = std.AutoHashMap(u32, u32).init(self.allocator);
        defer pass_id_to_idx.deinit();
        for (plan.gpu_passes, 0..) |gp, pi| {
            try pass_id_to_idx.put(gp.pass_id, @as(u32, @intCast(pi)));
        }

        // Phase 1: walk nodes in topological order, partition into runs
        // of consecutive same-queue passes.
        var compute_runs = std.ArrayList(std.ArrayList(u32)).init(self.allocator);
        var graphics_runs = std.ArrayList(std.ArrayList(u32)).init(self.allocator);

        var cur_passes = std.ArrayList(u32).init(self.allocator);
        var cur_queue: ?gpu_types.QueueType = null;

        for (plan.nodes) |node| {
            const pass_id = switch (node.kind) {
                .gpu => |g| g.pass_id,
                .render => |r| r.pass_id,
                .fsr3_generation => |f| f.pass_id,
                else => continue,
            };
            const pass_idx = pass_id_to_idx.get(pass_id) orelse continue;
            const q = plan.gpu_passes[pass_idx].queue;

            if (cur_queue == null or q != cur_queue.?) {
                if (cur_queue) |cq| {
                    var dst = if (cq == .compute) &compute_runs else &graphics_runs;
                    try dst.append(cur_passes);
                }
                cur_passes = std.ArrayList(u32).init(self.allocator);
                cur_queue = q;
            }
            try cur_passes.append(pass_idx);
        }
        if (cur_queue) |cq| {
            var dst = if (cq == .compute) &compute_runs else &graphics_runs;
            try dst.append(cur_passes);
        }

        // Phase 2: convert each run → GPUBatch with barrier compression.
        var comp_batches = std.ArrayList(GPUBatch).init(self.allocator);
        var gfx_batches = std.ArrayList(GPUBatch).init(self.allocator);
        var comp_passes: u32 = 0;
        var gfx_passes: u32 = 0;
        var barriers_in: u32 = 0;
        var barriers_out: u32 = 0;

        // Helper to compress one run into a batch
        const CompressFn = struct {
            fn compress(
                allocator: std.mem.Allocator,
                rp: *const render_graph.RenderPlan,
                run_passes: *std.ArrayList(u32),
                batch_queue: gpu_types.QueueType,
                out: *std.ArrayList(GPUBatch),
                p_barriers_in: *u32,
                p_barriers_out: *u32,
            ) !void {
                // Barrier compression: walk passes within batch,
                // track resource state, skip UAV→UAV / SRV→SRV.
                var compressed = std.ArrayList(render_graph.BarrierSlot).init(allocator);
                defer compressed.deinit();
                var state_map = std.AutoHashMap(gpu_types.ResourceId, gpu_types.ResourceState).init(allocator);
                defer state_map.deinit();

                for (run_passes.items) |pass_idx| {
                    const gp = &rp.gpu_passes[pass_idx];
                    p_barriers_in.* += @as(u32, @intCast(gp.barriers_before.len + gp.barriers_after.len));

                    for (gp.barriers_before) |b| {
                        const current = state_map.get(b.resource_id) orelse b.state_before;
                        if (current != b.state_after) {
                            try compressed.append(.{ .pass_index = pass_idx, .barrier = b });
                            try state_map.put(b.resource_id, b.state_after);
                            p_barriers_out.* += 1;
                        }
                    }

                    for (rp.auto_barriers) |ab| {
                        if (ab.pass_index != pass_idx) continue;
                        const current = state_map.get(ab.barrier.resource_id) orelse ab.barrier.state_before;
                        if (current != ab.barrier.state_after) {
                            try compressed.append(.{ .pass_index = pass_idx, .barrier = .{
                                .resource_id = ab.barrier.resource_id,
                                .barrier_type = .transition,
                                .state_before = current,
                                .state_after = ab.barrier.state_after,
                            } });
                            try state_map.put(ab.barrier.resource_id, ab.barrier.state_after);
                            p_barriers_out.* += 1;
                        }
                    }

                    for (gp.barriers_after) |b| {
                        const current = state_map.get(b.resource_id) orelse b.state_before;
                        if (current != b.state_after) {
                            try compressed.append(.{ .pass_index = pass_idx, .barrier = b });
                            try state_map.put(b.resource_id, b.state_after);
                            p_barriers_out.* += 1;
                        }
                    }
                }

                try out.append(GPUBatch{
                    .pass_indices = try run_passes.toOwnedSlice(),
                    .queue = batch_queue,
                    .barriers = try compressed.toOwnedSlice(),
                });
            }
        };

        // Process compute runs
        for (compute_runs.items, 0..) |_, ri| {
            const run_passes = &compute_runs.items[ri];
            comp_passes += @as(u32, @intCast(run_passes.items.len));
            try CompressFn.compress(self.allocator, plan, @constCast(run_passes), .compute, &comp_batches, &barriers_in, &barriers_out);
        }

        // Process graphics runs
        for (graphics_runs.items, 0..) |_, ri| {
            const run_passes = &graphics_runs.items[ri];
            gfx_passes += @as(u32, @intCast(run_passes.items.len));
            try CompressFn.compress(self.allocator, plan, @constCast(run_passes), .graphics, &gfx_batches, &barriers_in, &barriers_out);
        }

        // Cleanup run list ArrayLists (their items consumed by toOwnedSlice).
        for (compute_runs.items) |a| a.deinit();
        compute_runs.deinit();
        for (graphics_runs.items) |a| a.deinit();
        graphics_runs.deinit();

        const comp_batch_count = @as(u32, @intCast(comp_batches.items.len));
        const gfx_batch_count = @as(u32, @intCast(gfx_batches.items.len));

        return ScheduledFrame{
            .compute = .{ .batches = try comp_batches.toOwnedSlice() },
            .graphics = .{ .batches = try gfx_batches.toOwnedSlice() },
            .stats = .{
                .total_passes = @as(u32, @intCast(plan.gpu_passes.len)),
                .compute_passes = comp_passes,
                .graphics_passes = gfx_passes,
                .barriers_in = barriers_in,
                .barriers_out = barriers_out,
                .compute_batches = comp_batch_count,
                .graphics_batches = gfx_batch_count,
            },
        };
    }

    pub fn deinitScheduledFrame(allocator: std.mem.Allocator, sf: *const ScheduledFrame) void {
        for (sf.compute.batches) |b| {
            allocator.free(b.pass_indices);
            allocator.free(b.barriers);
            allocator.free(b.resolved_passes);
        }
        allocator.free(sf.compute.batches);
        for (sf.graphics.batches) |b| {
            allocator.free(b.pass_indices);
            allocator.free(b.barriers);
            allocator.free(b.resolved_passes);
        }
        allocator.free(sf.graphics.batches);
    }
};
