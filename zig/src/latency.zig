const std = @import("std");
const cpu = @import("cpu.zig");

const HT_COST_NS: u64 = 50;
const CORE_COST_NS: u64 = 200;
const NUMA_COST_NS: u64 = 1000;
const NUMA_PENALTY_NS: u64 = 800;
pub const LOAD_PENALTY_PER_JOB: u64 = 100;
const CACHE_DISTANCE_SCALE: u64 = 50;
const MIGRATION_LOG_CAPACITY: u32 = 1024;

pub const LoadState = enum(u8) {
    normal = 0,
    medium = 1,
    overload = 2,

    pub fn transition(current: LoadState, load: u32) LoadState {
        return switch (current) {
            .normal => if (load >= MEDIUM_ENTER) .medium else .normal,
            .medium => if (load >= OVERLOAD_ENTER) .overload else if (load <= MEDIUM_EXIT) .normal else .medium,
            .overload => if (load <= OVERLOAD_EXIT) .medium else .overload,
        };
    }
};

pub const MEDIUM_ENTER: u32 = 4;
const MEDIUM_EXIT: u32 = 2;
pub const OVERLOAD_ENTER: u32 = 8;
const OVERLOAD_EXIT: u32 = 5;

pub const WorkerAffinity = struct {
    core_id: u32,
    numa_node: u32,
    cache_level: u8,
    allowed_mask: u64,
};

pub const MigrationEvent = struct {
    from_core: u32,
    to_core: u32,
    cost_ns: u64,
    timestamp: u64,
};

const MigrationLog = struct {
    events: [MIGRATION_LOG_CAPACITY]MigrationEvent,
    count: std.atomic.Value(u32),
    cursor: std.atomic.Value(u32),

    fn init() MigrationLog {
        return MigrationLog{
            .events = undefined,
            .count = std.atomic.Value(u32).init(0),
            .cursor = std.atomic.Value(u32).init(0),
        };
    }

    fn push(l: *MigrationLog, event: MigrationEvent) void {
        const pos = l.cursor.fetchAdd(1, .monotonic) % MIGRATION_LOG_CAPACITY;
        l.events[pos] = event;
        _ = l.count.fetchAdd(1, .release);
    }

    fn recent(l: *const MigrationLog) []const MigrationEvent {
        const total = @min(l.count.load(.acquire), MIGRATION_LOG_CAPACITY);
        return l.events[0..total];
    }
};

const Matrix = struct {
    rows: [][]u64,
    buf: []u64,
    n: u32,

    fn init(allocator: std.mem.Allocator, n: u32) !Matrix {
        const rows = try allocator.alloc([]u64, n);
        errdefer allocator.free(rows);
        const buf = try allocator.alloc(u64, n * n);
        errdefer allocator.free(buf);
        @memset(buf, 0);
        for (0..n) |i| rows[i] = buf[i * n ..][0..n];
        return Matrix{ .rows = rows, .buf = buf, .n = n };
    }

    fn deinit(m: *Matrix, allocator: std.mem.Allocator) void {
        allocator.free(m.rows);
        allocator.free(m.buf);
    }
};

const DistMatrix = struct {
    rows: [][]u8,
    buf: []u8,
    n: u32,

    fn init(allocator: std.mem.Allocator, n: u32) !DistMatrix {
        const rows = try allocator.alloc([]u8, n);
        errdefer allocator.free(rows);
        const buf = try allocator.alloc(u8, n * n);
        errdefer allocator.free(buf);
        @memset(buf, 0);
        for (0..n) |i| rows[i] = buf[i * n ..][0..n];
        return DistMatrix{ .rows = rows, .buf = buf, .n = n };
    }

    fn deinit(m: *DistMatrix, allocator: std.mem.Allocator) void {
        allocator.free(m.rows);
        allocator.free(m.buf);
    }
};

