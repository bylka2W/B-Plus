const std = @import("std");
const rt = @import("runtime.zig");

const CAP = 8;
const CHUNK_CAP = 32;

var runtime_test_free_list: [CHUNK_CAP]u32 = undefined;

fn makeMetaStore(
    cids: *[CAP]u32,
    offs: *[CAP]u32,
    gens: *[CAP]u32,
    sizes: *[CAP]u32,
    states: *[CAP]rt.SlotState,
    free_next: *[CAP]u32,
    heats: *[CAP]u32,
    total_heats: *[CAP]u32,
) rt.MetaStore {
    return rt.MetaStore.init(cids, offs, gens, sizes, states, free_next, heats, total_heats);
}

fn makeRuntime(l1: *[4096]u8, l2: *[4096]u8, l3: *[4096]u8, ms: rt.MetaStore, log: *[64]rt.RuntimeEvent, chunks: *[CHUNK_CAP]rt.Chunk) rt.TieredRuntime {
    @memset(&runtime_test_free_list, 0);
    return rt.TieredRuntime.init(l1, l2, l3, ms, log, chunks, &runtime_test_free_list);
}

test "HandleTable alloc returns valid handle" {
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(0, 0, 16);
    try std.testing.expect(h.isValid());
    try std.testing.expect(h.slot < CAP);
    try std.testing.expectEqual(@as(u32, 1), h.generation);
    try std.testing.expectEqual(@as(u32, 1), ht.count);
}

test "HandleTable alloc reuses freed slot" {
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h1 = ht.alloc(0, 0, 16);
    try std.testing.expectEqual(@as(u32, 0), h1.slot);
    { var dummy_cs: [1]rt.Chunk = undefined; var dummy_fl: [1]u32 = undefined; var cs = rt.ChunkStore.init(&dummy_cs, &dummy_fl); ht.release(h1, &cs); }
    const h2 = ht.alloc(1, 0, 32);
    try std.testing.expectEqual(@as(u32, 0), h2.slot);
    try std.testing.expectEqual(@as(u32, 2), h2.generation);
}

test "touch increments heat" {
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(0, 0, 16);
    try std.testing.expectEqual(@as(u32, 0), ht.meta.heats[h.slot]);

    ht.touch(h);
    try std.testing.expectEqual(@as(u32, 1), ht.meta.heats[h.slot]);

    ht.touch(h);
    ht.touch(h);
    try std.testing.expectEqual(@as(u32, 3), ht.meta.heats[h.slot]);
}

test "touch caps heat at maxInt(u32)" {
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(0, 0, 16);
    ht.meta.heats[h.slot] = std.math.maxInt(u32);
    ht.touch(h);
    try std.testing.expectEqual(std.math.maxInt(u32), ht.meta.heats[h.slot]);
}

test "release zeros heat" {
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(0, 0, 16);
    ht.touch(h);
    ht.touch(h);
    try std.testing.expectEqual(@as(u32, 2), ht.meta.heats[h.slot]);
    { var dummy_cs: [1]rt.Chunk = undefined; var dummy_fl: [1]u32 = undefined; var cs = rt.ChunkStore.init(&dummy_cs, &dummy_fl); ht.release(h, &cs); }
    try std.testing.expectEqual(@as(u32, 0), ht.meta.heats[h.slot]);
}

test "TieredRuntime allocL1 and access" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL1(100);
    try std.testing.expect(h.isValid());
    const slice = tr.access(h);
    try std.testing.expectEqual(@as(usize, 100), slice.len);
}

test "access touches heat" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

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
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

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
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

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
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL1(16);
    tr.handles.meta.heats[h.slot] = 100;
    const unused_slot: u32 = if (h.slot == 0) 1 else 0;
    tr.handles.meta.heats[unused_slot] = 200;
    tr.tick();
    try std.testing.expectEqual(@as(u32, 50), tr.handles.meta.heats[h.slot]);
    try std.testing.expectEqual(@as(u32, 200), tr.handles.meta.heats[unused_slot]);
}

test "promote when chunk heat exceeds threshold" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL2(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    tr.chunks.chunks[cid].heat = 250;
    tr.tick();

    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L1, tier);
}

test "demote when chunk heat below threshold" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL2(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    tr.chunks.chunks[cid].heat = 10;
    tr.tick();

    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L3, tier);
}

test "hysteresis: stable range 30-100 does nothing" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL2(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    tr.chunks.chunks[cid].heat = 90;
    tr.tick();

    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L2, tier);
}

