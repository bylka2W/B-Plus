const std = @import("std");
const sched = @import("scheduler.zig");
const cpu = @import("cpu.zig");
const latency = @import("latency.zig");
const sched_config = @import("scheduler_config.zig");
const sched_state = @import("scheduler_state.zig");

const NUM_WORKERS: u32 = 4;
const ALLOC_SIZE = 64 * 1024 * 1024;

const TimingCtx = struct {
    submitted_at: u64,
    completed_at: u64,
    work_iters: u32,
};

fn timingJobFn(ctx: *anyopaque) void {
    const tc = @as(*TimingCtx, @ptrCast(@alignCast(ctx)));
    var x: u64 = 1;
    for (0..tc.work_iters) |_| x = x *| 7 +| 3;
    std.mem.doNotOptimizeAway(&x);
    tc.completed_at = @intCast(std.time.nanoTimestamp());
}

const RunResult = struct {
    label: []const u8,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    p999_ns: u64,
    throughput: f64,
    steals: u64,
    rejected: u64,
    migrations: u64,
    sticky: u64,
    stall_rate: f64,
    force_escape: u64,
};

fn makeJob(jobs: []sched.Job, idx: usize, ctxs: []TimingCtx, iters: u32, sticky_core: ?u32, stickiness: u8) void {
    ctxs[idx] = TimingCtx{ .submitted_at = 0, .completed_at = 0, .work_iters = iters };
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

    return RunResult{
        .label = label,
        .p50_ns = latencies[N * 50 / 100],
        .p95_ns = latencies[N * 95 / 100],
        .p99_ns = latencies[N * 99 / 100],
        .p999_ns = latencies[N * 999 / 1000],
        .throughput = throughput,
        .steals = if (scheduler.pool) |*p| p.metrics.steals.load(.acquire) else 0,
        .rejected = if (scheduler.pool) |*p| p.metrics.rejected_steals.load(.acquire) else 0,
        .migrations = if (scheduler.pool) |*p| p.metrics.migrations.load(.acquire) else 0,
        .sticky = if (scheduler.pool) |*p| p.metrics.sticky_honored.load(.acquire) else 0,
        .stall_rate = @as(f64, @floatFromInt(stalls)) / @as(f64, @floatFromInt(N)),
        .force_escape = if (scheduler.pool) |*p| p.metrics.force_migrate_escape.load(.acquire) else 0,
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
    }
    scheduler.waitAll();
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
    }
    scheduler.waitAll();
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
    }
    scheduler.waitAll();
    const end = @as(u64, @intCast(std.time.nanoTimestamp()));
    const result = compute("mixed-size", ctxs, &scheduler, first_submit, end);

    scheduler.deinit();
    if (smart) lp.deinit();
    if (smart) topo.deinit();
    return result;
}

// ── Pattern D: Affinity conflicts ──
fn runAffinityConflict(allocator: std.mem.Allocator, smart: bool) !RunResult {
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
    }
    while (idx < N) : (idx += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const sc = if (smart) @as(u32, @truncate(seed >> 32)) % 2 else 0;
        makeJob(jobs, idx, ctxs, 10, @as(?u32, @intCast(sc)), if (smart) 1 else 0);
        ctxs[idx].submitted_at = @as(u64, @intCast(std.time.nanoTimestamp()));
        scheduler.submit(&jobs[idx]);
    }
    scheduler.waitAll();
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
    }
    while (idx < N) : (idx += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const core = @as(u32, @truncate(seed >> 32)) % NUM_WORKERS;
        makeJob(jobs, idx, ctxs, 50, @as(?u32, @intCast(core)), if (smart) 1 else 0);
        ctxs[idx].submitted_at = @as(u64, @intCast(std.time.nanoTimestamp()));
        scheduler.submit(&jobs[idx]);
    }
    scheduler.waitAll();
    const end = @as(u64, @intCast(std.time.nanoTimestamp()));
    const result = compute("sticky-starvation", ctxs, &scheduler, first_submit, end);

    scheduler.deinit();
    if (smart) lp.deinit();
    if (smart) topo.deinit();
    return result;
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
        const labels = [_][]const u8{ "p50 latency", "p95 latency", "p99 latency", "throughput", "steals", "rejected", "migrations", "sticky" };
        const is_ns = [_]bool{ true, true, true, false, false, false, false, false };
        const bvals = [_]u64{ b.p50_ns, b.p95_ns, b.p99_ns, @intFromFloat(b.throughput), b.steals, b.rejected, b.migrations, b.sticky };
        const svals = [_]u64{ s.p50_ns, s.p95_ns, s.p99_ns, @intFromFloat(s.throughput), s.steals, s.rejected, s.migrations, s.sticky };

        for (labels, is_ns, bvals, svals) |row_label, ns, bv, sv| {
            const bstr = fmtVal(bv, ns);
            const sstr = fmtVal(sv, ns);
            const delta = fmtDelta(bv, sv);
            try stdout.print("║ {s: <16} ║ {s: <16} ║ {s: >9} ║ {s: >9} ║ {s} ║\n", .{ b.label, row_label, bstr, sstr, delta });
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

    for (smart) |r| {
        if (r.p99_ns > 1_000_000) {
            std.debug.print("\n  WARNING: p99={d}ns exceeds 1ms for {s}\n", .{ r.p99_ns, r.label });
        }
    }
}
