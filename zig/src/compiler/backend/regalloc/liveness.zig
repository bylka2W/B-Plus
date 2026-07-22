const std = @import("std");
const mir = @import("../mir/mir.zig");
const classes = @import("classes.zig");
const RegClass = classes.RegClass;

// ===== Live Interval =====

pub const LiveInterval = struct {
    vreg: u32,
    start: usize,
    end: usize,
    reg_class: RegClass = .gpr64,
    spill_weight: f64 = 0.0,
};

pub const IntervalList = std.ArrayList(LiveInterval);

// ===== CFG / Dominators =====

pub const CfgInfo = struct {
    predecessors: std.ArrayList(usize),
    successors: std.ArrayList(usize),
    dominators: std.ArrayList(usize),
    loop_depth: u32,
    block_start_pos: usize,
    block_end_pos: usize,
};

pub fn buildCfg(mfunc: *const mir.MFunction, cfg_infos: *std.ArrayList(CfgInfo), allocator: std.mem.Allocator) !void {
    for (mfunc.blocks.items) |_| {
        try cfg_infos.append(.{
            .predecessors = std.ArrayList(usize).init(allocator),
            .successors = std.ArrayList(usize).init(allocator),
            .dominators = std.ArrayList(usize).init(allocator),
            .loop_depth = 0,
            .block_start_pos = 0,
            .block_end_pos = 0,
        });
    }

    var pos: usize = 0;
    for (mfunc.blocks.items, 0..) |*block, i| {
        cfg_infos.items[i].block_start_pos = pos;
        for (block.instrs.items) |_| {
            pos += 1;
        }
        cfg_infos.items[i].block_end_pos = pos;

        if (block.instrs.items.len > 0) {
            const last = block.instrs.items[block.instrs.items.len - 1];
            switch (last) {
                .jmp => |j| {
                    if (j.target < mfunc.blocks.items.len) {
                        try cfg_infos.items[i].successors.append(j.target);
                        try cfg_infos.items[j.target].predecessors.append(i);
                    }
                },
                .jcc => |j| {
                    if (j.target < mfunc.blocks.items.len) {
                        try cfg_infos.items[i].successors.append(j.target);
                        try cfg_infos.items[j.target].predecessors.append(i);
                    }
                    if (i + 1 < mfunc.blocks.items.len) {
                        try cfg_infos.items[i].successors.append(i + 1);
                        try cfg_infos.items[i + 1].predecessors.append(i);
                    }
                },
                else => {
                    if (i + 1 < mfunc.blocks.items.len) {
                        try cfg_infos.items[i].successors.append(i + 1);
                        try cfg_infos.items[i + 1].predecessors.append(i);
                    }
                },
            }
        }
    }
}

pub fn computeDominators(mfunc: *const mir.MFunction, cfg_infos: []CfgInfo) !void {
    const n = mfunc.blocks.items.len;
    if (n == 0) return;

    for (cfg_infos) |*ci| {
        ci.dominators.clearRetainingCapacity();
    }

    try cfg_infos[0].dominators.append(0);
    for (cfg_infos, 0..) |*ci, i| {
        if (i == 0) continue;
        try ci.dominators.append(i);
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (cfg_infos, 0..) |*ci, i| {
            if (i == 0) continue;
            if (ci.predecessors.items.len == 0) continue;

            var first_pred_doms: std.ArrayList(usize) = std.ArrayList(usize).init(mfunc.allocator);
            defer first_pred_doms.deinit();

            if (cfg_infos[ci.predecessors.items[0]].dominators.items.len > 0) {
                for (cfg_infos[ci.predecessors.items[0]].dominators.items) |d| {
                    try first_pred_doms.append(d);
                }
            }

            for (ci.predecessors.items[1..]) |pred| {
                const pred_doms = cfg_infos[pred].dominators.items;
                var new_list = std.ArrayList(usize).init(mfunc.allocator);
                defer new_list.deinit();

                for (first_pred_doms.items) |d| {
                    for (pred_doms) |pd| {
                        if (d == pd) {
                            try new_list.append(d);
                            break;
                        }
                    }
                }
                first_pred_doms.clearRetainingCapacity();
                for (new_list.items) |d| {
                    try first_pred_doms.append(d);
                }
            }

            try first_pred_doms.append(i);

            if (first_pred_doms.items.len != ci.dominators.items.len) {
                ci.dominators.clearRetainingCapacity();
                for (first_pred_doms.items) |d| {
                    try ci.dominators.append(d);
                }
                changed = true;
            } else {
                var same = true;
                for (first_pred_doms.items, 0..) |d, j| {
                    if (d != ci.dominators.items[j]) {
                        same = false;
                        break;
                    }
                }
                if (!same) {
                    ci.dominators.clearRetainingCapacity();
                    for (first_pred_doms.items) |d| {
                        try ci.dominators.append(d);
                    }
                    changed = true;
                }
            }
        }
    }
}