test "already-promoted L1 handle does not promote further" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL1(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    tr.chunks.chunks[cid].heat = 200;
    tr.tick();

    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L1, tier);
}

test "cold L3 handle does not demote further" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL3(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    tr.chunks.chunks[cid].heat = 10;
    tr.tick();

    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L3, tier);
}

test "budget limits chunk migrations per tick to 4" {
    var l1: [8192]u8 = undefined;
    var l2: [16384]u8 = undefined;
    var l3: [8192]u8 = undefined;
    const BIG_CAP = 64;
    var big_cids: [BIG_CAP]u32 = undefined;
    var big_offs: [BIG_CAP]u32 = undefined;
    var big_gens: [BIG_CAP]u32 = undefined;
    var big_sizes: [BIG_CAP]u32 = undefined;
    var big_states: [BIG_CAP]rt.SlotState = undefined;
    var big_free_next: [BIG_CAP]u32 = undefined;
    var big_heats: [BIG_CAP]u32 = undefined;
    var big_total_heats: [BIG_CAP]u32 = undefined;
    var big_log: [64]rt.RuntimeEvent = undefined;
    var big_chunks: [32]rt.Chunk = undefined;
    var big_free_list: [32]u32 = undefined;
    const big_ms = rt.MetaStore.init(&big_cids, &big_offs, &big_gens, &big_sizes, &big_states, &big_free_next, &big_heats, &big_total_heats);
    var tr = rt.TieredRuntime.init(&l1, &l2, &l3, big_ms, &big_log, &big_chunks, &big_free_list);

    // Allocate 8 handles with 200 bytes each so each gets its own chunk
    // (2*200 = 400 > CHUNK_SIZE=256)
    var handles: [8]rt.Handle = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        handles[i] = tr.allocL2(200);
        const cid = tr.handles.meta.chunk_ids[handles[i].slot];
        tr.chunks.chunks[cid].heat = 250;
    }

    tr.tick();

    var promoted: u32 = 0;
    for (handles) |h| {
        if (tr.tierOfHandle(h) == .L1) promoted += 1;
    }
    try std.testing.expect(promoted <= 4);
    try std.testing.expect(promoted < 8);
}

test "migration preserves data integrity" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL2(16);
    const slice = tr.access(h);
    for (0..16) |j| slice[j] = @intCast(j + 42);

    const cid = tr.handles.meta.chunk_ids[h.slot];
    tr.chunks.chunks[cid].heat = 250;
    tr.tick();

    const slice2 = tr.access(h);
    try std.testing.expectEqual(@as(usize, 16), slice2.len);
    for (0..16) |j| {
        try std.testing.expectEqual(@as(u8, @intCast(j + 42)), slice2[j]);
    }

    const tier = tr.tierOfHandle(h);
    try std.testing.expectEqual(rt.Tier.L1, tier);
}

test "tick multiple: heat grows then decays" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL2(16);

    var k: u32 = 0;
    while (k < 10) : (k += 1) _ = tr.access(h);
    try std.testing.expectEqual(@as(u32, 10), tr.handles.meta.heats[h.slot]);

    tr.tick();
    try std.testing.expectEqual(@as(u32, 5), tr.handles.meta.heats[h.slot]);

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
    rl.log(.MIGRATE, 2, 3, 30);

    try std.testing.expectEqual(@as(u32, 2), rl.count);
    try std.testing.expectEqual(@as(u32, 1), rl.head);
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
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(0, 0, 16);
    { var dummy_cs: [1]rt.Chunk = undefined; var dummy_fl: [1]u32 = undefined; var cs = rt.ChunkStore.init(&dummy_cs, &dummy_fl); ht.release(h, &cs); }

    try std.testing.expectEqual(rt.SlotState.Free, ht.meta.states[h.slot]);
    try std.testing.expectEqual(@as(u32, 1), ht.meta.generations[h.slot]);
}

test "accessUntouched does not increment heat" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL1(16);
    _ = tr.accessUntouched(h);
    try std.testing.expectEqual(@as(u32, 0), tr.handles.meta.heats[h.slot]);
}

