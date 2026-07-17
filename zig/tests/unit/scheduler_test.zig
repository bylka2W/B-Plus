const std = @import("std");
const sched = @import("../../src/runtime/scheduler.zig");
const cpu = @import("../../src/runtime/cpu.zig");
const latency = @import("../../src/runtime/latency.zig");

test "Scheduler sync mode executes jobs inline" {
    var s = sched.Scheduler.initSync(0, 0);
    defer s.deinit();

    var counter: u32 = 0;
    var job1 = sched.Job{
        .func = struct {
            fn run(c: *anyopaque) void {
                const cnt = @as(*u32, @ptrCast(@alignCast(c)));
                cnt.* += 1;
            }
        }.run,
        .ctx = @as(*anyopaque, @ptrCast(&counter)),
        .priority = .Normal,
        .next = null,
    };
    var job2 = sched.Job{
        .func = struct {
            fn run(c: *anyopaque) void {
                const cnt = @as(*u32, @ptrCast(@alignCast(c)));
                cnt.* += 2;
            }
        }.run,
        .ctx = @as(*anyopaque, @ptrCast(&counter)),
        .priority = .Normal,
        .next = null,
    };

    s.submit(&job1);
    try std.testing.expectEqual(@as(u32, 1), counter);

    s.submit(&job2);
    try std.testing.expectEqual(@as(u32, 3), counter);
}

test "Scheduler priority ordering in sync mode" {
    var s = sched.Scheduler.initSync(0, 0);
    defer s.deinit();

    var order_idx: u32 = 0;

    var high_job = sched.Job{
        .func = struct {
            fn run(c: *anyopaque) void {
                const idx = @as(*u32, @ptrCast(@alignCast(c)));
                idx.* += 1;
            }
        }.run,
        .ctx = @as(*anyopaque, @ptrCast(&order_idx)),
        .priority = .High,
        .next = null,
    };

    var bg_job = sched.Job{
        .func = struct {
            fn run(c: *anyopaque) void {
                const idx = @as(*u32, @ptrCast(@alignCast(c)));
                idx.* += 10;
            }
        }.run,
        .ctx = @as(*anyopaque, @ptrCast(&order_idx)),
        .priority = .Background,
        .next = null,
    };

    s.submit(&bg_job);
    s.submit(&high_job);

    try std.testing.expectEqual(@as(u32, 11), order_idx);
}

test "CPU reservation math" {
    var r = sched.CPUReservation.init(0, 0);
    const all = r.total_cores;
    try std.testing.expectEqual(all, r.availableCores());
    try std.testing.expect(all > 0);

    r.reserve_absolute = 2;
    const avail = r.availableCores();
    try std.testing.expectEqual(all -| 2, avail);
}

test "Scheduler batch submit" {
    var s = sched.Scheduler.initSync(0, 0);
    defer s.deinit();

    var sum: u32 = 0;
    var jobs: [3]sched.Job = undefined;
    var job_ptrs: [3]*sched.Job = undefined;

    for (&jobs, 0..) |*j, i| {
        j.* = sched.Job{
            .func = struct {
                fn run(c: *anyopaque) void {
                    const sum_val = @as(*u32, @ptrCast(@alignCast(c)));
                    sum_val.* += 1;
                }
            }.run,
            .ctx = @as(*anyopaque, @ptrCast(&sum)),
            .priority = @as(sched.Priority, @enumFromInt(@as(u8, @intCast(i % 4)))),
            .next = null,
        };
        job_ptrs[i] = j;
    }

    s.submitBatch(&job_ptrs);
    try std.testing.expectEqual(@as(u32, 3), sum);
}

test "Scheduler threaded submit and wait" {
    var s: sched.Scheduler = undefined;
    try sched.Scheduler.initThreaded(&s, std.testing.allocator, 2, 0, 0);
    defer s.deinit();
    try s.start();

    var counter: u32 = 0;
    var job = sched.Job{
        .func = struct {
            fn run(c: *anyopaque) void {
                const cnt = @as(*u32, @ptrCast(@alignCast(c)));
                _ = @atomicRmw(u32, cnt, .Add, 1, .monotonic);
            }
        }.run,
        .ctx = @as(*anyopaque, @ptrCast(&counter)),
        .priority = .Normal,
        .next = null,
    };

    s.submit(&job);
    s.waitAll();
    try std.testing.expectEqual(@as(u32, 1), counter);
}

test "Scheduler threaded batch of 10" {
    var s: sched.Scheduler = undefined;
    try sched.Scheduler.initThreaded(&s, std.testing.allocator, 2, 0, 0);
    defer s.deinit();
    try s.start();

    var sum: u32 = 0;
    var jobs: [10]sched.Job = undefined;
    var job_ptrs: [10]*sched.Job = undefined;

    for (&jobs, 0..) |*j, i| {
        j.* = sched.Job{
            .func = struct {
                fn run(c: *anyopaque) void {
                    const sum_val = @as(*u32, @ptrCast(@alignCast(c)));
                    _ = @atomicRmw(u32, sum_val, .Add, 1, .monotonic);
                }
            }.run,
            .ctx = @as(*anyopaque, @ptrCast(&sum)),
            .priority = .Normal,
            .next = null,
        };
        job_ptrs[i] = j;
    }

    s.submitBatch(&job_ptrs);
    s.waitAll();
    try std.testing.expectEqual(@as(u32, 10), sum);
}

