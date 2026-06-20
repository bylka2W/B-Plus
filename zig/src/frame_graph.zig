const std = @import("std");
const gpu_job = @import("gpu_job.zig");

/// Per-resource history validity.
pub const HistoryUsage = packed struct {
    color: bool = false,
    depth: bool = false,
    motion: bool = false,
    exposure: bool = false,
};

/// A single history resource with generation tracking.
pub const HistoryResource = struct {
    id: u32 = 0,
    generation: u64 = 0,
    valid: bool = false,
};

/// Full set of history resources for one frame.
pub const HistorySet = struct {
    color: HistoryResource = .{},
    depth: HistoryResource = .{},
    motion: HistoryResource = .{},
    exposure: HistoryResource = .{},

    pub fn hasHistory(self: *const HistorySet, usage: HistoryUsage) bool {
        if (usage.color and !self.color.valid) return false;
        if (usage.depth and !self.depth.valid) return false;
        if (usage.motion and !self.motion.valid) return false;
        if (usage.exposure and !self.exposure.valid) return false;
        return true;
    }
};

pub const Pass = struct {
    id: u32,
    name: []const u8,
    deps: []const u32,
    gpu: bool,
    gpu_wait_for: []const u32,
    gpu_signal: []const u32,
    cost_us: u32,
    critical: bool,
    history_reads: HistoryUsage = .{},
    history_writes: HistoryUsage = .{},
};

pub const EdgeKind = enum {
    intra_frame,
    inter_frame,
};

pub const NodeKind = union(enum) {
    cpu: struct { pass_id: u32 },
    gpu: struct { pass_id: u32, job: gpu_job.GPUJob },

    /// Temporal render stage — reads/writes specific history resources.
    /// Scheduled only when all required history resources are valid.
    render: struct {
        pass_id: u32,
        job: gpu_job.GPUJob,
        history_reads: HistoryUsage = .{},
        history_writes: HistoryUsage = .{},
    },

    /// Temporal barrier — frame boundary synchronization.
    /// Blocks until ctx.frame_index >= wait_for_frame.
    barrier: struct {
        wait_for_frame: u64,
        buffer_mask: u32,
    },
};

/// A node in the unified temporal compute graph.
pub const ExecutionNode = struct {
    id: u32,
    name: []const u8,
    kind: NodeKind,
};

/// Dependency edge with temporal semantics.
/// `intra_frame`: within same frame (Stage 11–13 semantics).
/// `inter_frame`: crosses frame boundary; `temporal_offset` = frames back.
pub const DependencyEdge = struct {
    from: u32,
    to: u32,
    kind: EdgeKind = .intra_frame,
    temporal_offset: i32 = 0,
};

/// Per-frame context passed through the pipeline.
/// Carries temporal state, current/previous history sets, and metadata.
pub const FrameContext = struct {
    frame_index: u64,
    delta_time_ns: u64,
    current: HistorySet,
    previous: HistorySet,
    temporal_mask: u32,
};

/// ExecutionPlan — partially-ordered unified compute graph with temporal edges.
pub const ExecutionPlan = struct {
    nodes: []ExecutionNode,
    edges: []DependencyEdge,
    budget_us: u32,
};

