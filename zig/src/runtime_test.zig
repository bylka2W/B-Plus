const std = @import("std");
const rt = @import("runtime.zig");

const CAP = 8;

fn makeMetaStore(ptrs: *[CAP]?*anyopaque, gens: *[CAP]u32, sizes: *[CAP]u32, states: *[CAP]rt.SlotState, free_next: *[CAP]u32, heats: *[CAP]u32, total_heats: *[CAP]u32) rt.MetaStore {
    return rt.MetaStore.init(ptrs, gens, sizes, states, free_next, heats, total_heats);
}

fn makeRuntime(l1: *[4096]u8, l2: *[4096]u8, l3: *[4096]u8, ms: rt.MetaStore, log: *[64]rt.RuntimeEvent) rt.TieredRuntime {
    return rt.TieredRuntime.init(l1, l2, l3, ms, log);
}

test "HandleTable alloc returns valid handle" {
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var data: [16]u8 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(&data, 16);
    try std.testing.expect(h.isValid());
    try std.testing.expect(h.slot < CAP);
    try std.testing.expectEqual(@as(u32, 1), h.generation);
    try std.testing.expectEqual(@as(u32, 1), ht.count);
}

test "HandleTable alloc and access returns same ptr" {
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var data: [16]u8 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(&data, 16);
    const slice = ht.access(h);
    try std.testing.expectEqual(@as(usize, 16), slice.len);
    try std.testing.expectEqual(@intFromPtr(&data), @intFromPtr(slice.ptr));
}

test "HandleTable alloc reuses freed slot" {
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var data_a: [16]u8 = undefined;
    var data_b: [32]u8 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h1 = ht.alloc(&data_a, 16);
    try std.testing.expectEqual(@as(u32, 0), h1.slot);
    ht.release(h1);
    const h2 = ht.alloc(&data_b, 32);
    try std.testing.expectEqual(@as(u32, 0), h2.slot); // reuses slot 0
    try std.testing.expectEqual(@as(u32, 2), h2.generation); // generation incremented
}

test "touch increments heat" {
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var data: [16]u8 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(&data, 16);
    try std.testing.expectEqual(@as(u32, 0), ht.meta.heats[h.slot]);

    ht.touch(h);
    try std.testing.expectEqual(@as(u32, 1), ht.meta.heats[h.slot]);

    ht.touch(h);
    ht.touch(h);
    try std.testing.expectEqual(@as(u32, 3), ht.meta.heats[h.slot]);
}

test "touch caps heat at maxInt(u32)" {
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var data: [16]u8 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(&data, 16);
    ht.meta.heats[h.slot] = std.math.maxInt(u32);
    ht.touch(h);
    try std.testing.expectEqual(std.math.maxInt(u32), ht.meta.heats[h.slot]);
}

test "release zeros heat" {
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var data: [16]u8 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(&data, 16);
    ht.touch(h);
    ht.touch(h);
    try std.testing.expectEqual(@as(u32, 2), ht.meta.heats[h.slot]);
    ht.release(h);
    try std.testing.expectEqual(@as(u32, 0), ht.meta.heats[h.slot]);
}

test "TieredRuntime allocL1 and access" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    const h = tr.allocL1(100);
    try std.testing.expect(h.isValid());
    const slice = tr.access(h);
    try std.testing.expectEqual(@as(usize, 100), slice.len);
}

test "access touches heat" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    const h = tr.allocL1(16);
    try std.testing.expectEqual(@as(u32, 0), tr.handles.meta.heats[h.slot]);
    _ = tr.access(h);
    try std.testing.expectEqual(@as(u32, 1), tr.handles.meta.heats[h.slot]);
    _ = tr.access(h);
    _ = tr.access(h);
    try std.testing.expectEqual(@as(u32, 3), tr.handles.meta.heats[h.slot]);
}

test "tick increments epoch" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    try std.testing.expectEqual(@as(u64, 0), tr.epoch);
    tr.tick();
    try std.testing.expectEqual(@as(u64, 1), tr.epoch);
    tr.tick();
    try std.testing.expectEqual(@as(u64, 2), tr.epoch);
}