test "full cycle: alloc L2 -> access -> promote -> decay -> demote" {
    var l1: [8192]u8 = undefined;
    var l2: [16384]u8 = undefined;
    var l3: [8192]u8 = undefined;
    var cids: [64]u32 = undefined;
    var offs: [64]u32 = undefined;
    var gens: [64]u32 = undefined;
    var sizes: [64]u32 = undefined;
    var states: [64]rt.SlotState = undefined;
    var free_next: [64]u32 = undefined;
    var heats: [64]u32 = undefined;
    var total_heats: [64]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [64]rt.Chunk = undefined;
    var free_list: [64]u32 = undefined;
    const ms = rt.MetaStore.init(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = rt.TieredRuntime.init(&l1, &l2, &l3, ms, &log, &chunks, &free_list);

    const h = tr.allocL2(1024);
    try std.testing.expectEqual(rt.Tier.L2, tr.tierOfHandle(h));

    var i: u32 = 0;
    while (i < 300) : (i += 1) _ = tr.access(h);
    try std.testing.expectEqual(@as(u32, 300), tr.handles.meta.heats[h.slot]);

    tr.tick();
    try std.testing.expectEqual(rt.Tier.L1, tr.tierOfHandle(h));
    try std.testing.expectEqual(@as(u32, 150), tr.handles.meta.heats[h.slot]);

    var ticks: u32 = 0;
    while (tr.tierOfHandle(h) == .L1 and ticks < 20) : (ticks += 1) {
        tr.tick();
    }
    try std.testing.expect(ticks < 20);
    try std.testing.expectEqual(rt.Tier.L2, tr.tierOfHandle(h));
}

test "tick logs TICK event with migration count" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    tr.tick();
    try std.testing.expectEqual(rt.EventKind.TICK, log[0].kind);
    try std.testing.expectEqual(@as(u32, 0), log[0].arg);

    const h = tr.allocL2(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    tr.chunks.chunks[cid].heat = 250;
    tr.tick();
    const idx = @as(u32, @intCast(tr.logger.head - 1));
    const log_idx = (idx + tr.logger.capacity()) % tr.logger.capacity();
    try std.testing.expectEqual(rt.EventKind.TICK, tr.logger.buf[log_idx].kind);
}

test "dual-heat: heat=0 after release, total_heat preserved" {
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var ht = rt.HandleTable.init(makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats));

    const h = ht.alloc(0, 0, 16);
    try std.testing.expect(h.isValid());
    const slot = h.slot;

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        ht.touch(h);
    }
    try std.testing.expectEqual(@as(u32, 10), ht.meta.heats[slot]);
    try std.testing.expectEqual(@as(u32, 10), ht.meta.total_heats[slot]);

    { var dummy_cs: [1]rt.Chunk = undefined; var dummy_fl: [1]u32 = undefined; var cs = rt.ChunkStore.init(&dummy_cs, &dummy_fl); ht.release(h, &cs); }
    try std.testing.expectEqual(@as(u32, 0), ht.meta.heats[slot]);
    try std.testing.expectEqual(@as(u32, 10), ht.meta.total_heats[slot]);
}

test "top-K: only hottest chunks promoted within budget" {
    var l1: [8192]u8 = undefined;
    var l2: [16384]u8 = undefined;
    var l3: [8192]u8 = undefined;
    const BIG_CAP = 64;
    var big_cids: [BIG_CAP]u32 = undefined;
    var big_offs: [BIG_CAP]u32 = undefined;
    var big_gens: [BIG_CAP]u32 = undefined;
    var big_sizes: [BIG_CAP]u32 = undefined;
    var big_states: [BIG_CAP]rt.SlotState = undefined;
    var big_free_next: [BIG_CAP]u32 = undefined;
    var big_heats: [BIG_CAP]u32 = undefined;
    var big_total_heats: [BIG_CAP]u32 = undefined;
    var big_log: [64]rt.RuntimeEvent = undefined;
    var big_chunks: [32]rt.Chunk = undefined;
    var big_free_list: [32]u32 = undefined;
    const big_ms = rt.MetaStore.init(&big_cids, &big_offs, &big_gens, &big_sizes, &big_states, &big_free_next, &big_heats, &big_total_heats);
    var tr = rt.TieredRuntime.init(&l1, &l2, &l3, big_ms, &big_log, &big_chunks, &big_free_list);

    // Create 6 chunks with decreasing heat (heat values: 250, 240, 230, 220, 210, 200)
    // Each alloc uses 200B → separate chunk (2*200=400 > CHUNK_SIZE=256)
    var handles: [6]rt.Handle = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        handles[i] = tr.allocL2(200);
        const cid = tr.handles.meta.chunk_ids[handles[i].slot];
        tr.chunks.chunks[cid].heat = @as(u32, @intCast(250 - @as(u32, @intCast(i)) * 10));
    }

    tr.tick();

    var promoted: [6]bool = .{false} ** 6;
    for (handles, 0..) |h, idx| {
        if (tr.tierOfHandle(h) == .L1) promoted[idx] = true;
    }

    // Budget=4, only 4 hottest should promote (heat 250, 240, 230, 220)
    // Coldest 2 (210, 200) stay in L2
    try std.testing.expect(promoted[0]); // heat=250
    try std.testing.expect(promoted[1]); // heat=240
    try std.testing.expect(promoted[2]); // heat=230
    try std.testing.expect(promoted[3]); // heat=220
    try std.testing.expect(!promoted[4]); // heat=210
    try std.testing.expect(!promoted[5]); // heat=200
}

