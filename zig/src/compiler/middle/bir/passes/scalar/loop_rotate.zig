const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../../bir.zig");
const bir_cfg = @import("../../analysis/cfg/cfg.zig");
const bir_dominators = @import("../../analysis/dominator/dominator.zig");
const bir_loops = @import("../../analysis/loops/loops.zig");
const PreservedAnalyses = bir.PreservedAnalyses;
const INVALID_ID = bir.INVALID_ID;
const NO_VALUE = bir.NO_VALUE;
const BlockId = bir.BlockId;
const ValueId = bir.ValueId;

pub const LoopRotatePass = bir.Pass{
    .name = "loop-rotate",
    .run = runLoopRotate,
};

fn runLoopRotate(ctx: *bir.PassContext) anyerror!PreservedAnalyses {
    const module = ctx.module;
    for (module.functions.items, 0..) |*func, fid| {
        if (func.blocks.items.len < 3) continue;
        const func_id = @as(bir.FunctionId, @intCast(fid));

        const cfg = try ctx.analysis.getCFG(func_id);
        const loop_info = try ctx.analysis.getLoopInfo(func_id);
        const loops = loop_info.loops;

        for (loops) |loop| {
            try rotateLoop(module, func_id, func, cfg, &loop);
        }
    }
    return PreservedAnalyses.none();
}

fn rotateLoop(module: *bir.Module, func_id: bir.FunctionId, func: *bir.Function, _: *const bir_cfg.CFG, loop: *const bir_loops.Loop) !void {
    if (loop.back_edges.len != 1) return;

    const header = loop.header;
    const latch = loop.back_edges[0].from;
    const preheader = findPreheader(func, loop) orelse return;

    const hdr = func.getBlock(header);
    if (hdr.instrs.items.len < 2) return;

    const hdr_term = &hdr.instrs.items[hdr.instrs.items.len - 1];
    if (hdr_term.op != .cond_br) return;

    const cond_val = hdr_term.data.cond_branch.cond;
    const body_bid = hdr_term.data.cond_branch.then_block;
    const exit_bid = hdr_term.data.cond_branch.else_block;

    const cmp_idx = findDefIdxInBlock(func, header, cond_val) orelse return;
    const cmp_inst = &hdr.instrs.items[cmp_idx];

    const is_cmp = switch (cmp_inst.op) {
        .lt, .le, .gt, .ge, .eq, .ne => true,
        else => false,
    };
    if (!is_cmp) return;
    if (cmp_inst.operands.len != 2) return;

    var phi_operand_idx: ?usize = null;
    for (cmp_inst.operands, 0..) |op, i| {
        if (isPhiInBlock(func, header, op)) {
            phi_operand_idx = i;
            break;
        }
    }
    if (phi_operand_idx == null) return;

    const bound_val = cmp_inst.operands[1 - phi_operand_idx.?];

    const phi_val = cmp_inst.operands[phi_operand_idx.?];
    const phi_inst_idx = findDefIdxInBlock(func, header, phi_val) orelse return;
    const phi_inst = &hdr.instrs.items[phi_inst_idx];
    if (phi_inst.op != .phi) return;

    var init_val: ?ValueId = null;
    var next_val: ?ValueId = null;
    for (phi_inst.data.phi_incoming) |inc| {
        if (inc.block == preheader) init_val = inc.value;
        if (inc.block == latch) next_val = inc.value;
    }
    if (init_val == null or next_val == null) return;

    const guard_bid = try module.addBlock(func_id, "loop.guard");

    const cond_continues = (body_bid == hdr_term.data.cond_branch.then_block);
    const guard_enter = if (cond_continues) header else exit_bid;
    const guard_exit = if (cond_continues) exit_bid else header;

    const guard_cmp_ops = if (phi_operand_idx.? == 0)
        try module.allocator.dupe(ValueId, &.{ init_val.?, bound_val })
    else
        try module.allocator.dupe(ValueId, &.{ bound_val, init_val.? });
    const guard_cmp = try module.addInst(func_id, guard_bid, .{
        .op = cmp_inst.op,
        .ty = cmp_inst.ty,
        .result = NO_VALUE,
        .operands = guard_cmp_ops,
        .data = .{ .none = {} },
    });
    _ = try module.addInst(func_id, guard_bid, .{
        .op = .cond_br,
        .ty = bir.types.INVALID_TYPE,
        .result = NO_VALUE,
        .operands = try module.allocator.dupe(ValueId, &.{guard_cmp}),
        .data = .{ .cond_branch = .{
            .cond = guard_cmp,
            .then_block = guard_enter,
            .else_block = guard_exit,
        } },
    });

    module.allocator.free(hdr_term.operands);
    hdr_term.op = .br;
    hdr_term.data = .{ .block_target = body_bid };
    hdr_term.operands = &.{};

    const latch_block = func.getBlock(latch);
    const latch_last: u32 = @as(u32, @intCast(latch_block.instrs.items.len)) - 1;
    const latch_last_inst = &latch_block.instrs.items[latch_last];
    if (latch_last_inst.op != .br) return;
    module.removeInst(func_id, latch, latch_last);

    const latch_cmp_ops = if (phi_operand_idx.? == 0)
        try module.allocator.dupe(ValueId, &.{ next_val.?, bound_val })
    else
        try module.allocator.dupe(ValueId, &.{ bound_val, next_val.? });
    const latch_cmp = try module.addInst(func_id, latch, .{
        .op = cmp_inst.op,
        .ty = cmp_inst.ty,
        .result = NO_VALUE,
        .operands = latch_cmp_ops,
        .data = .{ .none = {} },
    });
    _ = try module.addInst(func_id, latch, .{
        .op = .cond_br,
        .ty = bir.types.INVALID_TYPE,
        .result = NO_VALUE,
        .operands = try module.allocator.dupe(ValueId, &.{latch_cmp}),
        .data = .{ .cond_branch = .{
            .cond = latch_cmp,
            .then_block = guard_enter,
            .else_block = guard_exit,
        } },
    });

    updateBranchTarget(func, preheader, header, guard_bid);

    for (hdr.instrs.items) |*inst| {
        if (inst.op != .phi) continue;
        for (inst.data.phi_incoming) |*inc| {
            if (inc.block == preheader) {
                inc.block = guard_bid;
            }
        }
    }

    if (exit_bid < func.blocks.items.len) {
        const exit_block = func.getBlock(exit_bid);
        for (exit_block.instrs.items) |*inst| {
            if (inst.op != .phi) continue;
            for (inst.data.phi_incoming) |*inc| {
                if (inc.block == header) {
                    inc.block = guard_bid;
                }
            }
        }
    }

    module.rebuildUses();
}

