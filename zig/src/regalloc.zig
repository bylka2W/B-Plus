const std = @import("std");
const mir = @import("mir.zig");
const x64 = @import("x64enc.zig");

pub const RegAllocResult = struct {
    regs: std.AutoHashMap(u32, i16),
    spills: std.AutoHashMap(u32, i32),
    spill_frame_size: u32,
};

const LiveInterval = struct {
    vreg: u32,
    start: usize,
    end: usize,
};

const IntervalList = std.ArrayList(LiveInterval);

const AVAILABLE_GPRS = [_]i16{ 0, 1, 2, 3, 6, 7, 8, 9, 10 };
const CALLEE_SAVED = [_]i16{ 3, 6, 7 };
const SPILL_SCRATCH: i16 = 11;

pub fn allocRegs(mfunc: *const mir.MFunction, allocator: std.mem.Allocator) !RegAllocResult {
    var regs = std.AutoHashMap(u32, i16).init(allocator);
    errdefer regs.deinit();
    var spills = std.AutoHashMap(u32, i32).init(allocator);
    errdefer spills.deinit();

    var intervals = std.ArrayList(LiveInterval).init(allocator);
    var call_positions = std.ArrayList(usize).init(allocator);
    try computeLiveIntervals(mfunc, &intervals, &call_positions, allocator);

    const sorted = try sortIntervals(intervals, allocator);
    defer allocator.free(sorted);

    try linearScan(sorted, call_positions.items, &regs, &spills, allocator);

    var max_spill: u32 = 0;
    var it = spills.valueIterator();
    while (it.next()) |off| {
        const abs_off = @as(u32, @intCast(-off.*));
        if (abs_off > max_spill) max_spill = abs_off;
    }

    return .{
        .regs = regs,
        .spills = spills,
        .spill_frame_size = max_spill,
    };
}

fn computeLiveIntervals(
    mfunc: *const mir.MFunction,
    out_intervals: *IntervalList,
    out_call_pos: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
) !void {
    var intervals = std.AutoHashMap(u32, LiveInterval).init(allocator);
    defer intervals.deinit();

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

    var it = intervals.iterator();
    while (it.next()) |kv| {
        try out_intervals.append(kv.value_ptr.*);
    }
}

fn vregOf(op: mir.MOperand) u32 {
    return switch (op) {
        .vreg => |v| v,
        else => 0,
    };
}

fn sortIntervals(intervals: IntervalList, allocator: std.mem.Allocator) ![]LiveInterval {
    const sorted = try allocator.dupe(LiveInterval, intervals.items);
    std.mem.sort(LiveInterval, sorted, {}, struct {
        fn less(_: void, a: LiveInterval, b: LiveInterval) bool {
            if (a.start != b.start) return a.start < b.start;
            return a.end < b.end;
        }
    }.less);
    return sorted;
}

fn spansCall(interval: LiveInterval, call_positions: []const usize) bool {
    for (call_positions) |cp| {
        if (cp > interval.start and cp < interval.end) return true;
    }
    return false;
}