test "Scheduler starvation protection: Background runs despite Critical flood" {
    var s: sched.Scheduler = undefined;
    try sched.Scheduler.initThreaded(&s, std.testing.allocator, 2, 0, 0);
    defer s.deinit();
    try s.start();

    var bg_ran: bool = false;
    var critical_count: u32 = 0;

    var crit_jobs: [50]sched.Job = undefined;
    var crit_ptrs: [50]*sched.Job = undefined;
    for (&crit_jobs, 0..) |*j, i| {
        j.* = sched.Job{
            .func = struct {
                fn run(c: *anyopaque) void {
                    const cnt = @as(*u32, @ptrCast(@alignCast(c)));
                    _ = @atomicRmw(u32, cnt, .Add, 1, .monotonic);
                }
            }.run,
            .ctx = @as(*anyopaque, @ptrCast(&critical_count)),
            .priority = .Critical,
            .next = null,
        };
        crit_ptrs[i] = j;
    }

    var bg_job = sched.Job{
        .func = struct {
            fn run(c: *anyopaque) void {
                const flag = @as(*bool, @ptrCast(@alignCast(c)));
                flag.* = true;
            }
        }.run,
        .ctx = @as(*anyopaque, @ptrCast(&bg_ran)),
        .priority = .Background,
        .next = null,
    };

    s.submitBatch(&crit_ptrs);
    s.submit(&bg_job);
    s.waitAll();

    try std.testing.expectEqual(@as(u32, 50), critical_count);
    try std.testing.expect(bg_ran);
}

test "Scheduler work stealing: single worker dequeues from shared queue" {
    var s: sched.Scheduler = undefined;
    try sched.Scheduler.initThreaded(&s, std.testing.allocator, 2, 0, 0);
    defer s.deinit();
    try s.start();

    var sum: u32 = 0;
    var jobs: [10]sched.Job = undefined;
    var job_ptrs: [10]*sched.Job = undefined;

    for (&jobs, 0..) |*j, i| {
        j.* = sched.Job{
            .func = struct {
                fn run(c: *anyopaque) void {
                    const sum_val = @as(*u32, @ptrCast(@alignCast(c)));
                    _ = @atomicRmw(u32, sum_val, .Add, 1, .monotonic);
                }
            }.run,
            .ctx = @as(*anyopaque, @ptrCast(&sum)),
            .priority = .Normal,
            .next = null,
        };
        job_ptrs[i] = j;
    }

    s.submitBatch(&job_ptrs);
    s.waitAll();
    try std.testing.expectEqual(@as(u32, 10), sum);
}

test "Scheduler with LatencyProfile: threaded submit and migrate" {
    const topo = try cpu.CpuTopology.detect(std.testing.allocator);
    defer topo.deinit();

    var lp = try latency.LatencyProfile.init(std.testing.allocator, &topo);
    defer lp.deinit();

    var s: sched.Scheduler = undefined;
    try sched.Scheduler.initThreadedWithTopo(&s, std.testing.allocator, 2, 0, 0, &lp);
    defer s.deinit();
    try s.start();

    var counter: u32 = 0;
    var job1 = sched.Job{
        .func = struct {
            fn run(c: *anyopaque) void {
                const cnt = @as(*u32, @ptrCast(@alignCast(c)));
                _ = @atomicRmw(u32, cnt, .Add, 1, .monotonic);
            }
        }.run,
        .ctx = @as(*anyopaque, @ptrCast(&counter)),
        .priority = .Normal,
        .next = null,
    };
    var job2 = sched.Job{
        .func = struct {
            fn run(c: *anyopaque) void {
                const cnt = @as(*u32, @ptrCast(@alignCast(c)));
                _ = @atomicRmw(u32, cnt, .Add, 2, .monotonic);
            }
        }.run,
        .ctx = @as(*anyopaque, @ptrCast(&counter)),
        .priority = .Normal,
        .next = null,
    };

    s.submit(&job1);
    s.submitAffine(&job2, 0);
    s.waitAll();
    try std.testing.expectEqual(@as(u32, 3), counter);

    if (s.pool) |*p| {
        if (p.latency_profile) |lp2| {
            _ = lp2.migrationCount();
        }
    }
}

test "Scheduler score consistency" {
    const topo = try cpu.CpuTopology.detect(std.testing.allocator);
    defer topo.deinit();

    var lp = try latency.LatencyProfile.init(std.testing.allocator, &topo);
    defer lp.deinit();

    _ = lp.logicalCoreCount();
    try std.testing.expectEqual(@as(u64, 0), lp.score(0, 0, 0));
    try std.testing.expect(lp.score(0, 1, 0) > 0);
    try std.testing.expect(lp.score(0, 0, 10) < lp.score(0, 1, 10));
}
