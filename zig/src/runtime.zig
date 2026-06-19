const std = @import("std");
const windows = std.os.windows;

// ═══════════════════════════════════════════════════════════════════
// 1. Panic Runtime
// ═══════════════════════════════════════════════════════════════════

pub const PanicCode = enum(u8) {
    INVALID_HANDLE,
    INVALID_TIER,
};

fn panicRuntime(code: PanicCode) noreturn {
    const msg = switch (code) {
        .INVALID_HANDLE => "PANIC: INVALID_HANDLE",
        .INVALID_TIER => "PANIC: INVALID_TIER",
    };
    std.log.err("{s}", .{msg});
    std.process.exit(1);
}

/// Assert an invariant at runtime. NOT exported — only used inside the 3 validation functions.
fn assertInvariant(cond: bool, code: PanicCode) void {
    if (!cond) panicRuntime(code);
}

// ═══════════════════════════════════════════════════════════════════
// 2. Tier FSM — L1 = hottest, DISK = coldest
// ═══════════════════════════════════════════════════════════════════

pub const Tier = enum(u8) {
    L1 = 0,
    L2 = 1,
    L3 = 2,
    DISK = 3,

    pub fn moveColder(current: Tier) ?Tier {
        return switch (current) {
            .L1 => .L2,
            .L2 => .L3,
            .L3 => null,
            .DISK => null,
        };
    }

    pub fn moveHotter(current: Tier) ?Tier {
        return switch (current) {
            .L1 => null,
            .L2 => .L1,
            .L3 => .L2,
            .DISK => .L3,
        };
    }

    pub fn isValidTransition(from: Tier, to: Tier) bool {
        return switch (from) {
            .L1 => to == .L2,
            .L2 => to == .L1 or to == .L3,
            .L3 => to == .L2 or to == .DISK,
            .DISK => to == .L3,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════
// 3. Handle & Metadata (SoA, flat arrays)
// ═══════════════════════════════════════════════════════════════════

pub const SlotState = enum(u8) {
    Free = 0,
    Used = 1,
};

pub const Handle = struct {
    slot: u32,
    generation: u32,

    pub fn invalid() Handle {
        return .{ .slot = 0xFFFFFFFF, .generation = 0 };
    }

    pub fn isValid(h: Handle) bool {
        return h.slot != 0xFFFFFFFF;
    }
};

pub const HANDLE_INVALID: u32 = 0xFFFFFFFF;

/// Metadata stored as Struct-of-Arrays.
/// Tier is NOT stored — it is derived from which Arena contains the pointer.
pub const MetaStore = struct {
    ptrs: []?*anyopaque,
    generations: []u32,
    sizes: []u32,
    states: []SlotState,
    free_next: []u32,
    heats: []u32,
    total_heats: []u32,

    pub fn init(
        ptrs_buf: []?*anyopaque,
        gen_buf: []u32,
        size_buf: []u32,
        state_buf: []SlotState,
        free_buf: []u32,
        heat_buf: []u32,
        total_heat_buf: []u32,
    ) MetaStore {
        const cap = ptrs_buf.len;
        @memset(ptrs_buf, null);
        @memset(gen_buf, 0);
        @memset(size_buf, 0);
        @memset(state_buf, .Free);
        @memset(heat_buf, 0);
        @memset(total_heat_buf, 0);
        var i: u32 = 0;
        while (i < cap) : (i += 1) {
            free_buf[i] = i + 1; // intrusive free list
        }
        return .{
            .ptrs = ptrs_buf,
            .generations = gen_buf,
            .sizes = size_buf,
            .states = state_buf,
            .free_next = free_buf,
            .heats = heat_buf,
            .total_heats = total_heat_buf,
        };
    }

    pub fn capacity(ms: *const MetaStore) u32 {
        return @intCast(ms.ptrs.len);
    }
};

/// HandleTable = source of truth.
/// Arena is a dumb byte provider. Tier is derived from pointer address.
pub const HandleTable = struct {
    meta: MetaStore,
    free_head: u32,
    count: u32,

    pub fn init(store: MetaStore) HandleTable {
        return .{
            .meta = store,
            .free_head = 0,
            .count = 0,
        };
    }

    pub fn capacity(ht: *const HandleTable) u32 {
        return ht.meta.capacity();
    }

    // ── 3 validation functions — ONLY entry points for invariant checks ──

    /// Validate that a handle is internally consistent:
    /// slot in range, slot is Used, generation matches.
    pub fn validateHandle(ht: *const HandleTable, handle: Handle) void {
        assertInvariant(handle.isValid(), .INVALID_HANDLE);
        assertInvariant(handle.slot < ht.capacity(), .INVALID_HANDLE);
        assertInvariant(ht.meta.states[handle.slot] == .Used, .INVALID_HANDLE);
        assertInvariant(ht.meta.generations[handle.slot] == handle.generation, .INVALID_HANDLE);
    }

    /// Validate handle + pointer consistency (ptr must be non-null).
    pub fn validateAccess(ht: *const HandleTable, handle: Handle) void {
        validateHandle(ht, handle);
        assertInvariant(ht.meta.ptrs[handle.slot] != null, .INVALID_HANDLE);
    }

    // ── Operations ──

    /// O(1) alloc from free list.
    pub fn alloc(ht: *HandleTable, ptr: ?*anyopaque, size: u32) Handle {
        const cap = ht.capacity();
        const slot = ht.free_head;
        // precondition: free_head is valid
        if (slot >= cap) unreachable;
        if (ht.meta.states[slot] != .Free) unreachable;

        ht.free_head = ht.meta.free_next[slot];
        const next_gen = ht.meta.generations[slot] +% 1;
        const gen: u32 = if (next_gen == 0) 1 else next_gen;

        ht.meta.ptrs[slot] = ptr;
        ht.meta.generations[slot] = gen;
        ht.meta.sizes[slot] = size;
        ht.meta.states[slot] = .Used;
        ht.meta.heats[slot] = 0;
        ht.count += 1;
        return .{ .slot = slot, .generation = gen };
    }

    /// O(1) release: push slot back to free list.
    pub fn release(ht: *HandleTable, handle: Handle) void {
        validateHandle(ht, handle);
        const slot = handle.slot;
        ht.meta.ptrs[slot] = null;
        ht.meta.states[slot] = .Free;
        ht.meta.sizes[slot] = 0;
        ht.meta.heats[slot] = 0;
        ht.meta.free_next[slot] = ht.free_head;
        ht.free_head = slot;
        ht.count -= 1;
    }

    /// Invalidate a single slot (used on arena reset).
    /// Generation INCREMENTS so old handles stay invalid.
    pub fn invalidateSlot(ht: *HandleTable, slot: u32) void {
        if (slot >= ht.capacity()) return;
        if (ht.meta.states[slot] != .Used) return;
        const next_gen = ht.meta.generations[slot] +% 1;
        ht.meta.generations[slot] = if (next_gen == 0) 1 else next_gen;
        ht.meta.ptrs[slot] = null;
        ht.meta.states[slot] = .Free;
        ht.meta.sizes[slot] = 0;
        ht.meta.heats[slot] = 0;
        ht.meta.free_next[slot] = ht.free_head;
        ht.free_head = slot;
        ht.count -= 1;
    }

    /// Access handle payload. Returns `[]u8` for the stored size.
    pub fn access(ht: *const HandleTable, handle: Handle) []u8 {
        validateAccess(ht, handle);
        const slot = handle.slot;
        const size = ht.meta.sizes[slot];
        return @as([*]u8, @ptrCast(ht.meta.ptrs[slot].?))[0..size];
    }

    pub fn touch(ht: *HandleTable, handle: Handle) void {
        validateHandle(ht, handle);
        const slot = handle.slot;
        const h = &ht.meta.heats[slot];
        if (h.* < std.math.maxInt(u32)) h.* += 1;
        const th = &ht.meta.total_heats[slot];
        if (th.* < std.math.maxInt(u32)) th.* += 1;
    }
};

// ═══════════════════════════════════════════════════════════════════
// 4. Arena Allocator (bounds-checked bump, integer arith)
// ═══════════════════════════════════════════════════════════════════

pub const Arena = struct {
    base_addr: usize,
    cursor_addr: usize,
    end_addr: usize,

    pub fn init(buf: []u8) Arena {
        return .{
            .base_addr = @intFromPtr(buf.ptr),
            .cursor_addr = @intFromPtr(buf.ptr),
            .end_addr = @intFromPtr(buf.ptr) + buf.len,
        };
    }

    pub fn alloc(arena: *Arena, size: usize) ?[*]u8 {
        if (arena.cursor_addr + size > arena.end_addr) return null;
        const result = @as([*]u8, @ptrFromInt(arena.cursor_addr));
        arena.cursor_addr += size;
        return result;
    }

    pub fn allocAligned(arena: *Arena, size: usize, alignment: u32) ?[*]u8 {
        const align_us = @as(usize, @intCast(alignment));
        const aligned = (arena.cursor_addr + align_us - 1) & ~(align_us - 1);
        if (aligned + size > arena.end_addr) return null;
        const result = @as([*]u8, @ptrFromInt(aligned));
        arena.cursor_addr = aligned + size;
        return result;
    }

    pub fn reset(arena: *Arena) void {
        arena.cursor_addr = arena.base_addr;
    }

    pub fn used(arena: *const Arena) usize {
        return arena.cursor_addr - arena.base_addr;
    }

    pub fn remaining(arena: *const Arena) usize {
        return arena.end_addr - arena.cursor_addr;
    }

    pub fn containsAddr(arena: *const Arena, addr: usize) bool {
        return addr >= arena.base_addr and addr < arena.end_addr;
    }

    pub fn containsPtr(arena: *const Arena, ptr: [*]u8) bool {
        return containsAddr(arena, @intFromPtr(ptr));
    }
};

// ═══════════════════════════════════════════════════════════════════
// 5. Ring Buffer Logger
// ═══════════════════════════════════════════════════════════════════

pub const EventKind = enum(u8) {
    ALLOC,
    RELEASE,
    MIGRATE,
    RESET_INVALIDATE,
    PANIC,
    TICK,
};

pub const RuntimeEvent = packed struct {
    epoch: u64,
    kind: EventKind,
    slot: u32,
    generation: u32,
    arg: u32,
};

pub const RingLogger = struct {
    buf: []RuntimeEvent,
    head: u32,
    count: u32,
    epoch: u64,

    pub fn init(slots: []RuntimeEvent) RingLogger {
        return .{
            .buf = slots,
            .head = 0,
            .count = 0,
            .epoch = 0,
        };
    }

    pub fn capacity(rl: *const RingLogger) u32 {
        return @intCast(rl.buf.len);
    }

    pub fn tick(rl: *RingLogger) void {
        rl.epoch += 1;
    }

    pub fn log(rl: *RingLogger, kind: EventKind, slot: u32, generation: u32, arg: u32) void {
        const cap = @as(u32, @intCast(rl.buf.len));
        if (cap == 0) return;
        rl.buf[rl.head] = .{
            .epoch = rl.epoch,
            .kind = kind,
            .slot = slot,
            .generation = generation,
            .arg = arg,
        };
        rl.head = (rl.head + 1) % cap;
        if (rl.count < cap) rl.count += 1;
    }
};

// ═══════════════════════════════════════════════════════════════════
// 6. TieredRuntime — hardened Stage 1 kernel
// ═══════════════════════════════════════════════════════════════════

pub const TieredRuntime = struct {
    l1: Arena,
    l2: Arena,
    l3: Arena,
    handles: HandleTable,
    logger: RingLogger,
    epoch: u64,
    retired_count: u32,

    pub const Transition = struct {
        handle: Handle,
        src_tier: Tier,
        dst_tier: Tier,
    };

    pub const MigrationResult = enum {
        success,
        dst_full,
        invalid_handle,
        at_boundary,
    };

    pub const Snapshot = struct {
        tiers: []Tier,
        heats: []u32,
        total_heats: []u32,
        states: []SlotState,
        ptrs: []?*anyopaque,
        gens: []u32,
        epoch: u64,
        retired_count: u32,
        arena_used_l1: usize,
        arena_used_l2: usize,
        arena_used_l3: usize,

        pub fn capture(tr: *const TieredRuntime, allocator: std.mem.Allocator) !Snapshot {
            const cap = tr.handles.capacity();
            const tiers = try allocator.alloc(Tier, cap);
            for (tr.handles.meta.ptrs, 0..) |p, i| {
                tiers[i] = tr.classifyPtr(p) orelse @as(Tier, .DISK);
            }
            return Snapshot{
                .tiers = tiers,
                .heats = try allocator.dupe(u32, tr.handles.meta.heats[0..]),
                .total_heats = try allocator.dupe(u32, tr.handles.meta.total_heats[0..]),
                .states = try allocator.dupe(SlotState, tr.handles.meta.states[0..]),
                .ptrs = try allocator.dupe(?*anyopaque, tr.handles.meta.ptrs[0..]),
                .gens = try allocator.dupe(u32, tr.handles.meta.generations[0..]),
                .epoch = tr.epoch,
                .retired_count = tr.retired_count,
                .arena_used_l1 = tr.l1.used(),
                .arena_used_l2 = tr.l2.used(),
                .arena_used_l3 = tr.l3.used(),
            };
        }

        pub fn deinit(s: *Snapshot, allocator: std.mem.Allocator) void {
            allocator.free(s.tiers);
            allocator.free(s.heats);
            allocator.free(s.total_heats);
            allocator.free(s.states);
            allocator.free(s.ptrs);
            allocator.free(s.gens);
        }

        pub fn tierOfSlot(s: *const Snapshot, slot: u32) ?Tier {
            if (slot >= @as(u32, @intCast(s.tiers.len))) return null;
            return s.tiers[slot];
        }
    };

    pub fn init(
        l1_buf: []u8,
        l2_buf: []u8,
        l3_buf: []u8,
        meta_store: MetaStore,
        log_buf: []RuntimeEvent,
    ) TieredRuntime {
        return .{
            .l1 = Arena.init(l1_buf),
            .l2 = Arena.init(l2_buf),
            .l3 = Arena.init(l3_buf),
            .handles = HandleTable.init(meta_store),
            .logger = RingLogger.init(log_buf),
            .epoch = 0,
            .retired_count = 0,
        };
    }

    // ── Tier derivation (single source of truth for address → Tier) ──

    /// Central classifier: any pointer → Tier | null.
    /// This is THE ONLY function that maps addresses to tiers.
    pub fn classifyPtr(tr: *const TieredRuntime, ptr: ?*anyopaque) ?Tier {
        const addr = @intFromPtr(ptr);
        if (tr.l1.containsAddr(addr)) return .L1;
        if (tr.l2.containsAddr(addr)) return .L2;
        if (tr.l3.containsAddr(addr)) return .L3;
        return null;
    }

    /// Resolve handle to its tier via MetaStore → classifyPtr.
    pub fn tierOfHandle(tr: *const TieredRuntime, handle: Handle) Tier {
        tr.handles.validateHandle(handle);
        const t = tr.classifyPtr(tr.handles.meta.ptrs[handle.slot]) orelse {
            assertInvariant(false, .INVALID_TIER);
            unreachable;
        };
        return t;
    }

    // ── Tier validation ──

    pub fn validateTier(tr: *const TieredRuntime, handle: Handle, expected: Tier) void {
        tr.handles.validateHandle(handle);
        const actual = tr.tierOfPtr(tr.handles.meta.ptrs[handle.slot]) orelse {
            assertInvariant(false, .INVALID_TIER);
            unreachable;
        };
        assertInvariant(actual == expected, .INVALID_TIER);
    }

    // ── Allocation (HandleTable owns, Arena provides) ──

    fn allocInArena(tr: *TieredRuntime, arena: *Arena, size: u32, tier: Tier) Handle {
        const ptr = arena.alloc(size) orelse return Handle.invalid();
        const h = tr.handles.alloc(ptr, size);
        const tier_bits = @as(u32, @intCast(@intFromEnum(tier))) << 24;
        tr.logger.log(.ALLOC, h.slot, h.generation, size | tier_bits);
        return h;
    }

    pub fn allocL1(tr: *TieredRuntime, size: u32) Handle {
        return tr.allocInArena(&tr.l1, size, .L1);
    }
    pub fn allocL2(tr: *TieredRuntime, size: u32) Handle {
        return tr.allocInArena(&tr.l2, size, .L2);
    }
    pub fn allocL3(tr: *TieredRuntime, size: u32) Handle {
        return tr.allocInArena(&tr.l3, size, .L3);
    }

    // ── Release ──

    pub fn release(tr: *TieredRuntime, handle: Handle) void {
        tr.handles.validateHandle(handle);
        const slot = handle.slot;
        const gen = tr.handles.meta.generations[slot];
        const size = tr.handles.meta.sizes[slot];
        tr.logger.log(.RELEASE, slot, gen, size);
        tr.handles.release(handle);
    }

    // ── Access ──

    pub fn access(tr: *TieredRuntime, handle: Handle) []u8 {
        tr.handles.touch(handle);
        return tr.handles.access(handle);
    }

    pub fn accessUntouched(tr: *const TieredRuntime, handle: Handle) []u8 {
        return tr.handles.access(handle);
    }

    // ── Tier migration (copy → validate → swap → retire) ──

    fn migrate(tr: *TieredRuntime, t: Transition) MigrationResult {
        if (!t.handle.isValid()) return .invalid_handle;
        tr.handles.validateAccess(t.handle);
        const slot = t.handle.slot;
        const size = tr.handles.meta.sizes[slot];
        const src_ptr = tr.handles.meta.ptrs[slot] orelse return .invalid_handle;
        const dst_arena = tr.arenaForTier(t.dst_tier);
        const dst_ptr = dst_arena.alloc(size) orelse return .dst_full;

        @memcpy(@as([*]u8, @ptrCast(dst_ptr))[0..size], @as([*]u8, @ptrCast(src_ptr))[0..size]);

        tr.handles.meta.ptrs[slot] = dst_ptr;

        tr.retired_count += 1;
        const tier_bits = @as(u32, @intCast(@intFromEnum(t.dst_tier))) << 24;
        tr.logger.log(.MIGRATE, slot, tr.handles.meta.generations[slot], size | tier_bits);
        return .success;
    }

    fn applyMigration(tr: *TieredRuntime, t: Transition) MigrationResult {
        return tr.migrate(t);
    }

    pub fn moveHotter(tr: *TieredRuntime, handle: Handle) MigrationResult {
        const src_tier = tr.tierOfHandle(handle);
        const dst_tier = src_tier.moveHotter() orelse return .at_boundary;
        return tr.applyMigration(.{
            .handle = handle,
            .src_tier = src_tier,
            .dst_tier = dst_tier,
        });
    }

    pub fn moveColder(tr: *TieredRuntime, handle: Handle) MigrationResult {
        const src_tier = tr.tierOfHandle(handle);
        const dst_tier = src_tier.moveColder() orelse return .at_boundary;
        return tr.applyMigration(.{
            .handle = handle,
            .src_tier = src_tier,
            .dst_tier = dst_tier,
        });
    }

    fn arenaForTier(tr: *TieredRuntime, tier: Tier) *Arena {
        return switch (tier) {
            .L1 => &tr.l1,
            .L2 => &tr.l2,
            .L3 => &tr.l3,
            .DISK => unreachable,
        };
    }

    // ── Arena reset ──

    fn resetArena(tr: *TieredRuntime, arena: *Arena, tier: Tier) void {
        const base = arena.base_addr;
        const end = arena.end_addr;
        const cap = tr.handles.capacity();
        var i: u32 = 0;
        while (i < cap) : (i += 1) {
            if (tr.handles.meta.states[i] == .Used) {
                if (tr.handles.meta.ptrs[i]) |ptr| {
                    const addr = @intFromPtr(ptr);
                    if (addr >= base and addr < end) {
                        const gen = tr.handles.meta.generations[i];
                        tr.logger.log(.RESET_INVALIDATE, i, gen, @intCast(@intFromEnum(tier)));
                        tr.handles.invalidateSlot(i);
                    }
                }
            }
        }
        arena.reset();
        tr.logger.log(.RESET_INVALIDATE, 0, 0, @intCast(@intFromEnum(tier)));
    }

    pub fn resetL1(tr: *TieredRuntime) void { tr.resetArena(&tr.l1, .L1); }
    pub fn resetL2(tr: *TieredRuntime) void { tr.resetArena(&tr.l2, .L2); }
    pub fn resetL3(tr: *TieredRuntime) void { tr.resetArena(&tr.l3, .L3); }

    // ── Tick / heat ──

    const PROMOTE_THRESH: u32 = 100;
    const DEMOTE_THRESH: u32 = 30;
    const MIGRATION_BUDGET: u32 = 4;

    pub fn tick(tr: *TieredRuntime) void {
        tr.epoch += 1;
        tr.logger.tick();

        // 1. Heat decay + collect migration candidates
        const cap = tr.handles.capacity();
        var candidates: [MIGRATION_BUDGET]struct { slot: u32, promote: bool } = undefined;
        var n_candidates: u32 = 0;

        for (0..cap) |i| {
            if (tr.handles.meta.states[i] != .Used) continue;
            const slot: u32 = @intCast(i);

            // Decay: heat >>= 1
            tr.handles.meta.heats[slot] >>= 1;

            if (n_candidates >= MIGRATION_BUDGET) continue;
            const heat = tr.handles.meta.heats[slot];
            const ptr = tr.handles.meta.ptrs[slot] orelse continue;
            const current = tr.classifyPtr(ptr) orelse continue;

            if (heat > PROMOTE_THRESH and current != .L1) {
                candidates[n_candidates] = .{ .slot = slot, .promote = true };
                n_candidates += 1;
            } else if (heat < DEMOTE_THRESH and current != .L3) {
                candidates[n_candidates] = .{ .slot = slot, .promote = false };
                n_candidates += 1;
            }
        }

        // 2. Apply migrations within budget
        var migrated: u32 = 0;
        var mig_fails: [3]u32 = .{0, 0, 0};
        for (0..n_candidates) |j| {
            const c = candidates[j];
            const gen = tr.handles.meta.generations[c.slot];
            const handle = Handle{ .slot = c.slot, .generation = gen };
            const result = if (c.promote) tr.moveHotter(handle) else tr.moveColder(handle);
            switch (result) {
                .success => migrated += 1,
                .dst_full => mig_fails[0] += 1,
                .invalid_handle => mig_fails[1] += 1,
                .at_boundary => mig_fails[2] += 1,
            }
        }

        tr.logger.log(.TICK, 0, 0, migrated);
        tr.retired_count = 0;
    }
};

// ═══════════════════════════════════════════════════════════════════
// 7. RuntimeIntrinsic — flat API for x64gen codegen
// ═══════════════════════════════════════════════════════════════════

pub const Intrinsic = enum(u16) {
    arena_l1_alloc = 0,
    arena_l2_alloc = 1,
    arena_l3_alloc = 2,
    arena_l1_reset = 3,
    arena_l2_reset = 4,
    arena_l3_reset = 5,
    handle_alloc = 6,
    handle_release = 7,
    handle_access = 8,
    handle_touch = 9,
    handle_validate = 10,
    move_hotter = 11,
    move_colder = 12,
    tick = 13,
    panic = 14,
    log_event = 15,
};

pub const IntrinsicSig = struct {
    name: []const u8,
    arg_count: u8,
    args: [4]struct { reg: []const u8, desc: []const u8 },
    ret: []const u8,
    stack_bytes: u16,
};

pub const INTRINSICS = blk: {
    @setEvalBranchQuota(5000);
    const sigs = [_]IntrinsicSig{
        .{ .name = "arena_l1_alloc", .arg_count = 1, .args = .{ .{ .reg = "RCX", .desc = "size: u32" }, .{}, .{}, .{} }, .ret = "RAX (Handle)", .stack_bytes = 40 },
        .{ .name = "arena_l2_alloc", .arg_count = 1, .args = .{ .{ .reg = "RCX", .desc = "size: u32" }, .{}, .{}, .{} }, .ret = "RAX (Handle)", .stack_bytes = 40 },
        .{ .name = "arena_l3_alloc", .arg_count = 1, .args = .{ .{ .reg = "RCX", .desc = "size: u32" }, .{}, .{}, .{} }, .ret = "RAX (Handle)", .stack_bytes = 40 },
        .{ .name = "arena_l1_reset", .arg_count = 0, .args = .{ .{}, .{}, .{}, .{} }, .ret = "void", .stack_bytes = 0 },
        .{ .name = "arena_l2_reset", .arg_count = 0, .args = .{ .{}, .{}, .{}, .{} }, .ret = "void", .stack_bytes = 0 },
        .{ .name = "arena_l3_reset", .arg_count = 0, .args = .{ .{}, .{}, .{}, .{} }, .ret = "void", .stack_bytes = 0 },
        .{ .name = "handle_alloc", .arg_count = 2, .args = .{ .{ .reg = "RCX", .desc = "ptr" }, .{ .reg = "RDX", .desc = "size: u32" }, .{}, .{} }, .ret = "RAX (Handle)", .stack_bytes = 40 },
        .{ .name = "handle_release", .arg_count = 2, .args = .{ .{ .reg = "RCX", .desc = "slot: u32" }, .{ .reg = "RDX", .desc = "generation: u32" }, .{}, .{} }, .ret = "void", .stack_bytes = 40 },
        .{ .name = "handle_access", .arg_count = 2, .args = .{ .{ .reg = "RCX", .desc = "slot: u32" }, .{ .reg = "RDX", .desc = "generation: u32" }, .{}, .{} }, .ret = "RAX (ptr)", .stack_bytes = 40 },
        .{ .name = "handle_touch", .arg_count = 2, .args = .{ .{ .reg = "RCX", .desc = "slot: u32" }, .{ .reg = "RDX", .desc = "generation: u32" }, .{}, .{} }, .ret = "void", .stack_bytes = 40 },
        .{ .name = "handle_validate", .arg_count = 2, .args = .{ .{ .reg = "RCX", .desc = "slot: u32" }, .{ .reg = "RDX", .desc = "generation: u32" }, .{}, .{} }, .ret = "void", .stack_bytes = 40 },
        .{ .name = "move_hotter", .arg_count = 2, .args = .{ .{ .reg = "RCX", .desc = "slot: u32" }, .{ .reg = "RDX", .desc = "generation: u32" }, .{}, .{} }, .ret = "void", .stack_bytes = 40 },
        .{ .name = "move_colder", .arg_count = 2, .args = .{ .{ .reg = "RCX", .desc = "slot: u32" }, .{ .reg = "RDX", .desc = "generation: u32" }, .{}, .{} }, .ret = "void", .stack_bytes = 40 },
        .{ .name = "tick", .arg_count = 0, .args = .{ .{}, .{}, .{}, .{} }, .ret = "void", .stack_bytes = 0 },
        .{ .name = "panic", .arg_count = 1, .args = .{ .{ .reg = "RCX", .desc = "code: u8" }, .{}, .{}, .{} }, .ret = "noreturn", .stack_bytes = 40 },
        .{ .name = "log_event", .arg_count = 5, .args = .{ .{ .reg = "RCX", .desc = "kind: u8" }, .{ .reg = "RDX", .desc = "slot: u32" }, .{ .reg = "R8", .desc = "gen: u32" }, .{ .reg = "R9", .desc = "arg: u32" } }, .ret = "void", .stack_bytes = 48 },
    };
    break :blk sigs;
};

// ═══════════════════════════════════════════════════════════════════
// 8. Windows API helpers
// ═══════════════════════════════════════════════════════════════════

pub fn reserveViaVirtualAlloc(size: usize) ![*]u8 {
    const ptr = windows.VirtualAlloc(null, size, windows.MEM_RESERVE | windows.MEM_COMMIT, windows.PAGE_READWRITE);
    if (ptr == null) return error.OutOfMemory;
    return @ptrCast(ptr);
}

pub fn freeViaVirtualAlloc(ptr: [*]u8, size: usize) void {
    _ = windows.VirtualFree(ptr, size, windows.MEM_RELEASE);
}

pub fn mmapFile(path: []const u8) !struct { data: []u8, handle: windows.HANDLE, mapping: windows.HANDLE } {
    const wide_path = try windows.sliceToPrefixedFileW(path);
    const handle = windows.CreateFileW(
        &wide_path,
        windows.GENERIC_READ,
        windows.FILE_SHARE_READ,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return error.FileNotFound;
    const size = try windows.GetFileSizeEx(handle);
    const mapping = try windows.CreateFileMapping(handle, null, windows.PAGE_READONLY, @intCast(size >> 32), @intCast(size & 0xFFFFFFFF), null);
    const data = try windows.MapViewOfFile(mapping, windows.FILE_MAP_READ, 0, 0, size);
    return .{ .data = data[0..size], .handle = handle, .mapping = mapping };
}

pub fn unmmapFile(mmap: struct { data: []u8, handle: windows.HANDLE, mapping: windows.HANDLE }) void {
    windows.UnmapViewOfFile(mmap.data.ptr);
    windows.CloseHandle(mmap.mapping);
    windows.CloseHandle(mmap.handle);
}
