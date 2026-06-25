const std = @import("std");
const sched = @import("scheduler.zig");
const cpu = @import("cpu.zig");
const latency = @import("latency.zig");
const sched_config = @import("scheduler_config.zig");
const sched_state = @import("scheduler_state.zig");
const frame_graph = @import("frame_graph.zig");
const gpu_job = @import("gpu_job.zig");
const gpu_scheduler = @import("gpu_scheduler.zig");
const render_graph = @import("render_graph.zig");
const gpu_ir = @import("gpu_ir.zig");

const NUM_WORKERS: u32 = 4;
const ALLOC_SIZE = 64 * 1024 * 1024;

const TimingCtx = struct {
    submitted_at: u64,
    started_at: u64,
    completed_at: u64,
    work_iters: u32,
    enqueue_depth: u32,
    completed_before_start: u64 = 0,
};

fn timingJobFn(ctx: *anyopaque) void {
    const tc = @as(*TimingCtx, @ptrCast(@alignCast(ctx)));
    tc.started_at = @intCast(std.time.nanoTimestamp());
    var x: u64 = 1;
    for (0..tc.work_iters) |_| x = x *| 7 +| 3;
    std.mem.doNotOptimizeAway(&x);
    tc.completed_at = @intCast(std.time.nanoTimestamp());
}

pub const RunResult = struct {
    label: []const u8,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    p999_ns: u64,
    throughput: f64,
    steals: u64,
    rejected: u64,
    steal_attempts: u64,
    local_pops: u64,
    migrations: u64,
    sticky: u64,
    stall_rate: f64,
    force_escape: u64,
    wave_wait_max_ns: u64,
    wave_wait_avg_ns: u64,
    wave_count: u64,
    queue_wait_max_ns: u64,
    queue_wait_p95_ns: u64,
    queue_wait_p99_ns: u64,
    queue_depth_p99: u32,
    queue_depth_max: u32,
    exec_time_p50_ns: u64,
    exec_time_p95_ns: u64,
    exec_time_p99_ns: u64,
    completed_before_p50: u64,
    completed_before_p95: u64,
    completed_before_p99: u64,
};

fn makeJob(jobs: []sched.Job, idx: usize, ctxs: []TimingCtx, iters: u32, sticky_core: ?u32, stickiness: u8) void {
    ctxs[idx] = TimingCtx{ .submitted_at = 0, .started_at = 0, .completed_at = 0, .work_iters = iters, .enqueue_depth = 0 };
    jobs[idx] = sched.Job{
        .func = timingJobFn,
        .ctx = @as(*anyopaque, @ptrCast(&ctxs[idx])),
        .priority = .Normal,
        .next = null,
        .sticky_core = sticky_core,
        .stickiness = stickiness,
    };
}

