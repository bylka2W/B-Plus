const std = @import("std");
const sched = @import("scheduler.zig");

pub const Stage = enum { upsample, sharpen, temporal };

pub const Frame = struct {
    id: u64,
    width: u32,
    height: u32,
    input: []f32,
    output: []f32,
    prev_frame: ?[]f32,
    prev_velocity: ?[]f32,
    motion: ?[]f32,
    timestamp_ns: u64,
};

pub const FrameCtx = struct {
    frame: *Frame,
    tile_x: u32,
    tile_y: u32,
    tile_w: u32,
    tile_h: u32,
    scale: f32,
    stage: Stage,
    allocator: std.mem.Allocator,
};

const FrameJob = struct {
    ctx: *FrameCtx,
    run: *const fn (*FrameCtx) void,
};

fn frameJobThunk(raw: *anyopaque) void {
    const job = @as(*FrameJob, @ptrCast(@alignCast(raw)));
    const ctx = job.ctx;
    const allocator = ctx.allocator;
    job.run(ctx);
    allocator.destroy(ctx);
    allocator.destroy(job);
}

pub const TileStream = struct {
    jobs: []sched.Job,

    pub fn deinit(ts: *TileStream, allocator: std.mem.Allocator) void {
        allocator.free(ts.jobs);
    }
};

fn upsampleTile(ctx: *FrameCtx) void {
    const f = ctx.frame;
    const in_slice = f.input;
    const out_slice = f.output;
    const x0 = ctx.tile_x;
    const y0 = ctx.tile_y;
    const w = f.width;
    const h = f.height;
    const scale = ctx.scale;

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

fn sharpenTile(ctx: *FrameCtx) void {
    const f = ctx.frame;
    const in_slice = f.input;
    const out_slice = f.output;
    const x0 = ctx.tile_x;
    const y0 = ctx.tile_y;
    const w = f.width;
    const h = f.height;
    const scale = ctx.scale;
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
            const center = in_slice[idx];
            const left = if (src_x > 0) in_slice[idx - 1] else center;
            const right = if (src_x + 1 < w) in_slice[idx + 1] else center;
            const up = if (src_y > 0) in_slice[idx - w] else center;
            const down = if (src_y + 1 < h) in_slice[idx + w] else center;
            const sharpened = center * 1.5 - (left + right + up + down) * 0.125;
            out_slice[out_idx] = @max(0.0, @min(1.0, sharpened));
        }
    }
}

fn temporalTile(ctx: *FrameCtx) void {
    const f = ctx.frame;
    const out_slice = f.output;
    const prev = f.prev_frame orelse return;
    const x0 = ctx.tile_x;
    const y0 = ctx.tile_y;
    const w = f.width;
    const h = f.height;
    const out_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(w)) * ctx.scale));

    var ty: u32 = 0;
    while (ty < ctx.tile_h) : (ty += 1) {
        const src_y = y0 + ty;
        if (src_y >= h) break;
        var tx: u32 = 0;
        while (tx < ctx.tile_w) : (tx += 1) {
            const src_x = x0 + tx;
            if (src_x >= w) break;
            const ox = @as(u32, @intFromFloat(@as(f32, @floatFromInt(src_x)) * ctx.scale));
            const oy = @as(u32, @intFromFloat(@as(f32, @floatFromInt(src_y)) * ctx.scale));
            const out_idx = oy * out_w + ox;
            if (out_idx >= out_slice.len) continue;
            const idx = src_y * w + src_x;
            const cur = out_slice[out_idx];
            const hist = if (idx < prev.len) prev[idx] else cur;
            out_slice[out_idx] = cur * 0.9 + hist * 0.1;
        }
    }
}

pub fn submitUpsample(pool: *sched.WorkerPool, allocator: std.mem.Allocator, frame: *Frame, scale: f32) !TileStream {
    return submitStage(pool, allocator, frame, scale, .upsample);
}

pub fn submitSharpen(pool: *sched.WorkerPool, allocator: std.mem.Allocator, frame: *Frame, scale: f32) !TileStream {
    return submitStage(pool, allocator, frame, scale, .sharpen);
}

pub fn submitTemporal(pool: *sched.WorkerPool, allocator: std.mem.Allocator, frame: *Frame, scale: f32) !TileStream {
    return submitStage(pool, allocator, frame, scale, .temporal);
}

fn stageFn(stage: Stage) *const fn (*FrameCtx) void {
    return switch (stage) {
        .upsample => upsampleTile,
        .sharpen => sharpenTile,
        .temporal => temporalTile,
    };
}

fn submitStage(pool: *sched.WorkerPool, allocator: std.mem.Allocator, frame: *Frame, scale: f32, stage: Stage) !TileStream {
    const tile_size: u32 = 64;
    const tiles_x = (frame.width + tile_size - 1) / tile_size;
    const tiles_y = (frame.height + tile_size - 1) / tile_size;
    const num_tiles = tiles_x * tiles_y;

    var jobs = try allocator.alloc(sched.Job, num_tiles);

    const run = stageFn(stage);
    var idx: usize = 0;
    var y: u32 = 0;
    while (y < frame.height) : (y += tile_size) {
        var x: u32 = 0;
        while (x < frame.width) : (x += tile_size) {
            const ctx = try allocator.create(FrameCtx);
            ctx.* = FrameCtx{
                .frame = frame,
                .tile_x = x,
                .tile_y = y,
                .tile_w = tile_size,
                .tile_h = tile_size,
                .scale = scale,
                .stage = stage,
                .allocator = allocator,
            };
            const fj = try allocator.create(FrameJob);
            fj.* = FrameJob{ .ctx = ctx, .run = run };
            jobs[idx] = sched.Job{
                .func = frameJobThunk,
                .ctx = @as(*anyopaque, @ptrCast(fj)),
                .priority = .Normal,
                .next = null,
            };
            pool.submit(&jobs[idx]);
            idx += 1;
        }
    }
    return TileStream{ .jobs = jobs };
}