pub const CoreStats = struct {
    steal_attempts: std.atomic.Value(u64),
    successful_steals: std.atomic.Value(u64),
    avg_cost: std.atomic.Value(u64),
    avg_benefit: std.atomic.Value(u64),
    load_state: std.atomic.Value(u8),
    smoothed_load: std.atomic.Value(u64),

    pub fn init() CoreStats {
        return CoreStats{
            .steal_attempts = std.atomic.Value(u64).init(0),
            .successful_steals = std.atomic.Value(u64).init(0),
            .avg_cost = std.atomic.Value(u64).init(0),
            .avg_benefit = std.atomic.Value(u64).init(0),
            .load_state = std.atomic.Value(u8).init(0),
            .smoothed_load = std.atomic.Value(u64).init(0),
        };
    }

    const LOAD_EMA_SHIFT: u6 = 3; // α = 1/8

    pub fn updateLoadState(stats: *CoreStats, vic_len: u32) LoadState {
        // EMA smooth the load snapshot
        const raw = stats.smoothed_load.load(.monotonic);
        const smoothed = raw - (raw >> LOAD_EMA_SHIFT) + (vic_len >> LOAD_EMA_SHIFT);
        stats.smoothed_load.store(smoothed, .monotonic);

        const current_u8 = stats.load_state.load(.monotonic);
        const current = @as(LoadState, @enumFromInt(current_u8));
        const next = LoadState.transition(current, @as(u32, @intCast(smoothed)));
        const next_u8 = @intFromEnum(next);
        if (next_u8 != current_u8) {
            stats.load_state.store(next_u8, .monotonic);
        }
        return next;
    }

    fn emaUpdate(current: u64, sample: u64) u64 {
        // alpha = 1/16
        return current - (current >> 4) + (sample >> 4);
    }
};