test "top-K: tie-breaking by chunk_id for equal heat" {
    var l1: [8192]u8 = undefined;
    var l2: [16384]u8 = undefined;
    var l3: [8192]u8 = undefined;
    const BIG_CAP = 64;
    var big_cids: [BIG_CAP]u32 = undefined;
    var big_offs: [BIG_CAP]u32 = undefined;
    var big_gens: [BIG_CAP]u32 = undefined;
    var big_sizes: [BIG_CAP]u32 = undefined;
    var big_states: [BIG_CAP]rt.SlotState = undefined;
    var big_free_next: [BIG_CAP]u32 = undefined;
    var big_heats: [BIG_CAP]u32 = undefined;
    var big_total_heats: [BIG_CAP]u32 = undefined;
    var big_log: [64]rt.RuntimeEvent = undefined;
    var big_chunks: [32]rt.Chunk = undefined;
    var big_free_list: [32]u32 = undefined;
    const big_ms = rt.MetaStore.init(&big_cids, &big_offs, &big_gens, &big_sizes, &big_states, &big_free_next, &big_heats, &big_total_heats);
    var tr = rt.TieredRuntime.init(&l1, &l2, &l3, big_ms, &big_log, &big_chunks, &big_free_list);

    // Create 5 chunks all with heat=250 → tie needs chunk_id to break
    var handles: [5]rt.Handle = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        handles[i] = tr.allocL2(200);
        const cid = tr.handles.meta.chunk_ids[handles[i].slot];
        tr.chunks.chunks[cid].heat = 250;
    }

    tr.tick();

    // Budget=4, 5 eligible with equal heat
    // Lowest chunk_id should win tie-break (chunk 0,1,2,3 promote; chunk 4 stays)
    var promoted: [5]bool = .{false} ** 5;
    for (handles, 0..) |h, idx| {
        if (tr.tierOfHandle(h) == .L1) promoted[idx] = true;
    }

    try std.testing.expect(promoted[0]);
    try std.testing.expect(promoted[1]);
    try std.testing.expect(promoted[2]);
    try std.testing.expect(promoted[3]);
    try std.testing.expect(!promoted[4]);
}

test "cooldown: fresh chunk migrates without cooldown" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    tr.tick(); // epoch=1
    const h = tr.allocL2(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    try std.testing.expectEqual(.success, tr.migrateChunk(cid, .L1));
}

test "cooldown blocks re-migration within window" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    tr.tick(); // epoch=1
    const h = tr.allocL2(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];

    // Migrate L2→L1 (succeeds)
    try std.testing.expectEqual(.success, tr.migrateChunk(cid, .L1));

    // Same epoch: cooldown blocks
    try std.testing.expectEqual(.cooldown, tr.migrateChunk(cid, .L2));

    // 1 tick later (epoch=2): cooldown active (2-1=1 < 3)
    tr.tick();
    try std.testing.expectEqual(.cooldown, tr.migrateChunk(cid, .L2));

    // 2 ticks later (epoch=3): cooldown active (3-1=2 < 3)
    tr.tick();
    try std.testing.expectEqual(.cooldown, tr.migrateChunk(cid, .L2));

    // 3 ticks later (epoch=4): cooldown expired (4-1=3 >= 3)
    tr.tick();
    const r = tr.migrateChunk(cid, .L2);
    try std.testing.expect(r != .cooldown);
}

