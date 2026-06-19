const std = @import("std");
const gpu_job = @import("gpu_job.zig");

pub const Pass = struct {
    id: u32,
    name: []const u8,
    deps: []const u32,
    gpu: bool,
    gpu_wait_for: []const u32,
    gpu_signal: []const u32,
    cost_us: u32,
    critical: bool,
};

/// ExecutionPlan — the output of a resolved FrameGraph.
/// `order` is the topological execution order of passes (indices into FrameGraph.passes).
/// Owned by the caller; use FrameGraph.deinitPlan() to free.
pub const ExecutionPlan = struct {
    order: []u32,
    count: usize,
    budget_us: u32,
};

pub const FrameGraph = struct {
    passes: []const Pass,

    pub fn init(passes: []const Pass) FrameGraph {
        return FrameGraph{ .passes = passes };
    }

    /// Topological sort + hard budget enforcement in one pass.
    /// Critical passes always survive; non-critical are greedily dropped from the end.
    pub fn resolve(self: *const FrameGraph, allocator: std.mem.Allocator, budget_us: u32) !ExecutionPlan {
        const n = self.passes.len;

        var in_degree = try allocator.alloc(u32, n);
        defer allocator.free(in_degree);
        @memset(in_degree, 0);

        var rev_adj = try allocator.alloc(std.ArrayList(u32), n);
        defer {
            for (0..n) |i| rev_adj[i].deinit();
            allocator.free(rev_adj);
        }
        for (0..n) |i| rev_adj[i] = std.ArrayList(u32).init(allocator);

        for (self.passes, 0..) |p, i| {
            in_degree[i] = @intCast(p.deps.len);
            for (p.deps) |dep| {
                if (dep < n) try rev_adj[dep].append(@intCast(i));
            }
        }

        var order = try allocator.alloc(u32, n);
        var written: usize = 0;

        var critical = std.ArrayList(u32).init(allocator);
        defer critical.deinit();
        var normal = std.ArrayList(u32).init(allocator);
        defer normal.deinit();

        for (0..n) |i| {
            if (in_degree[i] == 0) {
                if (self.passes[i].critical) try critical.append(@intCast(i)) else try normal.append(@intCast(i));
            }
        }

        while (critical.items.len > 0 or normal.items.len > 0) {
            while (critical.items.len > 0) {
                const idx = critical.pop().?;
                order[written] = idx;
                written += 1;
                for (rev_adj[idx].items) |succ| {
                    in_degree[succ] -= 1;
                    if (in_degree[succ] == 0) {
                        if (self.passes[succ].critical) try critical.append(succ) else try normal.append(succ);
                    }
                }
            }
            while (normal.items.len > 0) {
                const idx = normal.pop().?;
                order[written] = idx;
                written += 1;
                for (rev_adj[idx].items) |succ| {
                    in_degree[succ] -= 1;
                    if (in_degree[succ] == 0) {
                        if (self.passes[succ].critical) try critical.append(succ) else try normal.append(succ);
                    }
                }
            }
        }

        const plan_order = order[0..written];

        // Hard budget enforcement: drop non-critical passes from the end
        var total: u32 = 0;
        for (plan_order) |idx| total += self.passes[idx].cost_us;

        if (total > budget_us) {
            var i: usize = written;
            while (i > 0 and total > budget_us) {
                i -= 1;
                const idx = plan_order[i];
                const p = &self.passes[idx];
                if (!p.critical and p.cost_us <= total - budget_us) {
                    total -= p.cost_us;
                    for (i..written - 1) |j| order[j] = order[j + 1];
                    written -= 1;
                }
            }
        }

        return ExecutionPlan{
            .order = order,
            .count = written,
            .budget_us = budget_us,
        };
    }

    pub fn deinitPlan(allocator: std.mem.Allocator, plan: *const ExecutionPlan) void {
        allocator.free(plan.order);
    }

    /// Build a GPUJob from a pass at plan time for GPU scheduler dispatch.
    pub fn passToGPUJob(pass: *const Pass) gpu_job.GPUJob {
        return gpu_job.GPUJob{
            .id = pass.id,
            .pipeline_id = pass.id,
            .dispatch_x = 64,
            .dispatch_y = 64,
            .dispatch_z = 1,
            .wait_semaphore = if (pass.gpu_wait_for.len > 0) pass.gpu_wait_for[0] else 0,
            .signal_semaphore = if (pass.gpu_signal.len > 0) pass.gpu_signal[0] else 0,
            .deadline_ns = 0,
            .priority = if (pass.critical) 0 else 1,
            .dropable = !pass.critical,
        };
    }
};
