const std = @import("std");
const gpu_job = @import("../runtime/gpu_job.zig");
const gpu_types = @import("../compiler/gpu/gpu_types.zig");

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

    /// If non-null, this pass is an FSR 3.1 frame generation pass.
    /// The value identifies which sub-pass: 0=optical_flow, 1=disocclusion, 2=generate, 3=post_process.
    fsr3_pass: ?u32 = null,
    /// Interpolation factor for the frame gen pass.
    interp_t: f32 = 0.5,
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

    /// FSR 3.1 frame generation pass — interpolates between N-1 and N.
    /// Has multi-frame history access (reads N-1, N-2 for optical flow)
    /// and generates an output frame held in the present delay buffer.
    fsr3_generation: struct {
        pass_id: u32,
        job: gpu_job.GPUJob,
        history_reads: HistoryUsage = .{},
        history_writes: HistoryUsage = .{},
        /// Interpolation factor (0.5 for x2, 0.333 for x3, 0.25 for x4).
        interp_t: f32 = 0.5,
        /// Which frame generation pass: optical_flow, disocclusion, generate, post_process.
        fsr3_pass: u32,
        /// FSR 3.1 resource bindings.
        bindings: FSR3Bindings = .{},
    },
};

/// FSR 3.1 resource bindings for a frame generation pass.
pub const FSR3Bindings = struct {
    /// Current frame color (N).
    color_current: u32 = 0,
    /// Previous frame color (N-1).
    color_previous: u32 = 0,
    /// Optical flow field (2-channel half-float).
    optical_flow: u32 = 0,
    /// Confidence buffer (1-channel half-float).
    confidence: u32 = 0,
    /// Disocclusion mask (1-channel byte).
    disocclusion: u32 = 0,
    /// Generated intermediate frame output.
    output: u32 = 0,
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

/// Ordering key for deterministic topological sort.
const SortKey = struct {
    topo_level: u32,
    is_critical: bool,
    pass_id: u32,
};

fn sortKeyLessThan(a: SortKey, b: SortKey) bool {
    if (a.topo_level != b.topo_level) return a.topo_level < b.topo_level;
    if (a.is_critical != b.is_critical) return a.is_critical and !b.is_critical;
    return a.pass_id < b.pass_id;
}

/// Compute topological level (longest path from any root) for each pass index.
fn computeTopoLevels(id_to_idx: *const std.AutoHashMap(u32, usize), passes: []const Pass, allocator: std.mem.Allocator) ![]u32 {
    const n = passes.len;
    const levels = try allocator.alloc(u32, n);
    @memset(levels, 0);

    const memo = try allocator.alloc(bool, n);
    defer allocator.free(memo);
    @memset(memo, false);

    const MemoContext = struct {
        passes: []const Pass,
        id_to_idx: *const std.AutoHashMap(u32, usize),
        levels: []u32,
        memo: []bool,
        allocator: std.mem.Allocator,
    };

    var ctx = MemoContext{
        .passes = passes,
        .id_to_idx = id_to_idx,
        .levels = levels,
        .memo = memo,
        .allocator = allocator,
    };

    for (0..n) |i| {
        _ = try computeLevelRec(&ctx, @intCast(i));
    }

    return levels;
}

fn computeLevelRec(ctx: anytype, idx: usize) !u32 {
    if (ctx.memo[idx]) return ctx.levels[idx];
    ctx.memo[idx] = true;
    var max_level: u32 = 0;
    const p = &ctx.passes[idx];
    for (p.deps) |dep_id| {
        if (ctx.id_to_idx.get(dep_id)) |dep_idx| {
            const dep_level = try computeLevelRec(ctx, dep_idx);
            if (dep_level + 1 > max_level) max_level = dep_level + 1;
        }
    }
    ctx.levels[idx] = max_level;
    return max_level;
}

/// Normalize passes: sort by id, sort deps arrays, deduplicate deps.
pub fn normalizePasses(allocator: std.mem.Allocator, passes: []const Pass) ![]Pass {
    const n = passes.len;
    var sorted = try allocator.alloc(Pass, n);

    // Copy and sort by pass id
    @memcpy(sorted, passes);
    std.mem.sort(Pass, sorted, {}, struct {
        fn less(_: void, a: Pass, b: Pass) bool {
            return a.id < b.id;
        }
    }.less);

    // Sort and deduplicate deps for each pass
    for (0..n) |i| {
        const deps = sorted[i].deps;
        if (deps.len == 0) continue;

        var sorted_deps = try allocator.dupe(u32, deps);
        std.mem.sort(u32, sorted_deps, {}, std.sort.asc(u32));

        // Deduplicate
        var write: usize = 0;
        for (sorted_deps, 0..) |dep, j| {
            if (j == 0 or dep != sorted_deps[j - 1]) {
                sorted_deps[write] = dep;
                write += 1;
            }
        }
        sorted[i].deps = sorted_deps[0..write];
    }

    return sorted;
}

pub const FrameGraph = struct {
    passes: []const Pass,

    pub fn init(passes: []const Pass) FrameGraph {
        return FrameGraph{ .passes = passes };
    }

    /// Compile: normalize → stable topo sort → budget → freeze.
    /// Returns an ExecutionPlan that no longer references self.passes.
    pub fn compile(self: *const FrameGraph, allocator: std.mem.Allocator, budget_us: u32) !ExecutionPlan {
        // --- Phase 0: Normalize ---
        const norm_passes = try normalizePasses(allocator, self.passes);
        defer {
            for (norm_passes) |p| {
                if (p.deps.len > 0) allocator.free(p.deps);
            }
            allocator.free(norm_passes);
        }

        const n = norm_passes.len;

        var id_to_idx = std.AutoHashMap(u32, usize).init(allocator);
        defer id_to_idx.deinit();
        for (norm_passes, 0..) |p, i| try id_to_idx.put(p.id, i);

        // --- Phase 1: Compute topological levels ---
        const topo_levels = try computeTopoLevels(&id_to_idx, norm_passes, allocator);
        defer allocator.free(topo_levels);

        // --- Phase 2: Build adjacency ---
        var in_degree = try allocator.alloc(u32, n);
        defer allocator.free(in_degree);
        @memset(in_degree, 0);

        var rev_adj = try allocator.alloc(std.ArrayList(u32), n);
        defer {
            for (0..n) |i| rev_adj[i].deinit();
            allocator.free(rev_adj);
        }
        for (0..n) |i| rev_adj[i] = std.ArrayList(u32).init(allocator);

        for (norm_passes, 0..) |p, i| {
            in_degree[i] = @intCast(p.deps.len);
            for (p.deps) |dep| {
                if (id_to_idx.get(dep)) |dep_idx| try rev_adj[dep_idx].append(@intCast(i));
            }
        }

        // --- Phase 3: Stable topological sort ---
        // Priority queue key: (topo_level, is_critical, pass.id)
        const HeapEntry = struct { key: SortKey, idx: u32 };
        var order = try allocator.alloc(u32, n);
        var written: usize = 0;

        var heap = std.ArrayList(HeapEntry).init(allocator);
        defer heap.deinit();

        for (0..n) |i| {
            if (in_degree[i] == 0) {
                try heap.append(.{
                    .key = SortKey{
                        .topo_level = topo_levels[i],
                        .is_critical = norm_passes[i].critical,
                        .pass_id = norm_passes[i].id,
                    },
                    .idx = @intCast(i),
                });
            }
        }

        // Build min-heap
        std.mem.sort(HeapEntry, heap.items, {}, struct {
            fn less(_: void, a: HeapEntry, b: HeapEntry) bool {
                return sortKeyLessThan(a.key, b.key);
            }
        }.less);

        while (heap.items.len > 0) {
            // Pop smallest key
            std.mem.sort(HeapEntry, heap.items, {}, struct {
                fn less(_: void, a: HeapEntry, b: HeapEntry) bool {
                    return sortKeyLessThan(a.key, b.key);
                }
            }.less);
            const entry = heap.orderedRemove(0);
            const idx = entry.idx;

            order[written] = idx;
            written += 1;

            for (rev_adj[idx].items) |succ| {
                in_degree[succ] -= 1;
                if (in_degree[succ] == 0) {
                    try heap.append(.{
                        .key = SortKey{
                            .topo_level = topo_levels[succ],
                            .is_critical = norm_passes[succ].critical,
                            .pass_id = norm_passes[succ].id,
                        },
                        .idx = succ,
                    });
                }
            }
        }

        // --- Phase 4: Budget enforcement ---
        var total: u32 = 0;
        for (order[0..written]) |idx| total += norm_passes[idx].cost_us;

        if (total > budget_us) {
            var i: usize = written;
            while (i > 0 and total > budget_us) {
                i -= 1;
                const idx = order[i];
                const p = &norm_passes[idx];
                if (!p.critical and p.cost_us <= total - budget_us) {
                    total -= p.cost_us;
                    for (i..written - 1) |j| order[j] = order[j + 1];
                    written -= 1;
                }
            }
        }

        defer allocator.free(order);

        // --- Phase 5: Build execution nodes ---
        var pass_to_node = try allocator.alloc(?u32, n);
        defer allocator.free(pass_to_node);
        @memset(pass_to_node, null);

        var node_list = std.ArrayList(ExecutionNode).init(allocator);
        defer node_list.deinit();

        for (0..written) |oi| {
            const idx = order[oi];
            const p = &norm_passes[idx];
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

            if (p.fsr3_pass) |fp| {
                try node_list.append(ExecutionNode{
                    .id = p.id,
                    .name = p.name,
                    .kind = NodeKind{ .fsr3_generation = .{
                        .pass_id = p.id,
                        .job = base_job,
                        .history_reads = hr,
                        .history_writes = hw,
                        .interp_t = p.interp_t,
                        .fsr3_pass = fp,
                    } },
                });
            } else if (p.gpu) {
                if (@as(u4, @bitCast(hr)) != 0 or @as(u4, @bitCast(hw)) != 0) {
                    try node_list.append(ExecutionNode{
                        .id = p.id,
                        .name = p.name,
                        .kind = NodeKind{ .render = .{
                            .pass_id = p.id,
                            .job = base_job,
                            .history_reads = hr,
                            .history_writes = hw,
                        } },
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

        // --- Phase 6: Build edges ---
        var edge_list = std.ArrayList(DependencyEdge).init(allocator);
        defer edge_list.deinit();

        for (order[0..written]) |idx| {
            const p = &norm_passes[idx];
            const to_ni = pass_to_node[idx] orelse continue;
            for (p.deps) |dep_pid| {
                if (id_to_idx.get(dep_pid)) |dep_idx| {
                    if (pass_to_node[dep_idx]) |from_ni| {
                        try edge_list.append(DependencyEdge{
                            .from = from_ni,
                            .to = to_ni,
                            .kind = .intra_frame,
                            .temporal_offset = 0,
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

/// GPU pass descriptor — ties a FrameGraph pass to GPU IR data.
pub const GPUPassDesc = struct {
    pass_id: u32,
    queue: gpu_types.QueueType = .compute,
    pipeline: gpu_types.PipelineKey,
    grid: gpu_types.DispatchGrid,
    bindings: gpu_types.BindGroup,
    barriers_before: []const gpu_types.BarrierDesc = &.{},
    barriers_after: []const gpu_types.BarrierDesc = &.{},
};
