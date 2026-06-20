const std = @import("std");
const bench = @import("bench.zig");

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