pub const LatencyProfile = struct {
    migration_cost_ns: Matrix,
    numa_penalty_ns: Matrix,
    cache_distance: DistMatrix,
    core_to_numa: []u32,
    worker_affinities: []WorkerAffinity,
    workers_for_node: [][]u32,
    numa_count: u32,
    migration_log: MigrationLog,
    migration_cooldown_ns: u64,
    last_migration_time: []u64,
    core_stats: []CoreStats,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, topo: *const cpu.CpuTopology) !LatencyProfile {
        const n = topo.logical_cores;
        const numa_count = @as(u32, @intCast(topo.numa_nodes.len));

        var cost = try Matrix.init(allocator, n);
        errdefer cost.deinit(allocator);

        var penalty = try Matrix.init(allocator, numa_count);
        errdefer penalty.deinit(allocator);

        var dist = try DistMatrix.init(allocator, n);
        errdefer dist.deinit(allocator);

        const core_to_numa = try allocator.alloc(u32, n);
        errdefer allocator.free(core_to_numa);

        if (numa_count == 1) {
            @memset(core_to_numa, 0);
        } else {
            var core_idx: u32 = 0;
            for (0..numa_count) |nid| {
                const end: u32 = if (nid == numa_count - 1) n else core_idx + n / numa_count;
                while (core_idx < end) : (core_idx += 1) {
                    core_to_numa[core_idx] = @intCast(nid);
                }
            }
        }

        buildMatrices(n, numa_count, topo.logical_to_physical, core_to_numa, &cost, &penalty, &dist);

        const affinities = try allocator.alloc(WorkerAffinity, n);
        errdefer allocator.free(affinities);
        for (0..n) |i| {
            affinities[i] = WorkerAffinity{
                .core_id = @intCast(i),
                .numa_node = core_to_numa[i],
                .cache_level = detectCacheLevel(@intCast(i), n, topo),
                .allowed_mask = @as(u64, 1) << @as(u6, @intCast(i)),
            };
        }

        const wfn = try allocator.alloc([]u32, numa_count);
        errdefer allocator.free(wfn);
        for (0..numa_count) |nid| {
            var count: u32 = 0;
            for (0..n) |i| {
                if (core_to_numa[i] == nid) count += 1;
            }
            const slice = try allocator.alloc(u32, count);
            var idx: u32 = 0;
            for (0..n) |i| {
                if (core_to_numa[i] == nid) {
                    slice[idx] = @intCast(i);
                    idx += 1;
                }
            }
            wfn[nid] = slice;
        }

        const last_mig = try allocator.alloc(u64, n);
        errdefer allocator.free(last_mig);
        @memset(last_mig, 0);

        const stats = try allocator.alloc(CoreStats, n);
        errdefer allocator.free(stats);
        for (0..n) |i| stats[i] = CoreStats.init();

        return LatencyProfile{
            .migration_cost_ns = cost,
            .numa_penalty_ns = penalty,
            .cache_distance = dist,
            .core_to_numa = core_to_numa,
            .worker_affinities = affinities,
            .workers_for_node = wfn,
            .numa_count = numa_count,
            .migration_log = MigrationLog.init(),
            .migration_cooldown_ns = 50_000_000,
            .last_migration_time = last_mig,
            .core_stats = stats,
            .allocator = allocator,
        };
    }

    pub fn deinit(lp: *LatencyProfile) void {
        lp.migration_cost_ns.deinit(lp.allocator);
        lp.numa_penalty_ns.deinit(lp.allocator);
        lp.cache_distance.deinit(lp.allocator);
        lp.allocator.free(lp.core_to_numa);
        lp.allocator.free(lp.worker_affinities);
        for (lp.workers_for_node) |slice| lp.allocator.free(slice);
        lp.allocator.free(lp.workers_for_node);
        lp.allocator.free(lp.last_migration_time);
        lp.allocator.free(lp.core_stats);
    }

    pub fn score(
        lp: *const LatencyProfile,
        current_core: u32,
        target_core: u32,
        target_load: u32,
    ) u64 {
        const cur_node = lp.core_to_numa[current_core];
        const tgt_node = lp.core_to_numa[target_core];
        const node_pen = if (cur_node != tgt_node)
            lp.numa_penalty_ns.buf[cur_node * lp.numa_count + tgt_node]
        else
            0;
        return
            @as(u64, target_load) * LOAD_PENALTY_PER_JOB +
            lp.migration_cost_ns.buf[current_core * lp.logicalCoreCount() + target_core] +
            @as(u64, lp.cache_distance.buf[current_core * lp.logicalCoreCount() + target_core]) * CACHE_DISTANCE_SCALE +
            node_pen;
    }

    pub fn logicalCoreCount(lp: *const LatencyProfile) u32 {
        return @as(u32, @intCast(lp.migration_cost_ns.n));
    }

    pub fn getPreferredNode(lp: *const LatencyProfile, core: u32) u32 {
        return lp.core_to_numa[core];
    }

    pub fn recordMigration(lp: *LatencyProfile, from_core: u32, to_core: u32) void {
        const cost = lp.migration_cost_ns.buf[from_core * lp.logicalCoreCount() + to_core];
        const now: u64 = @intCast(std.time.nanoTimestamp());
        lp.last_migration_time[to_core] = now;
        lp.migration_log.push(MigrationEvent{
            .from_core = from_core,
            .to_core = to_core,
            .cost_ns = cost,
            .timestamp = now,
        });
    }

    pub fn canMigrate(lp: *const LatencyProfile, target_core: u32) bool {
        if (lp.migration_cooldown_ns == 0) return true;
        const last = lp.last_migration_time[target_core];
        if (last == 0) return true;
        const now: u64 = @intCast(std.time.nanoTimestamp());
        return (now -| last) >= lp.migration_cooldown_ns;
    }

    pub fn migrationCount(lp: *const LatencyProfile) u32 {
        return lp.migration_log.count.load(.acquire);
    }

    pub fn recentMigrations(lp: *const LatencyProfile) []const MigrationEvent {
        return lp.migration_log.recent();
    }

    pub fn recordStealAttempt(lp: *LatencyProfile, core: u32) void {
        _ = lp.core_stats[core].steal_attempts.fetchAdd(1, .monotonic);
    }

    pub fn recordSuccessfulSteal(lp: *LatencyProfile, core: u32, benefit: u64, cost: u64) void {
        _ = lp.core_stats[core].successful_steals.fetchAdd(1, .monotonic);
        // EMA update for avg_cost and avg_benefit
        var current = lp.core_stats[core].avg_cost.load(.monotonic);
        var new_val = CoreStats.emaUpdate(current, cost);
        _ = lp.core_stats[core].avg_cost.swap(new_val, .monotonic);

        current = lp.core_stats[core].avg_benefit.load(.monotonic);
        new_val = CoreStats.emaUpdate(current, benefit);
        _ = lp.core_stats[core].avg_benefit.swap(new_val, .monotonic);
    }

    pub fn getAdaptiveThreshold(lp: *const LatencyProfile, core: u32, current_cost: u64) u64 {
        const stats = &lp.core_stats[core];
        const attempts = stats.steal_attempts.load(.acquire);
        if (attempts < 4) return current_cost *| 2; // not enough data, use old 2x rule
        const succ = stats.successful_steals.load(.acquire);
        const avg_cost = stats.avg_cost.load(.acquire);
        if (avg_cost == 0) return current_cost *| 2;
        const fail_ratio = (attempts - succ) * 64 / attempts; // fixed-point: 64 = 1.0
        // threshold = avg_cost + avg_cost * fail_ratio / 2
        // In fixed-point: threshold = avg_cost + (avg_cost * fail_ratio) / 128
        const bonus = (avg_cost * fail_ratio) / 128;
        return avg_cost + bonus;
    }

    pub fn updateVictimState(lp: *LatencyProfile, victim_core: u32, vic_len: u32) LoadState {
        return CoreStats.updateLoadState(&lp.core_stats[victim_core], vic_len);
    }

    pub fn victimLoadState(lp: *const LatencyProfile, victim_core: u32) LoadState {
        return @as(LoadState, @enumFromInt(lp.core_stats[victim_core].load_state.load(.acquire)));
    }
};

