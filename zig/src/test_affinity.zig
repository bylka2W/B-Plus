const std = @import("std");
const bench = @import("bench.zig");
const frame = @import("frame.zig");
const frame_runtime = @import("frame_runtime.zig");
const sched = @import("scheduler.zig");

test "frame-smoke" {
    const allocator = std.testing.allocator;
    const stdout = std.io.getStdOut().writer();

    const w = 64;
    const h = 64;
    const w2 = @as(u32, @intFromFloat(@as(f32, @floatFromInt(w)) * 2.0));

    const in_buf = try allocator.alloc(f32, w * h);
    defer allocator.free(in_buf);
    const out_buf = try allocator.alloc(f32, w2 * w2);
    defer allocator.free(out_buf);

    @memset(in_buf, 1.0);
    @memset(out_buf, 0.0);

    var graph = frame.FrameGraph{
        .frame_id = 0,
        .width = w,
        .height = h,
        .input = in_buf,
        .output = out_buf,
        .history = null,
        .scale = 2.0,
    };

    var s: sched.Scheduler = undefined;
    try sched.Scheduler.initThreaded(&s, allocator, 4, 0, 0);
    defer s.deinit();
    try s.start();

    var batch = try frame.submitFrame(&s, allocator, &graph);
    defer batch.deinit(allocator);

    var sum: f64 = 0;
    for (out_buf) |v| sum += v;
    const mean = sum / @as(f64, @floatFromInt(out_buf.len));

    try stdout.print("\nframe-smoke: {d}x{d} -> {d}x{d}, output mean={d:.4}\n", .{ w, h, w2, w2, mean });
    try std.testing.expect(mean > 0);
}

test "frame-temporal" {
    const allocator = std.testing.allocator;
    const stdout = std.io.getStdOut().writer();

    const w: u32 = 64;
    const h: u32 = 64;
    const w2 = @as(u32, @intFromFloat(@as(f32, @floatFromInt(w)) * 2.0));

    const in_buf = try allocator.alloc(f32, w * h);
    defer allocator.free(in_buf);
    const hist_buf = try allocator.alloc(f32, w * h);
    defer allocator.free(hist_buf);
    const out_buf = try allocator.alloc(f32, w2 * w2);
    defer allocator.free(out_buf);

    @memset(in_buf, 0.5);
    @memset(hist_buf, 0.25);
    @memset(out_buf, 0.0);

    var graph = frame.FrameGraph{
        .frame_id = 1,
        .width = w,
        .height = h,
        .input = in_buf,
        .output = out_buf,
        .history = hist_buf,
        .scale = 2.0,
    };

    var s: sched.Scheduler = undefined;
    try sched.Scheduler.initThreaded(&s, allocator, 4, 0, 0);
    defer s.deinit();
    try s.start();

    var batch = try frame.submitFrame(&s, allocator, &graph);
    defer batch.deinit(allocator);

    var sum: f64 = 0;
    for (out_buf) |v| sum += v;
    const mean = sum / @as(f64, @floatFromInt(out_buf.len));

    try stdout.print("\nframe-temporal: frame_id={d} mean={d:.4}\n", .{ graph.frame_id, mean });
    try std.testing.expect(mean > 0);
}

test "frame-compiler" {
    const allocator = std.testing.allocator;
    const stdout = std.io.getStdOut().writer();

    const w: u32 = 32;
    const h: u32 = 32;

    const in_buf = try allocator.alloc(f32, w * h);
    defer allocator.free(in_buf);
    const out_buf = try allocator.alloc(f32, w * h);
    defer allocator.free(out_buf);
    const hist_buf = try allocator.alloc(f32, w * h);
    defer allocator.free(hist_buf);

    @memset(in_buf, 0.5);
    @memset(out_buf, 0.0);
    @memset(hist_buf, 0.25);

    var graph = frame.FrameGraph{
        .frame_id = 2,
        .width = w,
        .height = h,
        .input = in_buf,
        .output = out_buf,
        .history = hist_buf,
        .scale = 1.0,
    };

    const desc = frame.FgDesc{
        .nodes = &.{
            frame.FgNode{ .stage = .upsample, .deps = &.{} },
            frame.FgNode{ .stage = .sharpen, .deps = &.{0} },
            frame.FgNode{ .stage = .temporal, .deps = &.{0} },
        },
    };

    var s: sched.Scheduler = undefined;
    try sched.Scheduler.initThreaded(&s, allocator, 4, 0, 0);
    defer s.deinit();
    try s.start();

    var compiled = try frame.submitGraph(&s, allocator, &graph, &desc);
    defer compiled.deinit(allocator);

    try stdout.print("frame-compiler: {d} waves, {d} nodes\n", .{ compiled.waves.len, desc.nodes.len });
    try std.testing.expect(compiled.waves.len == 2);
    for (compiled.waves) |*wave| try std.testing.expect(wave.jobs.jobs.len > 0);

    var sum: f64 = 0;
    for (out_buf) |v| sum += v;
    const mean = sum / @as(f64, @floatFromInt(out_buf.len));
    try std.testing.expect(mean > 0);
}