fn findPreheader(func: *const bir.Function, loop: *const bir_loops.Loop) ?BlockId {
    const header = loop.header;
    var result: ?BlockId = null;
    for (func.blocks.items[header].preds.items) |pred| {
        var in_body = false;
        for (loop.body) |b| {
            if (b == pred) {
                in_body = true;
                break;
            }
        }
        if (!in_body) {
            if (result != null) return null;
            result = pred;
        }
    }
    return result;
}

fn findDefIdxInBlock(func: *bir.Function, block_id: BlockId, val: ValueId) ?usize {
    if (val == NO_VALUE) return null;
    if (val > func.value_info.items.len) return null;
    const vi = &func.value_info.items[val - 1];
    if (vi.def.block != block_id) return null;
    const block = func.getBlock(block_id);
    if (vi.def.idx >= block.instrs.items.len) return null;
    return @as(usize, @intCast(vi.def.idx));
}

fn isPhiInBlock(func: *bir.Function, block_id: BlockId, val: ValueId) bool {
    const idx = findDefIdxInBlock(func, block_id, val) orelse return false;
    return func.getBlock(block_id).instrs.items[idx].op == .phi;
}

fn updateBranchTarget(func: *bir.Function, block_id: BlockId, old_target: BlockId, new_target: BlockId) void {
    const block = func.getBlock(block_id);
    if (block.instrs.items.len == 0) return;
    const term = &block.instrs.items[block.instrs.items.len - 1];
    switch (term.op) {
        .br => {
            if (term.data.block_target == old_target) {
                term.data.block_target = new_target;
            }
        },
        .cond_br => {
            if (term.data.cond_branch.then_block == old_target) {
                term.data.cond_branch.then_block = new_target;
            }
            if (term.data.cond_branch.else_block == old_target) {
                term.data.cond_branch.else_block = new_target;
            }
        },
        else => {},
    }
}
