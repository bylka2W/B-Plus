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

pub const IVStrengthReducePass = bir.Pass{
    .name = "iv-strength-reduce",
    .run = runIVStrengthReduce,
};

fn runIVStrengthReduce(ctx: *bir.PassContext) anyerror!PreservedAnalyses {
    const module = ctx.module;
    for (module.functions.items, 0..) |*func, fid| {
        if (func.blocks.items.len < 3) continue;
        const func_id = @as(bir.FunctionId, @intCast(fid));

        const cfg = try ctx.analysis.getCFG(func_id);
        const loop_info = try ctx.analysis.getLoopInfo(func_id);
        const loops = loop_info.loops;

        for (loops) |loop| {
            try reduceLoop(module, func_id, func, cfg, &loop);
        }
    }
    return PreservedAnalyses.none();
}

const LoopIV = struct {
    phi_val: ValueId,
    init_val: ValueId,
    step_val: i64,
    cmp_op: bir.Op,
};

const MulCand = struct {
    result: ValueId,
    k: i64,
};

fn reduceLoop(module: *bir.Module, func_id: bir.FunctionId, func: *bir.Function, _: *const bir_cfg.CFG, loop: *const bir_loops.Loop) !void {
    if (loop.back_edges.len != 1) return;

    const header = loop.header;
    const latch = loop.back_edges[0].from;
    const preheader = findPreheader(func, loop) orelse return;

    const iv = detectIV(func, loop, preheader, latch) orelse return;

    var candidates = std.ArrayList(MulCand).init(module.allocator);
    defer candidates.deinit();

    for (loop.body) |bid| {
        const block = func.getBlock(bid);
        for (block.instrs.items) |*inst| {
            if (inst.op != .mul) continue;
            if (inst.result == NO_VALUE) continue;

            const iv_idx: ?usize = for (inst.operands, 0..) |op, i| {
                if (op == iv.phi_val) break i;
            } else null;
            if (iv_idx == null) continue;

            const other = inst.operands[1 - iv_idx.?];
            const k = getConstInt(func, other) orelse continue;
            if (k <= 1) continue;

            try candidates.append(.{ .result = inst.result, .k = k });
        }
    }

    if (candidates.items.len == 0) return;

    for (candidates.items) |cand| {
        const mul_step = iv.step_val * cand.k;
        const mul_init = (getConstInt(func, iv.init_val) orelse continue) * cand.k;

        const acc_phi = try module.addPhi(func_id, header, getIVType(func, iv.phi_val), try module.allocator.dupe(bir.PhiIncoming, &.{
            .{ .value = NO_VALUE, .block = preheader },
            .{ .value = NO_VALUE, .block = latch },
        }));

        const init_c = try emitConstBefore(module, func, header, mul_init);
        {
            const hdr = func.getBlock(header);
            for (hdr.instrs.items) |*inst| {
                if (inst.op != .phi) continue;
                if (inst.result != acc_phi) continue;
                for (inst.data.phi_incoming) |*inc| {
                    if (inc.block == preheader) inc.value = init_c;
                    if (inc.block == latch) inc.value = cand.result;
                }
                break;
            }
        }

        const step_c = try emitConstBeforeTerminator(module, func, latch, mul_step);
        const acc_next = try emitAddBeforeTerminator(module, func, latch, acc_phi, step_c);

        {
            const hdr = func.getBlock(header);
            for (hdr.instrs.items) |*inst| {
                if (inst.op != .phi) continue;
                if (inst.result != acc_phi) continue;
                for (inst.data.phi_incoming) |*inc| {
                    if (inc.block == latch) {
                        inc.value = acc_next;
                        break;
                    }
                }
                break;
            }
        }

        replaceAllUsesOf(func, cand.result, acc_phi);
    }

    for (loop.body) |bid| {
        const block = func.getBlock(bid);
        var i: usize = 0;
        while (i < block.instrs.items.len) {
            const inst = &block.instrs.items[i];
            if (inst.op == .mul and inst.result != NO_VALUE) {
                var dominated = false;
                for (candidates.items) |cand| {
                    if (cand.result == inst.result) {
                        dominated = true;
                        break;
                    }
                }
                if (dominated) {
                    module.removeInst(func_id, bid, @as(u32, @intCast(i)));
                    continue;
                }
            }
            i += 1;
        }
    }

    module.rebuildUses();
}