fn compute(label: []const u8, ctxs: []TimingCtx, scheduler: *sched.Scheduler, first_submit: u64, last_completion: u64) RunResult {
    const N = ctxs.len;
    var latencies = std.heap.page_allocator.alloc(u64, N) catch unreachable;
    defer std.heap.page_allocator.free(latencies);
    for (ctxs, 0..) |ctx, i| latencies[i] = ctx.completed_at - ctx.submitted_at;
    std.sort.block(u64, latencies, {}, std.sort.asc(u64));

    const wall_ns = last_completion - first_submit;
    const throughput = if (wall_ns > 0)
        @as(f64, @floatFromInt(N)) / (@as(f64, @floatFromInt(wall_ns)) / 1_000_000_000.0)
    else
        0;

    const median = latencies[N * 50 / 100];
    var stalls: u64 = 0;
    for (latencies) |l| {
        if (l > median * 2) stalls += 1;
    }

    const ww_max = if (scheduler.pool) |*p| p.metrics.wave_wait_max_ns.load(.acquire) else 0;
    const ww_sum = if (scheduler.pool) |*p| p.metrics.wave_wait_sum_ns.load(.acquire) else 0;
    const ww_cnt = if (scheduler.pool) |*p| p.metrics.wave_count.load(.acquire) else 0;
    const qw_max = if (scheduler.pool) |*p| p.metrics.queue_wait_max_ns.load(.acquire) else 0;

    var queue_waits = std.heap.page_allocator.alloc(u64, N) catch unreachable;
    defer std.heap.page_allocator.free(queue_waits);
    for (ctxs, 0..) |ctx, i| queue_waits[i] = if (ctx.started_at > 0) ctx.started_at -| ctx.submitted_at else 0;
    std.sort.block(u64, queue_waits, {}, std.sort.asc(u64));

    var depths = std.heap.page_allocator.alloc(u32, N) catch unreachable;
    defer std.heap.page_allocator.free(depths);
    for (ctxs, 0..) |ctx, i| depths[i] = ctx.enqueue_depth;
    std.sort.block(u32, depths, {}, std.sort.asc(u32));

    var exec_times = std.heap.page_allocator.alloc(u64, N) catch unreachable;
    defer std.heap.page_allocator.free(exec_times);
    for (ctxs, 0..) |ctx, i| exec_times[i] = if (ctx.started_at > 0) ctx.completed_at -| ctx.started_at else 0;
    std.sort.block(u64, exec_times, {}, std.sort.asc(u64));

    var completed_before = std.heap.page_allocator.alloc(u64, N) catch unreachable;
    defer std.heap.page_allocator.free(completed_before);
    for (ctxs, 0..) |ctx, i| completed_before[i] = ctx.completed_before_start;
    std.sort.block(u64, completed_before, {}, std.sort.asc(u64));

    return RunResult{
        .label = label,
        .p50_ns = latencies[N * 50 / 100],
        .p95_ns = latencies[N * 95 / 100],
        .p99_ns = latencies[N * 99 / 100],
        .p999_ns = latencies[N * 999 / 1000],
        .throughput = throughput,
        .steals = if (scheduler.pool) |*p| p.metrics.steals.load(.acquire) else 0,
        .rejected = if (scheduler.pool) |*p| p.metrics.rejected_steals.load(.acquire) else 0,
        .steal_attempts = if (scheduler.pool) |*p| p.metrics.steal_attempts.load(.acquire) else 0,
        .local_pops = if (scheduler.pool) |*p| p.metrics.local_pops.load(.acquire) else 0,
        .migrations = if (scheduler.pool) |*p| p.metrics.migrations.load(.acquire) else 0,
        .sticky = if (scheduler.pool) |*p| p.metrics.sticky_honored.load(.acquire) else 0,
        .stall_rate = @as(f64, @floatFromInt(stalls)) / @as(f64, @floatFromInt(N)),
        .force_escape = if (scheduler.pool) |*p| p.metrics.force_migrate_escape.load(.acquire) else 0,
        .wave_wait_max_ns = ww_max,
        .wave_wait_avg_ns = if (ww_cnt > 0) @divFloor(ww_sum, ww_cnt) else 0,
        .wave_count = ww_cnt,
        .queue_wait_max_ns = qw_max,
        .queue_wait_p95_ns = queue_waits[N * 95 / 100],
        .queue_wait_p99_ns = queue_waits[N * 99 / 100],
        .queue_depth_p99 = depths[N * 99 / 100],
        .queue_depth_max = depths[N - 1],
        .exec_time_p50_ns = exec_times[N * 50 / 100],
        .exec_time_p95_ns = exec_times[N * 95 / 100],
        .exec_time_p99_ns = exec_times[N * 99 / 100],
        .completed_before_p50 = completed_before[N * 50 / 100],
        .completed_before_p95 = completed_before[N * 95 / 100],
        .completed_before_p99 = completed_before[N * 99 / 100],
    };
}

// ── Pattern A: Hot core skew (70% to core 0) ──
fn runHotCoreSkew(allocator: std.mem.Allocator, smart: bool) !RunResult {
    const N = 2000;
    const mem = try allocator.alloc(u8, ALLOC_SIZE);
    defer allocator.free(mem);

    var topo: cpu.CpuTopology = undefined;
    var lp: latency.LatencyProfile = undefined;
    var scheduler: sched.Scheduler = undefined;

    if (smart) {
        topo = try cpu.CpuTopology.detect(allocator);
        lp = try latency.LatencyProfile.init(allocator, &topo);
        try sched.Scheduler.initThreadedWithTopo(&scheduler, allocator, NUM_WORKERS, 0, 0, &lp);
    } else {
        try sched.Scheduler.initThreaded(&scheduler, allocator, NUM_WORKERS, 0, 0);
    }
    try scheduler.start();

    var jobs = try allocator.alloc(sched.Job, N);
    defer allocator.free(jobs);
    var ctxs = try allocator.alloc(TimingCtx, N);
    defer allocator.free(ctxs);

    const first_submit = @as(u64, @intCast(std.time.nanoTimestamp()));
    for (0..N) |i| {
        const is_hot = smart and i < N * 70 / 100;
        makeJob(jobs, i, ctxs, 50, if (is_hot) @as(?u32, @intCast(0)) else null, if (is_hot) 1 else 0);
        ctxs[i].submitted_at = @as(u64, @intCast(std.time.nanoTimestamp()));
        if (is_hot)
            scheduler.submitAffine(&jobs[i], 0)
        else
            scheduler.submit(&jobs[i]);
        ctxs[i].enqueue_depth = jobs[i].enqueue_depth;
    }
    scheduler.waitAll();
    for (0..N) |i| ctxs[i].completed_before_start = jobs[i].completed_before_start;
    const end = @as(u64, @intCast(std.time.nanoTimestamp()));
    const result = compute("hot-core-skew", ctxs, &scheduler, first_submit, end);

    scheduler.deinit();
    if (smart) lp.deinit();
    if (smart) topo.deinit();
    return result;
}