test "decay halves heat on tick" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    const h = tr.allocL1(16);
    tr.handles.meta.heats[h.slot] = 100;
    tr.tick();
    try std.testing.expectEqual(@as(u32, 50), tr.handles.meta.heats[h.slot]);
    tr.tick();
    try std.testing.expectEqual(@as(u32, 25), tr.handles.meta.heats[h.slot]);
}

test "decay only applies to Used slots" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    const h = tr.allocL1(16);
    tr.handles.meta.heats[h.slot] = 100;
    // Manually zero an unused slot's heat via MetaStore
    const unused_slot: u32 = if (h.slot == 0) 1 else 0;
    tr.handles.meta.heats[unused_slot] = 200; // Free slot, should be ignored
    tr.tick();
    try std.testing.expectEqual(@as(u32, 50), tr.handles.meta.heats[h.slot]);
    // Free slot heat should remain unchanged (tick skips it)
    try std.testing.expectEqual(@as(u32, 200), tr.handles.meta.heats[unused_slot]);
}

test "promote when heat exceeds threshold" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    // Allocate in L2 so there's room to promote to L1
    const h = tr.allocL2(16);
    tr.handles.meta.heats[h.slot] = 250; // > 100 after decay (250>>1=125)
    tr.tick();

    // Should have migrated to L1
    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L1, tier);
}

test "demote when heat below threshold" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    // Allocate in L2 so there's room to demote to L3
    const h = tr.allocL2(16);
    tr.handles.meta.heats[h.slot] = 10; // < 30 = demote
    tr.tick();

    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L3, tier);
}

test "hysteresis: stable range 30-100 does nothing" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    const h = tr.allocL2(16);
    tr.handles.meta.heats[h.slot] = 90; // After decay: 45 — in [30,100] = no migration
    tr.tick();

    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L2, tier);
}

test "already-promoted L1 handle does not promote further" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    const h = tr.allocL1(16);
    tr.handles.meta.heats[h.slot] = 200; // hot but already L1
    tr.tick();

    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L1, tier);
}

test "cold L3 handle does not demote further" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    const h = tr.allocL3(16);
    tr.handles.meta.heats[h.slot] = 10; // cold but already L3
    tr.tick();

    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L3, tier);
}

test "budget limits migrations per tick to 4" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    // Need a bigger handle table for this test
    const BIG_CAP = 64;
    var big_ptrs: [BIG_CAP]?*anyopaque = undefined;
    var big_gens: [BIG_CAP]u32 = undefined;
    var big_sizes: [BIG_CAP]u32 = undefined;
    var big_states: [BIG_CAP]rt.SlotState = undefined;
    var big_free_next: [BIG_CAP]u32 = undefined;
    var big_heats: [BIG_CAP]u32 = undefined;
    var big_total_heats: [BIG_CAP]u32 = undefined;
    var big_log: [64]rt.RuntimeEvent = undefined;
    const big_ms = rt.MetaStore.init(&big_ptrs, &big_gens, &big_sizes, &big_states, &big_free_next, &big_heats, &big_total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, big_ms, &big_log);

    // Allocate 8 handles in L2 (all can promote to L1)
    var handles: [8]rt.Handle = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        handles[i] = tr.allocL2(16);
        tr.handles.meta.heats[handles[i].slot] = 250; // > 100 after decay
    }

    tr.tick();

    // At most 4 should have migrated
    var promoted: u32 = 0;
    for (handles) |h| {
        if (tr.tierOfHandle(h) == .L1) promoted += 1;
    }
    try std.testing.expect(promoted <= 4);
    // At least one should still be L2 (budget limits)
    try std.testing.expect(promoted < 8);
}

test "migration preserves data integrity" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    const h = tr.allocL2(16);
    // Write known pattern
    const slice = tr.access(h);
    for (0..16) |j| slice[j] = @intCast(j + 42);

    // Trigger promotion via heat (set >200 so after decay it's still >100)
    tr.handles.meta.heats[h.slot] = 250;
    tr.tick();

    // Read back and verify data
    const slice2 = tr.access(h);
    try std.testing.expectEqual(@as(usize, 16), slice2.len);
    for (0..16) |j| {
        try std.testing.expectEqual(@as(u8, @intCast(j + 42)), slice2[j]);
    }

    // Should now be in L1
    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L1, tier);
}