fn buildMatrices(
    n: u32,
    numa_count: u32,
    logical_to_physical: []const u32,
    core_to_numa: []const u32,
    cost: *Matrix,
    penalty: *Matrix,
    dist: *DistMatrix,
) void {
    for (0..numa_count) |a| {
        penalty.buf[a * numa_count + a] = 0;
        for (a + 1..numa_count) |b| {
            penalty.buf[a * numa_count + b] = NUMA_PENALTY_NS;
            penalty.buf[b * numa_count + a] = NUMA_PENALTY_NS;
        }
    }

    for (0..n) |i| {
        cost.buf[i * n + i] = 0;
        dist.buf[i * n + i] = 0;
        for (i + 1..n) |j| {
            const same_phys = logical_to_physical[i] == logical_to_physical[j];
            const same_numa = core_to_numa[i] == core_to_numa[j];
            if (same_phys) {
                cost.buf[i * n + j] = HT_COST_NS;
                cost.buf[j * n + i] = HT_COST_NS;
                dist.buf[i * n + j] = 1;
                dist.buf[j * n + i] = 1;
            } else if (same_numa) {
                cost.buf[i * n + j] = CORE_COST_NS;
                cost.buf[j * n + i] = CORE_COST_NS;
                dist.buf[i * n + j] = 3;
                dist.buf[j * n + i] = 3;
            } else {
                cost.buf[i * n + j] = NUMA_COST_NS;
                cost.buf[j * n + i] = NUMA_COST_NS;
                dist.buf[i * n + j] = 5;
                dist.buf[j * n + i] = 5;
            }
        }
    }
}

fn detectCacheLevel(core: u32, total_cores: u32, topo: *const cpu.CpuTopology) u8 {
    _ = core;
    _ = total_cores;
    return if (topo.class == .tiny) 1 else if (topo.class == .pc) 2 else 3;
}