fn emitConstBefore(_: *bir.Module, func: *bir.Function, block_id: BlockId, val: i64) !ValueId {
    const block = func.getBlock(block_id);
    var insert_idx: usize = 0;
    for (block.instrs.items) |inst| {
        if (inst.op == .phi) {
            insert_idx += 1;
        } else {
            break;
        }
    }
    const vid = try func.createValue();
    try block.instrs.insert(insert_idx, .{
        .op = .@"const",
        .ty = bir.types.INVALID_TYPE,
        .result = vid,
        .operands = &.{},
        .data = .{ .const_data = .{ .int = val } },
    });
    func.getValueInfo(vid).def = .{ .block = block_id, .idx = @as(u32, @intCast(insert_idx)) };
    shiftDefsAfter(func, block_id, insert_idx + 1);
    return vid;
}

fn emitConstBeforeTerminator(_: *bir.Module, func: *bir.Function, block_id: BlockId, val: i64) !ValueId {
    const block = func.getBlock(block_id);
    const insert_idx: usize = block.instrs.items.len - 1;
    const vid = try func.createValue();
    try block.instrs.insert(insert_idx, .{
        .op = .@"const",
        .ty = bir.types.INVALID_TYPE,
        .result = vid,
        .operands = &.{},
        .data = .{ .const_data = .{ .int = val } },
    });
    func.getValueInfo(vid).def = .{ .block = block_id, .idx = @as(u32, @intCast(insert_idx)) };
    shiftDefsAfter(func, block_id, insert_idx + 1);
    return vid;
}

fn emitAddBeforeTerminator(module: *bir.Module, func: *bir.Function, block_id: BlockId, lhs: ValueId, rhs: ValueId) !ValueId {
    const block = func.getBlock(block_id);
    const insert_idx: usize = block.instrs.items.len - 1;
    const vid = try func.createValue();
    try block.instrs.insert(insert_idx, .{
        .op = .add,
        .ty = getIVType(func, lhs),
        .result = vid,
        .operands = try module.allocator.dupe(ValueId, &.{ lhs, rhs }),
        .data = .{ .none = {} },
    });
    func.getValueInfo(vid).def = .{ .block = block_id, .idx = @as(u32, @intCast(insert_idx)) };
    try func.getValueInfo(lhs).uses.append(vid);
    try func.getValueInfo(rhs).uses.append(vid);
    shiftDefsAfter(func, block_id, insert_idx + 1);
    return vid;
}

fn shiftDefsAfter(func: *bir.Function, block_id: BlockId, after_idx: usize) void {
    const block = func.getBlock(block_id);
    var i: u32 = @as(u32, @intCast(after_idx));
    while (i < block.instrs.items.len) : (i += 1) {
        const shifted = &block.instrs.items[i];
        if (shifted.result != NO_VALUE) {
            func.getValueInfo(shifted.result).def.idx = i;
        }
    }
}

fn replaceAllUsesOf(func: *bir.Function, old_val: ValueId, new_val: ValueId) void {
    if (old_val == new_val) return;
    const old_vi = func.getValueInfo(old_val);
    const uses_copy = func.allocator.dupe(ValueId, old_vi.uses.items) catch return;
    defer func.allocator.free(uses_copy);

    for (uses_copy) |user_val| {
        if (user_val == NO_VALUE or user_val > func.value_info.items.len) continue;
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
                if (si.lod) |*lod| { if (lod.* == old_val) lod.* = new_val; }
                if (si.offset) |*off| { if (off.* == old_val) off.* = new_val; }
            },
            .call_info => |*ci| {
                if (ci.callee == old_val) ci.callee = new_val;
                for (ci.args) |*arg| { if (arg.* == old_val) arg.* = new_val; }
            },
            .gep_info => |*gi| {
                if (gi.ptr == old_val) gi.ptr = new_val;
                for (gi.indices) |*idx| { if (idx.* == old_val) idx.* = new_val; }
            },
            .named_call => |*nc| {
                for (nc.args) |*arg| { if (arg.* == old_val) arg.* = new_val; }
            },
            .atomic_info => |*ai| {
                if (ai.ptr == old_val) ai.ptr = new_val;
                if (ai.val == old_val) ai.val = new_val;
            },
            else => {},
        }
    }

    old_vi.uses.clearRetainingCapacity();
}

