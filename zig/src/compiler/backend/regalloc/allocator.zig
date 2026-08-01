const std = @import("std");
const mir = @import("../mir/mir.zig");
const classes = @import("classes.zig");
const RegClass = classes.RegClass;
const liveness = @import("liveness.zig");
const LiveInterval = liveness.LiveInterval;
const IntervalList = liveness.IntervalList;
const CfgInfo = liveness.CfgInfo;

// Rematerialization

pub const Remat = union(enum) {
    imm64: i64,
    zero: void,
};

// Constraints 

pub const ConstrainedReg = struct {
    vreg: u32,
    required_reg: i16,
};

pub fn collectConstraints(
    mfunc: *const mir.MFunction,
    out: *std.ArrayList(ConstrainedReg),
) !void {
    for (mfunc.blocks.items) |*block| {
        for (block.instrs.items) |inst| {
            switch (inst) {
                .idiv => |d| {
                    if (liveness.vregOf(d.quotient) != 0) {
                        try out.append(.{ .vreg = liveness.vregOf(d.quotient), .required_reg = 0 });
                    }
                },
                else => {},
            }
        }
    }
}

pub fn applyConstraints(
    sorted: []LiveInterval,
    constraints: *const std.ArrayList(ConstrainedReg),
    regs: *std.AutoHashMap(u32, i16),
) !void {
    for (constraints.items) |c| {
        for (sorted) |*interval| {
            if (interval.vreg == c.vreg) {
                try regs.put(c.vreg, c.required_reg);
                break;
            }
        }
    }
}

// Linear Scan with Splitting 

pub fn linearScanSplitting(
    initial: []const LiveInterval,
    call_positions: []const usize,
    use_points: *const std.AutoHashMap(u32, std.ArrayList(usize)),
    hints: *const std.AutoHashMap(u32, u32),
    regs: *std.AutoHashMap(u32, i16),
    spills: *std.AutoHashMap(u32, i32),
    remat: *std.AutoHashMap(u32, Remat),
    remat_candidates: *const std.AutoHashMap(u32, Remat),
    allocator: std.mem.Allocator,
) !void {
    var worklist = std.ArrayList(LiveInterval).init(allocator);
    defer worklist.deinit();
    for (initial) |iv| try worklist.append(iv);

    var active_gpr = std.ArrayList(LiveInterval).init(allocator);
    defer active_gpr.deinit();
    var active_xmm = std.ArrayList(LiveInterval).init(allocator);
    defer active_xmm.deinit();

    var free_gpr = std.ArrayList(i16).init(allocator);
    defer free_gpr.deinit();
    var free_xmm = std.ArrayList(i16).init(allocator);
    defer free_xmm.deinit();

    var next_spill_off: i32 = 0;

    var wi: usize = 0;
    while (wi < worklist.items.len) {
        const interval = worklist.items[wi];
        wi += 1;

        if (interval.start > interval.end) continue;
        if (interval.vreg == 0) continue;
        if (regs.contains(interval.vreg)) continue;

        const active = switch (interval.reg_class) {
            .gpr64 => &active_gpr,
            .xmm => &active_xmm,
            .flags => &active_gpr,
        };
        const free_regs = switch (interval.reg_class) {
            .gpr64 => &free_gpr,
            .xmm => &free_xmm,
            .flags => &free_gpr,
        };

        try rebuildFreeSplit(active, free_regs, regs, interval.start, interval.reg_class);

        const pool_info = interval.reg_class.info();
        const callee_saved = pool_info.callee_saved;
        const call_spans = if (callee_saved.len > 0) liveness.spansCall(interval, call_positions) else false;
        const pool = if (call_spans) callee_saved else pool_info.available;

        var allocated = false;

        if (hints.get(interval.vreg)) |src_vreg| {
            if (regs.get(src_vreg)) |hinted_reg| {
                var dominated = false;
                for (free_regs.items) |fr| {
                    if (fr == hinted_reg) { dominated = true; break; }
                }
                if (dominated) {
                    removeReg(free_regs, hinted_reg);
                    try regs.put(interval.vreg, hinted_reg);
                    try insertSortedByEnd(active, interval);
                    allocated = true;
                }
            }
        }

        if (!allocated) {
            if (findAvailReg(free_regs, pool)) |reg| {
                removeReg(free_regs, reg);
                try regs.put(interval.vreg, reg);
                try insertSortedByEnd(active, interval);
                allocated = true;
            }
        }

        if (!allocated) {
            const victim_idx = findBestSpillCandidate(active, use_points, interval.start);
            const victim = active.items[victim_idx];
            const victim_reg = regs.get(victim.vreg) orelse continue;

            const split_point = chooseSplitPoint(victim, interval.start, use_points);

            if (split_point < victim.end) {
                _ = regs.remove(victim.vreg);

                try worklist.append(.{
                    .vreg = victim.vreg,
                    .start = split_point,
                    .end = victim.end,
                    .reg_class = victim.reg_class,
                    .spill_weight = victim.spill_weight,
                });

                try regs.put(interval.vreg, victim_reg);
                active.items[victim_idx] = .{
                    .vreg = victim.vreg,
                    .start = victim.start,
                    .end = split_point,
                    .reg_class = victim.reg_class,
                    .spill_weight = victim.spill_weight,
                };
                try insertSortedByEnd(active, interval);
            } else {
                _ = regs.remove(victim.vreg);

                if (remat_candidates.get(victim.vreg)) |r| {
                    try remat.put(victim.vreg, r);
                } else {
                    next_spill_off -= 8;
                    try spills.put(victim.vreg, next_spill_off);
                }

                try regs.put(interval.vreg, victim_reg);
                _ = active.orderedRemove(victim_idx);
                try insertSortedByEnd(active, interval);
            }
        }
    }

    for (active_gpr.items) |act| {
        if (!regs.contains(act.vreg) and !spills.contains(act.vreg) and !remat.contains(act.vreg)) {
            if (remat_candidates.get(act.vreg)) |r| {
                try remat.put(act.vreg, r);
            } else {
                next_spill_off -= 8;
                try spills.put(act.vreg, next_spill_off);
            }
        }
    }
    for (active_xmm.items) |act| {
        if (!regs.contains(act.vreg) and !spills.contains(act.vreg) and !remat.contains(act.vreg)) {
            if (remat_candidates.get(act.vreg)) |r| {
                try remat.put(act.vreg, r);
            } else {
                next_spill_off -= 8;
                try spills.put(act.vreg, next_spill_off);
            }
        }
    }
}