test "LatencyProfile builds from topology" {
    const topo = try cpu.CpuTopology.detect(std.testing.allocator);
    defer topo.deinit();

    var lp = try LatencyProfile.init(std.testing.allocator, &topo);
    defer lp.deinit();

    const n = lp.logicalCoreCount();
    try std.testing.expect(n > 0);
    try std.testing.expectEqual(n, topo.logical_cores);

    // Same core = zero cost, zero distance
    try std.testing.expectEqual(@as(u64, 0), lp.migration_cost_ns.buf[0 * n + 0]);
    try std.testing.expectEqual(@as(u8, 0), lp.cache_distance.buf[0 * n + 0]);

    // HT sibling should have low cost
    if (topo.has_hyperthreading) {
        for (1..n) |j| {
            if (topo.logical_to_physical[0] == topo.logical_to_physical[j]) {
                try std.testing.expectEqual(@as(u64, HT_COST_NS), lp.migration_cost_ns.buf[0 * n + j]);
                try std.testing.expectEqual(@as(u8, 1), lp.cache_distance.buf[0 * n + j]);
                break;
            }
        }
    }

    // NUMA diagonal is zero
    try std.testing.expectEqual(@as(u64, 0), lp.numa_penalty_ns.buf[0 * lp.numa_count + 0]);

    // Worker affinities match core count
    try std.testing.expectEqual(n, @as(u32, @intCast(lp.worker_affinities.len)));

    // Score: same core should be just load * LOAD_PENALTY
    try std.testing.expectEqual(@as(u64, 0), lp.score(0, 0, 0));
    try std.testing.expectEqual(LOAD_PENALTY_PER_JOB * 5, lp.score(0, 0, 5));

    // Migration log starts empty
    try std.testing.expectEqual(@as(u32, 0), lp.migrationCount());

    // Record a migration
    lp.recordMigration(0, 1);
    try std.testing.expectEqual(@as(u32, 1), lp.migrationCount());
}

test "NUMA-aware preferred node" {
    const topo = try cpu.CpuTopology.detect(std.testing.allocator);
    defer topo.deinit();

    var lp = try LatencyProfile.init(std.testing.allocator, &topo);
    defer lp.deinit();

    const n = lp.logicalCoreCount();
    // getPreferredNode should return node 0 for all cores on single-NUMA system
    for (0..n) |i| {
        try std.testing.expectEqual(@as(u32, 0), lp.getPreferredNode(@intCast(i)));
    }
}

test "Cross-NUMA penalty when multiple nodes" {
    const topo = try cpu.CpuTopology.detect(std.testing.allocator);
    defer topo.deinit();

    var lp = try LatencyProfile.init(std.testing.allocator, &topo);
    defer lp.deinit();

    if (lp.numa_count > 1) {
        try std.testing.expect(lp.numa_penalty_ns.buf[0 * lp.numa_count + 1] > 0);
        try std.testing.expect(lp.score(0, lp.logicalCoreCount() / 2, 0) > 0);
    }
}

test "Migration log capacity" {
    const topo = try cpu.CpuTopology.detect(std.testing.allocator);
    defer topo.deinit();

    var lp = try LatencyProfile.init(std.testing.allocator, &topo);
    defer lp.deinit();

    // Fill past capacity
    for (0..MIGRATION_LOG_CAPACITY + 50) |i| {
        lp.recordMigration(0, @intCast((i + 1) % lp.logicalCoreCount()));
    }

    const count = lp.migrationCount();
    try std.testing.expect(count >= MIGRATION_LOG_CAPACITY);
    // The recent() should return at most MIGRATION_LOG_CAPACITY entries
    try std.testing.expect(lp.recentMigrations().len <= MIGRATION_LOG_CAPACITY);
}

test "Score monotonic with load" {
    const topo = try cpu.CpuTopology.detect(std.testing.allocator);
    defer topo.deinit();

    var lp = try LatencyProfile.init(std.testing.allocator, &topo);
    defer lp.deinit();

    const s0 = lp.score(0, 1, 0);
    const s1 = lp.score(0, 1, 10);
    const s2 = lp.score(0, 1, 100);

    try std.testing.expect(s1 > s0);
    try std.testing.expect(s2 > s1);
}
