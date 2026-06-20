const std = @import("std");
const latency = @import("latency.zig");
const sched_config = @import("scheduler_config.zig");
const sched_state = @import("scheduler_state.zig");
const gpu_job_mod = @import("gpu_job.zig");
const gpu_sched_mod = @import("gpu_scheduler.zig");
const frame_graph = @import("frame_graph.zig");

pub const Priority = enum(u8) {
    Critical = 0,
    High = 1,
    Normal = 2,
    Background = 3,

    pub fn count() u32 {
        return 4;
    }
};

pub const JobFn = *const fn (ctx: *anyopaque) void;

pub const Job = struct {
    func: JobFn,
    ctx: *anyopaque,
    priority: Priority,
    next: ?*Job,
    sticky_core: ?u32 = null,
    stickiness: u8 = 0,
    submitted_at: u64 = 0,
    enqueue_depth: u32 = 0,
    completed_before_start: u64 = 0,
};

/// Per-worker double-ended queue.
/// Worker pushes from back, pops from back (LIFO → hot cache).
/// Stealers pop from front (FIFO → victim cache friendly).
const WorkerQueue = struct {
    items: std.ArrayListUnmanaged(*Job),
    mutex: std.Thread.Mutex = .{},

    fn init(q: *WorkerQueue) void {
        q.* = WorkerQueue{ .items = .{}, .mutex = .{} };
    }

    fn deinit(q: *WorkerQueue, allocator: std.mem.Allocator) void {
        q.items.deinit(allocator);
    }

    fn pushBack(q: *WorkerQueue, job: *Job, allocator: std.mem.Allocator) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        q.items.append(allocator, job) catch {};
    }

    fn popBack(q: *WorkerQueue) ?*Job {
        q.mutex.lock();
        defer q.mutex.unlock();
        if (q.items.items.len == 0) return null;
        return q.items.pop();
    }

    fn popFront(q: *WorkerQueue) ?*Job {
        q.mutex.lock();
        defer q.mutex.unlock();
        if (q.items.items.len == 0) return null;
        return q.items.orderedRemove(0);
    }

    fn tryPopFront(q: *WorkerQueue) ?*Job {
        if (!q.mutex.tryLock()) return null;
        defer q.mutex.unlock();
        if (q.items.items.len == 0) return null;
        return q.items.orderedRemove(0);
    }

    /// Approximate queue length (no lock — OK for heuristic decisions).
    fn approxLen(q: *const WorkerQueue) u32 {
        return @intCast(@min(q.items.items.len, std.math.maxInt(u32)));
    }
};

/// Shared submission queue (per priority level).
/// Protected by pool.shared_mutex.
const SharedQueue = struct {
    head: ?*Job,
    tail: ?*Job,
    count: u32,
};

pub const UnifiedJob = union(enum) {
    cpu: *Job,
    gpu: gpu_job_mod.GPUJob,
};

pub const Metrics = struct {
    migrations: std.atomic.Value(u64),
    steals: std.atomic.Value(u64),
    rejected_steals: std.atomic.Value(u64),
    steal_attempts: std.atomic.Value(u64),
    local_pops: std.atomic.Value(u64),
    sticky_honored: std.atomic.Value(u64),
    force_migrate_escape: std.atomic.Value(u64),
    wave_wait_max_ns: std.atomic.Value(u64),
    wave_wait_sum_ns: std.atomic.Value(u64),
    wave_count: std.atomic.Value(u64),
    queue_wait_max_ns: std.atomic.Value(u64),

    pub fn init() Metrics {
        return Metrics{
            .migrations = std.atomic.Value(u64).init(0),
            .steals = std.atomic.Value(u64).init(0),
            .rejected_steals = std.atomic.Value(u64).init(0),
            .steal_attempts = std.atomic.Value(u64).init(0),
            .local_pops = std.atomic.Value(u64).init(0),
            .sticky_honored = std.atomic.Value(u64).init(0),
            .force_migrate_escape = std.atomic.Value(u64).init(0),
            .wave_wait_max_ns = std.atomic.Value(u64).init(0),
            .wave_wait_sum_ns = std.atomic.Value(u64).init(0),
            .wave_count = std.atomic.Value(u64).init(0),
            .queue_wait_max_ns = std.atomic.Value(u64).init(0),
        };
    }
};