// ── Pattern B: Burst load ──
fn runBurstLoad(allocator: std.mem.Allocator, smart: bool) !RunResult {
    const N = 10000;
    const mem = try allocator.alloc(u8, ALLOC_SIZE);
    defer allocator.free(mem);

    var topo: cpu.CpuTopology = undefined;
    var lp: latency.LatencyProfile = undefined;
    var scheduler: sched.Scheduler = undefined;

    if (smart) {
        topo = try cpu.CpuTopology.detect(allocator);
        lp = try latency.LatencyProfile.init(allocator, &topo);
        try sched.Scheduler.initThreadedWithTopo(&scheduler, allocator, NUM_WORKERS, 0, 0, &lp);
    } else {
        try sched.Scheduler.initThreaded(&scheduler, allocator, NUM_WORKERS, 0, 0);
    }
    try scheduler.start();

    var jobs = try allocator.alloc(sched.Job, N);
    defer allocator.free(jobs);
    var ctxs = try allocator.alloc(TimingCtx, N);
    defer allocator.free(ctxs);

    const first_submit = @as(u64, @intCast(std.time.nanoTimestamp()));
    for (0..N) |i| {
        const st = if (smart) @as(?u32, @intCast(@as(u32, @truncate(i % 4)))) else null;
        makeJob(jobs, i, ctxs, 10, st, if (st != null) 1 else 0);
        ctxs[i].submitted_at = @as(u64, @intCast(std.time.nanoTimestamp()));
        scheduler.submit(&jobs[i]);
        ctxs[i].enqueue_depth = jobs[i].enqueue_depth;
    }
    scheduler.waitAll();
    for (0..N) |i| ctxs[i].completed_before_start = jobs[i].completed_before_start;
    const end = @as(u64, @intCast(std.time.nanoTimestamp()));
    const result = compute("burst-load", ctxs, &scheduler, first_submit, end);

    scheduler.deinit();
    if (smart) lp.deinit();
    if (smart) topo.deinit();
    return result;
}

// ── Pattern C: Mixed size jobs ──
fn runMixedSize(allocator: std.mem.Allocator, smart: bool) !RunResult {
    const N = 2000;
    const mem = try allocator.alloc(u8, ALLOC_SIZE);
    defer allocator.free(mem);

    var topo: cpu.CpuTopology = undefined;
    var lp: latency.LatencyProfile = undefined;
    var scheduler: sched.Scheduler = undefined;

    if (smart) {
        topo = try cpu.CpuTopology.detect(allocator);
        lp = try latency.LatencyProfile.init(allocator, &topo);
        try sched.Scheduler.initThreadedWithTopo(&scheduler, allocator, NUM_WORKERS, 0, 0, &lp);
    } else {
        try sched.Scheduler.initThreaded(&scheduler, allocator, NUM_WORKERS, 0, 0);
    }
    try scheduler.start();

    var jobs = try allocator.alloc(sched.Job, N);
    defer allocator.free(jobs);
    var ctxs = try allocator.alloc(TimingCtx, N);
    defer allocator.free(ctxs);

    var seed: u64 = 42;
    const first_submit = @as(u64, @intCast(std.time.nanoTimestamp()));
    for (0..N) |i| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const rnd = @as(u32, @truncate(seed >> 32));
        const iters: u32 = if (rnd % 2 == 0) 10 else 500;
        const st = if (smart) @as(?u32, @intCast(rnd % NUM_WORKERS)) else null;
        makeJob(jobs, i, ctxs, iters, st, if (st != null) 1 else 0);
        ctxs[i].submitted_at = @as(u64, @intCast(std.time.nanoTimestamp()));
        scheduler.submit(&jobs[i]);
        ctxs[i].enqueue_depth = jobs[i].enqueue_depth;
    }
    scheduler.waitAll();
    for (0..N) |i| ctxs[i].completed_before_start = jobs[i].completed_before_start;
    const end = @as(u64, @intCast(std.time.nanoTimestamp()));
    const result = compute("mixed-size", ctxs, &scheduler, first_submit, end);

    scheduler.deinit();
    if (smart) lp.deinit();
    if (smart) topo.deinit();
    return result;
}

