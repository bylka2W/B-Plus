const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("bir.zig");
const bir_cfg = @import("bir_cfg.zig");
const bir_dominators = @import("bir_dominators.zig");
const bir_loops = @import("bir_loops.zig");
const INVALID_ID = bir.INVALID_ID;
const NO_VALUE = bir.NO_VALUE;

pub const LICMPass = bir.Pass{
    .name = "licm",
    .pass_type = .transform,
    .run = runLICM,
};

fn runLICM(module: *bir.Module, allocator: Allocator) anyerror!void {
    _ = allocator;
    for (module.functions.items, 0..) |*func, fid| {
        if (func.blocks.items.len < 2) continue;

        var cfg = try bir_cfg.buildCFG(module.allocator, func);
        defer cfg.deinit();

        var dom_tree = try bir_dominators.buildDominators(module.allocator, &cfg);
        defer dom_tree.deinit();

        const loops = try bir_loops.findLoops(module.allocator, &cfg, &dom_tree);
        defer {
            for (loops) |*lp| {
                module.allocator.free(lp.back_edges);
                module.allocator.free(lp.body);
            }
            module.allocator.free(loops);
        }

        const func_id = @as(bir.FunctionId, @intCast(fid));
        for (loops) |loop| {
            try hoistLoop(module, func_id, func, &cfg, &dom_tree, &loop);
        }
    }
}

fn hoistLoop(module: *bir.Module, func_id: bir.FunctionId, func: *bir.Function, cfg: *const bir_cfg.CFG, _: *const bir_dominators.DominatorTree, loop: *const bir_loops.Loop) !void {
    const preheader = findPreheader(cfg, loop) orelse return;

    var in_loop_set = try module.allocator.alloc(bool, cfg.blocks.items.len);
    defer module.allocator.free(in_loop_set);
    @memset(in_loop_set, false);
    for (loop.body) |b| {
        if (b < cfg.blocks.items.len) in_loop_set[b] = true;
    }

    var invariant = std.AutoHashMap(bir.ValueId, void).init(module.allocator);
    defer invariant.deinit();

    var changed = true;
    while (changed) {
        changed = false;
        for (cfg.rpo.items) |bid| {
            if (!in_loop_set[bid]) continue;
            const block = func.getBlock(bid);
            for (block.instrs.items) |*inst| {
                if (inst.result == NO_VALUE) continue;
                if (inst.op == .phi) continue;
                if (invariant.contains(inst.result)) continue;
                if (!isHoistable(inst.op)) continue;
                if (allOperandsInvariant(func, in_loop_set, &invariant, inst)) {
                    try invariant.put(inst.result, {});
                    changed = true;
                }
            }
        }
    }

    if (invariant.count() == 0) return;

    var old_to_new = std.AutoHashMap(bir.ValueId, bir.ValueId).init(module.allocator);
    defer old_to_new.deinit();

    for (cfg.rpo.items) |bid| {
        if (!in_loop_set[bid]) continue;
        const block = func.getBlock(bid);
        const block_instrs = try module.allocator.dupe(bir.Inst, block.instrs.items);
        defer module.allocator.free(block_instrs);

        for (block_instrs) |*inst| {
            if (inst.result == NO_VALUE) continue;
            if (!invariant.contains(inst.result)) continue;

            var new_operands = try module.allocator.dupe(bir.ValueId, inst.operands);
            for (new_operands, 0..) |op, j| {
                if (old_to_new.get(op)) |new_op| {
                    new_operands[j] = new_op;
                }
            }

            const new_val = try module.addInst(func_id, preheader, .{
                .op = inst.op,
                .ty = inst.ty,
                .result = NO_VALUE,
                .operands = new_operands,
                .data = cloneData(module.allocator, &inst.data),
            });
            try old_to_new.put(inst.result, new_val);
        }
    }

    for (cfg.rpo.items) |bid| {
        if (!in_loop_set[bid]) continue;
        const block = func.getBlock(bid);
        for (block.instrs.items) |*inst| {
            for (inst.operands, 0..) |op, j| {
                if (old_to_new.get(op)) |new_op| {
                    inst.operands[j] = new_op;
                }
            }
            switch (inst.data) {
                .phi_incoming => |incoming| {
                    for (incoming) |*inc| {
                        if (old_to_new.get(inc.value)) |nv| inc.value = nv;
                    }
                },
                .texture_store_info => |*tsi| {
                    if (old_to_new.get(tsi.tex)) |nv| tsi.tex = nv;
                    if (old_to_new.get(tsi.coord_x)) |nv| tsi.coord_x = nv;
                    if (old_to_new.get(tsi.coord_y)) |nv| tsi.coord_y = nv;
                    if (old_to_new.get(tsi.val)) |nv| tsi.val = nv;
                },
                .sample_info => |*si| {
                    if (old_to_new.get(si.tex)) |nv| si.tex = nv;
                    if (old_to_new.get(si.sampler)) |nv| si.sampler = nv;
                    if (old_to_new.get(si.coord)) |nv| si.coord = nv;
                    if (si.lod) |*lod| { if (old_to_new.get(lod.*)) |nv| lod.* = nv; }
                    if (si.offset) |*off| { if (old_to_new.get(off.*)) |nv| off.* = nv; }
                },
                .call_info => |*ci| {
                    if (old_to_new.get(ci.callee)) |nv| ci.callee = nv;
                    for (ci.args) |*arg| {
                        if (old_to_new.get(arg.*)) |nv| arg.* = nv;
                    }
                },
                .gep_info => |*gi| {
                    if (old_to_new.get(gi.ptr)) |nv| gi.ptr = nv;
                    for (gi.indices) |*idx| {
                        if (old_to_new.get(idx.*)) |nv| idx.* = nv;
                    }
                },
                .cond_branch => |*cb| {
                    if (old_to_new.get(cb.cond)) |nv| cb.cond = nv;
                },
                .atomic_info => |*ai| {
                    if (old_to_new.get(ai.ptr)) |nv| ai.ptr = nv;
                    if (old_to_new.get(ai.val)) |nv| ai.val = nv;
                },
                else => {},
            }
        }
    }

    module.rebuildUses();
}