pub const FrameGraph = struct {
    passes: []const Pass,

    pub fn init(passes: []const Pass) FrameGraph {
        return FrameGraph{ .passes = passes };
    }

    /// Compile: topo sort + budget + temporal node materialization + edge emission.
    pub fn compile(self: *const FrameGraph, allocator: std.mem.Allocator, budget_us: u32) !ExecutionPlan {
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

        var crit_q = std.ArrayList(u32).init(allocator);
        defer crit_q.deinit();
        var norm_q = std.ArrayList(u32).init(allocator);
        defer norm_q.deinit();

        for (0..n) |i| {
            if (in_degree[i] == 0) {
                if (self.passes[i].critical) try crit_q.append(@intCast(i)) else try norm_q.append(@intCast(i));
            }
        }

        while (crit_q.items.len > 0 or norm_q.items.len > 0) {
            while (crit_q.items.len > 0) {
                const idx = crit_q.pop().?;
                order[written] = idx;
                written += 1;
                for (rev_adj[idx].items) |succ| {
                    in_degree[succ] -= 1;
                    if (in_degree[succ] == 0) {
                        if (self.passes[succ].critical) try crit_q.append(succ) else try norm_q.append(succ);
                    }
                }
            }
            while (norm_q.items.len > 0) {
                const idx = norm_q.pop().?;
                order[written] = idx;
                written += 1;
                for (rev_adj[idx].items) |succ| {
                    in_degree[succ] -= 1;
                    if (in_degree[succ] == 0) {
                        if (self.passes[succ].critical) try crit_q.append(succ) else try norm_q.append(succ);
                    }
                }
            }
        }

        // Budget enforcement: drop non-critical from end
        var total: u32 = 0;
        for (order[0..written]) |idx| total += self.passes[idx].cost_us;

        if (total > budget_us) {
            var i: usize = written;
            while (i > 0 and total > budget_us) {
                i -= 1;
                const idx = order[i];
                const p = &self.passes[idx];
                if (!p.critical and p.cost_us <= total - budget_us) {
                    total -= p.cost_us;
                    for (i..written - 1) |j| order[j] = order[j + 1];
                    written -= 1;
                }
            }
        }

        defer allocator.free(order);

        var pass_to_node = try allocator.alloc(?u32, n);
        defer allocator.free(pass_to_node);
        @memset(pass_to_node, null);

        // Build unified nodes: cpu, gpu, or render (temporal GPU)
        var node_list = std.ArrayList(ExecutionNode).init(allocator);
        defer node_list.deinit();

        for (0..written) |oi| {
            const idx = order[oi];
            const p = &self.passes[idx];
            const ni = @as(u32, @intCast(node_list.items.len));
            pass_to_node[idx] = ni;

            const base_job = gpu_job.GPUJob{
                .id = p.id,
                .pipeline_id = p.id,
                .dispatch_x = 64,
                .dispatch_y = 64,
                .dispatch_z = 1,
                .wait_semaphore = if (p.gpu_wait_for.len > 0) p.gpu_wait_for[0] else 0,
                .signal_semaphore = if (p.gpu_signal.len > 0) p.gpu_signal[0] else 0,
                .deadline_ns = 0,
                .priority = if (p.critical) 0 else 1,
                .dropable = !p.critical,
            };

            const hr = p.history_reads;
            const hw = p.history_writes;

            if (p.gpu) {
                if (@as(u4, @bitCast(hr)) != 0 or @as(u4, @bitCast(hw)) != 0) {
                    try node_list.append(ExecutionNode{
                        .id = p.id,
                        .name = p.name,
                        .kind = NodeKind{ .render = .{
                            .pass_id = p.id,
                            .job = base_job,
                            .history_reads = hr,
                            .history_writes = hw,
                        }},
                    });
                } else {
                    try node_list.append(ExecutionNode{
                        .id = p.id,
                        .name = p.name,
                        .kind = NodeKind{ .gpu = .{ .pass_id = p.id, .job = base_job } },
                    });
                }
            } else {
                try node_list.append(ExecutionNode{
                    .id = p.id,
                    .name = p.name,
                    .kind = NodeKind{ .cpu = .{ .pass_id = p.id } },
                });
            }
        }

        // Build edges with temporal kind detection
        var edge_list = std.ArrayList(DependencyEdge).init(allocator);
        defer edge_list.deinit();

        for (order[0..written]) |idx| {
            const p = &self.passes[idx];
            const to_ni = pass_to_node[idx] orelse continue;
            for (p.deps) |dep_pid| {
                if (dep_pid < n) {
                    if (pass_to_node[dep_pid]) |from_ni| {
                        const is_temporal = @as(u4, @bitCast(p.history_reads)) != 0 or @as(u4, @bitCast(p.history_writes)) != 0;
                        const kind: EdgeKind = if (is_temporal) .inter_frame else .intra_frame;
                        try edge_list.append(DependencyEdge{
                            .from = from_ni,
                            .to = to_ni,
                            .kind = kind,
                            .temporal_offset = if (kind == .inter_frame) -1 else 0,
                        });
                    }
                }
            }
        }

        return ExecutionPlan{
            .nodes = try node_list.toOwnedSlice(),
            .edges = try edge_list.toOwnedSlice(),
            .budget_us = budget_us,
        };
    }

    pub fn deinitPlan(allocator: std.mem.Allocator, plan: *const ExecutionPlan) void {
        allocator.free(plan.nodes);
        allocator.free(plan.edges);
    }
};
