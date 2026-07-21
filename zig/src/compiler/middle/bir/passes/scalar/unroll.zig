const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../../bir.zig");
const bir_cfg = @import("../../analysis/cfg/cfg.zig");
const bir_dominators = @import("../../analysis/dominator/dominator.zig");
const bir_loops = @import("../../analysis/loops/loops.zig");
const PreservedAnalyses = bir.PreservedAnalyses;
const INVALID_ID = bir.INVALID_ID;
const NO_VALUE = bir.NO_VALUE;

pub const UnrollPass = bir.Pass{
    .name = "loop-unroll",
    .run = runUnroll,
};

const InductionVar = struct {
    phi_val: bir.ValueId,
    init_val: bir.ValueId,
    step_val: i64,
    bound_val: i64,
    cmp_op: bir.Op,
    count: u64,
};

fn runUnroll(ctx: *bir.PassContext) anyerror!PreservedAnalyses {
    const module = ctx.module;
    for (module.functions.items, 0..) |*func, fid| {
        if (func.blocks.items.len < 3) continue;
        const func_id = @as(bir.FunctionId, @intCast(fid));

        const cfg = try ctx.analysis.getCFG(func_id);
        const dom_tree = try ctx.analysis.getDomTree(func_id);
        const loop_info = try ctx.analysis.getLoopInfo(func_id);
        const loops = loop_info.loops;

        for (loops) |loop| {
            try unrollLoop(module, func_id, func, cfg, dom_tree, &loop);
        }
    }
    return PreservedAnalyses.none();
}