// ── Pattern D: Affinity conflicts ──
pub fn runAffinityConflict(allocator: std.mem.Allocator, smart: bool) !RunResult {
    const N = 2000;
    const mem = try allocator.alloc(u8, ALLOC_SIZE);
    defer allocator.free(mem);

    var topo: cpu.CpuTopology = undefined;
    var lp: latency.LatencyProfile = undefined;
    var scheduler: sched.Scheduler = undefined;

    if (smart) {
        topo = try cpu.CpuTopology.detect(allocator);
        lp = try latency.LatencyProfile.init(allocator, &topo);
        try sched.Scheduler.initThreadedWithTopo(&scheduler, allocator, NUM_WORKERS, 0, 0, &lp);
    } else {
        try sched.Scheduler.initThreaded(&scheduler, allocator, NUM_WORKERS, 0, 0);
    }
    try scheduler.start();

    var jobs = try allocator.alloc(sched.Job, N);
    defer allocator.free(jobs);
    var ctxs = try allocator.alloc(TimingCtx, N);
    defer allocator.free(ctxs);

    var seed: u64 = 7;
    const first_submit = @as(u64, @intCast(std.time.nanoTimestamp()));
    const heavy = N * 70 / 100;
    var idx: usize = 0;
    while (idx < heavy) : (idx += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const core = @as(u32, @truncate(seed >> 32)) % NUM_WORKERS;
        makeJob(jobs, idx, ctxs, 500, null, 0);
        ctxs[idx].submitted_at = @as(u64, @intCast(std.time.nanoTimestamp()));
        if (smart)
            scheduler.submitAffine(&jobs[idx], core)
        else
            scheduler.submit(&jobs[idx]);
        ctxs[idx].enqueue_depth = jobs[idx].enqueue_depth;
    }
    while (idx < N) : (idx += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const sc = if (smart) @as(u32, @truncate(seed >> 32)) % 2 else 0;
        makeJob(jobs, idx, ctxs, 10, @as(?u32, @intCast(sc)), if (smart) 1 else 0);
        ctxs[idx].submitted_at = @as(u64, @intCast(std.time.nanoTimestamp()));
        scheduler.submit(&jobs[idx]);
        ctxs[idx].enqueue_depth = jobs[idx].enqueue_depth;
    }
    scheduler.waitAll();
    for (0..N) |i| ctxs[i].completed_before_start = jobs[i].completed_before_start;
    const end = @as(u64, @intCast(std.time.nanoTimestamp()));
    const result = compute("affinity-conflict", ctxs, &scheduler, first_submit, end);

    scheduler.deinit();
    if (smart) lp.deinit();
    if (smart) topo.deinit();
    return result;
}

// ── Pattern E: Sticky starvation (90% pinned to core 0, 10% random) ──
fn runStickyStarvation(allocator: std.mem.Allocator, smart: bool) !RunResult {
    const N = 2000;
    const mem = try allocator.alloc(u8, ALLOC_SIZE);
    defer allocator.free(mem);

    var topo: cpu.CpuTopology = undefined;
    var lp: latency.LatencyProfile = undefined;
    var scheduler: sched.Scheduler = undefined;

    if (smart) {
        topo = try cpu.CpuTopology.detect(allocator);
        lp = try latency.LatencyProfile.init(allocator, &topo);
        try sched.Scheduler.initThreadedWithTopo(&scheduler, allocator, NUM_WORKERS, 0, 0, &lp);
        var cfg = sched_config.SchedulerConfig.default();
        cfg.max_sticky_ns = 5_000_000;
        scheduler.setPoolConfig(cfg);
    } else {
        try sched.Scheduler.initThreaded(&scheduler, allocator, NUM_WORKERS, 0, 0);
    }
    try scheduler.start();

    var jobs = try allocator.alloc(sched.Job, N);
    defer allocator.free(jobs);
    var ctxs = try allocator.alloc(TimingCtx, N);
    defer allocator.free(ctxs);

    var seed: u64 = 42;
    const first_submit = @as(u64, @intCast(std.time.nanoTimestamp()));
    const pinned = N * 90 / 100;
    var idx: usize = 0;
    while (idx < pinned) : (idx += 1) {
        makeJob(jobs, idx, ctxs, 100, @as(?u32, @intCast(0)), if (smart) 1 else 0);
        ctxs[idx].submitted_at = @as(u64, @intCast(std.time.nanoTimestamp()));
        scheduler.submit(&jobs[idx]);
        ctxs[idx].enqueue_depth = jobs[idx].enqueue_depth;
    }
    while (idx < N) : (idx += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const core = @as(u32, @truncate(seed >> 32)) % NUM_WORKERS;
        makeJob(jobs, idx, ctxs, 50, @as(?u32, @intCast(core)), if (smart) 1 else 0);
        ctxs[idx].submitted_at = @as(u64, @intCast(std.time.nanoTimestamp()));
        scheduler.submit(&jobs[idx]);
        ctxs[idx].enqueue_depth = jobs[idx].enqueue_depth;
    }
    scheduler.waitAll();
    for (0..N) |i| ctxs[i].completed_before_start = jobs[i].completed_before_start;
    const end = @as(u64, @intCast(std.time.nanoTimestamp()));
    const result = compute("sticky-starvation", ctxs, &scheduler, first_submit, end);

    scheduler.deinit();
    if (smart) lp.deinit();
    if (smart) topo.deinit();
    return result;
}

