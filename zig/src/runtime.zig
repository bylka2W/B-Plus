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
// 3. Chunk — atomic unit of migration
// ═══════════════════════════════════════════════════════════════════

pub const CHUNK_SIZE = 256; // 64KB in production; 256B for testing with small arenas

pub const Chunk = struct {
    tier: Tier,
    arena_base: usize,
    heat: u32,
    used: u32,
    arena_offset: u32,
    slot_count: u16,
    last_migration_tick: u32,
};

pub const ChunkStore = struct {
    chunks: []Chunk,
    count: u32,

    pub fn init(buf: []Chunk) ChunkStore {
        return .{ .chunks = buf, .count = 0 };
    }

    pub fn capacity(cs: *const ChunkStore) u32 {
        return @intCast(cs.chunks.len);
    }

    pub fn allocChunk(cs: *ChunkStore, tier: Tier, arena_base: usize, arena_offset: u32) ?u32 {
        if (cs.count >= cs.capacity()) return null;
        const id = cs.count;
        cs.count += 1;
        cs.chunks[id] = .{
            .tier = tier,
            .arena_base = arena_base,
            .heat = 0,
            .used = 0,
            .arena_offset = arena_offset,
            .slot_count = 0,
            .last_migration_tick = 0,
        };
        return id;
    }

    pub fn get(cs: *const ChunkStore, id: u32) *const Chunk {
        return &cs.chunks[id];
    }

    pub fn getMut(cs: *ChunkStore, id: u32) *Chunk {
        return &cs.chunks[id];
    }

    pub fn findChunkWithSpace(cs: *const ChunkStore, tier: Tier, size: u32) ?u32 {
        var i: u32 = 0;
        while (i < cs.count) : (i += 1) {
            const c = &cs.chunks[i];
            if (c.tier == tier and c.used + size <= CHUNK_SIZE) return i;
        }
        return null;
    }

    pub fn findChunksByTier(cs: *const ChunkStore, tier: Tier, out: []u32) u32 {
        var n: u32 = 0;
        var i: u32 = 0;
        while (i < cs.count and n < @as(u32, @intCast(out.len))) : (i += 1) {
            if (cs.chunks[i].tier == tier) {
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    pub fn releaseHandlesInTier(cs: *ChunkStore, tier: Tier, handles: *HandleTable) void {
        var buf: [256]u32 = undefined;
        const n = cs.findChunksByTier(tier, &buf);
        var ci: u32 = 0;
        while (ci < n) : (ci += 1) {
            const chunk_id = buf[ci];
            // Invalidate all handles referencing this chunk
            const cap = handles.capacity();
            var si: u32 = 0;
            while (si < cap) : (si += 1) {
                if (handles.meta.states[si] == .Used and handles.meta.chunk_ids[si] == chunk_id) {
                    handles.invalidateSlot(si);
                }
            }
            // Clear chunk
            cs.chunks[chunk_id] = undefined;
        }
        // Compact chunks: shift remaining chunks down
        if (n > 0) {
            var write: u32 = buf[0];
            var read: u32 = buf[0] + 1;
            while (read < cs.count) : (read += 1) {
                if (cs.chunks[read].tier == tier) {
                    // Skip — these are the ones we're removing
                    continue;
                }
                // Update handle chunk_ids pointing to 'read' to point to 'write'
                const cap = handles.capacity();
                var si: u32 = 0;
                while (si < cap) : (si += 1) {
                    if (handles.meta.states[si] == .Used and handles.meta.chunk_ids[si] == read) {
                        handles.meta.chunk_ids[si] = write;
                    }
                }
                cs.chunks[write] = cs.chunks[read];
                write += 1;
            }
            cs.count = write;
        }
    }
};

// ═══════════════════════════════════════════════════════════════════
// 4. Handle & Metadata (SoA, flat arrays)
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
/// Tier is derived from chunk_id → Chunk.tier, NOT from pointer address.
pub const MetaStore = struct {
    chunk_ids: []u32,
    offsets: []u32,
    generations: []u32,
    sizes: []u32,
    states: []SlotState,
    free_next: []u32,
    heats: []u32,
    total_heats: []u32,

    pub fn init(
        cid_buf: []u32,
        off_buf: []u32,
        gen_buf: []u32,
        size_buf: []u32,
        state_buf: []SlotState,
        free_buf: []u32,
        heat_buf: []u32,
        total_heat_buf: []u32,
    ) MetaStore {
        const cap = cid_buf.len;
        @memset(cid_buf, 0xFFFFFFFF);
        @memset(off_buf, 0);
        @memset(gen_buf, 0);
        @memset(size_buf, 0);
        @memset(state_buf, .Free);
        @memset(heat_buf, 0);
        @memset(total_heat_buf, 0);
        var i: u32 = 0;
        while (i < cap) : (i += 1) {
            free_buf[i] = i + 1;
        }
        return .{
            .chunk_ids = cid_buf,
            .offsets = off_buf,
            .generations = gen_buf,
            .sizes = size_buf,
            .states = state_buf,
            .free_next = free_buf,
            .heats = heat_buf,
            .total_heats = total_heat_buf,
        };
    }

    pub fn capacity(ms: *const MetaStore) u32 {
        return @intCast(ms.chunk_ids.len);
    }
};

/// HandleTable = source of truth for slot metadata.
/// Tier is derived from chunk_id → Chunk.tier, NOT from pointer address.
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

    // ── Validation ──

    pub fn validateHandle(ht: *const HandleTable, handle: Handle) void {
        assertInvariant(handle.isValid(), .INVALID_HANDLE);
        assertInvariant(handle.slot < ht.capacity(), .INVALID_HANDLE);
        assertInvariant(ht.meta.states[handle.slot] == .Used, .INVALID_HANDLE);
        assertInvariant(ht.meta.generations[handle.slot] == handle.generation, .INVALID_HANDLE);
    }

    // ── Operations ──

    pub fn alloc(ht: *HandleTable, chunk_id: u32, offset: u32, size: u32) Handle {
        const cap = ht.capacity();
        const slot = ht.free_head;
        if (slot >= cap) unreachable;
        if (ht.meta.states[slot] != .Free) unreachable;

        ht.free_head = ht.meta.free_next[slot];
        const next_gen = ht.meta.generations[slot] +% 1;
        const gen: u32 = if (next_gen == 0) 1 else next_gen;

        ht.meta.chunk_ids[slot] = chunk_id;
        ht.meta.offsets[slot] = offset;
        ht.meta.generations[slot] = gen;
        ht.meta.sizes[slot] = size;
        ht.meta.states[slot] = .Used;
        ht.meta.heats[slot] = 0;
        ht.count += 1;
        return .{ .slot = slot, .generation = gen };
    }

    pub fn release(ht: *HandleTable, handle: Handle, chunk_store: *ChunkStore) void {
        validateHandle(ht, handle);
        const slot = handle.slot;
        const chunk_id = ht.meta.chunk_ids[slot];
        if (chunk_id < chunk_store.count) {
            const ch = &chunk_store.chunks[chunk_id];
            if (ch.slot_count > 0) ch.slot_count -= 1;
        }
        ht.meta.chunk_ids[slot] = 0xFFFFFFFF;
        ht.meta.offsets[slot] = 0;
        ht.meta.states[slot] = .Free;
        ht.meta.sizes[slot] = 0;
        ht.meta.heats[slot] = 0;
        ht.meta.free_next[slot] = ht.free_head;
        ht.free_head = slot;
        ht.count -= 1;
    }

    pub fn invalidateSlot(ht: *HandleTable, slot: u32) void {
        if (slot >= ht.capacity()) return;
        if (ht.meta.states[slot] != .Used) return;
        const next_gen = ht.meta.generations[slot] +% 1;
        ht.meta.generations[slot] = if (next_gen == 0) 1 else next_gen;
        ht.meta.chunk_ids[slot] = 0xFFFFFFFF;
        ht.meta.offsets[slot] = 0;
        ht.meta.states[slot] = .Free;
        ht.meta.sizes[slot] = 0;
        ht.meta.heats[slot] = 0;
        ht.meta.free_next[slot] = ht.free_head;
        ht.free_head = slot;
        ht.count -= 1;
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
// 6. TieredRuntime — Stage 2: chunk-based memory physics
// ═══════════════════════════════════════════════════════════════════

pub const TieredRuntime = struct {
    l1: Arena,
    l2: Arena,
    l3: Arena,
    handles: HandleTable,
    chunks: ChunkStore,
    logger: RingLogger,
    epoch: u64,
    retired_count: u32,

    pub const MigrationResult = enum {
        success,
        dst_full,
        invalid_handle,
        at_boundary,
        cooldown,
    };

    pub const Snapshot = struct {
        tiers: []Tier,
        heats: []u32,
        total_heats: []u32,
        states: []SlotState,
        chunk_ids: []u32,
        offsets: []u32,
        gens: []u32,
        chunk_tiers: []Tier,
        chunk_heats: []u32,
        epoch: u64,
        retired_count: u32,
        arena_used_l1: usize,
        arena_used_l2: usize,
        arena_used_l3: usize,

        pub fn capture(tr: *const TieredRuntime, allocator: std.mem.Allocator) !Snapshot {
            const cap = tr.handles.capacity();
            const cc = tr.chunks.capacity();
            const tiers = try allocator.alloc(Tier, cap);
            for (0..cap) |i| {
                if (tr.handles.meta.states[i] == .Used) {
                    const cid = tr.handles.meta.chunk_ids[i];
                    tiers[i] = tr.chunks.chunks[cid].tier;
                } else {
                    tiers[i] = .DISK;
                }
            }
            const chunk_tiers = try allocator.alloc(Tier, cc);
            const chunk_heats = try allocator.alloc(u32, cc);
            for (0..cc) |i| {
                if (i < tr.chunks.count) {
                    chunk_tiers[i] = tr.chunks.chunks[i].tier;
                    chunk_heats[i] = tr.chunks.chunks[i].heat;
                } else {
                    chunk_tiers[i] = .DISK;
                    chunk_heats[i] = 0;
                }
            }
            return Snapshot{
                .tiers = tiers,
                .heats = try allocator.dupe(u32, tr.handles.meta.heats[0..]),
                .total_heats = try allocator.dupe(u32, tr.handles.meta.total_heats[0..]),
                .states = try allocator.dupe(SlotState, tr.handles.meta.states[0..]),
                .chunk_ids = try allocator.dupe(u32, tr.handles.meta.chunk_ids[0..]),
                .offsets = try allocator.dupe(u32, tr.handles.meta.offsets[0..]),
                .gens = try allocator.dupe(u32, tr.handles.meta.generations[0..]),
                .chunk_tiers = chunk_tiers,
                .chunk_heats = chunk_heats,
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
            allocator.free(s.chunk_ids);
            allocator.free(s.offsets);
            allocator.free(s.gens);
            allocator.free(s.chunk_tiers);
            allocator.free(s.chunk_heats);
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
        chunk_buf: []Chunk,
    ) TieredRuntime {
        return .{
            .l1 = Arena.init(l1_buf),
            .l2 = Arena.init(l2_buf),
            .l3 = Arena.init(l3_buf),
            .handles = HandleTable.init(meta_store),
            .chunks = ChunkStore.init(chunk_buf),
            .logger = RingLogger.init(log_buf),
            .epoch = 0,
            .retired_count = 0,
        };
    }

    // ── Tier derivation ──

    pub fn tierOfHandle(tr: *const TieredRuntime, handle: Handle) Tier {
        tr.handles.validateHandle(handle);
        const cid = tr.handles.meta.chunk_ids[handle.slot];
        return tr.chunks.chunks[cid].tier;
    }

    // ── Allocation (chunk-aware) ──

    fn allocInArena(tr: *TieredRuntime, arena: *Arena, size: u32, tier: Tier) Handle {
        // Find existing chunk with space
        if (tr.chunks.findChunkWithSpace(tier, size)) |chunk_id| {
            const chunk = &tr.chunks.chunks[chunk_id];
            const offset = chunk.used;
            chunk.used += size;
            chunk.slot_count += 1;
            const h = tr.handles.alloc(chunk_id, offset, size);
            const tier_bits = @as(u32, @intCast(@intFromEnum(tier))) << 24;
            tr.logger.log(.ALLOC, h.slot, h.generation, size | tier_bits);
            return h;
        }
        // No chunk with space: allocate a new chunk from arena
        const mem = arena.alloc(CHUNK_SIZE) orelse return Handle.invalid();
        const arena_offset = @as(u32, @intCast(@intFromPtr(mem) - arena.base_addr));
        const chunk_id = tr.chunks.allocChunk(tier, arena.base_addr, arena_offset) orelse return Handle.invalid();
        {
            const chunk = &tr.chunks.chunks[chunk_id];
            chunk.used = size;
            chunk.slot_count = 1;
        }
        const h = tr.handles.alloc(chunk_id, 0, size);
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
        tr.handles.release(handle, &tr.chunks);
    }

    // ── Access ──

    pub fn access(tr: *TieredRuntime, handle: Handle) []u8 {
        tr.handles.validateHandle(handle);
        const slot = handle.slot;
        const size = tr.handles.meta.sizes[slot];

        tr.handles.touch(handle);

        const chunk_id = tr.handles.meta.chunk_ids[slot];
        const chunk = &tr.chunks.chunks[chunk_id];
        if (chunk.heat < std.math.maxInt(u32)) chunk.heat += 1;

        const offset = tr.handles.meta.offsets[slot];
        const ptr = @as([*]u8, @ptrFromInt(chunk.arena_base + chunk.arena_offset + offset));
        return ptr[0..size];
    }

    pub fn accessUntouched(tr: *TieredRuntime, handle: Handle) []u8 {
        tr.handles.validateHandle(handle);
        const slot = handle.slot;
        const size = tr.handles.meta.sizes[slot];
        const chunk_id = tr.handles.meta.chunk_ids[slot];
        const chunk = &tr.chunks.chunks[chunk_id];
        const offset = tr.handles.meta.offsets[slot];
        const ptr = @as([*]u8, @ptrFromInt(chunk.arena_base + chunk.arena_offset + offset));
        return ptr[0..size];
    }

    // ── Chunk migration (tier switch + physical byte copy) ──

    pub fn migrateChunk(tr: *TieredRuntime, chunk_id: u32, dst_tier: Tier) MigrationResult {
        if (chunk_id >= tr.chunks.count) return .invalid_handle;
        const chunk = &tr.chunks.chunks[chunk_id];
        if (!chunk.tier.isValidTransition(dst_tier)) return .at_boundary;

        const current_tick = @as(u32, @truncate(tr.epoch));
        if (chunk.last_migration_tick != 0 and (current_tick -| chunk.last_migration_tick) < COOLDOWN_TICKS) {
            return .cooldown;
        }

        const src_tier = chunk.tier;

        // Allocate destination memory in the target arena
        const dst_arena = tr.arenaForTier(dst_tier);
        const dst_mem = dst_arena.alloc(CHUNK_SIZE) orelse return .dst_full;
        const dst_arena_offset = @as(u32, @intCast(@intFromPtr(dst_mem) - dst_arena.base_addr));

        // Copy used bytes from source to destination
        const src_ptr = @as([*]u8, @ptrFromInt(chunk.arena_base + chunk.arena_offset));
        const dst_ptr = @as([*]u8, @ptrFromInt(dst_arena.base_addr + dst_arena_offset));
        @memcpy(dst_ptr[0..chunk.used], src_ptr[0..chunk.used]);

        // Update chunk metadata to point to new location
        chunk.arena_base = dst_arena.base_addr;
        chunk.arena_offset = dst_arena_offset;
        chunk.tier = dst_tier;
        chunk.heat >>= 1;
        chunk.last_migration_tick = current_tick;

        tr.retired_count += 1;
        const tier_bits = @as(u32, @intCast(@intFromEnum(src_tier))) << 24 | @as(u32, @intCast(@intFromEnum(dst_tier))) << 16;
        tr.logger.log(.MIGRATE, chunk_id, 0, tier_bits);
        return .success;
    }

    pub fn moveHotter(tr: *TieredRuntime, handle: Handle) MigrationResult {
        tr.handles.validateHandle(handle);
        const chunk_id = tr.handles.meta.chunk_ids[handle.slot];
        const src_tier = tr.chunks.chunks[chunk_id].tier;
        const dst_tier = src_tier.moveHotter() orelse return .at_boundary;
        return tr.migrateChunk(chunk_id, dst_tier);
    }

    pub fn moveColder(tr: *TieredRuntime, handle: Handle) MigrationResult {
        tr.handles.validateHandle(handle);
        const chunk_id = tr.handles.meta.chunk_ids[handle.slot];
        const src_tier = tr.chunks.chunks[chunk_id].tier;
        const dst_tier = src_tier.moveColder() orelse return .at_boundary;
        return tr.migrateChunk(chunk_id, dst_tier);
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
        tr.chunks.releaseHandlesInTier(tier, &tr.handles);
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
    const COOLDOWN_TICKS: u32 = 3;

    pub fn tick(tr: *TieredRuntime) void {
        tr.epoch += 1;
        tr.logger.tick();

        const promoteCmp = struct {
            fn lessThan(chunks: *ChunkStore, a: u32, b: u32) bool {
                const ha = chunks.chunks[a].heat;
                const hb = chunks.chunks[b].heat;
                if (ha != hb) return ha > hb;
                return a < b;
            }
        }.lessThan;

        const demoteCmp = struct {
            fn lessThan(chunks: *ChunkStore, a: u32, b: u32) bool {
                const ha = chunks.chunks[a].heat;
                const hb = chunks.chunks[b].heat;
                if (ha != hb) return ha < hb;
                return a < b;
            }
        }.lessThan;

        // 1. Decay chunk heat + handle heat
        var ci: u32 = 0;
        while (ci < tr.chunks.count) : (ci += 1) {
            tr.chunks.chunks[ci].heat >>= 1;
        }
        const cap = tr.handles.capacity();
        for (0..cap) |i| {
            if (tr.handles.meta.states[i] == .Used) {
                tr.handles.meta.heats[i] >>= 1;
                tr.handles.meta.total_heats[i] >>= 1;
            }
        }

        // 2. Scan all chunks → partial top-K selection (no global buffer)
        var promote_buf: [MIGRATION_BUDGET]u32 = undefined;
        var demote_buf: [MIGRATION_BUDGET]u32 = undefined;
        var np: u32 = 0;
        var nd: u32 = 0;

        ci = 0;
        while (ci < tr.chunks.count) : (ci += 1) {
            const ch = &tr.chunks.chunks[ci];
            if (ch.slot_count == 0) continue;
            const cur_tick = @as(u32, @truncate(tr.epoch));
            if (ch.last_migration_tick != 0 and (cur_tick -| ch.last_migration_tick) < COOLDOWN_TICKS) continue;

            if (ch.heat > PROMOTE_THRESH and ch.tier != .L1) {
                if (np < MIGRATION_BUDGET) {
                    promote_buf[np] = ci;
                    np += 1;
                    if (np == MIGRATION_BUDGET) {
                        std.mem.sort(u32, promote_buf[0..np], &tr.chunks, promoteCmp);
                    }
                } else if (promoteCmp(&tr.chunks, ci, promote_buf[MIGRATION_BUDGET - 1])) {
                    promote_buf[MIGRATION_BUDGET - 1] = ci;
                    std.mem.sort(u32, promote_buf[0..MIGRATION_BUDGET], &tr.chunks, promoteCmp);
                }
            }

            if (ch.heat < DEMOTE_THRESH and ch.tier != .L3) {
                if (nd < MIGRATION_BUDGET) {
                    demote_buf[nd] = ci;
                    nd += 1;
                    if (nd == MIGRATION_BUDGET) {
                        std.mem.sort(u32, demote_buf[0..nd], &tr.chunks, demoteCmp);
                    }
                } else if (demoteCmp(&tr.chunks, ci, demote_buf[MIGRATION_BUDGET - 1])) {
                    demote_buf[MIGRATION_BUDGET - 1] = ci;
                    std.mem.sort(u32, demote_buf[0..MIGRATION_BUDGET], &tr.chunks, demoteCmp);
                }
            }
        }

        // 3. Apply top-K
        var migrated: u32 = 0;
        var i: u32 = 0;
        while (i < np) : (i += 1) {
            const cid = promote_buf[i];
            const dst = tr.chunks.chunks[cid].tier.moveHotter() orelse continue;
            if (tr.migrateChunk(cid, dst) == .success) migrated += 1;
        }
        i = 0;
        while (i < nd) : (i += 1) {
            const cid = demote_buf[i];
            const dst = tr.chunks.chunks[cid].tier.moveColder() orelse continue;
            if (tr.migrateChunk(cid, dst) == .success) migrated += 1;
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
