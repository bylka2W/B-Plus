const std = @import("std");
const sched = @import("scheduler.zig");
const frame = @import("frame.zig");

pub const PassType = enum {
    motion,
    depth,
    reactive,
    upsample,
    sharpen,
    temporal,
};

pub const FrameResources = struct {
    input: []f32,
    output: []f32,
    history: []f32,
    motion_x: []f32,
    motion_y: []f32,
    reactive: []f32,
    depth: []f32,
};

pub const FrameCtx = struct {
    id: u64,
    width: u32,
    height: u32,
    scale: f32,
    resources: *FrameResources,
    jitter_x: f32,
    jitter_y: f32,
};

fn clampInt(v: i32, max: i32) i32 {
    if (v < 0) return 0;
    if (v >= max) return max - 1;
    return v;
}

fn motionPass(ctx: *FrameCtx) void {
    const mx = ctx.resources.motion_x;
    const my = ctx.resources.motion_y;
    const w = ctx.width;
    const h = ctx.height;

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = y * w + x;
            // inverse-reprojection convention: motion = current_pos - prev_pos
            // temporal pass then computes history_pos = current_pos - motion
            const js: f32 = 0.5;
            mx[i] = ctx.jitter_x * js;
            my[i] = ctx.jitter_y * js;
            if (x < w / 2) {
                mx[i] += 1.0;
            } else {
                mx[i] -= 1.0;
            }
        }
    }
}

fn depthPass(ctx: *FrameCtx) void {
    const d = ctx.resources.depth;
    const in_slice = ctx.resources.input;
    for (in_slice, 0..) |v, i| d[i] = 1.0 - v;
}

fn reactivePass(ctx: *FrameCtx) void {
    const r = ctx.resources.reactive;
    const d = ctx.resources.depth;
    for (d, 0..) |depth_val, i| {
        r[i] = if (depth_val > 0.7) 0.3 else 1.0;
    }
}

fn neighborMinMax(buf: []const f32, w: u32, h: u32, cx: u32, cy: u32) struct { f32, f32 } {
    var mn: f32 = 1.0;
    var mx: f32 = 0.0;
    const y0 = if (cy > 0) cy - 1 else 0;
    const y1 = @min(cy + 1, h - 1);
    const x0 = if (cx > 0) cx - 1 else 0;
    const x1 = @min(cx + 1, w - 1);
    var yy: u32 = y0;
    while (yy <= y1) : (yy += 1) {
        var xx: u32 = x0;
        while (xx <= x1) : (xx += 1) {
            const v = buf[yy * w + xx];
            if (v < mn) mn = v;
            if (v > mx) mx = v;
        }
    }
    return .{ mn, mx };
}

fn temporalPass(ctx: *FrameCtx) void {
    const cur = ctx.resources.input;
    const hist = ctx.resources.history;
    const mx = ctx.resources.motion_x;
    const my = ctx.resources.motion_y;
    const depth = ctx.resources.depth;
    const reactive = ctx.resources.reactive;
    const w = ctx.width;
    const h = ctx.height;

    for (cur, 0..) |current, i| {
        const x = @as(i32, @intCast(i % w));
        const y = @as(i32, @intCast(i / w));

        const mx_i = @as(i32, @intFromFloat(mx[i]));
        const my_i = @as(i32, @intFromFloat(my[i]));

        const hx = x - mx_i;
        const hy = y - my_i;

        const cx = @as(usize, @intCast(clampInt(hx, @as(i32, @intCast(w)))));
        const cy = @as(usize, @intCast(clampInt(hy, @as(i32, @intCast(h)))));

        const ri = cy * w + cx;

        const raw_history = hist[ri];

        const nm = neighborMinMax(cur, w, h, @as(u32, @intCast(i % w)), @as(u32, @intCast(i / w)));
        const clamped_history = @max(nm[0], @min(raw_history, nm[1]));

        const depth_current = depth[i];
        const depth_history = depth[ri];
        const depth_delta = @abs(depth_current - depth_history);
        const motion_len = @abs(mx_i) + @abs(my_i);

        var alpha: f32 = if (reactive[i] > 0.5) 0.15 else 0.85;

        if (depth_delta > 0.2) alpha = 0.05;
        if (motion_len > 4.0) alpha *= 0.5;

        cur[i] = current * (1.0 - alpha) + clamped_history * alpha;
    }
}