const Decision = enum(u8) { prefer_affinity, balanced };

const DecisionContext = struct {
    core_id: u32,
    queue_len: u32,
    is_sticky: bool,
    load_state: latency.LoadState,
};

const Worker = struct {
    thread: ?std.Thread,
    id: u32,
    local_q: WorkerQueue,
    affinity: ?latency.WorkerAffinity,
    jobs_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub const WorkerPool = struct {
    workers: []Worker,
    count: u32,
    shared_queues: [4]SharedQueue,
    shared_mutex: std.Thread.Mutex,
    worker_cond: std.Thread.Condition,
    pending: std.atomic.Value(u32),
    completed_mutex: std.Thread.Mutex,
    completed_cond: std.Thread.Condition,
    shutdown: bool,
    bg_quota: u32,
    dispatch_counter: u32,
    allocator: std.mem.Allocator,
    next_worker_id: std.atomic.Value(u32),
    latency_profile: ?*latency.LatencyProfile,
    workers_for_node: [][]u32,
    metrics: Metrics,
    config: sched_config.SchedulerConfig,
    global_state: ?*sched_state.GlobalSchedulerState,
    gpu_sched: ?*gpu_sched_mod.GPUScheduler,

    pub fn init(pool: *WorkerPool, allocator: std.mem.Allocator, num_workers: u32) !void {
        try initWithTopo(pool, allocator, num_workers, null);
    }

    pub fn initWithTopo(pool: *WorkerPool, allocator: std.mem.Allocator, num_workers: u32, topo: ?*latency.LatencyProfile) !void {
        const workers = try allocator.alloc(Worker, num_workers);
        for (0..num_workers) |i| {
            workers[i] = Worker{
                .thread = null,
                .id = @intCast(i),
                .local_q = undefined,
                .affinity = null,
            };
            workers[i].local_q.init();
        }

        var wfn_buf: [][]u32 = &.{};
        if (topo) |lp| {
            const numa_count = lp.numa_count;
            const wfn = try allocator.alloc([]u32, numa_count);
            for (0..numa_count) |nid| {
                var count: u32 = 0;
                for (0..num_workers) |wi| {
                    const core_id = wi % lp.logicalCoreCount();
                    if (lp.core_to_numa[core_id] == nid) count += 1;
                }
                const slice = try allocator.alloc(u32, count);
                var idx: u32 = 0;
                for (0..num_workers) |wi| {
                    const core_id = wi % lp.logicalCoreCount();
                    if (lp.core_to_numa[core_id] == nid) {
                        slice[idx] = @intCast(wi);
                        idx += 1;
                    }
                }
                wfn[nid] = slice;
            }
            wfn_buf = wfn;

            for (0..num_workers) |i| {
                const core_id = i % lp.logicalCoreCount();
                workers[i].affinity = lp.worker_affinities[core_id];
            }
        }

        pool.* = WorkerPool{
            .workers = workers,
            .count = num_workers,
            .shared_queues = .{
                SharedQueue{ .head = null, .tail = null, .count = 0 },
                SharedQueue{ .head = null, .tail = null, .count = 0 },
                SharedQueue{ .head = null, .tail = null, .count = 0 },
                SharedQueue{ .head = null, .tail = null, .count = 0 },
            },
            .shared_mutex = .{},
            .worker_cond = .{},
            .pending = std.atomic.Value(u32).init(0),
            .completed_mutex = .{},
            .completed_cond = .{},
            .shutdown = false,
            .bg_quota = 8,
            .dispatch_counter = 0,
            .allocator = allocator,
            .next_worker_id = std.atomic.Value(u32).init(0),
            .latency_profile = topo,
            .workers_for_node = wfn_buf,
            .metrics = Metrics.init(),
            .config = sched_config.SchedulerConfig.default(),
            .global_state = null,
            .gpu_sched = null,
        };
    }

    pub fn deinit(pool: *WorkerPool) void {
        {
            pool.shared_mutex.lock();
            defer pool.shared_mutex.unlock();
            pool.shutdown = true;
        }
        pool.worker_cond.broadcast();
        for (pool.workers) |*w| {
            if (w.thread) |th| th.join();
        }
        for (pool.workers) |*w| {
            w.local_q.deinit(pool.allocator);
        }
        pool.allocator.free(pool.workers);
        for (pool.workers_for_node) |slice| pool.allocator.free(slice);
        if (pool.workers_for_node.len > 0) pool.allocator.free(pool.workers_for_node);
    }

    fn assignToWorker(pool: *WorkerPool, job: *Job, wid: u32) void {
        job.enqueue_depth = @intCast(@min(pool.workers[wid].local_q.items.items.len, std.math.maxInt(u32)));
        pool.workers[wid].local_q.pushBack(job, pool.allocator);
        _ = pool.pending.fetchAdd(1, .release);
        pool.worker_cond.signal();
    }

    pub fn setConfig(pool: *WorkerPool, cfg: sched_config.SchedulerConfig) void {
        pool.config = cfg;
    }

    pub fn setGlobalState(pool: *WorkerPool, gs: *sched_state.GlobalSchedulerState) void {
        pool.global_state = gs;
    }

    pub fn setGPUScheduler(pool: *WorkerPool, gs: *gpu_sched_mod.GPUScheduler) void {
        pool.gpu_sched = gs;
    }

    pub fn submitJob(pool: *WorkerPool, uj: UnifiedJob) void {
        switch (uj) {
            .cpu => |j| pool.submit(j),
            .gpu => |gj| {
                if (pool.gpu_sched) |gs| {
                    gs.submit(gj);
                }
            },
        }
    }

    /// Submit a fully materialized ExecutionPlan with temporal context.
    /// Queue-driven Kahn's algorithm O(n+e) with temporal gating:
    /// - intra_frame edges → standard in_degree counting
    /// - inter_frame edges → history availability check before dispatch
    /// CPU → WorkerPool, GPU/GPU.render → GPUScheduler, barrier → frame sync.
    fn nodeBlocked(node: *const frame_graph.ExecutionNode, ctx: *const frame_graph.FrameContext) bool {
        switch (node.kind) {
            .render => |r| if (!ctx.previous.hasHistory(r.history_reads)) return true,
            .barrier => |b| if (ctx.frame_index < b.wait_for_frame) return true,
            else => {},
        }
        return false;
    }

    pub fn submitFrame(pool: *WorkerPool, plan: *const frame_graph.ExecutionPlan, ctx: *const frame_graph.FrameContext) void {
        const n = plan.nodes.len;
        if (n == 0) return;

        // Count only intra_frame edges for Kahn in_degree
        var in_degree = pool.allocator.alloc(u32, n) catch return;
        defer pool.allocator.free(in_degree);
        @memset(in_degree, 0);

        for (plan.edges) |e| {
            if (e.to < n and e.kind == .intra_frame) {
                in_degree[e.to] += 1;
            }
        }

        var cpu_stubs = pool.allocator.alloc(Job, n) catch return;
        defer pool.allocator.free(cpu_stubs);

        var gpu_ready = pool.allocator.alloc(u32, n) catch return;
        defer pool.allocator.free(gpu_ready);

        const Dummy = struct {
            fn run(_: *anyopaque) void {}
        };

        // Two ready lists + two blocked lists for queue-driven Kahn
        var ready_a = std.ArrayList(u32).init(pool.allocator);
        defer ready_a.deinit();
        var ready_b = std.ArrayList(u32).init(pool.allocator);
        defer ready_b.deinit();

        var blocked_a = std.ArrayList(u32).init(pool.allocator);
        defer blocked_a.deinit();
        var blocked_b = std.ArrayList(u32).init(pool.allocator);
        defer blocked_b.deinit();

        for (0..n) |i| {
            if (in_degree[i] == 0) {
                if (nodeBlocked(&plan.nodes[i], ctx)) {
                    blocked_a.append(@intCast(i)) catch {};
                } else {
                    ready_a.append(@intCast(i)) catch {};
                }
            }
        }

        var remaining: usize = n;
        var cur = &ready_a;
        var nxt = &ready_b;
        var blocked_cur = &blocked_a;
        var blocked_nxt = &blocked_b;

        // Exit when no ready nodes remain. Blocked nodes (temporal/barrier)
        // can't make progress this frame — blocking conditions are frame-invariant
        // and will be re-evaluated on the next submitFrame() call.
        while (cur.items.len > 0 and remaining > 0) {
            // Phase 1: submit CPU nodes, collect GPU indices
            var cpu_count: usize = 0;
            var gpu_count: usize = 0;
            for (cur.items) |idx| {
                const node = &plan.nodes[idx];
                switch (node.kind) {
                    .cpu => {
                        cpu_stubs[cpu_count] = Job{ .func = Dummy.run, .ctx = undefined, .priority = .Normal, .next = null };
                        pool.submit(&cpu_stubs[cpu_count]);
                        cpu_count += 1;
                    },
                    .gpu, .render => {
                        gpu_ready[gpu_count] = idx;
                        gpu_count += 1;
                    },
                    .barrier => {},
                }
            }

            // CPU wave completes before GPU wave of same level
            if (cpu_count > 0) {
                const t0 = @as(u64, @intCast(std.time.nanoTimestamp()));
                pool.waitAll();
                const t1 = @as(u64, @intCast(std.time.nanoTimestamp()));
                const wait_ns = t1 -| t0;
                var prev = pool.metrics.wave_wait_max_ns.load(.monotonic);
                while (wait_ns > prev) {
                    if (pool.metrics.wave_wait_max_ns.cmpxchgStrong(prev, wait_ns, .monotonic, .monotonic)) |actual| {
                        prev = actual;
                    } else break;
                }
                _ = pool.metrics.wave_wait_sum_ns.fetchAdd(wait_ns, .monotonic);
                _ = pool.metrics.wave_count.fetchAdd(1, .monotonic);
            }

            // Phase 2: submit GPU nodes
            for (0..gpu_count) |gi| {
                const idx = gpu_ready[gi];
                const node = &plan.nodes[idx];
                const job = switch (node.kind) {
                    .gpu => |g| g.job,
                    .render => |r| r.job,
                    else => continue,
                };
                if (pool.gpu_sched) |gs| gs.submit(job);
            }
            if (pool.gpu_sched) |gs| gs.tick();

            // Build next ready set from completed nodes (cur items)
            nxt.clearRetainingCapacity();
            blocked_nxt.clearRetainingCapacity();

            for (cur.items) |idx| {
                remaining -= 1;
                for (plan.edges) |e| {
                    if (e.from == idx and e.to < n and e.kind == .intra_frame) {
                        if (in_degree[e.to] > 0) in_degree[e.to] -= 1;
                        if (in_degree[e.to] == 0) {
                            if (nodeBlocked(&plan.nodes[e.to], ctx)) {
                                blocked_nxt.append(e.to) catch {};
                            } else {
                                nxt.append(e.to) catch {};
                            }
                        }
                    }
                }
            }

            // Recheck blocked nodes from previous wave
            for (blocked_cur.items) |idx| {
                if (nodeBlocked(&plan.nodes[idx], ctx)) {
                    blocked_nxt.append(idx) catch {};
                } else {
                    nxt.append(idx) catch {};
                }
            }

            // Swap ready and blocked lists
            const tmp_ready = cur;
            cur = nxt;
            nxt = tmp_ready;

            const tmp_blocked = blocked_cur;
            blocked_cur = blocked_nxt;
            blocked_nxt = tmp_blocked;
        }
    }

    fn buildDecisionContext(pool: *const WorkerPool, job: *const Job) DecisionContext {
        const sc = job.sticky_core orelse 0;
        const wid = sc % pool.count;
        const qlen = pool.workers[wid].local_q.approxLen();
        const state = if (pool.latency_profile) |lp|
            lp.updateVictimState(sc, qlen)
        else
            if (qlen < latency.MEDIUM_ENTER) latency.LoadState.normal else latency.LoadState.overload;
        return DecisionContext{
            .core_id = sc,
            .queue_len = qlen,
            .is_sticky = job.stickiness > 0,
            .load_state = state,
        };
    }

    fn localPolicy(pool: *const WorkerPool, ctx: *const DecisionContext, job: *const Job) Decision {
        _ = pool;
        if (ctx.load_state == .overload)
            return .balanced;
        if (ctx.is_sticky and job.sticky_core != null)
            return .prefer_affinity;
        return .balanced;
    }

    fn safetyOverride(pool: *const WorkerPool, ctx: *const DecisionContext, d: Decision) Decision {
        if (d != .prefer_affinity) return d;
        if (ctx.queue_len > pool.config.max_queue_len) {
            return .balanced;
        }
        return d;
    }

    fn applyGlobal(pool: *const WorkerPool, ctx: *const DecisionContext, d: Decision) Decision {
        _ = ctx;
        const gs = pool.global_state orelse return d;
        const load = &gs.last_system_load;
        if (load.imbalance_ratio > 3.0) {
            return .balanced;
        }
        if (load.imbalance_ratio > 2.0) {
            if (d == .prefer_affinity) {
                return .balanced;
            }
        }
        return d;
    }

    fn executeDecision(pool: *WorkerPool, job: *Job, ctx: *const DecisionContext, d: Decision) void {
        _ = ctx;
        switch (d) {
            .prefer_affinity => {
                _ = pool.metrics.sticky_honored.fetchAdd(1, .monotonic);
                const wid = (job.sticky_core orelse 0) % pool.count;
                assignToWorker(pool, job, wid);
            },
            .balanced => {
                pool.enqueueBalanced(job);
            },
        }
    }

    fn enqueueBalanced(pool: *WorkerPool, job: *Job) void {
        if (pool.latency_profile) |lp| {
            const preferred_node = lp.core_to_numa[0];
            if (preferred_node < pool.workers_for_node.len) {
                const workers = pool.workers_for_node[preferred_node];
                if (workers.len > 0) {
                    var best_wid = workers[0];
                    var best_load = pool.workers[best_wid].local_q.approxLen();
                    for (workers) |wid| {
                        const load = pool.workers[wid].local_q.approxLen();
                        if (load < best_load) {
                            best_load = load;
                            best_wid = wid;
                        }
                    }
                    assignToWorker(pool, job, best_wid);
                    return;
                }
            }
        }
        pool.shared_mutex.lock();
        const q = &pool.shared_queues[@intFromEnum(job.priority)];
        job.next = null;
        if (q.tail) |tail| {
            tail.next = job;
        } else {
            q.head = job;
        }
        q.tail = job;
        q.count += 1;
        _ = pool.pending.fetchAdd(1, .release);
        pool.shared_mutex.unlock();
        pool.worker_cond.signal();
    }

    pub fn submit(pool: *WorkerPool, job: *Job) void {
        job.submitted_at = @intCast(std.time.nanoTimestamp());
        const ctx = pool.buildDecisionContext(job);
        var d = pool.localPolicy(&ctx, job);
        d = pool.safetyOverride(&ctx, d);
        d = pool.applyGlobal(&ctx, d);
        pool.executeDecision(job, &ctx, d);
    }

    pub fn submitAffine(pool: *WorkerPool, job: *Job, target_core: u32) void {
        job.submitted_at = @intCast(std.time.nanoTimestamp());
        const wid = target_core % pool.count;
        if (pool.latency_profile != null) {
            if (pool.workers[wid].affinity) |aff| {
                if (aff.core_id == target_core) {
                    // Backpressure: if target core queue is deep, redistribute via balanced
                    if (pool.workers[wid].local_q.approxLen() >= pool.config.max_queue_len) {
                        pool.submit(job);
                        return;
                    }
                    assignToWorker(pool, job, wid);
                    return;
                }
            }
        }
        pool.submit(job);
    }

    pub fn submitBatch(pool: *WorkerPool, jobs: []*Job) void {
        const now: u64 = @intCast(std.time.nanoTimestamp());
        for (jobs) |job| {
            job.submitted_at = now;
        }
        pool.shared_mutex.lock();
        for (jobs) |job| {
            const q = &pool.shared_queues[@intFromEnum(job.priority)];
            job.next = null;
            if (q.tail) |tail| {
                tail.next = job;
            } else {
                q.head = job;
            }
            q.tail = job;
            q.count += 1;
        }
        _ = pool.pending.fetchAdd(@intCast(jobs.len), .release);
        pool.shared_mutex.unlock();
        pool.worker_cond.signal();
    }

    pub fn start(pool: *WorkerPool) !void {
        _ = pool.next_worker_id.store(0, .monotonic);
        for (pool.workers) |*w| {
            w.thread = try std.Thread.spawn(.{}, workerEntry, .{pool});
        }
    }

    /// Wait until all submitted jobs have completed (condition variable, no busy-wait).
    pub fn waitAll(pool: *WorkerPool) void {
        pool.completed_mutex.lock();
        defer pool.completed_mutex.unlock();
        while (pool.pending.load(.acquire) > 0) {
            pool.completed_cond.wait(&pool.completed_mutex);
        }
    }

    pub fn runningCount(pool: *const WorkerPool) u32 {
        return pool.count;
    }
};

fn workerEntry(pool: *WorkerPool) void {
    const id = pool.next_worker_id.fetchAdd(1, .monotonic);
    const me = &pool.workers[if (id < pool.count) id else 0];
    const my_core = if (me.affinity) |a| a.core_id else id;

    while (true) {
        // 1. Try local queue (FIFO — fair, no starvation)
        if (me.local_q.popFront()) |job| {
            _ = pool.metrics.local_pops.fetchAdd(1, .monotonic);
            executeAndComplete(pool, me, job);
            continue;
        }

        // 2. Steal from neighbors (front, non-blocking, cost-benefit)
        _ = pool.metrics.steal_attempts.fetchAdd(1, .monotonic);
        const start = (id + 1) % pool.count;
        var i: u32 = 0;
        while (i < pool.count - 1) : (i += 1) {
            const vid = (start + i) % pool.count;
            const victim = &pool.workers[vid];

            const vic_len = victim.local_q.approxLen();
            if (vic_len == 0) continue;

            // State machine: hysteresis prevents oscillation
            const vc = if (victim.affinity) |a| a.core_id else vid;
            const state = if (pool.latency_profile) |lp| blk: {
                break :blk lp.updateVictimState(vc, vic_len);
            } else latency.LoadState.overload;

            switch (state) {
                .normal => {
                    // Strict cost-benefit with adaptive threshold + sticky honored
                    if (pool.latency_profile) |lp| {
                        lp.recordStealAttempt(vc);
                        const cost = lp.score(my_core, vc, 0);
                        const benefit = @as(u64, vic_len) * latency.LOAD_PENALTY_PER_JOB;
                        const adaptive = lp.getAdaptiveThreshold(vc, cost);
                        if (benefit < adaptive) {
                            _ = pool.metrics.rejected_steals.fetchAdd(1, .monotonic);
                            continue;
                        }
                    }
                },
                .medium => {
                    // Relaxed: skip cost-benefit, still respect sticky + cooldown
                    if (pool.latency_profile) |lp| {
                        lp.recordStealAttempt(vc);
                    }
                },
                .overload => {
                    // Bypass all: no cost-benefit, no sticky, no cooldown
                },
            }

            if (victim.local_q.tryPopFront()) |job| {
                const is_sticky = job.stickiness > 0;
                if (is_sticky and state != .overload) {
                    const now: u64 = @intCast(std.time.nanoTimestamp());
                    const wait_ns = now -| job.submitted_at;
                    if (wait_ns > pool.config.max_sticky_ns) {
                        _ = pool.metrics.force_migrate_escape.fetchAdd(1, .monotonic);
                        _ = pool.metrics.steals.fetchAdd(1, .monotonic);
                        if (pool.latency_profile) |lp| {
                            const benefit = @as(u64, vic_len) * latency.LOAD_PENALTY_PER_JOB;
                            const cost = lp.score(my_core, vc, 0);
                            lp.recordSuccessfulSteal(vc, benefit, cost);
                        }
                        executeAndComplete(pool, me, job);
                        break;
                    }
                    victim.local_q.pushBack(job, pool.allocator);
                    _ = pool.metrics.rejected_steals.fetchAdd(1, .monotonic);
                    continue;
                }
                _ = pool.metrics.steals.fetchAdd(1, .monotonic);
                if (pool.latency_profile) |lp| {
                    const benefit = @as(u64, vic_len) * latency.LOAD_PENALTY_PER_JOB;
                    const cost = lp.score(my_core, vc, 0);
                    lp.recordSuccessfulSteal(vc, benefit, cost);
                    if (state == .overload or lp.canMigrate(my_core)) {
                        lp.recordMigration(vc, my_core);
                        _ = pool.metrics.migrations.fetchAdd(1, .monotonic);
                    }
                }
                executeAndComplete(pool, me, job);
                break;
            }
        } else {
            // No local, no steal — check shared queue
            pool.shared_mutex.lock();
            defer pool.shared_mutex.unlock();

            // Try to pop from shared queues (highest priority first)
            if (popSharedLocked(pool)) |job| {
                executeAndComplete(pool, me, job);
                continue;
            }

            // Nothing available — wait or exit
            if (pool.shutdown) return;
            pool.worker_cond.wait(&pool.shared_mutex);
            if (pool.shutdown) return;

            // Shared mutex is re-locked after wait. Try to pop again.
            if (popSharedLocked(pool)) |job| {
                executeAndComplete(pool, me, job);
                continue;
            }
        }
    }
}

fn popSharedLocked(pool: *WorkerPool) ?*Job {
    // Starvation protection: every bg_quota dispatches, force Background
    if (pool.dispatch_counter >= pool.bg_quota) {
        pool.dispatch_counter = 0;
        const bg = &pool.shared_queues[3];
        if (bg.head) |job| {
            bg.head = job.next;
            if (bg.head == null) bg.tail = null;
            bg.count -= 1;
            return job;
        }
    }
    // Normal priorities (0..2: Critical, High, Normal)
    for (0..3) |prio| {
        const q = &pool.shared_queues[prio];
        const job = q.head orelse continue;
        q.head = job.next;
        if (q.head == null) q.tail = null;
        q.count -= 1;
        pool.dispatch_counter += 1;
        return job;
    }
    // Background (when quota not forcing it)
    const bg = &pool.shared_queues[3];
    if (bg.head) |job| {
        bg.head = job.next;
        if (bg.head == null) bg.tail = null;
        bg.count -= 1;
        pool.dispatch_counter = 0;
        return job;
    }
    pool.dispatch_counter = 0;
    return null;
}

fn executeAndComplete(pool: *WorkerPool, me: *Worker, job: *Job) void {
    job.completed_before_start = me.jobs_completed.load(.monotonic);
    const wait_ns = @as(u64, @intCast(std.time.nanoTimestamp())) -| job.submitted_at;
    var prev = pool.metrics.queue_wait_max_ns.load(.monotonic);
    while (wait_ns > prev) {
        if (pool.metrics.queue_wait_max_ns.cmpxchgStrong(prev, wait_ns, .monotonic, .monotonic)) |actual| {
            prev = actual;
        } else break;
    }
    job.func(job.ctx);
    _ = me.jobs_completed.fetchAdd(1, .monotonic);
    const prev_pending = pool.pending.fetchSub(1, .release);
    if (prev_pending == 1) {
        pool.completed_mutex.lock();
        pool.completed_cond.broadcast();
        pool.completed_mutex.unlock();
    }
}

pub const CPUReservation = struct {
    reserve_absolute: u32,
    reserve_percent: u32,
    total_cores: u32,

    pub fn init(reserve_absolute: u32, reserve_percent: u32) CPUReservation {
        return CPUReservation{
            .reserve_absolute = reserve_absolute,
            .reserve_percent = reserve_percent,
            .total_cores = @intCast(std.Thread.getCpuCount() catch 1),
        };
    }

    pub fn availableCores(r: *const CPUReservation) u32 {
        if (r.reserve_absolute > 0) {
            const reserved = @min(r.reserve_absolute, r.total_cores -| 1);
            return r.total_cores - reserved;
        }
        if (r.reserve_percent > 0) {
            const reserved = @min((r.total_cores * r.reserve_percent) / 100, r.total_cores -| 1);
            return r.total_cores - reserved;
        }
        return r.total_cores;
    }
};

pub const Scheduler = struct {
    pool: ?WorkerPool,
    reservation: CPUReservation,
    allocator: std.mem.Allocator,

    pub fn initSync(reserve_absolute: u32, reserve_percent: u32) Scheduler {
        return Scheduler{
            .pool = null,
            .reservation = CPUReservation.init(reserve_absolute, reserve_percent),
            .allocator = undefined,
        };
    }

    pub fn initThreaded(s: *Scheduler, allocator: std.mem.Allocator, num_workers: u32, reserve_absolute: u32, reserve_percent: u32) !void {
        var wp: WorkerPool = undefined;
        try WorkerPool.init(&wp, allocator, num_workers);
        s.* = Scheduler{
            .pool = wp,
            .reservation = CPUReservation.init(reserve_absolute, reserve_percent),
            .allocator = allocator,
        };
    }

    pub fn initThreadedWithTopo(s: *Scheduler, allocator: std.mem.Allocator, num_workers: u32, reserve_absolute: u32, reserve_percent: u32, lp: *latency.LatencyProfile) !void {
        var wp: WorkerPool = undefined;
        try WorkerPool.initWithTopo(&wp, allocator, num_workers, lp);
        s.* = Scheduler{
            .pool = wp,
            .reservation = CPUReservation.init(reserve_absolute, reserve_percent),
            .allocator = allocator,
        };
    }

    pub fn deinit(s: *Scheduler) void {
        if (s.pool) |*p| p.deinit();
    }

    pub fn submit(s: *Scheduler, job: *Job) void {
        if (s.pool) |*p| {
            p.submit(job);
        } else {
            job.func(job.ctx);
        }
    }

    pub fn submitAffine(s: *Scheduler, job: *Job, target_core: u32) void {
        if (s.pool) |*p| {
            p.submitAffine(job, target_core);
        } else {
            job.func(job.ctx);
        }
    }

    pub fn submitBatch(s: *Scheduler, jobs: []*Job) void {
        if (s.pool) |*p| {
            p.submitBatch(jobs);
        } else {
            for (jobs) |job| job.func(job.ctx);
        }
    }

    pub fn start(s: *Scheduler) !void {
        if (s.pool) |*p| try p.start();
    }

    pub fn waitAll(s: *Scheduler) void {
        if (s.pool) |*p| p.waitAll();
    }

    pub fn logicalCores() u32 {
        return @intCast(std.Thread.getCpuCount() catch 1);
    }

    pub fn workingCount(s: *const Scheduler) u32 {
        if (s.pool) |p| return p.runningCount();
        return 1;
    }

    pub fn setPoolConfig(s: *Scheduler, cfg: sched_config.SchedulerConfig) void {
        if (s.pool) |*p| p.setConfig(cfg);
    }

    pub fn setPoolGlobalState(s: *Scheduler, gs: *sched_state.GlobalSchedulerState) void {
        if (s.pool) |*p| p.setGlobalState(gs);
    }

    pub fn setPoolGPUScheduler(s: *Scheduler, gs: *gpu_sched_mod.GPUScheduler) void {
        if (s.pool) |*p| p.setGPUScheduler(gs);
    }

    pub fn submitJob(s: *Scheduler, uj: UnifiedJob) void {
        if (s.pool) |*p| {
            p.submitJob(uj);
        } else {
            switch (uj) {
                .cpu => |j| j.func(j.ctx),
                .gpu => {},
            }
        }
    }

    pub fn submitFrame(s: *Scheduler, plan: *const frame_graph.ExecutionPlan, ctx: *const frame_graph.FrameContext) void {
        if (s.pool) |*p| {
            p.submitFrame(plan, ctx);
        }
    }
};
