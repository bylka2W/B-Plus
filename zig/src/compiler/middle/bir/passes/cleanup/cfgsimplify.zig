const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../../bir.zig");
const bir_cfg = @import("../../analysis/cfg/cfg.zig");
const INVALID_ID = bir.INVALID_ID;
const NO_VALUE = bir.NO_VALUE;
const ValueId = bir.ValueId;
const BlockId = bir.BlockId;
const PreservedAnalyses = bir.PreservedAnalyses;
const Module = bir.Module;

pub const CFGSimplifyPass = bir.Pass{
    .name = "cfg-simplify",
    .run = runCFGSimplify,
};

fn runCFGSimplify(ctx: *bir.PassContext) anyerror!PreservedAnalyses {
    const module = ctx.module;
    const allocator = ctx.allocator;
    var changed = true;
    while (changed) {
        changed = false;

        for (module.functions.items, 0..) |*func, fid| {
            if (func.blocks.items.len < 2) continue;
            const func_id = @as(bir.FunctionId, @intCast(fid));

            var cfg2 = try bir_cfg.buildCFG(allocator, func);
            defer cfg2.deinit();

            changed = try mergeStraightLine(module, func_id, func, &cfg2) or changed;
        }

        for (module.functions.items, 0..) |*func, fid| {
            if (func.blocks.items.len < 2) continue;
            const func_id = @as(bir.FunctionId, @intCast(fid));

            var cfg = try bir_cfg.buildCFG(allocator, func);
            defer cfg.deinit();

            changed = try redirectToSingleSuccessor(module, func_id, func, &cfg) or changed;
        }
    }
    return PreservedAnalyses.none();
}

fn redirectToSingleSuccessor(
    _: *Module,
    _: bir.FunctionId,
    func: *bir.Function,
    cfg: *const bir_cfg.CFG,
) !bool {
    var changed = false;
    var i: usize = func.blocks.items.len;
    while (i > 0) {
        i -= 1;
        const bid = @as(BlockId, @intCast(i));
        if (bid == cfg.entry) continue;

        const block = func.getBlock(bid);
        if (block.instrs.items.len == 0) continue;

        const last = &block.instrs.items[block.instrs.items.len - 1];
        if (last.op != .br) continue;

        const target = last.data.block_target;
        if (target == bid) continue;

        const preds = func.blocks.items[bid].preds.items;
        if (preds.len == 0) continue;

        for (preds) |pred| {
            replaceBranchTarget(func, pred, bid, target);
        }

        changed = true;
    }
    return changed;
}

fn mergeStraightLine(
    module: *Module,
    func_id: bir.FunctionId,
    func: *bir.Function,
    cfg: *const bir_cfg.CFG,
) !bool {
    var changed = false;
    var i: usize = func.blocks.items.len;
    while (i > 0) {
        i -= 1;
        const bid = @as(BlockId, @intCast(i));
        if (bid == cfg.entry) continue;

        const preds = func.blocks.items[bid].preds.items;
        if (preds.len != 1) continue;

        const pred = preds[0];
        if (pred == bid) continue;

        const pred_block = func.getBlock(pred);
        if (pred_block.instrs.items.len == 0) continue;

        const pred_term = &pred_block.instrs.items[pred_block.instrs.items.len - 1];
        if (pred_term.op != .br) continue;
        if (pred_term.data.block_target != bid) continue;

        const target_block = func.getBlock(bid);
        if (target_block.instrs.items.len == 0) continue;

        const term_idx = pred_block.instrs.items.len - 1;
        _ = pred_block.instrs.orderedRemove(term_idx);

        for (target_block.instrs.items) |*src_inst| {
            const new_operands = try module.allocator.dupe(ValueId, src_inst.operands);

            const new_val = try module.addInst(func_id, pred, .{
                .op = src_inst.op,
                .ty = src_inst.ty,
                .result = NO_VALUE,
                .operands = new_operands,
                .data = cloneInstData(module.allocator, &src_inst.data),
            });

            replaceAllUses(func, src_inst.result, new_val);
        }

        changed = true;
    }
    return changed;
}