fn upsamplePass(ctx: *FrameCtx) void {
    const in_slice = ctx.resources.input;
    const out_slice = ctx.resources.output;
    const w = ctx.width;
    const h = ctx.height;
    const scale = ctx.scale;
    const out_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(w)) * scale));

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const idx = y * w + x;
            const v = in_slice[idx];
            const ox = @as(u32, @intFromFloat(@as(f32, @floatFromInt(x)) * scale));
            const oy = @as(u32, @intFromFloat(@as(f32, @floatFromInt(y)) * scale));
            const out_idx = oy * out_w + ox;
            if (out_idx < out_slice.len) out_slice[out_idx] = v;
        }
    }
}

fn sharpenPass(ctx: *FrameCtx) void {
    const s = ctx.resources.output;
    const w = ctx.width;
    const h = ctx.height;

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = y * w + x;
            const c = s[i];
            const l = if (x > 0) s[i - 1] else c;
            const r = if (x + 1 < w) s[i + 1] else c;
            const u = if (y > 0) s[i - w] else c;
            const d = if (y + 1 < h) s[i + w] else c;
            s[i] = @max(0.0, @min(1.0, c * 1.5 - (l + r + u + d) * 0.125));
        }
    }
}

const PassJob = struct {
    ctx: *FrameCtx,
    pass: PassType,
};

fn passThunk(raw: *anyopaque) void {
    const job = @as(*PassJob, @ptrCast(@alignCast(raw)));
    switch (job.pass) {
        .motion => motionPass(job.ctx),
        .depth => depthPass(job.ctx),
        .reactive => reactivePass(job.ctx),
        .upsample => upsamplePass(job.ctx),
        .sharpen => sharpenPass(job.ctx),
        .temporal => temporalPass(job.ctx),
    }
}

pub const FrameBatch = struct {
    jobs: []sched.Job,

    pub fn deinit(fb: *FrameBatch, allocator: std.mem.Allocator) void {
        for (fb.jobs) |*j| {
            const pj = @as(*PassJob, @ptrCast(@alignCast(j.ctx)));
            allocator.destroy(pj);
        }
        allocator.free(fb.jobs);
    }
};

pub const FsrPipeline = struct {
    passes: []const PassType,

    pub fn default() FsrPipeline {
        return FsrPipeline{
            .passes = &.{ .motion, .depth, .reactive, .temporal, .upsample, .sharpen },
        };
    }
};

pub fn submitFrame(s: *sched.Scheduler, allocator: std.mem.Allocator, ctx: *FrameCtx) !FrameBatch {
    return submitPipeline(s, allocator, ctx, &FsrPipeline.default());
}

pub fn submitPipeline(s: *sched.Scheduler, allocator: std.mem.Allocator, ctx: *FrameCtx, pipeline: *const FsrPipeline) !FrameBatch {
    const n = pipeline.passes.len;
    var jobs = try allocator.alloc(sched.Job, n);
    for (pipeline.passes, 0..) |pass, i| {
        const pj = try allocator.create(PassJob);
        pj.* = PassJob{ .ctx = ctx, .pass = pass };
        jobs[i] = sched.Job{
            .func = passThunk,
            .ctx = @as(*anyopaque, @ptrCast(pj)),
            .priority = .Normal,
            .next = null,
        };
        s.submit(&jobs[i]);
    }
    s.waitAll();

    if (ctx.resources.history.len > 0) {
        const copy_n = @min(ctx.resources.history.len, ctx.resources.input.len);
        @memcpy(ctx.resources.history[0..copy_n], ctx.resources.input[0..copy_n]);
    }

    return FrameBatch{ .jobs = jobs };
}