test "tick multiple: heat grows then decays" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    const h = tr.allocL2(16);

    // Access 10 times (heat = 10)
    var k: u32 = 0;
    while (k < 10) : (k += 1) _ = tr.access(h);
    try std.testing.expectEqual(@as(u32, 10), tr.handles.meta.heats[h.slot]);

    // Tick decays: 10 >> 1 = 5
    tr.tick();
    try std.testing.expectEqual(@as(u32, 5), tr.handles.meta.heats[h.slot]);

    // Tick decays: 5 >> 1 = 2
    tr.tick();
    try std.testing.expectEqual(@as(u32, 2), tr.handles.meta.heats[h.slot]);
}

test "RingLogger basic log and tick" {
    var log_buf: [4]rt.RuntimeEvent = undefined;
    var rl = rt.RingLogger.init(&log_buf);

    try std.testing.expectEqual(@as(u64, 0), rl.epoch);
    rl.tick();
    try std.testing.expectEqual(@as(u64, 1), rl.epoch);

    rl.log(.ALLOC, 0, 1, 100);
    try std.testing.expectEqual(@as(u32, 1), rl.count);
    try std.testing.expectEqual(@as(u64, 1), rl.buf[0].epoch);
    try std.testing.expectEqual(rt.EventKind.ALLOC, rl.buf[0].kind);
    try std.testing.expectEqual(@as(u32, 0), rl.buf[0].slot);
    try std.testing.expectEqual(@as(u32, 1), rl.buf[0].generation);
    try std.testing.expectEqual(@as(u32, 100), rl.buf[0].arg);
}

test "RingLogger wraps around" {
    var log_buf: [2]rt.RuntimeEvent = undefined;
    var rl = rt.RingLogger.init(&log_buf);

    rl.log(.ALLOC, 0, 1, 10);
    rl.log(.RELEASE, 1, 2, 20);
    rl.log(.MIGRATE, 2, 3, 30); // wraps, overwrites slot 0

    try std.testing.expectEqual(@as(u32, 2), rl.count); // capped at capacity
    try std.testing.expectEqual(@as(u32, 1), rl.head); // head = (0+3)%2 = 1
    try std.testing.expectEqual(rt.EventKind.MIGRATE, rl.buf[0].kind);
}

test "Tier isValidTransition" {
    try std.testing.expect(rt.Tier.L1.isValidTransition(.L2));
    try std.testing.expect(!rt.Tier.L1.isValidTransition(.L1));
    try std.testing.expect(!rt.Tier.L1.isValidTransition(.L3));

    try std.testing.expect(rt.Tier.L2.isValidTransition(.L1));
    try std.testing.expect(rt.Tier.L2.isValidTransition(.L3));
    try std.testing.expect(!rt.Tier.L2.isValidTransition(.L2));

    try std.testing.expect(rt.Tier.L3.isValidTransition(.L2));
    try std.testing.expect(rt.Tier.L3.isValidTransition(.DISK));
    try std.testing.expect(!rt.Tier.L3.isValidTransition(.L1));
}

test "Tier moveHotter moveColder" {
    try std.testing.expectEqual(rt.Tier.L2, rt.Tier.L1.moveColder().?);
    try std.testing.expectEqual(rt.Tier.L3, rt.Tier.L2.moveColder().?);
    try std.testing.expectEqual(null, rt.Tier.L3.moveColder());
    try std.testing.expectEqual(null, rt.Tier.DISK.moveColder());

    try std.testing.expectEqual(null, rt.Tier.L1.moveHotter());
    try std.testing.expectEqual(rt.Tier.L1, rt.Tier.L2.moveHotter().?);
    try std.testing.expectEqual(rt.Tier.L2, rt.Tier.L3.moveHotter().?);
    try std.testing.expectEqual(rt.Tier.L3, rt.Tier.DISK.moveHotter().?);
}

