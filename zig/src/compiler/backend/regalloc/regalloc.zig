const std = @import("std");
const mir = @import("../mir/mir.zig");

pub const RegClass = @import("classes.zig").RegClass;
pub const RegClassInfo = @import("classes.zig").RegClassInfo;
pub const SCRATCH_REG = @import("classes.zig").SCRATCH_REG;
pub const SCRATCH_REG_2 = @import("classes.zig").SCRATCH_REG_2;

pub const Remat = @import("allocator.zig").Remat;
pub const RegAllocResult = @import("spill.zig").RegAllocResult;

pub const regForOp = @import("spill.zig").regForOp;
pub const isSpilled = @import("spill.zig").isSpilled;
pub const isRemat = @import("spill.zig").isRemat;
pub const spilledMemOp = @import("spill.zig").spilledMemOp;
pub const loadSpilledOp = @import("spill.zig").loadSpilledOp;
pub const storeSpilledOp = @import("spill.zig").storeSpilledOp;
pub const getUsedCalleeSaved = @import("spill.zig").getUsedCalleeSaved;

pub fn allocRegs(mfunc: *const mir.MFunction, allocator: std.mem.Allocator) !RegAllocResult {
    const liveness = @import("liveness.zig");
    const allocator_mod = @import("allocator.zig");

    var regs = std.AutoHashMap(u32, i16).init(allocator);
    errdefer regs.deinit();
    var spills = std.AutoHashMap(u32, i32).init(allocator);
    errdefer spills.deinit();
    var remat = std.AutoHashMap(u32, Remat).init(allocator);
    errdefer remat.deinit();

    var intervals = std.ArrayList(liveness.LiveInterval).init(allocator);
    defer intervals.deinit();
    var call_positions = std.ArrayList(usize).init(allocator);
    defer call_positions.deinit();
    var constraints = std.ArrayList(allocator_mod.ConstrainedReg).init(allocator);
    defer constraints.deinit();

    var use_points = std.AutoHashMap(u32, std.ArrayList(usize)).init(allocator);
    defer {
        var up_it = use_points.iterator();
        while (up_it.next()) |kv| kv.value_ptr.deinit();
        use_points.deinit();
    }

    var hints = std.AutoHashMap(u32, u32).init(allocator);
    defer hints.deinit();

    var remat_candidates = std.AutoHashMap(u32, Remat).init(allocator);
    defer remat_candidates.deinit();

    var cfg_infos = std.ArrayList(liveness.CfgInfo).init(allocator);
    defer {
        for (cfg_infos.items) |*ci| {
            ci.predecessors.deinit();
            ci.successors.deinit();
            ci.dominators.deinit();
        }
        cfg_infos.deinit();
    }

    try liveness.buildCfg(mfunc, &cfg_infos, allocator);
    try liveness.computeDominators(mfunc, cfg_infos.items);
    liveness.computeLoopDepths(mfunc, cfg_infos.items);

    try liveness.computeLiveIntervals(mfunc, &intervals, &call_positions, &use_points, &hints, &remat_candidates, &cfg_infos, allocator);
    try allocator_mod.collectConstraints(mfunc, &constraints);

    const sorted = try liveness.sortIntervals(intervals, allocator);
    defer allocator.free(sorted);

    try allocator_mod.applyConstraints(sorted, &constraints, &regs);
    try allocator_mod.linearScanSplitting(sorted, call_positions.items, &use_points, &hints, &regs, &spills, &remat, &remat_candidates, allocator);

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
        .remat = remat,
    };
}
