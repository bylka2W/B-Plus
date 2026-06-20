const std = @import("std");
const sched = @import("scheduler.zig");

pub const Stage = enum { upsample, sharpen, temporal };

pub const FrameGraph = struct {
    frame_id: u64,
    input: []f32,
    output: []f32,
    history: ?[]f32,
    width: u32,
    height: u32,
    scale: f32,
};

pub const FrameStageCtx = struct {
    graph: *FrameGraph,
    stage: Stage,
    tile_x: u32,
    tile_y: u32,
    tile_w: u32,
    tile_h: u32,
    allocator: std.mem.Allocator,
};

const FsJob = struct {
    ctx: *FrameStageCtx,
    run: *const fn (*FrameStageCtx) void,
};

fn fsJobThunk(raw: *anyopaque) void {
    const job = @as(*FsJob, @ptrCast(@alignCast(raw)));
    const ctx = job.ctx;
    const a = ctx.allocator;
    job.run(ctx);
    a.destroy(ctx);
    a.destroy(job);
}

pub const TileStream = struct {
    jobs: []sched.Job,

    pub fn deinit(ts: *TileStream, allocator: std.mem.Allocator) void {
        allocator.free(ts.jobs);
    }
};

pub const FrameBatch = struct {
    upsample: TileStream,
    sharpen: TileStream,
    temporal: TileStream,

    pub fn deinit(fb: *FrameBatch, allocator: std.mem.Allocator) void {
        fb.upsample.deinit(allocator);
        fb.sharpen.deinit(allocator);
        fb.temporal.deinit(allocator);
    }
};

fn upsampleTile(ctx: *FrameStageCtx) void {
    const g = ctx.graph;
    const in_slice = g.input;
    const out_slice = g.output;
    const x0 = ctx.tile_x;
    const y0 = ctx.tile_y;
    const w = g.width;
    const h = g.height;
    const scale = g.scale;

    var ty: u32 = 0;
    while (ty < ctx.tile_h) : (ty += 1) {
        const src_y = y0 + ty;
        if (src_y >= h) break;
        var tx: u32 = 0;
        while (tx < ctx.tile_w) : (tx += 1) {
            const src_x = x0 + tx;
            if (src_x >= w) break;
            const idx = src_y * w + src_x;
            const v = in_slice[idx];
            const ox = @as(u32, @intFromFloat(@as(f32, @floatFromInt(src_x)) * scale));
            const oy = @as(u32, @intFromFloat(@as(f32, @floatFromInt(src_y)) * scale));
            const out_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(w)) * scale));
            const out_idx = oy * out_w + ox;
            if (out_idx < out_slice.len) out_slice[out_idx] = v;
        }
    }
}

fn sharpenTile(ctx: *FrameStageCtx) void {
    const g = ctx.graph;
    const in_slice = g.output;
    const out_slice = g.output;
    const x0 = ctx.tile_x;
    const y0 = ctx.tile_y;
    const w = g.width;
    const h = g.height;
    const scale = g.scale;
    const out_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(w)) * scale));

    var ty: u32 = 0;
    while (ty < ctx.tile_h) : (ty += 1) {
        const src_y = y0 + ty;
        if (src_y >= h) break;
        var tx: u32 = 0;
        while (tx < ctx.tile_w) : (tx += 1) {
            const src_x = x0 + tx;
            if (src_x >= w) break;
            const idx = src_y * w + src_x;
            const ox = @as(u32, @intFromFloat(@as(f32, @floatFromInt(src_x)) * scale));
            const oy = @as(u32, @intFromFloat(@as(f32, @floatFromInt(src_y)) * scale));
            const out_idx = oy * out_w + ox;
            if (out_idx >= out_slice.len) continue;
            const center = if (idx < in_slice.len) in_slice[idx] else 0;
            const left = if (src_x > 0 and idx - 1 < in_slice.len) in_slice[idx - 1] else center;
            const right = if (src_x + 1 < w and idx + 1 < in_slice.len) in_slice[idx + 1] else center;
            const up = if (src_y > 0 and idx -| w < in_slice.len) in_slice[idx - w] else center;
            const down = if (src_y + 1 < h and idx + w < in_slice.len) in_slice[idx + w] else center;
            const sharpened = center * 1.5 - (left + right + up + down) * 0.125;
            out_slice[out_idx] = @max(0.0, @min(1.0, sharpened));
        }
    }
}

fn temporalTile(ctx: *FrameStageCtx) void {
    const g = ctx.graph;
    const out_slice = g.output;
    const prev = g.history orelse return;
    const x0 = ctx.tile_x;
    const y0 = ctx.tile_y;
    const w = g.width;
    const h = g.height;
    const out_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(w)) * g.scale));

    var ty: u32 = 0;
    while (ty < ctx.tile_h) : (ty += 1) {
        const src_y = y0 + ty;
        if (src_y >= h) break;
        var tx: u32 = 0;
        while (tx < ctx.tile_w) : (tx += 1) {
            const src_x = x0 + tx;
            if (src_x >= w) break;
            const ox = @as(u32, @intFromFloat(@as(f32, @floatFromInt(src_x)) * g.scale));
            const oy = @as(u32, @intFromFloat(@as(f32, @floatFromInt(src_y)) * g.scale));
            const out_idx = oy * out_w + ox;
            if (out_idx >= out_slice.len) continue;
            const idx = src_y * w + src_x;
            const cur = out_slice[out_idx];
            const hist = if (idx < prev.len) prev[idx] else cur;
            out_slice[out_idx] = cur * 0.9 + hist * 0.1;
        }
    }
}