fn detectIV(func: *bir.Function, loop: *const bir_loops.Loop, preheader: BlockId, latch: BlockId) ?LoopIV {
    const header = loop.header;
    const hdr = func.getBlock(header);
    if (hdr.instrs.items.len < 2) return null;

    const term = &hdr.instrs.items[hdr.instrs.items.len - 1];
    if (term.op != .cond_br) return null;

    const cond_val = term.data.cond_branch.cond;
    const cond_def = getDef(func, cond_val) orelse return null;

    const is_cmp = switch (cond_def.op) {
        .lt, .le, .gt, .ge, .eq, .ne => true,
        else => false,
    };
    if (!is_cmp) return null;

    var bound_val: ?i64 = null;
    for (cond_def.operands) |op| {
        const op_def = getDef(func, op);
        if (op_def != null and op_def.?.op == .@"const") {
            if (op_def.?.data.const_data == .int) {
                bound_val = op_def.?.data.const_data.int;
            }
        }
    }
    if (bound_val == null) return null;

    for (hdr.instrs.items) |*inst| {
        if (inst.op != .phi) continue;
        const incoming = inst.data.phi_incoming;
        if (incoming.len != 2) continue;

        var from_preheader: ?ValueId = null;
        var from_latch: ?ValueId = null;
        for (incoming) |inc| {
            if (inc.block == preheader) from_preheader = inc.value;
            if (inc.block == latch) from_latch = inc.value;
        }
        if (from_preheader == null or from_latch == null) continue;

        const init_def = getDef(func, from_preheader.?);
        if (init_def == null or init_def.?.op != .@"const") continue;
        if (init_def.?.data.const_data != .int) continue;

        const latch_def = getDef(func, from_latch.?);
        if (latch_def == null) continue;

        if (latch_def.?.op != .add and latch_def.?.op != .sub) continue;

        var step_val: i64 = undefined;
        var has_iv = false;
        var step_detected = false;
        for (latch_def.?.operands) |op| {
            if (op == inst.result) {
                has_iv = true;
                continue;
            }
            const op_def = getDef(func, op);
            if (op_def != null and op_def.?.op == .@"const") {
                if (op_def.?.data.const_data == .int) {
                    step_val = if (latch_def.?.op == .add) op_def.?.data.const_data.int else -op_def.?.data.const_data.int;
                    step_detected = true;
                }
            }
        }
        if (!has_iv or !step_detected) continue;
        if (step_val <= 0) continue;

        return LoopIV{
            .phi_val = inst.result,
            .init_val = from_preheader.?,
            .step_val = step_val,
            .cmp_op = cond_def.op,
        };
    }

    return null;
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

fn getDef(func: *bir.Function, val: ValueId) ?*const bir.Inst {
    if (val == NO_VALUE) return null;
    if (val > func.value_info.items.len) return null;
    const vi = &func.value_info.items[val - 1];
    if (vi.def.block == INVALID_ID) return null;
    if (vi.def.block >= func.blocks.items.len) return null;
    const block = &func.blocks.items[vi.def.block];
    if (vi.def.idx >= block.instrs.items.len) return null;
    return &block.instrs.items[vi.def.idx];
}

fn getConstInt(func: *bir.Function, val: ValueId) ?i64 {
    const def = getDef(func, val) orelse return null;
    if (def.op != .@"const") return null;
    if (def.data.const_data == .int) return def.data.const_data.int;
    return null;
}

fn getIVType(func: *bir.Function, phi_val: ValueId) bir.TypeId {
    const vi = func.getValueInfo(phi_val);
    if (vi.def.block == INVALID_ID) return bir.types.INVALID_TYPE;
    if (vi.def.block >= func.blocks.items.len) return bir.types.INVALID_TYPE;
    const block = &func.blocks.items[vi.def.block];
    if (vi.def.idx >= block.instrs.items.len) return bir.types.INVALID_TYPE;
    return block.instrs.items[vi.def.idx].ty;
}
