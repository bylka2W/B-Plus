const std = @import("std");
const rt = @import("runtime.zig");

const HANDLES = 64;
const OPS = 100_000;
const SEED = 42;

var rng_state: u64 = SEED;

fn rng() u32 {
    rng_state = rng_state *% 6364136223846793005 +% 1442695040888963407;
    return @as(u32, @truncate(rng_state >> 32));
}

fn allocSize() u32 {
    return (@as(u32, @truncate(rng() & 0xFF)) + 1) * 4;
}

fn hashState(s: *const rt.TieredRuntime.Snapshot) u64 {
    var h: u64 = SEED;
    for (s.heats, 0..) |v, i| {
        h = h *% 6364136223846793005 +% v;
        h = h *% 6364136223846793005 +% s.total_heats[i];
        h = h *% 6364136223846793005 +% @as(u8, @intFromEnum(s.tiers[i]));
        h = h *% 6364136223846793005 +% @as(u8, @intFromEnum(s.states[i]));
        h = h *% 6364136223846793005 +% s.gens[i];
    }
    return h;
}

test "deterministic stress: 100k ops with migration, budget, heat" {
    const l1 = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(l1);
    const l2 = try std.testing.allocator.alloc(u8, 64 * 1024 * 1024);
    defer std.testing.allocator.free(l2);
    const l3 = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(l3);
    var cids: [HANDLES]u32 = undefined;
    var offs: [HANDLES]u32 = undefined;
    var gens: [HANDLES]u32 = undefined;
    var sizes: [HANDLES]u32 = undefined;
    var states: [HANDLES]rt.SlotState = undefined;
    var free_next: [HANDLES]u32 = undefined;
    var heats: [HANDLES]u32 = undefined;
    var total_heats: [HANDLES]u32 = undefined;
    var log: [4096]rt.RuntimeEvent = undefined;
    const total_chunks = (l1.len + l2.len + l3.len) / rt.CHUNK_SIZE + 1;
    const chunk_buf = try std.testing.allocator.alloc(rt.Chunk, total_chunks);
    defer std.testing.allocator.free(chunk_buf);
    const free_list_buf = try std.testing.allocator.alloc(u32, total_chunks);
    defer std.testing.allocator.free(free_list_buf);
    const ms = rt.MetaStore.init(&cids, &offs, &gens, &sizes, &states, &free_next, &heats, &total_heats);
    var tr = rt.TieredRuntime.init(l1, l2, l3, ms, &log, chunk_buf, free_list_buf);

    var handles = std.ArrayList(rt.Handle).init(std.testing.allocator);
    defer handles.deinit();

    var total_alloc: u32 = 0;
    var total_access: u32 = 0;
    var total_release: u32 = 0;
    var total_migrations: u32 = 0;
    var total_ticks: u32 = 0;
    var total_tier_changes: u32 = 0;

    var i: u32 = 0;
    while (i < OPS) : (i += 1) {
        if (i % 100 == 0) {
            var pre = try rt.TieredRuntime.Snapshot.capture(&tr, std.testing.allocator);
            defer pre.deinit(std.testing.allocator);

            const log_head_before = tr.logger.head;
            tr.tick();
            total_ticks += 1;

            var tick_migs: u32 = 0;
            const capacity = tr.logger.capacity();
            var k = log_head_before;
            while (k != tr.logger.head) : (k = (k + 1) % capacity) {
                if (tr.logger.buf[k].kind == .MIGRATE) tick_migs += 1;
            }
            total_migrations += tick_migs;

            var post = try rt.TieredRuntime.Snapshot.capture(&tr, std.testing.allocator);
            defer post.deinit(std.testing.allocator);

            var tier_changes: u32 = 0;
            for (0..HANDLES) |slot| {
                if (post.states[slot] == .Used) {
                    const pre_tier = pre.tiers[slot];
                    const post_tier = post.tiers[slot];
                    if (pre_tier != post_tier and pre_tier != .DISK and post_tier != .DISK) {
                        tier_changes += 1;
                    }
                    try std.testing.expect(post.heats[slot] <= post.total_heats[slot]);
                } else {
                    try std.testing.expectEqual(@as(u32, 0), post.heats[slot]);
                }
            }

            total_tier_changes += tier_changes;
        }

        const op = rng() % 3;
        switch (op) {
            0 => {
                if (handles.items.len < HANDLES) {
                    const sz = allocSize();
                    const h = tr.allocL2(@max(sz, 16));
                    if (h.isValid()) {
                        try handles.append(h);
                        total_alloc += 1;
                    }
                }
            },
            1 => {
                if (handles.items.len > 0) {
                    const idx = rng() % @as(u32, @intCast(handles.items.len));
                    const h = handles.items[idx];
                    if (!h.isValid()) continue;
                    _ = tr.access(h);
                    total_access += 1;
                }
            },
            2 => {
                if (handles.items.len > 0) {
                    const idx = rng() % @as(u32, @intCast(handles.items.len));
                    const h = handles.items[idx];
                    tr.release(h);
                    _ = handles.swapRemove(idx);
                    total_release += 1;
                }
            },
            else => unreachable,
        }
    }

    var final_snap = try rt.TieredRuntime.Snapshot.capture(&tr, std.testing.allocator);
    defer final_snap.deinit(std.testing.allocator);

    var used_count: u32 = 0;
    for (0..HANDLES) |slot| {
        if (tr.handles.meta.states[slot] == .Used) used_count += 1;
    }
    try std.testing.expectEqual(@as(u32, @intCast(handles.items.len)), used_count);

    for (0..HANDLES) |slot| {
        if (final_snap.states[slot] == .Used) {
            try std.testing.expect(final_snap.heats[slot] <= final_snap.total_heats[slot]);
        } else {
            try std.testing.expectEqual(@as(u32, 0), final_snap.heats[slot]);
        }
    }

    const fp = hashState(&final_snap);

    const mig_rate = @as(f64, @floatFromInt(total_migrations)) / @as(f64, @floatFromInt(OPS)) * 1000.0;
    std.debug.print("\n=== STRESS RESULTS (seed={d}) ===\n", .{SEED});
    std.debug.print("Ops: {d} (a={d} ac={d} r={d} t={d})\n", .{ OPS, total_alloc, total_access, total_release, total_ticks });
    std.debug.print("Migrations: {d} ({d:.3}/1k ops)\n", .{ total_migrations, mig_rate });
    std.debug.print("Active handles: {d}\n", .{handles.items.len});
    std.debug.print("Tier changes detected: {d}\n", .{total_tier_changes});
    const excess = total_tier_changes -| total_migrations;
    std.debug.print("Multi-handle chunk excess: {d}\n", .{excess});
    try std.testing.expect(total_migrations <= total_tier_changes);
    std.debug.print("Fingerprint: 0x{x:016}\n", .{fp});

    const Pair = struct { slot: u32, val: u32 };

    var sorted_th: [HANDLES]Pair = undefined;
    for (final_snap.total_heats, 0..) |th, slot| {
        sorted_th[slot] = .{ .slot = @intCast(slot), .val = th };
    }
    std.mem.sort(Pair, &sorted_th, {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool { return a.val > b.val; }
    }.lessThan);
    std.debug.print("Top total_heat: ", .{});
    for (0..@min(5, handles.items.len)) |j| {
        std.debug.print("{d}:{d} ", .{ sorted_th[j].slot, sorted_th[j].val });
    }
    std.debug.print("\n", .{});

    var sorted_h: [HANDLES]Pair = undefined;
    for (final_snap.heats, 0..) |h, slot| {
        sorted_h[slot] = .{ .slot = @intCast(slot), .val = h };
    }
    std.mem.sort(Pair, &sorted_h, {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool { return a.val > b.val; }
    }.lessThan);
    std.debug.print("Top heat: ", .{});
    for (0..@min(5, handles.items.len)) |j| {
        std.debug.print("{d}:{d} ", .{ sorted_h[j].slot, sorted_h[j].val });
    }
    std.debug.print("\n", .{});
}