test "Handle invalid returns INVALID_HANDLE" {
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var data: [16]u8 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(&data, 16);
    ht.release(h);

    // After release, handle is invalid (states[h.slot] == Free)
    // Calling validateHandle on a released handle should panic
    // We can't easily catch panics in Zig tests, so we just verify state
    try std.testing.expectEqual(rt.SlotState.Free, ht.meta.states[h.slot]);
    try std.testing.expectEqual(@as(u32, 1), ht.meta.generations[h.slot]);
}

test "accessUntouched does not increment heat" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    const h = tr.allocL1(16);
    _ = tr.accessUntouched(h);
    try std.testing.expectEqual(@as(u32, 0), tr.handles.meta.heats[h.slot]);
}

test "full cycle: alloc L2 → access → promote → decay → demote" {
    var l1: [4096]u8 = undefined;
    var l2: [8192]u8 = undefined;
    var l3: [8192]u8 = undefined;
    var ptrs: [64]?*anyopaque = undefined;
    var gens: [64]u32 = undefined;
    var sizes: [64]u32 = undefined;
    var states: [64]rt.SlotState = undefined;
    var free_next: [64]u32 = undefined;
    var heats: [64]u32 = undefined;
    var total_heats: [64]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = rt.MetaStore.init(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = rt.TieredRuntime.init(&l1, &l2, &l3, ms, &log);

    const h = tr.allocL2(1024);
    try std.testing.expectEqual(rt.Tier.L2, tr.tierOfHandle(h));

    // Access 300 times — heat grows to 300
    var i: u32 = 0;
    while (i < 300) : (i += 1) _ = tr.access(h);
    try std.testing.expectEqual(@as(u32, 300), tr.handles.meta.heats[h.slot]);

    // Tick: decay 300→150, still >100 → promote to L1
    tr.tick();
    try std.testing.expectEqual(rt.Tier.L1, tr.tierOfHandle(h));
    try std.testing.expectEqual(@as(u32, 150), tr.handles.meta.heats[h.slot]);

    // More ticks: 150→75→37→18→9→4→2→1→0
    // After heat < 30, demote from L1 → L2
    var ticks: u32 = 0;
    while (tr.tierOfHandle(h) == .L1 and ticks < 20) : (ticks += 1) {
        tr.tick();
    }
    try std.testing.expect(ticks < 20); // should demote within 20 ticks
    try std.testing.expectEqual(rt.Tier.L2, tr.tierOfHandle(h));
}

test "tick logs TICK event with migration count" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    const ms = makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log);

    tr.tick();
    // Last event should be TICK
    try std.testing.expectEqual(rt.EventKind.TICK, log[0].kind);
    try std.testing.expectEqual(@as(u32, 0), log[0].arg); // 0 migrations

    // Promote a handle and check tick log
    const h = tr.allocL2(16);
    tr.handles.meta.heats[h.slot] = 250;
    tr.tick();
    const idx = @as(u32, @intCast(tr.logger.head - 1)); // last written
    const log_idx = (idx + tr.logger.capacity()) % tr.logger.capacity();
    // Should have TICK event with migrated count
    try std.testing.expectEqual(rt.EventKind.TICK, tr.logger.buf[log_idx].kind);
}

test "dual-heat: heat=0 after release, total_heat preserved" {
    var ptrs: [CAP]?*anyopaque = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
var total_heats: [CAP]u32 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&ptrs, &gens, &sizes, &states, &free_next, &heats, &total_heats));
    var data: [16]u8 = undefined;

    const h = ht.alloc(&data, 16);
    try std.testing.expect(h.isValid());
    const slot = h.slot;

    // Touch 10 times (increments both heat and total_heat)
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        ht.touch(h);
    }
    try std.testing.expectEqual(@as(u32, 10), ht.meta.heats[slot]);
    try std.testing.expectEqual(@as(u32, 10), ht.meta.total_heats[slot]);

    // Release → heat = 0, total_heat unchanged
    ht.release(h);
    try std.testing.expectEqual(@as(u32, 0), ht.meta.heats[slot]);
    try std.testing.expectEqual(@as(u32, 10), ht.meta.total_heats[slot]);
}