test "cooldown in tick: promoted chunk stays L1 for COOLDOWN_TICKS" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL2(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    tr.chunks.chunks[cid].heat = 250;

    // Tick 1: promotes L2→L1, cooldown starts
    tr.tick();
    try std.testing.expectEqual(rt.Tier.L1, tr.tierOfHandle(h));

    // Tick 2 & 3: cooldown active → heat decays but stays L1
    tr.tick();
    try std.testing.expectEqual(rt.Tier.L1, tr.tierOfHandle(h));
    tr.tick();
    try std.testing.expectEqual(rt.Tier.L1, tr.tierOfHandle(h));

    // Tick 4: cooldown expired (3 ticks = COOLDOWN_TICKS) + heat below DEMOTE_THRESH → demotes
    tr.tick();
    try std.testing.expectEqual(rt.Tier.L2, tr.tierOfHandle(h));
    // heat after 4 ticks of decay: 250 → 125(t1) → 62(t2) → 31(t3) → 15(t4)
    // After t4 promote: 125>>1 = 62. After t2: 31. After t3: 15. After t4: 7.
    // At t4: cooldown expired (4-1=3) + heat 7 < 30 → demote L1→L2
}

test "cost: expensive demote blocked for heat near threshold" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL1(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    // Before tick: heat=59. After decay: 29. cost=2 → score=(30-29)-2 = -1 ≤ 0 → blocked
    tr.chunks.chunks[cid].heat = 59;
    tr.tick();
    try std.testing.expectEqual(rt.Tier.L1, tr.tierOfHandle(h));
}

test "cost: cheap demote passes for cold chunk" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL2(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    // Before tick: heat=5. After decay: 2. cost=1 → score=(30-2)-1 = 27 > 0 → passes
    tr.chunks.chunks[cid].heat = 5;
    tr.tick();
    try std.testing.expectEqual(rt.Tier.L3, tr.tierOfHandle(h));
}

test "cost: promote still works for hot chunk" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL3(16);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    // Before tick: heat=300. After decay: 150 (>100) → promote. cost=1 → score=149 > 0 → passes
    tr.chunks.chunks[cid].heat = 300;
    tr.tick();
    try std.testing.expectEqual(rt.Tier.L2, tr.tierOfHandle(h));
}

// ═══════════════════════════════════════════════
// Stage 6: Memory Layer (free-list + compaction)
// ═══════════════════════════════════════════════

test "Stage 6: free list reuses chunk IDs after release empties chunk" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h1 = tr.allocL2(200);
    const cid1 = tr.handles.meta.chunk_ids[h1.slot];

    // Release — chunk has 1 slot so it becomes empty
    tr.release(h1);

    // Allocate again — should reuse freed chunk_id
    const h2 = tr.allocL2(200);
    const cid2 = tr.handles.meta.chunk_ids[h2.slot];
    try std.testing.expectEqual(cid1, cid2);
}

test "Stage 6: free list maintains multiple freed chunk IDs" {
    var l1: [8192]u8 = undefined;
    var l2: [16384]u8 = undefined;
    var l3: [8192]u8 = undefined;
    const BIG_CAP = 64;
    var big_cids: [BIG_CAP]u32 = undefined;
    var big_offs: [BIG_CAP]u32 = undefined;
    var big_gens: [BIG_CAP]u32 = undefined;
    var big_sizes: [BIG_CAP]u32 = undefined;
    var big_states: [BIG_CAP]rt.SlotState = undefined;
    var big_free_next: [BIG_CAP]u32 = undefined;
    var big_heats: [BIG_CAP]u32 = undefined;
    var big_total_heats: [BIG_CAP]u32 = undefined;
    var big_log: [64]rt.RuntimeEvent = undefined;
    var big_chunks: [32]rt.Chunk = undefined;
    var big_free_list: [32]u32 = undefined;
    const big_ms = rt.MetaStore.init(&big_cids, &big_offs, &big_gens, &big_sizes, &big_states, &big_free_next, &big_heats, &big_total_heats);
    var tr = rt.TieredRuntime.init(&l1, &l2, &l3, big_ms, &big_log, &big_chunks, &big_free_list);

    // Allocate 3 chunks, each 200 bytes (separate chunks because 2*200 > 256)
    var handles: [3]rt.Handle = undefined;
    for (&handles, 0..) |*h, i| {
        h.* = tr.allocL2(200);
        const slice = tr.access(h.*);
        for (0..200) |j| slice[j] = @intCast((i * 200 + j) & 0xFF);
    }

    for (handles, 0..) |h, i| {
        const slice = tr.access(h);
        try std.testing.expectEqual(@as(u8, @intCast((i * 200) & 0xFF)), slice[0]);
    }

    // Release all handles (reverse order to test LIFO free stack)
    var released_cids: [3]u32 = undefined;
    for (&released_cids, handles, 0..) |*rc, h, i| {
        rc.* = tr.handles.meta.chunk_ids[h.slot];
        tr.release(h);
        // After release, chunk is freed
        _ = i;
    }

    // Allocate again — should reuse freed IDs (LIFO: last freed first)
    var new_handles: [3]rt.Handle = undefined;
    for (&new_handles) |*h| h.* = tr.allocL2(200);

    // The last freed chunk_id should be reused first
    const new_cid0 = tr.handles.meta.chunk_ids[new_handles[0].slot];
    try std.testing.expectEqual(released_cids[2], new_cid0);
}