fn linearScan(
    sorted: []const LiveInterval,
    call_positions: []const usize,
    regs: *std.AutoHashMap(u32, i16),
    spills: *std.AutoHashMap(u32, i32),
    allocator: std.mem.Allocator,
) !void {
    var active = std.ArrayList(*const LiveInterval).init(allocator);
    defer active.deinit();

    var free_regs = std.ArrayList(i16).init(allocator);
    defer free_regs.deinit();

    var next_spill_off: i32 = 0;

    for (sorted) |*interval| {
        if (interval.start > interval.end) continue;
        if (interval.vreg == 0) continue;

        try rebuildFree(&active, &free_regs, regs, interval.start);

        const pool: []const i16 = if (spansCall(interval.*, call_positions)) &CALLEE_SAVED else &AVAILABLE_GPRS;

        if (findAvailReg(&free_regs, pool)) |reg| {
            removeReg(&free_regs, reg);
            try regs.put(interval.vreg, reg);
            try insertSortedByEnd(&active, interval);
        } else {
            var spill_candidate: *const LiveInterval = undefined;
            var spill_idx: usize = 0;
            var farthest_end: usize = 0;

            for (active.items, 0..) |act, i| {
                if (act.end > farthest_end) {
                    farthest_end = act.end;
                    spill_candidate = act;
                    spill_idx = i;
                }
            }

            if (farthest_end > interval.end) {
                const spilled_vreg = spill_candidate.vreg;
                const reg = regs.get(spilled_vreg).?;
                _ = regs.remove(spilled_vreg);

                next_spill_off -= 8;
                try spills.put(spilled_vreg, next_spill_off);

                try regs.put(interval.vreg, reg);
                _ = active.orderedRemove(spill_idx);
                try insertSortedByEnd(&active, interval);
            } else {
                next_spill_off -= 8;
                try spills.put(interval.vreg, next_spill_off);
            }
        }
    }
}

fn rebuildFree(
    active: *std.ArrayList(*const LiveInterval),
    free_regs: *std.ArrayList(i16),
    regs: *std.AutoHashMap(u32, i16),
    current_start: usize,
) !void {
    free_regs.clearRetainingCapacity();
    for (&AVAILABLE_GPRS) |*r| try free_regs.append(r.*);

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

fn insertSortedByEnd(list: *std.ArrayList(*const LiveInterval), item: *const LiveInterval) !void {
    var i: usize = 0;
    while (i < list.items.len and list.items[i].end < item.end) {
        i += 1;
    }
    try list.insert(i, item);
}

pub fn regForOp(ra: *const RegAllocResult, op: mir.MOperand) i16 {
    return switch (op) {
        .vreg => |v| ra.regs.get(v) orelse -1,
        .phys => |r| @intFromEnum(r),
        .imm => -1,
        .mem => |m| @intFromEnum(m.base),
    };
}

pub fn isSpilled(ra: *const RegAllocResult, op: mir.MOperand) bool {
    return switch (op) {
        .vreg => |v| ra.spills.contains(v),
        else => false,
    };
}

pub fn spilledMemOp(ra: *const RegAllocResult, op: mir.MOperand) x64.Operand {
    const vreg = switch (op) {
        .vreg => |v| v,
        else => return .{},
    };
    const off = ra.spills.get(vreg) orelse return .{};
    return x64.Operand{ .base_reg = 5, .disp = off };
}

pub fn loadSpilledOp(code: *std.ArrayList(u8), ra: *const RegAllocResult, op: mir.MOperand, scratch: i16) !void {
    const vreg = switch (op) {
        .vreg => |v| v,
        else => return,
    };
    const off = ra.spills.get(vreg) orelse return;
    const mem = x64.Operand{ .base_reg = 5, .disp = off };
    try x64.emit(code, .MOV_R64_MEM, &.{ .{ .reg = scratch }, mem });
}

pub fn storeSpilledOp(code: *std.ArrayList(u8), ra: *const RegAllocResult, op: mir.MOperand, scratch: i16) !void {
    const vreg = switch (op) {
        .vreg => |v| v,
        else => return,
    };
    const off = ra.spills.get(vreg) orelse return;
    const mem = x64.Operand{ .base_reg = 5, .disp = off };
    try x64.emit(code, .MOV_MEM_R64, &.{ mem, .{ .reg = scratch } });
}

const CALLEE_SAVED_LIST = [_]i16{ 3, 6, 7 };

pub fn getUsedCalleeSaved(ra: *const RegAllocResult, out: *std.ArrayList(i16)) void {
    for (&CALLEE_SAVED_LIST) |reg| {
        var it = ra.regs.valueIterator();
        while (it.next()) |r| {
            if (r.* == reg) {
                out.append(reg) catch {};
                break;
            }
        }
    }
}