fn chooseSplitPoint(
    victim: LiveInterval,
    current_start: usize,
    use_points: *const std.AutoHashMap(u32, std.ArrayList(usize)),
) usize {
    const next_use = liveness.findNextUse(use_points, victim.vreg, current_start);
    if (next_use) |nu| {
        if (nu > victim.start) return nu;
    }
    return victim.end;
}

fn findBestSpillCandidate(
    active: *const std.ArrayList(LiveInterval),
    use_points: *const std.AutoHashMap(u32, std.ArrayList(usize)),
    current_start: usize,
) usize {
    _ = use_points;
    _ = current_start;
    var best_idx: usize = 0;
    var best_weight: f64 = std.math.inf(f64);

    for (active.items, 0..) |act, i| {
        if (act.spill_weight < best_weight) {
            best_weight = act.spill_weight;
            best_idx = i;
        }
    }
    return best_idx;
}

fn rebuildFreeSplit(
    active: *std.ArrayList(LiveInterval),
    free_regs: *std.ArrayList(i16),
    regs: *const std.AutoHashMap(u32, i16),
    current_start: usize,
    reg_class: RegClass,
) !void {
    free_regs.clearRetainingCapacity();
    const pool = reg_class.info().available;
    for (pool) |r| try free_regs.append(r);

    var i: usize = 0;
    while (i < active.items.len) {
        if (active.items[i].end >= current_start) {
            const vreg = active.items[i].vreg;
            if (regs.get(vreg)) |r| {
                for (free_regs.items, 0..) |fr, j| {
                    if (fr == r) {
                        _ = free_regs.orderedRemove(j);
                        break;
                    }
                }
            }
            i += 1;
        } else {
            _ = active.orderedRemove(i);
        }
    }
}

fn findAvailReg(free_regs: *const std.ArrayList(i16), preferred: []const i16) ?i16 {
    for (preferred) |r| {
        for (free_regs.items) |fr| {
            if (fr == r) return r;
        }
    }
    return null;
}

fn removeReg(free_regs: *std.ArrayList(i16), reg: i16) void {
    for (free_regs.items, 0..) |r, i| {
        if (r == reg) {
            _ = free_regs.orderedRemove(i);
            return;
        }
    }
}

fn insertSortedByEnd(list: *std.ArrayList(LiveInterval), item: LiveInterval) !void {
    var i: usize = 0;
    while (i < list.items.len and list.items[i].end < item.end) {
        i += 1;
    }
    try list.insert(i, item);
}