fn unrollLoop(module: *bir.Module, func_id: bir.FunctionId, func: *bir.Function, _: *const bir_cfg.CFG, _: *const bir_dominators.DominatorTree, loop: *const bir_loops.Loop) !void {
    const preheader = findPreheader(func, loop) orelse return;
    if (loop.back_edges.len != 1) return;
    const latch = loop.back_edges[0].from;

    const iv = detectInductionVar(func, loop, preheader, latch) orelse return;
    if (iv.count < 2 or iv.count > 64) return;

    const header = loop.header;

    var exit_block: ?bir.BlockId = null;
    {
        const header_block = func.getBlock(header);
        const term = &header_block.instrs.items[header_block.instrs.items.len - 1];
        if (term.op != .cond_br) return;
        const cond = term.data.cond_branch;
        const body_bid = if (cond.then_block != exit_block orelse bir.INVALID_ID) cond.then_block else cond.else_block;
        const exit_bid = if (cond.then_block == body_bid) cond.else_block else cond.then_block;
        exit_block = exit_bid;
    }

    var body_blocks = std.ArrayList(bir.BlockId).init(module.allocator);
    defer body_blocks.deinit();
    for (loop.body) |bid| {
        if (bid != header) try body_blocks.append(bid);
    }
    if (body_blocks.items.len == 0) return;

    var total_unrolled: u64 = 0;
    const count = iv.count;
    var last_block_of_prev_iter: bir.BlockId = preheader;

    if (count > 0) {
        var phi_replacements = std.AutoHashMap(bir.ValueId, bir.ValueId).init(module.allocator);
        defer phi_replacements.deinit();
        for (func.getBlock(header).instrs.items) |*inst| {
            if (inst.op != .phi) continue;
            for (inst.data.phi_incoming) |inc| {
                if (inc.block == preheader) {
                    try phi_replacements.put(inst.result, inc.value);
                    break;
                }
            }
        }

        const header_term_succs = [2]bir.BlockId{
            func.getBlock(header).instrs.items[func.getBlock(header).instrs.items.len - 1].data.cond_branch.then_block,
            func.getBlock(header).instrs.items[func.getBlock(header).instrs.items.len - 1].data.cond_branch.else_block,
        };
        var exit_bid: bir.BlockId = undefined;
        var first_body_bid: bir.BlockId = undefined;
        {
            var in_body = false;
            for (body_blocks.items) |b| { if (b == header_term_succs[0]) { in_body = true; break; } }
            if (in_body) {
                first_body_bid = header_term_succs[0];
                exit_bid = header_term_succs[1];
            } else {
                first_body_bid = header_term_succs[1];
                exit_bid = header_term_succs[0];
            }
        }

        for (body_blocks.items, 0..) |bid, i| {
            if (bid == first_body_bid and i > 0) {
                const tmp = body_blocks.items[0];
                body_blocks.items[0] = bid;
                body_blocks.items[i] = tmp;
                break;
            }
        }

        var first_unrolled_block: bir.BlockId = INVALID_ID;
        var last_old_to_new: ?std.AutoHashMap(bir.ValueId, bir.ValueId) = null;
        var iter: u64 = 0;
        while (iter < count) : (iter += 1) {
            var old_to_new = std.AutoHashMap(bir.ValueId, bir.ValueId).init(module.allocator);
            var new_blocks = std.ArrayList(bir.BlockId).init(module.allocator);
            defer new_blocks.deinit();

            for (body_blocks.items) |bid| {
                const src_block = func.getBlock(bid);
                var new_instrs = std.ArrayList(bir.Inst).init(module.allocator);
                defer new_instrs.deinit();

                for (src_block.instrs.items) |*inst| {
                    var new_operands = try module.allocator.dupe(bir.ValueId, inst.operands);
                    for (new_operands, 0..) |op, j| {
                        if (phi_replacements.get(op)) |nv| new_operands[j] = nv;
                        if (old_to_new.get(op)) |nv| new_operands[j] = nv;
                    }

                    var new_data = cloneData(module.allocator, &inst.data);
                    switch (new_data) {
                        .phi_incoming => |incoming| {
                            for (incoming) |*inc| {
                                if (phi_replacements.get(inc.value)) |nv| inc.value = nv;
                                if (old_to_new.get(inc.value)) |nv| inc.value = nv;
                            }
                        },
                        .texture_store_info => |*tsi| {
                            if (phi_replacements.get(tsi.tex)) |nv| tsi.tex = nv;
                            if (old_to_new.get(tsi.tex)) |nv| tsi.tex = nv;
                            if (phi_replacements.get(tsi.coord_x)) |nv| tsi.coord_x = nv;
                            if (old_to_new.get(tsi.coord_x)) |nv| tsi.coord_x = nv;
                            if (phi_replacements.get(tsi.coord_y)) |nv| tsi.coord_y = nv;
                            if (old_to_new.get(tsi.coord_y)) |nv| tsi.coord_y = nv;
                            if (phi_replacements.get(tsi.val)) |nv| tsi.val = nv;
                            if (old_to_new.get(tsi.val)) |nv| tsi.val = nv;
                        },
                        .sample_info => |*si| {
                            if (phi_replacements.get(si.tex)) |nv| si.tex = nv;
                            if (old_to_new.get(si.tex)) |nv| si.tex = nv;
                            if (phi_replacements.get(si.sampler)) |nv| si.sampler = nv;
                            if (old_to_new.get(si.sampler)) |nv| si.sampler = nv;
                            if (phi_replacements.get(si.coord)) |nv| si.coord = nv;
                            if (old_to_new.get(si.coord)) |nv| si.coord = nv;
                            if (si.lod) |*lod| {
                                if (phi_replacements.get(lod.*)) |nv| lod.* = nv;
                                if (old_to_new.get(lod.*)) |nv| lod.* = nv;
                            }
                            if (si.offset) |*off| {
                                if (phi_replacements.get(off.*)) |nv| off.* = nv;
                                if (old_to_new.get(off.*)) |nv| off.* = nv;
                            }
                        },
                        .named_call => |*nc| {
                            for (nc.args) |*arg| {
                                if (phi_replacements.get(arg.*)) |nv| arg.* = nv;
                                if (old_to_new.get(arg.*)) |nv| arg.* = nv;
                            }
                        },
                        .gep_info => |*gi| {
                            if (phi_replacements.get(gi.ptr)) |nv| gi.ptr = nv;
                            if (old_to_new.get(gi.ptr)) |nv| gi.ptr = nv;
                            for (gi.indices) |*idx| {
                                if (phi_replacements.get(idx.*)) |nv| idx.* = nv;
                                if (old_to_new.get(idx.*)) |nv| idx.* = nv;
                            }
                        },
                        .cond_branch => |*cb| {
                            if (phi_replacements.get(cb.cond)) |nv| cb.cond = nv;
                            if (old_to_new.get(cb.cond)) |nv| cb.cond = nv;
                        },
                        .atomic_info => |*ai| {
                            if (phi_replacements.get(ai.ptr)) |nv| ai.ptr = nv;
                            if (old_to_new.get(ai.ptr)) |nv| ai.ptr = nv;
                            if (phi_replacements.get(ai.val)) |nv| ai.val = nv;
                            if (old_to_new.get(ai.val)) |nv| ai.val = nv;
                        },
                        else => {},
                    }

                    const new_val = try func.createValue();
                    const new_idx = new_instrs.items.len;
                    func.getValueInfo(new_val).def = .{ .block = 0, .idx = @as(u32, @intCast(new_idx)) };

                    if (inst.result != NO_VALUE) {
                        try old_to_new.put(inst.result, new_val);
                    }

                    try new_instrs.append(.{
                        .op = inst.op,
                        .ty = inst.ty,
                        .result = new_val,
                        .operands = new_operands,
                        .data = new_data,
                    });
                }

                const new_label = try std.fmt.allocPrint(module.allocator, "{s}.unroll.{d}", .{ src_block.label, iter });
                const new_bid = try module.addBlockWithInstrs(func_id, new_label, new_instrs.items);
                try new_blocks.append(new_bid);
            }

            var block_map = std.AutoHashMap(bir.BlockId, bir.BlockId).init(module.allocator);
            defer block_map.deinit();
            for (body_blocks.items, new_blocks.items) |orig, cloned| {
                try block_map.put(orig, cloned);
            }

            for (0..new_blocks.items.len) |bi| {
                const new_bid = new_blocks.items[bi];
                const new_block = func.getBlock(new_bid);
                const new_term_idx = new_block.instrs.items.len - 1;
                const new_term = &new_block.instrs.items[new_term_idx];

                for (new_block.instrs.items, 0..) |*inst, ii| {
                    if (inst.op == .phi) {
                        for (inst.data.phi_incoming) |*inc| {
                            if (block_map.get(inc.block)) |nb| inc.block = nb;
                        }
                    }
                    if (ii == new_term_idx) {
                        if (inst.op == .br) {
                            if (block_map.get(inst.data.block_target)) |nb| inst.data.block_target = nb;
                        } else if (inst.op == .cond_br) {
                            const cb = &inst.data.cond_branch;
                            if (block_map.get(cb.then_block)) |nb| cb.then_block = nb;
                            if (block_map.get(cb.else_block)) |nb| cb.else_block = nb;
                        }
                    }
                }

                if (iter == count - 1) {
                    if (new_term.op == .br and new_term.data.block_target == header) {
                        new_term.data.block_target = exit_bid;
                    } else if (new_term.op == .cond_br) {
                        const cb = &new_term.data.cond_branch;
                        if (cb.then_block == header) cb.then_block = exit_bid;
                        if (cb.else_block == header) cb.else_block = exit_bid;
                    }
                }

                if (bi == 0 and last_block_of_prev_iter != INVALID_ID) {
                    const prev_term = &func.getBlock(last_block_of_prev_iter).instrs.items[func.getBlock(last_block_of_prev_iter).instrs.items.len - 1];
                    if (prev_term.op == .br and prev_term.data.block_target == header) {
                        prev_term.data.block_target = new_bid;
                    } else if (prev_term.op == .cond_br) {
                        const cb = &prev_term.data.cond_branch;
                        if (cb.then_block == header) cb.then_block = new_bid;
                        if (cb.else_block == header) cb.else_block = new_bid;
                    }
                }
            }

            for (func.getBlock(header).instrs.items) |*hdr_inst| {
                if (hdr_inst.op != .phi) continue;
                for (hdr_inst.data.phi_incoming) |inc| {
                    if (inc.block == latch) {
                        if (old_to_new.get(inc.value)) |nv| {
                            try phi_replacements.put(hdr_inst.result, nv);
                        }
                        break;
                    }
                }
            }

            total_unrolled += 1;
            if (iter == count - 1) {
                if (last_old_to_new) |*map| map.deinit();
                last_old_to_new = old_to_new;
            } else {
                old_to_new.deinit();
            }
            if (new_blocks.items.len > 0) {
                if (first_unrolled_block == INVALID_ID) {
                    first_unrolled_block = new_blocks.items[0];
                }
                var latch_block = new_blocks.items[new_blocks.items.len - 1];
                for (new_blocks.items) |bid| {
                    const blk = func.getBlock(bid);
                    const term = blk.instrs.items[blk.instrs.items.len - 1];
                    if (term.op == .br and term.data.block_target == header) {
                        latch_block = bid;
                        break;
                    }
                    if (term.op == .cond_br) {
                        const cb = term.data.cond_branch;
                        if (cb.then_block == header or cb.else_block == header) {
                            latch_block = bid;
                            break;
                        }
                    }
                }
                last_block_of_prev_iter = latch_block;
            }
        }

        if (first_unrolled_block != INVALID_ID) {
            for (func.getBlock(preheader).instrs.items) |*inst| {
                if (inst.op == .br and inst.data.block_target == header) {
                    inst.data.block_target = first_unrolled_block;
                }
            }
        }

        if (last_old_to_new) |*lotn| {
            var phi_to_last = std.AutoHashMap(bir.ValueId, bir.ValueId).init(module.allocator);
            defer phi_to_last.deinit();
            for (func.getBlock(header).instrs.items) |*phi_inst| {
                if (phi_inst.op != .phi) continue;
                for (phi_inst.data.phi_incoming) |inc| {
                    if (inc.block == latch) {
                        if (lotn.get(inc.value)) |nv| {
                            try phi_to_last.put(phi_inst.result, nv);
                        }
                        break;
                    }
                }
            }
            if (phi_to_last.count() > 0) {
                for (func.blocks.items, 0..) |*blk, bid| {
                    if (bid == header) continue;
                    var in_body = false;
                    for (body_blocks.items) |bb| { if (bid == bb) { in_body = true; break; } }
                    if (in_body) continue;
                    for (blk.instrs.items) |*inst| {
                        for (inst.operands, 0..) |op, i| {
                            if (phi_to_last.get(op)) |nv| inst.operands[i] = nv;
                        }
                        switch (inst.data) {
                            .phi_incoming => |incoming| {
                                for (incoming) |*inc| {
                                    if (phi_to_last.get(inc.value)) |nv| inc.value = nv;
                                }
                            },
                            .cond_branch => |*cb| {
                                if (phi_to_last.get(cb.cond)) |nv| cb.cond = nv;
                            },
                            .texture_store_info => |*tsi| {
                                if (phi_to_last.get(tsi.tex)) |nv| tsi.tex = nv;
                                if (phi_to_last.get(tsi.coord_x)) |nv| tsi.coord_x = nv;
                                if (phi_to_last.get(tsi.coord_y)) |nv| tsi.coord_y = nv;
                                if (phi_to_last.get(tsi.val)) |nv| tsi.val = nv;
                            },
                            .sample_info => |*si| {
                                if (phi_to_last.get(si.tex)) |nv| si.tex = nv;
                                if (phi_to_last.get(si.sampler)) |nv| si.sampler = nv;
                                if (phi_to_last.get(si.coord)) |nv| si.coord = nv;
                                if (si.lod) |*lod| { if (phi_to_last.get(lod.*)) |nv| lod.* = nv; }
                                if (si.offset) |*off| { if (phi_to_last.get(off.*)) |nv| off.* = nv; }
                            },
                            .named_call => |*nc| {
                                for (nc.args) |*arg| { if (phi_to_last.get(arg.*)) |nv| arg.* = nv; }
                            },
                            .gep_info => |*gi| {
                                if (phi_to_last.get(gi.ptr)) |nv| gi.ptr = nv;
                                for (gi.indices) |*idx| { if (phi_to_last.get(idx.*)) |nv| idx.* = nv; }
                            },
                            .atomic_info => |*ai| {
                                if (phi_to_last.get(ai.ptr)) |nv| ai.ptr = nv;
                                if (phi_to_last.get(ai.val)) |nv| ai.val = nv;
                            },
                            else => {},
                        }
                    }
                }
            }
        }
    }

    module.rebuildUses();
}

