const std = @import("std");
const bench = @import("bench.zig");
const frame = @import("frame.zig");
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

    var f = frame.Frame{
        .id = 0,
        .width = w,
        .height = h,
        .input = in_buf,
        .output = out_buf,
        .prev_frame = null,
        .prev_velocity = null,
        .motion = null,
        .timestamp_ns = @intCast(std.time.nanoTimestamp()),
    };

    var s: sched.Scheduler = undefined;
    try sched.Scheduler.initThreaded(&s, allocator, 4, 0, 0);
    defer s.deinit();
    try s.start();

    var ts1 = try frame.submitUpsample(&s.pool.?, allocator, &f, 2.0);
    defer ts1.deinit(allocator);
    s.waitAll();

    var ts2 = try frame.submitSharpen(&s.pool.?, allocator, &f, 2.0);
    defer ts2.deinit(allocator);
    s.waitAll();

    var sum: f64 = 0;
    for (out_buf) |v| sum += v;
    const mean = sum / @as(f64, @floatFromInt(out_buf.len));

    try stdout.print("\nframe-smoke: {d}x{d} -> {d}x{d}, output mean={d:.4}\n", .{ w, h, w2, w2, mean });
    try std.testing.expect(mean > 0);
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