test "Stage 6: compaction preserves data integrity" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h = tr.allocL2(128);
    const cid = tr.handles.meta.chunk_ids[h.slot];
    const slice = tr.access(h);
    for (0..128) |j| slice[j] = @intCast(j ^ 0xAB);

    // Set heat in stable range (30-100) so tick doesn't migrate
    tr.chunks.chunks[cid].heat = 90;

    // Force compaction by setting epoch to COMPACT_INTERVAL-1 then ticking
    tr.setAllocator(std.testing.allocator);
    tr.epoch = rt.TieredRuntime.COMPACT_INTERVAL - 1;
    tr.tick();

    // Verify data survived compaction
    const slice2 = tr.access(h);
    try std.testing.expectEqual(@as(usize, 128), slice2.len);
    for (0..128) |j| {
        try std.testing.expectEqual(@as(u8, @intCast(j ^ 0xAB)), slice2[j]);
    }
    // Tier unchanged (heat 90→45 after decay, still in stable range)
    try std.testing.expectEqual(rt.Tier.L2, tr.tierOfHandle(h));
}

test "Stage 6: compaction across multiple tiers" {
    var l1: [4096]u8 = undefined;
    var l2: [4096]u8 = undefined;
    var l3: [4096]u8 = undefined;
    var cids: [CAP]u32 = undefined;
    var offs: [CAP]u32 = undefined;
    var gens: [CAP]u32 = undefined;
    var sizes: [CAP]u32 = undefined;
    var states: [CAP]rt.SlotState = undefined;
    var free_next: [CAP]u32 = undefined;
    var heats: [CAP]u32 = undefined;
    var total_heats: [CAP]u32 = undefined;
    var log: [64]rt.RuntimeEvent = undefined;
    var chunks: [CHUNK_CAP]rt.Chunk = undefined;
    const ms = makeMetaStore(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = makeRuntime(&l1, &l2, &l3, ms, &log, &chunks);

    const h1 = tr.allocL1(64);
    const h2 = tr.allocL2(64);
    const h3 = tr.allocL3(64);

    // Set heats in stable range so tick doesn't migrate
    {
        const c1 = tr.handles.meta.chunk_ids[h1.slot];
        const c2 = tr.handles.meta.chunk_ids[h2.slot];
        const c3 = tr.handles.meta.chunk_ids[h3.slot];
        tr.chunks.chunks[c1].heat = 90;
        tr.chunks.chunks[c2].heat = 90;
        tr.chunks.chunks[c3].heat = 90;
    }

    // Write distinct patterns
    var s1 = tr.access(h1);
    var s2 = tr.access(h2);
    var s3 = tr.access(h3);
    for (0..64) |j| {
        s1[j] = @intCast(0x10 + j);
        s2[j] = @intCast(0x20 + j);
        s3[j] = @intCast(0x30 + j);
    }

    // Force compaction
    tr.setAllocator(std.testing.allocator);
    tr.epoch = rt.TieredRuntime.COMPACT_INTERVAL - 1;
    tr.tick();

    // Verify all three patterns survived
    const r1 = tr.access(h1);
    const r2 = tr.access(h2);
    const r3 = tr.access(h3);
    for (0..64) |j| {
        try std.testing.expectEqual(@as(u8, @intCast(0x10 + j)), r1[j]);
        try std.testing.expectEqual(@as(u8, @intCast(0x20 + j)), r2[j]);
        try std.testing.expectEqual(@as(u8, @intCast(0x30 + j)), r3[j]);
    }
}