fn replaceBranchTarget(func: *bir.Function, from: BlockId, old_target: BlockId, new_target: BlockId) void {
    const block = func.getBlock(from);
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

fn cloneInstData(allocator: Allocator, data: *const bir.Inst.Data) bir.Inst.Data {
    switch (data.*) {
        .const_data => |cd| return .{ .const_data = cd },
        .block_target => |bt| return .{ .block_target = bt },
        .cond_branch => |cb| return .{ .cond_branch = cb },
        .none => return .{ .none = {} },
        .string => |s| return .{ .string = allocator.dupe(u8, s) catch return .{ .none = {} } },
        .phi_incoming => |inc| return .{ .phi_incoming = allocator.dupe(bir.PhiIncoming, inc) catch return .{ .none = {} } },
        .cast_info => |ci| return .{ .cast_info = ci },
        .call_info => |ci| return .{ .call_info = .{
            .callee = ci.callee,
            .args = allocator.dupe(ValueId, ci.args) catch return .{ .none = {} },
        } },
        .gep_info => |gi| return .{ .gep_info = .{
            .ptr = gi.ptr,
            .indices = allocator.dupe(ValueId, gi.indices) catch return .{ .none = {} },
            .result_elem_type = gi.result_elem_type,
        } },
        .named_call => |nc| return .{ .named_call = .{
            .name = allocator.dupe(u8, nc.name) catch return .{ .none = {} },
            .args = allocator.dupe(ValueId, nc.args) catch return .{ .none = {} },
        } },
        .atomic_info => |ai| return .{ .atomic_info = ai },
        .sample_info => |si| return .{ .sample_info = si },
        .barrier_kind => |bk| return .{ .barrier_kind = bk },
        .extract_info => |ei| return .{ .extract_info = ei },
        .texture_store_info => |tsi| return .{ .texture_store_info = tsi },
        .vector_shuffle => |vs| return .{ .vector_shuffle = .{
            .a = vs.a,
            .b = vs.b,
            .mask = allocator.dupe(u32, vs.mask) catch return .{ .none = {} },
        } },
        .group_info => |gi| return .{ .group_info = gi },
        .fence_info => |fi| return .{ .fence_info = fi },
        .groupshared_size => |gs| return .{ .groupshared_size = gs },
        .branch_on_bit => |bb| return .{ .branch_on_bit = bb },
    }
}

fn replaceAllUses(func: *bir.Function, old_val: ValueId, new_val: ValueId) void {
    if (old_val == new_val) return;
    if (old_val > func.locals_count) return;
    const old_vi = func.getValueInfo(old_val);
    const uses_copy = func.allocator.dupe(ValueId, old_vi.uses.items) catch return;
    defer func.allocator.free(uses_copy);

    for (uses_copy) |user_val| {
        if (user_val == NO_VALUE or user_val > func.locals_count) continue;
        const user_vi = func.getValueInfo(user_val);
        if (user_vi.def.block == INVALID_ID) continue;
        if (user_vi.def.block >= func.blocks.items.len) continue;
        const block = func.getBlock(user_vi.def.block);
        if (user_vi.def.idx >= block.instrs.items.len) continue;
        const inst = &block.instrs.items[user_vi.def.idx];

        for (inst.operands) |*op| {
            if (op.* == old_val) op.* = new_val;
        }
        switch (inst.data) {
            .phi_incoming => |incoming| {
                for (incoming) |*inc| {
                    if (inc.value == old_val) inc.value = new_val;
                }
            },
            .cond_branch => |*cb| {
                if (cb.cond == old_val) cb.cond = new_val;
            },
            .call_info => |*ci| {
                if (ci.callee == old_val) ci.callee = new_val;
                for (ci.args) |*arg| {
                    if (arg.* == old_val) arg.* = new_val;
                }
            },
            .gep_info => |*gi| {
                if (gi.ptr == old_val) gi.ptr = new_val;
                for (gi.indices) |*idx| {
                    if (idx.* == old_val) idx.* = new_val;
                }
            },
            .texture_store_info => |*tsi| {
                if (tsi.tex == old_val) tsi.tex = new_val;
                if (tsi.coord_x == old_val) tsi.coord_x = new_val;
                if (tsi.coord_y == old_val) tsi.coord_y = new_val;
                if (tsi.val == old_val) tsi.val = new_val;
            },
            .sample_info => |*si| {
                if (si.tex == old_val) si.tex = new_val;
                if (si.sampler == old_val) si.sampler = new_val;
                if (si.coord == old_val) si.coord = new_val;
                if (si.lod) |*lod| {
                    if (lod.* == old_val) lod.* = new_val;
                }
                if (si.offset) |*off| {
                    if (off.* == old_val) off.* = new_val;
                }
            },
            .atomic_info => |*ai| {
                if (ai.ptr == old_val) ai.ptr = new_val;
                if (ai.val == old_val) ai.val = new_val;
            },
            else => {},
        }

        const new_vi = func.getValueInfo(new_val);
        new_vi.uses.append(user_val) catch {};
    }

    old_vi.uses.clearRetainingCapacity();
}
