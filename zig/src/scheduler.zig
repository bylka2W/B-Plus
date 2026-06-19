const std = @import("std");
const latency = @import("latency.zig");

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

pub const Metrics = struct {
    migrations: std.atomic.Value(u64),
    steals: std.atomic.Value(u64),
    rejected_steals: std.atomic.Value(u64),
    sticky_honored: std.atomic.Value(u64),

    pub fn init() Metrics {
        return Metrics{
            .migrations = std.atomic.Value(u64).init(0),
            .steals = std.atomic.Value(u64).init(0),
            .rejected_steals = std.atomic.Value(u64).init(0),
            .sticky_honored = std.atomic.Value(u64).init(0),
        };
    }
};

const Worker = struct {
    thread: ?std.Thread,
    id: u32,
    local_q: WorkerQueue,
    affinity: ?latency.WorkerAffinity,
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
        pool.workers[wid].local_q.pushBack(job, pool.allocator);
        _ = pool.pending.fetchAdd(1, .release);
        pool.worker_cond.signal();
    }

    pub fn submit(pool: *WorkerPool, job: *Job) void {
        // Sticky core: honour if load permits (state machine)
        if (job.sticky_core) |sc| {
            const wid = sc % pool.count;
            const vic_len = pool.workers[wid].local_q.approxLen();
            const state = if (pool.latency_profile) |lp|
                lp.updateVictimState(sc, vic_len)
            else
                if (vic_len < latency.MEDIUM_ENTER) latency.LoadState.normal else latency.LoadState.overload;
            if (state != .overload) {
                _ = pool.metrics.sticky_honored.fetchAdd(1, .monotonic);
                assignToWorker(pool, job, wid);
                return;
            }
        }
        // NUMA-aware fallback: pick least-loaded worker on the node
        if (pool.latency_profile) |lp| {
            const preferred_node = lp.core_to_numa[0];
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
        // Shared queue
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

    pub fn submitAffine(pool: *WorkerPool, job: *Job, target_core: u32) void {
        const wid = target_core % pool.count;
        if (pool.latency_profile != null) {
            if (pool.workers[wid].affinity) |aff| {
                if (aff.core_id == target_core) {
                    assignToWorker(pool, job, wid);
                    return;
                }
            }
        }
        pool.submit(job);
    }

    pub fn submitBatch(pool: *WorkerPool, jobs: []*Job) void {
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
        // 1. Try local queue (LIFO — own tasks)
        if (me.local_q.popBack()) |job| {
            executeAndComplete(pool, job);
            continue;
        }

        // 2. Steal from neighbors (front, non-blocking, cost-benefit)
        const start = (id + 1) % pool.count;
        var i: u32 = 0;
        while (i < pool.count - 1) : (i += 1) {
            const vid = (start + i) % pool.count;
            const victim = &pool.workers[vid];

            const vic_len = victim.local_q.approxLen();
            if (vic_len == 0) continue;

            // State machine: hysteresis prevents oscillation
            const state = if (pool.latency_profile) |lp| blk: {
                const vic_core = if (victim.affinity) |a| a.core_id else vid;
                break :blk lp.updateVictimState(vic_core, vic_len);
            } else latency.LoadState.overload;

            switch (state) {
                .normal => {
                    // Strict cost-benefit with adaptive threshold + sticky honored
                    if (pool.latency_profile) |lp| {
                        const vic_core = if (victim.affinity) |a| a.core_id else vid;
                        lp.recordStealAttempt(vic_core);
                        const cost = lp.score(my_core, vic_core, 0);
                        const benefit = @as(u64, vic_len) * latency.LOAD_PENALTY_PER_JOB;
                        const adaptive = lp.getAdaptiveThreshold(vic_core, cost);
                        if (benefit < adaptive) {
                            _ = pool.metrics.rejected_steals.fetchAdd(1, .monotonic);
                            continue;
                        }
                    }
                },
                .medium => {
                    // Relaxed: skip cost-benefit, still respect sticky + cooldown
                    if (pool.latency_profile) |lp| {
                        const vic_core = if (victim.affinity) |a| a.core_id else vid;
                        lp.recordStealAttempt(vic_core);
                    }
                },
                .overload => {
                    // Bypass all: no cost-benefit, no sticky, no cooldown
                },
            }

            if (victim.local_q.tryPopFront()) |job| {
                const is_sticky = job.stickiness > 0;
                if (is_sticky and state != .overload) {
                    victim.local_q.pushBack(job, pool.allocator);
                    _ = pool.metrics.rejected_steals.fetchAdd(1, .monotonic);
                    continue;
                }
                _ = pool.metrics.steals.fetchAdd(1, .monotonic);
                if (pool.latency_profile) |lp| {
                    const vic_core = if (victim.affinity) |a| a.core_id else vid;
                    const benefit = @as(u64, vic_len) * latency.LOAD_PENALTY_PER_JOB;
                    const cost = lp.score(my_core, vic_core, 0);
                    lp.recordSuccessfulSteal(vic_core, benefit, cost);
                    if (state == .overload or lp.canMigrate(my_core)) {
                        lp.recordMigration(vic_core, my_core);
                        _ = pool.metrics.migrations.fetchAdd(1, .monotonic);
                    }
                }
                executeAndComplete(pool, job);
                break;
            }
        } else {
            // No local, no steal — check shared queue
            pool.shared_mutex.lock();
            defer pool.shared_mutex.unlock();

            // Try to pop from shared queues (highest priority first)
            if (popSharedLocked(pool)) |job| {
                executeAndComplete(pool, job);
                continue;
            }

            // Nothing available — wait or exit
            if (pool.shutdown) return;
            pool.worker_cond.wait(&pool.shared_mutex);
            if (pool.shutdown) return;

            // Shared mutex is re-locked after wait. Try to pop again.
            if (popSharedLocked(pool)) |job| {
                executeAndComplete(pool, job);
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

fn executeAndComplete(pool: *WorkerPool, job: *Job) void {
    job.func(job.ctx);
    const prev = pool.pending.fetchSub(1, .release);
    if (prev == 1) {
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
};