test "fsr-pipeline" {
    const allocator = std.testing.allocator;
    const stdout = std.io.getStdOut().writer();

    const w: u32 = 32;
    const h: u32 = 32;
    const out_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(w)) * 2.0));
    const out_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(h)) * 2.0));

    const out_buf2 = try allocator.alloc(f32, out_w * out_h);
    defer allocator.free(out_buf2);
    const hist_buf = try allocator.alloc(f32, w * h);
    defer allocator.free(hist_buf);
    const mx_buf = try allocator.alloc(f32, w * h);
    defer allocator.free(mx_buf);
    const my_buf = try allocator.alloc(f32, w * h);
    defer allocator.free(my_buf);
    const react_buf = try allocator.alloc(f32, w * h);
    defer allocator.free(react_buf);
    const depth_buf = try allocator.alloc(f32, w * h);
    defer allocator.free(depth_buf);
    const in_buf2 = try allocator.alloc(f32, w * h);
    defer allocator.free(in_buf2);

    var resources = frame_runtime.FrameResources{
        .input = in_buf2,
        .output = out_buf2,
        .history = hist_buf,
        .motion_x = mx_buf,
        .motion_y = my_buf,
        .reactive = react_buf,
        .depth = depth_buf,
    };

    @memset(resources.input, 0.5);
    @memset(resources.output, 0.0);
    @memset(resources.history, 0.25);
    @memset(resources.motion_x, 0.0);
    @memset(resources.motion_y, 0.0);
    @memset(resources.reactive, 0.0);
    @memset(resources.depth, 0.0);

    var s: sched.Scheduler = undefined;
    try sched.Scheduler.initThreaded(&s, allocator, 4, 0, 0);
    defer s.deinit();
    try s.start();

    var ctx = frame_runtime.FrameCtx{
        .id = 0,
        .width = w,
        .height = h,
        .scale = 2.0,
        .resources = &resources,
        .jitter_x = 0.0,
        .jitter_y = 0.0,
    };

    var batch0 = try frame_runtime.submitFrame(&s, allocator, &ctx);
    defer batch0.deinit(allocator);

    var mean0: f64 = 0;
    for (resources.output) |v| mean0 += v;
    mean0 /= @as(f64, @floatFromInt(resources.output.len));

    ctx.id = 1;
    ctx.jitter_x = 0.3;
    ctx.jitter_y = 0.5;
    var batch1 = try frame_runtime.submitFrame(&s, allocator, &ctx);
    defer batch1.deinit(allocator);

    var mean1: f64 = 0;
    for (resources.output) |v| mean1 += v;
    mean1 /= @as(f64, @floatFromInt(resources.output.len));

    var mx_sum: f64 = 0;
    for (resources.motion_x) |v| {
        const vf = @as(f64, v);
        mx_sum += if (v < 0) -vf else vf;
    }
    mx_sum /= @as(f64, @floatFromInt(resources.motion_x.len));

    try stdout.print("\nfsr-pipeline: {d}x{d} -> {d}x{d}, frame0_mean={d:.4}, frame1_mean={d:.4}, motion_x_mean={d:.4}, history_updated={any}\n", .{ w, h, out_w, out_h, mean0, mean1, mx_sum, resources.history[0] > 0 });
    try std.testing.expect(mean0 > 0);
    try std.testing.expect(mean1 > 0);
    try std.testing.expect(resources.history[0] > 0);
}

test "affinity-conflict" {
    const allocator = std.testing.allocator;
    const stdout = std.io.getStdOut().writer();

    const baseline = try bench.runAffinityConflict(allocator, false);
    const smart = try bench.runAffinityConflict(allocator, true);

    try stdout.print("\naffinity-conflict:\n", .{});
    try stdout.print("  baseline: p99={}ns  qw_p99={}ns  qw_max={}ns  depth_p99={} depth_max={}\n", .{ baseline.p99_ns, baseline.queue_wait_p99_ns, baseline.queue_wait_max_ns, baseline.queue_depth_p99, baseline.queue_depth_max });
    try stdout.print("  smart:    p99={}ns  qw_p99={}ns  qw_max={}ns  depth_p99={} depth_max={}\n", .{ smart.p99_ns, smart.queue_wait_p99_ns, smart.queue_wait_max_ns, smart.queue_depth_p99, smart.queue_depth_max });
    try stdout.print("  steals={} local_pops={} rejected={} attempts={} migrations={}\n", .{ smart.steals, smart.local_pops, smart.rejected, smart.steal_attempts, smart.migrations });
    try stdout.print("  exec_p50={}ns  exec_p95={}ns  exec_p99={}ns\n", .{ smart.exec_time_p50_ns, smart.exec_time_p95_ns, smart.exec_time_p99_ns });
    try stdout.print("  baseline exec_p50={}ns  exec_p95={}ns  exec_p99={}ns\n", .{ baseline.exec_time_p50_ns, baseline.exec_time_p95_ns, baseline.exec_time_p99_ns });
    try stdout.print("  wait_seq_p50={} wait_seq_p95={} wait_seq_p99={}\n", .{ smart.completed_before_p50, smart.completed_before_p95, smart.completed_before_p99 });
    try stdout.print("  baseline wait_seq_p50={} wait_seq_p95={} wait_seq_p99={}\n", .{ baseline.completed_before_p50, baseline.completed_before_p95, baseline.completed_before_p99 });
}