fn findPreheader(cfg: *const bir_cfg.CFG, loop: *const bir_loops.Loop) ?bir.BlockId {
    const header = loop.header;
    var result: ?bir.BlockId = null;
    for (cfg.get(header).predecessors.items) |pred| {
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

fn isHoistable(op: bir.Op) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .neg,
        .fadd, .fsub, .fmul, .fdiv, .fmod, .fneg, .fma,
        .sqrt, .rsqrt, .exp, .log, .sin, .cos,
        .floor, .ceil, .frac, .abs, .saturate, .lerp,
        .eq, .ne, .lt, .le, .gt, .ge,
        .feq, .fne, .flt, .fle, .fgt, .fge,
        .or_op, .and_op, .xor_op, .not, .shl, .shr, .shra,
        .cast, .bitcast, .sext, .zext, .trunc,
        .fptosi, .sitofp, .fpext, .fptrunc,
        .composite, .extract, .insert, .shuffle,
        .splat, .extract_element, .insert_element,
        .select, .@"const",
        .load, .texture_load,
        => true,
        else => false,
    };
}

fn allOperandsInvariant(func: *const bir.Function, in_loop_set: []const bool, invariant: *const std.AutoHashMap(bir.ValueId, void), inst: *const bir.Inst) bool {
    for (inst.operands) |op_val| {
        if (op_val == NO_VALUE) continue;
        if (!isValueLoopInvariant(func, in_loop_set, invariant, op_val)) return false;
    }

    switch (inst.data) {
        .sample_info => |si| {
            if (!isValueLoopInvariant(func, in_loop_set, invariant, si.tex)) return false;
            if (!isValueLoopInvariant(func, in_loop_set, invariant, si.sampler)) return false;
            if (!isValueLoopInvariant(func, in_loop_set, invariant, si.coord)) return false;
            if (si.lod) |lod| {
                if (!isValueLoopInvariant(func, in_loop_set, invariant, lod)) return false;
            }
            if (si.offset) |off| {
                if (!isValueLoopInvariant(func, in_loop_set, invariant, off)) return false;
            }
        },
        .texture_store_info => |tsi| {
            if (!isValueLoopInvariant(func, in_loop_set, invariant, tsi.tex)) return false;
            if (!isValueLoopInvariant(func, in_loop_set, invariant, tsi.coord_x)) return false;
            if (!isValueLoopInvariant(func, in_loop_set, invariant, tsi.coord_y)) return false;
            if (!isValueLoopInvariant(func, in_loop_set, invariant, tsi.val)) return false;
        },
        .phi_incoming => |incoming| {
            for (incoming) |inc| {
                if (!isValueLoopInvariant(func, in_loop_set, invariant, inc.value)) return false;
            }
        },
        .call_info => |ci| {
            if (!isValueLoopInvariant(func, in_loop_set, invariant, ci.callee)) return false;
            for (ci.args) |arg| {
                if (!isValueLoopInvariant(func, in_loop_set, invariant, arg)) return false;
            }
        },
        .gep_info => |gi| {
            if (!isValueLoopInvariant(func, in_loop_set, invariant, gi.ptr)) return false;
            for (gi.indices) |idx| {
                if (!isValueLoopInvariant(func, in_loop_set, invariant, idx)) return false;
            }
        },
        .cond_branch => |cb| {
            if (!isValueLoopInvariant(func, in_loop_set, invariant, cb.cond)) return false;
        },
        .atomic_info => |ai| {
            if (!isValueLoopInvariant(func, in_loop_set, invariant, ai.ptr)) return false;
            if (!isValueLoopInvariant(func, in_loop_set, invariant, ai.val)) return false;
        },
        .vector_shuffle => |vs| {
            if (!isValueLoopInvariant(func, in_loop_set, invariant, vs.a)) return false;
            if (!isValueLoopInvariant(func, in_loop_set, invariant, vs.b)) return false;
        },
        else => {},
    }

    return true;
}

fn isValueLoopInvariant(func: *const bir.Function, in_loop_set: []const bool, invariant: *const std.AutoHashMap(bir.ValueId, void), val: bir.ValueId) bool {
    if (val == NO_VALUE) return true;
    const vi = &func.value_info.items[val - 1];
    if (vi.def.block == INVALID_ID) return true;
    if (vi.def.block >= func.blocks.items.len) return true;
    if (!in_loop_set[vi.def.block]) return true;
    if (invariant.contains(val)) return true;
    return false;
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