fn findPreheader(func: *const bir.Function, loop: *const bir_loops.Loop) ?bir.BlockId {
    const header = loop.header;
    var result: ?bir.BlockId = null;
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

fn detectInductionVar(func: *bir.Function, loop: *const bir_loops.Loop, preheader: bir.BlockId, latch: bir.BlockId) ?InductionVar {
    const header = loop.header;
    const header_block = func.getBlock(header);
    if (header_block.instrs.items.len < 2) return null;

    const term = &header_block.instrs.items[header_block.instrs.items.len - 1];
    if (term.op != .cond_br) return null;

    const cond_val = term.data.cond_branch.cond;
    const cond_def = getDef(func, cond_val) orelse return null;
    const cmp_op = cond_def.op;

    const is_unsigned = switch (cmp_op) {
        .lt, .le, .gt, .ge, .eq, .ne => false,
        else => return null,
    };
    _ = is_unsigned;

    const cmp_lhs = if (cond_def.operands.len >= 2) cond_def.operands[0] else return null;
    var bound_val: ?i64 = null;
    for (cond_def.operands) |op| {
        const op_def = getDef(func, op);
        if (op_def != null and op_def.?.op == .@"const") {
            const cd = op_def.?.data.const_data;
            if (cd == .int) {
                bound_val = cd.int;
            }
        }
    }

    var phi_candidate: ?bir.ValueId = null;
    for (header_block.instrs.items) |*inst| {
        if (inst.op != .phi) continue;
        const incoming = inst.data.phi_incoming;
        if (incoming.len != 2) continue;

        var from_preheader: ?bir.ValueId = null;
        var from_latch: ?bir.ValueId = null;
        for (incoming) |inc| {
            if (inc.block == preheader) from_preheader = inc.value;
            if (inc.block == latch) from_latch = inc.value;
        }
        if (from_preheader == null or from_latch == null) continue;

        const init_val = from_preheader.?;
        const init_def = getDef(func, init_val);
        if (init_def == null or init_def.?.op != .@"const") continue;
        if (init_def.?.data.const_data != .int) continue;
        const init_int = init_def.?.data.const_data.int;

        const latch_def = getDef(func, from_latch.?);
        if (latch_def == null) continue;

        var step_val: i64 = undefined;
        const iv_phi_val = inst.result;

        if (latch_def.?.op == .add or latch_def.?.op == .sub) {
            const add_ops = latch_def.?.operands;
            var has_iv = false;
            var step_detected = false;
            for (add_ops) |op| {
                if (op == iv_phi_val) { has_iv = true; continue; }
                const op_def = getDef(func, op);
                if (op_def != null and op_def.?.op == .@"const") {
                    if (op_def.?.data.const_data == .int) {
                        step_val = if (latch_def.?.op == .add) op_def.?.data.const_data.int else -op_def.?.data.const_data.int;
                        step_detected = true;
                    }
                }
            }
            if (!has_iv or !step_detected) continue;
        } else if (latch_def.?.op == .@"const") {
            step_val = 0;
        } else {
            continue;
        }

        if (step_val <= 0) continue;
        if (bound_val == null) continue;

        if (iv_phi_val == cmp_lhs) {
            phi_candidate = iv_phi_val;
        } else {
            const cmp_def = getDef(func, cmp_lhs);
            if (cmp_def != null) {
                for (cmp_def.?.operands) |op| {
                    if (op == iv_phi_val) {
                        phi_candidate = iv_phi_val;
                        break;
                    }
                }
            }
        }

        if (phi_candidate == null) continue;

        const bound = bound_val.?;
        if (bound == init_int and cmp_op == .lt) return InductionVar{ .phi_val = undefined, .init_val = undefined, .step_val = undefined, .bound_val = undefined, .cmp_op = undefined, .count = 0 };
        const count: u64 = if (init_int >= bound) 0 else switch (cmp_op) {
            .lt => @as(u64, @intCast(@divTrunc(bound - init_int + step_val - 1, step_val))),
            .le => @as(u64, @intCast(@divTrunc(bound - init_int + step_val, step_val))),
            .gt => @as(u64, @intCast(@divTrunc(init_int - bound + step_val - 1, step_val))),
            .ge => @as(u64, @intCast(@divTrunc(init_int - bound + step_val, step_val))),
            else => return null,
        };

        return InductionVar{
            .phi_val = phi_candidate.?,
            .init_val = init_val,
            .step_val = step_val,
            .bound_val = bound,
            .cmp_op = cmp_op,
            .count = count,
        };
    }

    return null;
}

fn getDef(func: *bir.Function, val: bir.ValueId) ?*const bir.Inst {
    if (val == NO_VALUE) return null;
    if (val > func.value_info.items.len) return null;
    const vi = &func.value_info.items[val - 1];
    if (vi.def.block == INVALID_ID) return null;
    if (vi.def.block >= func.blocks.items.len) return null;
    const block = &func.blocks.items[vi.def.block];
    if (vi.def.idx >= block.instrs.items.len) return null;
    return &block.instrs.items[vi.def.idx];
}

fn getIntType(func: *bir.Function, val: bir.ValueId) bir.TypeId {
    if (val == NO_VALUE or val > func.value_info.items.len) return 0;
    const vi = &func.value_info.items[val - 1];
    if (vi.def.block == INVALID_ID or vi.def.block >= func.blocks.items.len) return 0;
    const block = &func.blocks.items[vi.def.block];
    if (vi.def.idx >= block.instrs.items.len) return 0;
    return block.instrs.items[vi.def.idx].ty;
}

fn createAddConst(_: *bir.Module, _: bir.FunctionId, _: bir.BlockId, base: bir.ValueId, _: i64) !bir.ValueId {
    return base;
}

fn cloneData(allocator: Allocator, data: *const bir.Inst.Data) bir.Inst.Data {
    switch (data.*) {
        .string => |s| return .{ .string = allocator.dupe(u8, s) catch return .{ .none = {} } },
        .phi_incoming => |incoming| {
            const copy = allocator.dupe(bir.PhiIncoming, incoming) catch return .{ .none = {} };
            return .{ .phi_incoming = copy };
        },
        .call_info => |ci| {
            const args_copy = allocator.dupe(bir.ValueId, ci.args) catch return .{ .none = {} };
            return .{ .call_info = .{ .callee = ci.callee, .args = args_copy } };
        },
        .gep_info => |gi| {
            const idx_copy = allocator.dupe(bir.ValueId, gi.indices) catch return .{ .none = {} };
            return .{ .gep_info = .{ .ptr = gi.ptr, .indices = idx_copy, .result_elem_type = gi.result_elem_type } };
        },
        .vector_shuffle => |vs| {
            const mask_copy = allocator.dupe(u32, vs.mask) catch return .{ .none = {} };
            return .{ .vector_shuffle = .{ .a = vs.a, .b = vs.b, .mask = mask_copy } };
        },
        else => return data.*,
    }
}