fn runFrameGraph(allocator: std.mem.Allocator) !u64 {
    const passes = [_]frame_graph.Pass{
        .{ .id = 0, .name = "depth", .deps = &.{}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 200, .critical = true },
        .{ .id = 1, .name = "motion_vectors", .deps = &.{}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 300, .critical = true },
        .{ .id = 2, .name = "reproject", .deps = &.{ 0, 1 }, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 500, .critical = true },
        .{ .id = 3, .name = "upscale", .deps = &.{2}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 800, .critical = false },
        .{ .id = 4, .name = "sharpen", .deps = &.{3}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 400, .critical = false },
        .{ .id = 5, .name = "present", .deps = &.{4}, .gpu = false, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 100, .critical = true },
    };
    var fg = frame_graph.FrameGraph.init(&passes);

    const budget_us = 1400;
    const plan = try fg.compile(allocator, budget_us);
    defer frame_graph.FrameGraph.deinitPlan(allocator, &plan);

    // Validate: present (5) is CPU node; reproject (2) is GPU node
    var has_present: bool = false;
    var has_reproject: bool = false;
    for (plan.nodes) |*node| {
        switch (node.kind) {
            .cpu => |c| { if (c.pass_id == 5) has_present = true; },
            .gpu => |g| { if (g.pass_id == 2) has_reproject = true; },
            .render => |r| { if (r.pass_id == 2) has_reproject = true; },
            .barrier => {},
        }
    }
    if (!has_present) return error.PresentDropped;
    if (!has_reproject) return error.ReprojectDropped;

    // Validate edges: reproject ← depth, motion_vectors; upscale ← reproject
    if (plan.nodes.len >= 3) {
        var edge_depth: bool = false;
        var edge_mv: bool = false;
        var edge_upscale: bool = false;
        for (plan.edges) |e| {
            if (e.from == 0 and e.to == 2) edge_depth = true;
            if (e.from == 1 and e.to == 2) edge_mv = true;
            if (e.from == 2 and e.to == 3) edge_upscale = true;
        }
        if (!edge_depth) return error.MissingEdgeDepth;
        if (!edge_mv) return error.MissingEdgeMV;
        if (plan.nodes.len > 3 and !edge_upscale) return error.MissingEdgeUpscale;
    }
    return @as(u64, @intCast(plan.nodes.len));
}

fn runGPUScheduler(allocator: std.mem.Allocator, smart: bool) !RunResult {
    _ = smart;
    var gs = gpu_scheduler.GPUScheduler.init(allocator);

    const passes = [_]frame_graph.Pass{
        .{ .id = 0, .name = "depth", .deps = &.{}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 200, .critical = true },
        .{ .id = 1, .name = "upscale", .deps = &.{0}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 300, .critical = false },
    };
    var fg = frame_graph.FrameGraph.init(&passes);
    const plan = try fg.compile(allocator, 16_600);
    defer frame_graph.FrameGraph.deinitPlan(allocator, &plan);

    // Build RenderPlan from execution plan nodes
    var gpu_passes_list = std.ArrayList(frame_graph.GPUPassDesc).init(allocator);
    defer {
        for (gpu_passes_list.items) |*gp| allocator.free(gp.bindings.entries);
        gpu_passes_list.deinit();
    }
    for (plan.nodes) |*node| {
        switch (node.kind) {
            .gpu => |g| {
                const entries = try allocator.alloc(gpu_ir.BindEntry, 0);
                try gpu_passes_list.append(.{
                    .pass_id = g.pass_id,
                    .pipeline = .{ .shader = .{ .source = "dummy" }, .layout = .{ .slots = &.{} } },
                    .grid = .{ .x = g.job.dispatch_x, .y = g.job.dispatch_y, .z = g.job.dispatch_z },
                    .bindings = .{ .entries = entries },
                });
            },
            .render => |r| {
                const entries = try allocator.alloc(gpu_ir.BindEntry, 0);
                try gpu_passes_list.append(.{
                    .pass_id = r.pass_id,
                    .pipeline = .{ .shader = .{ .source = "dummy" }, .layout = .{ .slots = &.{} } },
                    .grid = .{ .x = r.job.dispatch_x, .y = r.job.dispatch_y, .z = r.job.dispatch_z },
                    .bindings = .{ .entries = entries },
                });
            },
            else => {},
        }
    }

    const render_plan = render_graph.RenderPlan{
        .nodes = plan.nodes,
        .edges = plan.edges,
        .budget_us = plan.budget_us,
        .gpu_passes = gpu_passes_list.items,
        .transients = &.{},
        .auto_barriers = &.{},
    };
    const sf = try gs.build(&render_plan);
    defer gpu_scheduler.GPUScheduler.deinitScheduledFrame(allocator, &sf);

    const total = sf.stats.total_passes;
    return RunResult{
        .label = "gpu-scheduler",
        .p50_ns = 0,
        .p95_ns = 0,
        .p99_ns = 0,
        .p999_ns = 0,
        .throughput = @as(f64, @floatFromInt(total)),
        .steals = 0,
        .rejected = 0,
        .steal_attempts = 0,
        .local_pops = 0,
        .migrations = 0,
        .sticky = 0,
        .stall_rate = 0,
        .force_escape = 0,
        .wave_wait_max_ns = 0,
        .wave_wait_avg_ns = 0,
        .wave_count = 0,
        .queue_wait_max_ns = 0,
        .queue_wait_p95_ns = 0,
        .queue_wait_p99_ns = 0,
        .queue_depth_p99 = 0,
        .queue_depth_max = 0,
        .exec_time_p50_ns = 0,
        .exec_time_p95_ns = 0,
        .exec_time_p99_ns = 0,
        .completed_before_p50 = 0,
        .completed_before_p95 = 0,
        .completed_before_p99 = 0,
    };
}