pub fn computeLoopDepths(mfunc: *const mir.MFunction, cfg_infos: []CfgInfo) void {
    const n = mfunc.blocks.items.len;
    if (n == 0) return;

    for (cfg_infos) |*ci| {
        ci.loop_depth = 0;
    }

    var in_loop: [256]bool = undefined;
    var worklist: [256]usize = undefined;
    var wl_len: usize = 0;

    for (cfg_infos, 0..) |*ci, header| {
        var has_back_edge = false;
        for (ci.predecessors.items) |tail| {
            if (isDominatedBy(tail, header, cfg_infos)) {
                has_back_edge = true;
                break;
            }
        }
        if (!has_back_edge) continue;

        for (in_loop[0..n]) |*b| b.* = false;
        wl_len = 0;

        for (ci.predecessors.items) |tail| {
            if (isDominatedBy(tail, header, cfg_infos) and !in_loop[tail]) {
                in_loop[tail] = true;
                worklist[wl_len] = tail;
                wl_len += 1;
            }
        }

        while (wl_len > 0) {
            wl_len -= 1;
            const current = worklist[wl_len];
            for (cfg_infos[current].predecessors.items) |pred| {
                if (!in_loop[pred] and isDominatedBy(pred, header, cfg_infos)) {
                    in_loop[pred] = true;
                    worklist[wl_len] = pred;
                    wl_len += 1;
                }
            }
        }

        var bi: usize = 0;
        while (bi < n) : (bi += 1) {
            if (in_loop[bi]) {
                cfg_infos[bi].loop_depth += 1;
            }
        }
    }
}

pub fn isDominatedBy(node: usize, dominator: usize, cfg_infos: []const CfgInfo) bool {
    for (cfg_infos[node].dominators.items) |d| {
        if (d == dominator) return true;
    }
    return false;
}

// ===== Utilities =====

pub fn vregOf(op: mir.MOperand) u32 {
    return switch (op) {
        .vreg => |v| v,
        else => 0,
    };
}

pub fn sortIntervals(intervals: IntervalList, allocator: std.mem.Allocator) ![]LiveInterval {
    const sorted = try allocator.dupe(LiveInterval, intervals.items);
    std.mem.sort(LiveInterval, sorted, {}, struct {
        fn less(_: void, a: LiveInterval, b: LiveInterval) bool {
            if (a.start != b.start) return a.start < b.start;
            return a.end < b.end;
        }
    }.less);
    return sorted;
}

pub fn spansCall(interval: LiveInterval, call_positions: []const usize) bool {
    for (call_positions) |cp| {
        if (cp > interval.start and cp < interval.end) return true;
    }
    return false;
}

pub fn findNextUse(
    use_points: *const std.AutoHashMap(u32, std.ArrayList(usize)),
    vreg: u32,
    after: usize,
) ?usize {
    const uses = use_points.get(vreg) orelse return null;
    for (uses.items) |u| {
        if (u > after) return u;
    }
    return null;
}

// ===== Live Interval Computation =====

const Remat = @import("allocator.zig").Remat;