fn stageFn(stage: Stage) *const fn (*FrameStageCtx) void {
    return switch (stage) {
        .upsample => upsampleTile,
        .sharpen => sharpenTile,
        .temporal => temporalTile,
    };
}

fn buildStage(allocator: std.mem.Allocator, graph: *FrameGraph, stage: Stage) !TileStream {
    const tile_size: u32 = 64;
    const tiles_x = (graph.width + tile_size - 1) / tile_size;
    const tiles_y = (graph.height + tile_size - 1) / tile_size;
    const num_tiles = tiles_x * tiles_y;

    var jobs = try allocator.alloc(sched.Job, num_tiles);

    const run = stageFn(stage);
    var idx: usize = 0;
    var y: u32 = 0;
    while (y < graph.height) : (y += tile_size) {
        var x: u32 = 0;
        while (x < graph.width) : (x += tile_size) {
            const ctx = try allocator.create(FrameStageCtx);
            ctx.* = FrameStageCtx{
                .graph = graph,
                .tile_x = x,
                .tile_y = y,
                .tile_w = tile_size,
                .tile_h = tile_size,
                .stage = stage,
                .allocator = allocator,
            };
            const fj = try allocator.create(FsJob);
            fj.* = FsJob{ .ctx = ctx, .run = run };
            jobs[idx] = sched.Job{
                .func = fsJobThunk,
                .ctx = @as(*anyopaque, @ptrCast(fj)),
                .priority = .Normal,
                .next = null,
            };
            idx += 1;
        }
    }
    return TileStream{ .jobs = jobs };
}

fn submitStage(pool: *sched.WorkerPool, allocator: std.mem.Allocator, graph: *FrameGraph, stage: Stage) !TileStream {
    const ts = try buildStage(allocator, graph, stage);
    for (ts.jobs) |*j| pool.submit(j);
    return ts;
}

pub fn submitFrame(s: *sched.Scheduler, allocator: std.mem.Allocator, graph: *FrameGraph) !FrameBatch {
    const pool = &s.pool.?;
    var batch = FrameBatch{
        .upsample = try submitStage(pool, allocator, graph, .upsample),
        .sharpen = TileStream{ .jobs = &.{} },
        .temporal = TileStream{ .jobs = &.{} },
    };
    s.waitAll();

    batch.sharpen = try submitStage(pool, allocator, graph, .sharpen);
    s.waitAll();

    if (graph.history != null) {
        batch.temporal = try submitStage(pool, allocator, graph, .temporal);
        s.waitAll();
    }

    return batch;
}

// ── Frame Graph Compiler ──

pub const FgNode = struct {
    stage: Stage,
    deps: []const u32,
};

pub const FgDesc = struct {
    nodes: []const FgNode,
};

pub const FgWave = struct {
    jobs: TileStream,
};

pub const FgCompiled = struct {
    waves: []FgWave,

    pub fn deinit(c: *FgCompiled, allocator: std.mem.Allocator) void {
        for (c.waves) |*w| w.jobs.deinit(allocator);
        allocator.free(c.waves);
    }
};

fn topoDepth(desc: *const FgDesc, allocator: std.mem.Allocator) ![]u32 {
    const n = desc.nodes.len;
    const depth = try allocator.alloc(u32, n);
    for (0..n) |i| {
        var d: u32 = 0;
        for (desc.nodes[i].deps) |dep| {
            const dd = depth[dep] + 1;
            if (dd > d) d = dd;
        }
        depth[i] = d;
    }
    return depth;
}

pub fn compile(desc: *const FgDesc, graph: *FrameGraph, allocator: std.mem.Allocator) !FgCompiled {
    const depth = try topoDepth(desc, allocator);
    defer allocator.free(depth);

    var max_depth: u32 = 0;
    for (depth) |d| {
        if (d > max_depth) max_depth = d;
    }
    const wave_count = max_depth + 1;

    var wave_list = try allocator.alloc(FgWave, wave_count);
    for (0..wave_count) |i| wave_list[i] = FgWave{ .jobs = TileStream{ .jobs = &.{} } };

    for (desc.nodes, 0..) |node, i| {
        const w = depth[i];
        const ts = try buildStage(allocator, graph, node.stage);
        const prev = wave_list[w].jobs.jobs;
        wave_list[w].jobs.jobs = try allocator.alloc(sched.Job, prev.len + ts.jobs.len);
        @memcpy(wave_list[w].jobs.jobs[0..prev.len], prev);
        @memcpy(wave_list[w].jobs.jobs[prev.len..], ts.jobs);
        allocator.free(prev);
        allocator.free(ts.jobs);
    }

    return FgCompiled{ .waves = wave_list };
}

pub fn submitGraph(s: *sched.Scheduler, allocator: std.mem.Allocator, graph: *FrameGraph, desc: *const FgDesc) !FgCompiled {
    const compiled = try compile(desc, graph, allocator);
    const pool = &s.pool.?;
    for (compiled.waves) |*wave| {
        for (wave.jobs.jobs) |*j| pool.submit(j);
        s.waitAll();
    }
    return compiled;
}