fn runTemporalFrameGraph(allocator: std.mem.Allocator) !u64 {
    const passes = [_]frame_graph.Pass{
        .{ .id = 0, .name = "depth", .deps = &.{}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 200, .critical = true },
        .{ .id = 1, .name = "motion", .deps = &.{}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 300, .critical = true },
        .{ .id = 2, .name = "reproject", .deps = &.{0}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 500, .critical = true, .history_reads = .{ .color = true, .motion = true } },
        .{ .id = 3, .name = "temporal_accum", .deps = &.{ 1, 2 }, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 600, .critical = false, .history_reads = .{ .color = true, .motion = true }, .history_writes = .{ .color = true } },
        .{ .id = 4, .name = "sharpen", .deps = &.{3}, .gpu = true, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 400, .critical = false },
        .{ .id = 5, .name = "present", .deps = &.{4}, .gpu = false, .gpu_wait_for = &.{}, .gpu_signal = &.{}, .cost_us = 100, .critical = true },
    };
    var fg = frame_graph.FrameGraph.init(&passes);
    const plan = try fg.compile(allocator, 3000);
    defer frame_graph.FrameGraph.deinitPlan(allocator, &plan);

    // Validate reproject and temporal_accum are .render nodes
    var has_reproject_render: bool = false;
    var has_accum_render: bool = false;
    var has_present_cpu: bool = false;
    for (plan.nodes) |*node| {
        switch (node.kind) {
            .render => |r| {
                if (r.pass_id == 2) has_reproject_render = true;
                if (r.pass_id == 3) has_accum_render = true;
            },
            .cpu => |c| { if (c.pass_id == 5) has_present_cpu = true; },
            else => {},
        }
    }
    if (!has_reproject_render) return error.MissingReprojectRender;
    if (!has_accum_render) return error.MissingAccumRender;
    if (!has_present_cpu) return error.MissingPresent;

    // Validate edges: all deps emit intra_frame edges (same-frame data flow).
    // Inter-frame edges are explicit (not auto-detected from history_reads).
    for (plan.edges) |e| {
        if (e.kind != .intra_frame) return error.UnexpectedInterFrame;
        // temporal_offset is 0 for same-frame deps
        if (e.temporal_offset != 0) return error.NonZeroTemporalOffset;
    }

    // Build FrameContext with per-resource history for temporal gating
    const hist = frame_graph.HistorySet{
        .color = .{ .id = 1, .generation = 0, .valid = true },
        .depth = .{ .id = 2, .generation = 0, .valid = true },
        .motion = .{ .id = 3, .generation = 0, .valid = true },
        .exposure = .{ .id = 4, .generation = 0, .valid = false },
    };
    const ctx = frame_graph.FrameContext{
        .frame_index = 1,
        .delta_time_ns = 16_666_666,
        .current = hist,
        .previous = hist,
        .temporal_mask = 0,
    };

    // Validate per-resource temporal gating:
    // Frame 1: reproject needs color + motion → both valid in previous → dispatchable
    // Frame 0: empty history → reproject should be blocked (history not available)
    var reproject_hr: frame_graph.HistoryUsage = .{};
    var accum_hr: frame_graph.HistoryUsage = .{};
    for (plan.nodes) |*node| {
        switch (node.kind) {
            .render => |r| {
                if (r.pass_id == 2) reproject_hr = r.history_reads;
                if (r.pass_id == 3) accum_hr = r.history_reads;
            },
            else => {},
        }
    }
    // Frame 1: history available
    const empty = frame_graph.HistorySet{};
    if (ctx.previous.hasHistory(reproject_hr) != true) return error.HistoryNotAvailableFrame1;
    // Frame 0: empty history → blocked
    if (empty.hasHistory(reproject_hr) != false) return error.HistoryLeakFrame0;
    // sharpen depends on temporal_accum (intra_frame). If accum blocked, sharpen stays blocked.
    if (empty.hasHistory(accum_hr) != false) return error.HistoryLeakAccumFrame0;

    return @as(u64, @intCast(plan.nodes.len));
}