pub fn computeLiveIntervals(
    mfunc: *const mir.MFunction,
    out_intervals: *IntervalList,
    out_call_pos: *std.ArrayList(usize),
    use_points: *std.AutoHashMap(u32, std.ArrayList(usize)),
    hints: *std.AutoHashMap(u32, u32),
    remat_candidates: *std.AutoHashMap(u32, Remat),
    cfg_infos: *const std.ArrayList(CfgInfo),
    allocator: std.mem.Allocator,
) !void {
    var intervals = std.AutoHashMap(u32, LiveInterval).init(allocator);
    defer intervals.deinit();

    var use_counts = std.AutoHashMap(u32, u32).init(allocator);
    defer use_counts.deinit();

    var pos: usize = 0;

    for (mfunc.blocks.items) |*block| {
        for (block.instrs.items) |inst| {
            var reads: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
            var read_count: usize = 0;
            var writes: [2]u32 = .{ 0, 0 };
            var write_count: usize = 0;

            switch (inst) {
                .mov => |m| {
                    writes[write_count] = vregOf(m.dst); write_count += 1;
                    reads[read_count] = vregOf(m.src); read_count += 1;
                    if (vregOf(m.dst) != 0 and vregOf(m.src) != 0) {
                        try hints.put(vregOf(m.dst), vregOf(m.src));
                        try hints.put(vregOf(m.src), vregOf(m.dst));
                    }
                    if (vregOf(m.dst) != 0 and m.src == .imm) {
                        if (m.src.imm == 0) {
                            try remat_candidates.put(vregOf(m.dst), .zero);
                        } else {
                            try remat_candidates.put(vregOf(m.dst), .{ .imm64 = m.src.imm });
                        }
                    }
                },
                .add => |a| {
                    writes[write_count] = vregOf(a.dst); write_count += 1;
                    reads[read_count] = vregOf(a.dst); read_count += 1;
                    reads[read_count] = vregOf(a.src); read_count += 1;
                },
                .sub => |s| {
                    writes[write_count] = vregOf(s.dst); write_count += 1;
                    reads[read_count] = vregOf(s.dst); read_count += 1;
                    reads[read_count] = vregOf(s.src); read_count += 1;
                },
                .imul => |m| {
                    writes[write_count] = vregOf(m.dst); write_count += 1;
                    reads[read_count] = vregOf(m.dst); read_count += 1;
                    reads[read_count] = vregOf(m.src); read_count += 1;
                },
                .idiv => |m| {
                    writes[write_count] = vregOf(m.dst); write_count += 1;
                    reads[read_count] = vregOf(m.dst); read_count += 1;
                    reads[read_count] = vregOf(m.src); read_count += 1;
                },
                .@"and" => |m| {
                    writes[write_count] = vregOf(m.dst); write_count += 1;
                    reads[read_count] = vregOf(m.dst); read_count += 1;
                    reads[read_count] = vregOf(m.src); read_count += 1;
                },
                .@"or" => |m| {
                    writes[write_count] = vregOf(m.dst); write_count += 1;
                    reads[read_count] = vregOf(m.dst); read_count += 1;
                    reads[read_count] = vregOf(m.src); read_count += 1;
                },
                .xor => |m| {
                    writes[write_count] = vregOf(m.dst); write_count += 1;
                    reads[read_count] = vregOf(m.dst); read_count += 1;
                    reads[read_count] = vregOf(m.src); read_count += 1;
                },
                .shl, .shr, .sar => |m| {
                    writes[write_count] = vregOf(m.dst); write_count += 1;
                    reads[read_count] = vregOf(m.dst); read_count += 1;
                    reads[read_count] = vregOf(m.amount); read_count += 1;
                },
                .not_op, .neg_op => |m| {
                    writes[write_count] = vregOf(m.dst); write_count += 1;
                    reads[read_count] = vregOf(m.dst); read_count += 1;
                },
                .test_flags => |tf| {
                    reads[read_count] = vregOf(tf.a); read_count += 1;
                    reads[read_count] = vregOf(tf.b); read_count += 1;
                },
                .cmp => |c| {
                    writes[write_count] = vregOf(c.dst); write_count += 1;
                    reads[read_count] = vregOf(c.a); read_count += 1;
                    reads[read_count] = vregOf(c.b); read_count += 1;
                },
                .cmp_flags => |cf| {
                    reads[read_count] = vregOf(cf.a); read_count += 1;
                    reads[read_count] = vregOf(cf.b); read_count += 1;
                },
                .jmp, .jcc => {},
                .alloca => |a| {
                    writes[write_count] = vregOf(a.dst); write_count += 1;
                },
                .lea => |l| {
                    writes[write_count] = vregOf(l.dst); write_count += 1;
                    reads[read_count] = vregOf(l.base); read_count += 1;
                    if (l.index != .imm) {
                        reads[read_count] = vregOf(l.index); read_count += 1;
                    }
                },
                .load => |l| {
                    writes[write_count] = vregOf(l.dst); write_count += 1;
                    reads[read_count] = vregOf(l.ptr); read_count += 1;
                },
                .store => |s| {
                    reads[read_count] = vregOf(s.ptr); read_count += 1;
                    reads[read_count] = vregOf(s.src); read_count += 1;
                },
                .call => |c| {
                    try out_call_pos.append(pos);
                    writes[write_count] = vregOf(c.dst); write_count += 1;
                    for (0..c.arg_count) |i| {
                        reads[read_count] = vregOf(c.args[i]); read_count += 1;
                    }
                },
                .ret => |r| {
                    reads[read_count] = vregOf(r.val); read_count += 1;
                },
                .phi => {
                    writes[write_count] = vregOf(inst.phi.dst); write_count += 1;
                },
                .fadd, .fsub, .fmul, .fdiv => |f| {
                    writes[write_count] = vregOf(f.dst); write_count += 1;
                    reads[read_count] = vregOf(f.a); read_count += 1;
                    reads[read_count] = vregOf(f.b); read_count += 1;
                },
                .fneg_op, .fsqrt_op => |f| {
                    writes[write_count] = vregOf(f.dst); write_count += 1;
                    reads[read_count] = vregOf(f.dst); read_count += 1;
                },
                .fcmp => |c| {
                    writes[write_count] = vregOf(c.dst); write_count += 1;
                    reads[read_count] = vregOf(c.a); read_count += 1;
                    reads[read_count] = vregOf(c.b); read_count += 1;
                },
                .sitofp, .fptosi, .fpext, .fptrunc, .sext_op, .zext_op, .trunc_op => |c| {
                    writes[write_count] = vregOf(c.dst); write_count += 1;
                    reads[read_count] = vregOf(c.src); read_count += 1;
                },
                .select => |s| {
                    writes[write_count] = vregOf(s.dst); write_count += 1;
                    reads[read_count] = vregOf(s.dst); read_count += 1;
                    reads[read_count] = vregOf(s.src); read_count += 1;
                },
            }

            for (reads[0..read_count]) |vreg| {
                if (vreg == 0) continue;
                const entry = try intervals.getOrPut(vreg);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{ .vreg = vreg, .start = pos, .end = pos };
                } else {
                    if (pos > entry.value_ptr.*.end) entry.value_ptr.*.end = pos;
                    if (pos < entry.value_ptr.*.start) entry.value_ptr.*.start = pos;
                }
                const up = try use_points.getOrPut(vreg);
                if (!up.found_existing) up.value_ptr.* = std.ArrayList(usize).init(allocator);
                try up.value_ptr.append(pos);

                const uc = try use_counts.getOrPut(vreg);
                if (!uc.found_existing) uc.value_ptr.* = 0;
                uc.value_ptr.* += 1;
            }

            for (writes[0..write_count]) |vreg| {
                if (vreg == 0) continue;
                const entry = try intervals.getOrPut(vreg);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{ .vreg = vreg, .start = pos, .end = pos };
                } else {
                    if (pos < entry.value_ptr.*.start) entry.value_ptr.*.start = pos;
                    if (pos > entry.value_ptr.*.end) entry.value_ptr.*.end = pos;
                }
                const uc = try use_counts.getOrPut(vreg);
                if (!uc.found_existing) uc.value_ptr.* = 0;
                uc.value_ptr.* += 1;
            }

            pos += 1;
        }
    }

    for (mfunc.params) |p| {
        const vreg = vregOf(p);
        if (vreg == 0) continue;
        const entry = try intervals.getOrPut(vreg);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .vreg = vreg, .start = 0, .end = pos };
        } else {
            entry.value_ptr.*.start = 0;
        }
    }

    // ── Extend intervals across back-edges ──
    for (mfunc.blocks.items, 0..) |*blk, bi| {
        if (blk.instrs.items.len > 0) {
            const last = blk.instrs.items[blk.instrs.items.len - 1];
            switch (last) {
                .jmp => |j| {
                    if (j.target <= bi) {
                        const tstart = cfg_infos.items[j.target].block_start_pos;
                        var it2 = intervals.iterator();
                        while (it2.next()) |kv| {
                            const iv = kv.value_ptr.*;
                            if (iv.start < tstart and iv.end >= tstart) {
                                const be = if (cfg_infos.items[bi].block_end_pos > 0) cfg_infos.items[bi].block_end_pos - 1 else 0;
                                if (be > kv.value_ptr.end) kv.value_ptr.end = be;
                            }
                        }
                    }
                },
                .jcc => |j| {
                    if (j.target <= bi) {
                        const tstart = cfg_infos.items[j.target].block_start_pos;
                        var it2 = intervals.iterator();
                        while (it2.next()) |kv| {
                            const iv = kv.value_ptr.*;
                            if (iv.start < tstart and iv.end >= tstart) {
                                const be = if (cfg_infos.items[bi].block_end_pos > 0) cfg_infos.items[bi].block_end_pos - 1 else 0;
                                if (be > kv.value_ptr.end) kv.value_ptr.end = be;
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    var it = intervals.iterator();
    while (it.next()) |kv| {
        var iv = kv.value_ptr.*;
        const len: f64 = @floatFromInt(@max(iv.end - iv.start + 1, 1));
        const uses: f64 = @floatFromInt(use_counts.get(iv.vreg) orelse 0);

        var max_loop_depth: f64 = 0;
        for (cfg_infos.items) |ci| {
            const bstart = ci.block_start_pos;
            const bend = ci.block_end_pos;
            if (bend > bstart and iv.start < bend and iv.end >= bstart) {
                max_loop_depth = @max(max_loop_depth, @as(f64, @floatFromInt(ci.loop_depth)));
            }
        }

        iv.spill_weight = (uses * (1.0 + max_loop_depth * 10.0)) / len;

        // Apply type-based register class from vreg_info
        if (mfunc.vreg_info.get(iv.vreg)) |info| {
            iv.reg_class = switch (info.class) {
                .gpr => .gpr64,
                .xmm => .xmm,
            };
        }

        try out_intervals.append(iv);
    }
}