fn fmtVal(v: u64, is_ns: bool) [12]u8 {
    var buf: [12]u8 = undefined;
    if (is_ns) {
        if (v >= 1_000_000_000) {
            _ = std.fmt.bufPrint(&buf, "{d:.2}s", .{@as(f64, @floatFromInt(v)) / 1_000_000_000.0}) catch return "  ERR       ".*;
        } else if (v >= 1_000_000) {
            _ = std.fmt.bufPrint(&buf, "{d:.2}ms", .{@as(f64, @floatFromInt(v)) / 1_000_000.0}) catch return "  ERR       ".*;
        } else if (v >= 1_000) {
            _ = std.fmt.bufPrint(&buf, "{d:.2}us", .{@as(f64, @floatFromInt(v)) / 1_000.0}) catch return "  ERR       ".*;
        } else {
            _ = std.fmt.bufPrint(&buf, "{}ns", .{v}) catch return "  ERR       ".*;
        }
    } else {
        _ = std.fmt.bufPrint(&buf, "{d: >8}", .{v}) catch return "  ERR       ".*;
    }
    return buf;
}

fn fmtDelta(bv: u64, sv: u64) [10]u8 {
    if (bv == 0) return "  N/A     ".*;
    const diff = (@as(f64, @floatFromInt(sv)) - @as(f64, @floatFromInt(bv))) / @as(f64, @floatFromInt(bv)) * 100;
    var dbuf: [10]u8 = undefined;
    var di = std.fmt.bufPrint(&dbuf, "{d:.1}", .{diff}) catch return "  ERR     ".*;
    if (di.len > 0 and di[0] != '-') {
        std.mem.copyBackwards(u8, dbuf[1..di.len + 1], di);
        dbuf[0] = '+';
        di = dbuf[0 .. di.len + 1];
    }
    if (di.len < 9) {
        const shift = 9 - di.len;
        std.mem.copyBackwards(u8, dbuf[shift..di.len + shift], di);
        @memset(dbuf[0..shift], ' ');
    }
    dbuf[9] = '%';
    return dbuf;
}

fn printTable(base: []const RunResult, smart: []const RunResult) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n╔══════════════════╦════════════════════╦═══════════╦═══════════╦═══════════╗\n", .{});
    try stdout.print("║ Pattern          ║ Metric             ║ Baseline  ║ Smart     ║ Delta     ║\n", .{});
    try stdout.print("╠══════════════════╬════════════════════╬═══════════╬═══════════╬═══════════╣\n", .{});

    for (base, smart) |b, s| {
        const labels = [_][]const u8{ "p50 latency", "p95 latency", "p99 latency", "throughput", "steals", "rejected", "attempts", "migrations", "sticky", "local_pops" };
        const is_ns = [_]bool{ true, true, true, false, false, false, false, false, false, false };
        const bvals = [_]u64{ b.p50_ns, b.p95_ns, b.p99_ns, @intFromFloat(b.throughput), b.steals, b.rejected, b.steal_attempts, b.migrations, b.sticky, b.local_pops };
        const svals = [_]u64{ s.p50_ns, s.p95_ns, s.p99_ns, @intFromFloat(s.throughput), s.steals, s.rejected, s.steal_attempts, s.migrations, s.sticky, s.local_pops };

        for (labels, is_ns, bvals, svals) |row_label, ns, bv, sv| {
            const bstr = fmtVal(bv, ns);
            const sstr = fmtVal(sv, ns);
            const delta = fmtDelta(bv, sv);
            try stdout.print("║ {s: <16} ║ {s: <16} ║ {s: >9} ║ {s: >9} ║ {s} ║\n", .{ b.label, row_label, bstr, sstr, delta });
        }

        // Wave wait diagnostic (only non-zero if submitFrame was used)
        if (s.wave_count > 0) {
            const maxstr = fmtVal(s.wave_wait_max_ns, true);
            const avgstr = fmtVal(s.wave_wait_avg_ns, true);
            try stdout.print("║ {s: <16} ║ wave_wait_max/avg  ║ {s: >9} ║ {s: >9} ║           ║\n", .{ s.label, maxstr, avgstr });
        }
        // Queue wait diagnostic — directly measures submit→exec stall
        if (s.queue_wait_max_ns > 0) {
            const bq = fmtVal(b.queue_wait_max_ns, true);
            const sq = fmtVal(s.queue_wait_max_ns, true);
            const bq95 = fmtVal(b.queue_wait_p95_ns, true);
            const sq95 = fmtVal(s.queue_wait_p95_ns, true);
            const bq99 = fmtVal(b.queue_wait_p99_ns, true);
            const sq99 = fmtVal(s.queue_wait_p99_ns, true);
            try stdout.print("║ {s: <16} ║ queue_wait_max     ║ {s: >9} ║ {s: >9} ║           ║\n", .{ s.label, bq, sq });
            try stdout.print("║ {s: <16} ║ queue_wait_p95     ║ {s: >9} ║ {s: >9} ║           ║\n", .{ s.label, bq95, sq95 });
            try stdout.print("║ {s: <16} ║ queue_wait_p99     ║ {s: >9} ║ {s: >9} ║           ║\n", .{ s.label, bq99, sq99 });
            const bdp99 = fmtVal(b.queue_depth_p99, false);
            const sdp99 = fmtVal(s.queue_depth_p99, false);
            const bdmax = fmtVal(b.queue_depth_max, false);
            const sdmax = fmtVal(s.queue_depth_max, false);
            try stdout.print("║ {s: <16} ║ depth_p99/max     ║ {s: >4}/{s: <4} ║ {s: >4}/{s: <4} ║           ║\n", .{ s.label, bdp99, bdmax, sdp99, sdmax });
            const be50 = fmtVal(b.exec_time_p50_ns, true);
            const se50 = fmtVal(s.exec_time_p50_ns, true);
            const be95 = fmtVal(b.exec_time_p95_ns, true);
            const se95 = fmtVal(s.exec_time_p95_ns, true);
            const be99 = fmtVal(b.exec_time_p99_ns, true);
            const se99 = fmtVal(s.exec_time_p99_ns, true);
            try stdout.print("║ {s: <16} ║ exec_time_p50     ║ {s: >9} ║ {s: >9} ║           ║\n", .{ s.label, be50, se50 });
            try stdout.print("║ {s: <16} ║ exec_time_p95     ║ {s: >9} ║ {s: >9} ║           ║\n", .{ s.label, be95, se95 });
            try stdout.print("║ {s: <16} ║ exec_time_p99     ║ {s: >9} ║ {s: >9} ║           ║\n", .{ s.label, be99, se99 });
            const bcb50 = fmtVal(b.completed_before_p50, false);
            const scb50 = fmtVal(s.completed_before_p50, false);
            const bcb95 = fmtVal(b.completed_before_p95, false);
            const scb95 = fmtVal(s.completed_before_p95, false);
            const bcb99 = fmtVal(b.completed_before_p99, false);
            const scb99 = fmtVal(s.completed_before_p99, false);
            try stdout.print("║ {s: <16} ║ wait_seq_p50      ║ {s: >9} ║ {s: >9} ║           ║\n", .{ s.label, bcb50, scb50 });
            try stdout.print("║ {s: <16} ║ wait_seq_p95      ║ {s: >9} ║ {s: >9} ║           ║\n", .{ s.label, bcb95, scb95 });
            try stdout.print("║ {s: <16} ║ wait_seq_p99      ║ {s: >9} ║ {s: >9} ║           ║\n", .{ s.label, bcb99, scb99 });
        }

        try stdout.print("╠══════════════════╬════════════════════╬═══════════╬═══════════╬═══════════╣\n", .{});
    }
    try stdout.print("╚══════════════════╩════════════════════╩═══════════╩═══════════╩═══════════╝\n", .{});
}

test "benchmark: baseline vs smart comparison" {
    const allocator = std.testing.allocator;
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n\n═══ Benchmark: Baseline (dumb) vs Smart scheduler ═══\n", .{});

    const patterns = [_]struct {
        label: []const u8,
        runFn: *const fn (allocator: std.mem.Allocator, smart: bool) anyerror!RunResult,
    }{
        .{ .label = "hot-core-skew", .runFn = runHotCoreSkew },
        .{ .label = "burst-load", .runFn = runBurstLoad },
        .{ .label = "mixed-size", .runFn = runMixedSize },
        .{ .label = "affinity-conflict", .runFn = runAffinityConflict },
    };

    var baseline: [patterns.len]RunResult = undefined;
    var smart: [patterns.len]RunResult = undefined;

    for (patterns, 0..) |p, i| {
        try stdout.print("  [{s}] baseline…", .{p.label});
        baseline[i] = try p.runFn(allocator, false);
        try stdout.print(" smart…", .{});
        smart[i] = try p.runFn(allocator, true);
        try stdout.print(" done.\n", .{});
    }

    try printTable(&baseline, &smart);

    // Stage 9: Frame Graph + GPU scheduler smoke test
    try stdout.print("\n  [frame-graph] resolving…", .{});
    const pruned_len = try runFrameGraph(allocator);
    try stdout.print(" {d} passes after prune.\n", .{pruned_len});

    try stdout.print("  [gpu-scheduler] smoke test…", .{});
    const gpu_result = try runGPUScheduler(allocator, true);
    try stdout.print(" dispatched={d:.0}.\n", .{gpu_result.throughput});

    try stdout.print("  [temporal-frame] smoke test…", .{});
    const temporal_count = try runTemporalFrameGraph(allocator);
    try stdout.print(" {d} temporal passes.\n", .{temporal_count});

    for (smart) |r| {
        if (r.p99_ns > 1_000_000) {
            std.debug.print("\n  WARNING: p99={d}ns exceeds 1ms for {s}\n", .{ r.p99_ns, r.label });
        }
    }

    // Diagnostic: wave_wait metrics confirm wave barrier is NOT triggered
    // in CPU-only benchmarks (submitFrame not called).
    var any_wave: bool = false;
    for (smart) |r| {
        if (r.wave_count > 0) any_wave = true;
    }
    if (!any_wave) {
        try stdout.print("\n  [diag] wave_wait_max_ns=0 (CPU benchmarks don't use submitFrame)\n", .{});
    }
}
