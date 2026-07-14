const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("bir.zig");
const bir_cfg = @import("bir_cfg.zig");
const bir_dominators = @import("bir_dominators.zig");
const bir_alias = @import("bir_alias.zig");
const bir_memory_ssa = @import("bir_memory_ssa.zig");
const bir_licm = @import("bir_licm.zig");
const bir_unroll = @import("bir_unroll.zig");
const bir_verify = @import("bir_verify.zig");
const Module = bir.Module;
const Op = bir.Op;
const Inst = bir.Inst;
const ConstData = bir.ConstData;
const NO_VALUE = bir.NO_VALUE;
const INVALID_ID = bir.INVALID_ID;

// ─── Dead Code Elimination ───

pub const DCEPass = bir.Pass{
    .name = "dead-code-elimination",
    .pass_type = .transform,
    .run = runDCE,
};

fn runDCE(module: *Module, allocator: Allocator) anyerror!void {
    module.rebuildUses();

    for (module.functions.items) |*func| {
        for (func.blocks.items) |*block| {
            var live = try allocator.alloc(bool, block.instrs.items.len);
            defer allocator.free(live);
            @memset(live, false);

            var changed = true;
            while (changed) {
                changed = false;
                for (block.instrs.items, 0..) |inst, i| {
                    if (live[i]) continue;
                    if (isSideEffecting(inst.op)) {
                        live[i] = true;
                        changed = true;
                        continue;
                    }
                    if (inst.result != NO_VALUE) {
                        const uses = &func.value_info.items[inst.result - 1].uses;
                        if (uses.items.len > 0) {
                            live[i] = true;
                            changed = true;
                        }
                    }
                }
            }

            var write_idx: usize = 0;
            for (block.instrs.items, 0..) |*inst, i| {
                if (isTerminator(inst.op)) live[i] = true;
                if (live[i]) {
                    if (write_idx != i) {
                        block.instrs.items[write_idx] = block.instrs.items[i];
                        if (inst.result != NO_VALUE) {
                            func.value_info.items[inst.result - 1].def.idx = @as(u32, @intCast(write_idx));
                        }
                    }
                    write_idx += 1;
                } else {
                    inst.deinit(module.allocator);
                }
            }
            block.instrs.shrinkRetainingCapacity(write_idx);
        }
    }
}

fn isSideEffecting(op: Op) bool {
    return switch (op) {
        .store, .texture_store, .barrier, .groupshared_barrier,
        .atomic_add, .atomic_sub, .atomic_min, .atomic_max,
        .atomic_and, .atomic_or, .atomic_xor, .atomic_xchg,
        .atomic_cmpxchg, .fence, .call, .ret, .br, .cond_br,
        .unreachable_op,
        => true,
        else => false,
    };
}

fn isTerminator(op: Op) bool {
    return switch (op) {
        .br, .cond_br, .ret, .unreachable_op => true,
        else => false,
    };
}

// ─── Constant Folding ───

pub const ConstantFoldingPass = bir.Pass{
    .name = "constant-folding",
    .pass_type = .transform,
    .run = runConstantFolding,
};

fn runConstantFolding(module: *Module, allocator: Allocator) anyerror!void {
    _ = allocator;
    var changed = true;
    while (changed) {
        changed = false;
        module.rebuildUses();
        for (module.functions.items) |*func| {
            for (func.blocks.items) |*block| {
                for (block.instrs.items, 0..) |*inst, i| {
                    _ = i;
                    if (inst.op == .@"const") continue;
                    var all_const = true;
                    for (inst.operands) |op_val| {
                        if (op_val == NO_VALUE) {
                            all_const = false;
                            break;
                        }
                        if (getConstValue(func, op_val)) |_| {} else {
                            all_const = false;
                            break;
                        }
                    }
                    if (!all_const) continue;
                    if (inst.operands.len == 0) continue;

                    const result = foldConstantOp(func, inst) orelse continue;

                    for (inst.operands) |op_val| {
                        if (op_val != NO_VALUE) {
                            const vi = func.getValueInfo(op_val);
                            if (std.mem.indexOfScalar(bir.ValueId, vi.uses.items, inst.result)) |use_idx| {
                                _ = vi.uses.swapRemove(use_idx);
                            }
                        }
                    }

                    inst.op = .@"const";
                    inst.operands = &.{};
                    inst.data = .{ .const_data = result };
                    changed = true;
                }
            }
        }
    }
}

fn getConstValue(func: *bir.Function, val: bir.ValueId) ?ConstData {
    if (val == NO_VALUE) return null;
    const vi = func.getValueInfo(val);
    if (vi.def.block == INVALID_ID) return null;
    if (vi.def.block >= func.blocks.items.len) return null;
    const block = &func.blocks.items[vi.def.block];
    if (vi.def.idx >= block.instrs.items.len) return null;
    const def = &block.instrs.items[vi.def.idx];
    if (def.op != .@"const") return null;
    return switch (def.data) {
        .const_data => |cd| cd,
        else => null,
    };
}

fn foldConstantOp(func: *bir.Function, inst: *const Inst) ?ConstData {
    const op = inst.op;
    switch (op) {
        .add, .sub, .mul, .div, .mod => {
            if (inst.operands.len != 2) return null;
            const a = switch (getConstValue(func, inst.operands[0]) orelse return null) {
                .int => |v| v,
                else => return null,
            };
            const b = switch (getConstValue(func, inst.operands[1]) orelse return null) {
                .int => |v| v,
                else => return null,
            };
            return switch (op) {
                .add => ConstData{ .int = a +% b },
                .sub => ConstData{ .int = a -% b },
                .mul => ConstData{ .int = a *% b },
                .div => if (b != 0) ConstData{ .int = @divTrunc(a, b) } else null,
                .mod => if (b != 0) ConstData{ .int = @rem(a, b) } else null,
                else => unreachable,
            };
        },
        .fadd, .fsub, .fmul, .fdiv, .fmod => {
            if (inst.operands.len != 2) return null;
            const a = switch (getConstValue(func, inst.operands[0]) orelse return null) {
                .float => |v| v,
                else => return null,
            };
            const b = switch (getConstValue(func, inst.operands[1]) orelse return null) {
                .float => |v| v,
                else => return null,
            };
            return switch (op) {
                .fadd => ConstData{ .float = a + b },
                .fsub => ConstData{ .float = a - b },
                .fmul => ConstData{ .float = a * b },
                .fdiv => if (b != 0.0) ConstData{ .float = a / b } else null,
                .fmod => if (b != 0.0) ConstData{ .float = @mod(a, b) } else null,
                else => unreachable,
            };
        },
        .neg => {
            if (inst.operands.len != 1) return null;
            const a = switch (getConstValue(func, inst.operands[0]) orelse return null) {
                .int => |v| v,
                else => return null,
            };
            return ConstData{ .int = -%a };
        },
        .fneg => {
            if (inst.operands.len != 1) return null;
            const a = switch (getConstValue(func, inst.operands[0]) orelse return null) {
                .float => |v| v,
                else => return null,
            };
            return ConstData{ .float = -a };
        },
        else => return null,
    }
}

// ─── Common Subexpression Elimination ───

pub const CSEPass = bir.Pass{
    .name = "cse",
    .pass_type = .transform,
    .run = runCSE,
};

fn runCSE(module: *Module, allocator: Allocator) anyerror!void {
    module.rebuildUses();

    for (module.functions.items) |*func| {
        if (func.blocks.items.len == 0) continue;
        if (func.blocks.items.len == 1 and func.blocks.items[0].instrs.items.len == 0) continue;

        var cfg = try bir_cfg.buildCFG(allocator, func);
        defer cfg.deinit();

        var dom_tree = try bir_dominators.buildDominators(allocator, &cfg);
        defer dom_tree.deinit();

        const rpo = cfg.rpo.items;

        var seen = std.AutoHashMap(u64, bir.ValueId).init(allocator);
        defer seen.deinit();

        for (rpo) |bid| {
            const block = func.getBlock(bid);
            for (block.instrs.items, 0..) |*inst, i| {
                _ = i;
                if (inst.result == NO_VALUE) continue;
                if (!isCSEable(inst.op)) continue;

                const key = computeCSEKey(inst);

                if (seen.get(key)) |existing| {
                    const existing_vi = func.getValueInfo(existing);
                    if (existing_vi.def.block != INVALID_ID and
                        dom_tree.dominates(existing_vi.def.block, bid))
                    {
                        replaceAllUsesWith(func, inst.result, existing);
                    }
                } else {
                    try seen.put(key, inst.result);
                }
            }
        }
    }
}

fn isCSEable(op: Op) bool {
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
        .select,
        => true,
        else => false,
    };
}

fn computeCSEKey(inst: *const Inst) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&inst.op));
    hasher.update(std.mem.asBytes(&inst.ty));
    for (inst.operands) |op_val| {
        hasher.update(std.mem.asBytes(&op_val));
    }
    switch (inst.data) {
        .cast_info => |ci| {
            hasher.update(std.mem.asBytes(&ci));
        },
        .vector_shuffle => |vs| {
            hasher.update(std.mem.asBytes(&vs.a));
            hasher.update(std.mem.asBytes(&vs.b));
            for (vs.mask) |m| {
                hasher.update(std.mem.asBytes(&m));
            }
        },
        .gep_info => |gi| {
            hasher.update(std.mem.asBytes(&gi.ptr));
            hasher.update(std.mem.asBytes(&gi.result_elem_type));
            for (gi.indices) |idx| {
                hasher.update(std.mem.asBytes(&idx));
            }
        },
        else => {},
    }
    return hasher.final();
}

fn replaceAllUsesWith(func: *bir.Function, old_val: bir.ValueId, new_val: bir.ValueId) void {
    if (old_val == new_val) return;
    const old_vi = func.getValueInfo(old_val);
    const old_uses = old_vi.uses.items;
    if (old_uses.len == 0) return;

    const uses_copy = func.allocator.dupe(bir.ValueId, old_uses) catch return;
    defer func.allocator.free(uses_copy);

    for (uses_copy) |user_val| {
        const user_vi = func.getValueInfo(user_val);
        if (user_vi.def.block == INVALID_ID) continue;
        if (user_vi.def.block >= func.blocks.items.len) continue;
        const block = func.getBlock(user_vi.def.block);
        if (user_vi.def.idx >= block.instrs.items.len) continue;
        const inst = &block.instrs.items[user_vi.def.idx];

        for (inst.operands) |*op| {
            if (op.* == old_val) {
                op.* = new_val;
            }
        }
        switch (inst.data) {
            .phi_incoming => |incoming| {
                for (incoming) |*inc| {
                    if (inc.value == old_val) inc.value = new_val;
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
                if (si.lod) |*lod| { if (lod.* == old_val) lod.* = new_val; }
                if (si.offset) |*off| { if (off.* == old_val) off.* = new_val; }
            },
            .gep_info => |*gi| {
                if (gi.ptr == old_val) gi.ptr = new_val;
                for (gi.indices) |*idx| {
                    if (idx.* == old_val) idx.* = new_val;
                }
            },
            .call_info => |*ci| {
                if (ci.callee == old_val) ci.callee = new_val;
                for (ci.args) |*arg| {
                    if (arg.* == old_val) arg.* = new_val;
                }
            },
            .cond_branch => |*cb| {
                if (cb.cond == old_val) cb.cond = new_val;
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

// ─── Global Value Numbering ───

pub const GVNPass = bir.Pass{
    .name = "gvn",
    .pass_type = .transform,
    .run = runGVN,
};

fn runGVN(module: *Module, allocator: Allocator) anyerror!void {
    module.rebuildUses();

    for (module.functions.items) |*func| {
        if (func.blocks.items.len == 0) continue;

        var cfg = try bir_cfg.buildCFG(allocator, func);
        defer cfg.deinit();

        var dom_tree = try bir_dominators.buildDominators(allocator, &cfg);
        defer dom_tree.deinit();

        const rpo = cfg.rpo.items;

        var vn_for_val = std.AutoHashMap(bir.ValueId, u32).init(allocator);
        defer vn_for_val.deinit();

        var key_to_val = std.AutoHashMap(u64, bir.ValueId).init(allocator);
        defer key_to_val.deinit();

        var next_vn: u32 = 1;

        for (rpo) |bid| {
            const block = func.getBlock(bid);
            for (block.instrs.items) |*inst| {
                if (inst.result == NO_VALUE) continue;
                if (!isGVNable(inst.op)) {
                    try vn_for_val.put(inst.result, next_vn);
                    next_vn += 1;
                    continue;
                }

                const key = computeVNKey(inst, &vn_for_val);

                if (key_to_val.get(key)) |canonical| {
                    const can_vi = func.getValueInfo(canonical);
                    if (can_vi.def.block != INVALID_ID and
                        dom_tree.dominates(can_vi.def.block, bid))
                    {
                        replaceAllUsesWith(func, inst.result, canonical);
                        if (vn_for_val.get(canonical)) |can_vn| {
                            try vn_for_val.put(inst.result, can_vn);
                        } else {
                            try vn_for_val.put(inst.result, next_vn);
                            next_vn += 1;
                        }
                        continue;
                    }
                }

                try key_to_val.put(key, inst.result);
                try vn_for_val.put(inst.result, next_vn);
                next_vn += 1;
            }
        }
    }
}

fn isGVNable(op: Op) bool {
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
        .select,
        .@"const",
        .phi,
        => true,
        else => false,
    };
}

fn computeVNKey(inst: *const Inst, vn_map: *const std.AutoHashMap(bir.ValueId, u32)) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&inst.op));
    hasher.update(std.mem.asBytes(&inst.ty));

    switch (inst.data) {
        .const_data => |cd| {
            switch (cd) {
                .int => |v| hasher.update(std.mem.asBytes(&v)),
                .float => |v| hasher.update(std.mem.asBytes(&v)),
                .bool => |v| hasher.update(std.mem.asBytes(&v)),
                .undefined, .zero => {},
            }
        },
        .cast_info => |ci| {
            hasher.update(std.mem.asBytes(&ci));
        },
        .phi_incoming => |incoming| {
            for (incoming) |inc| {
                const vn = vn_map.get(inc.value) orelse 0;
                hasher.update(std.mem.asBytes(&vn));
                hasher.update(std.mem.asBytes(&inc.block));
            }
        },
        .vector_shuffle => |vs| {
            const vn_a = vn_map.get(vs.a) orelse 0;
            const vn_b = vn_map.get(vs.b) orelse 0;
            hasher.update(std.mem.asBytes(&vn_a));
            hasher.update(std.mem.asBytes(&vn_b));
            for (vs.mask) |m| {
                hasher.update(std.mem.asBytes(&m));
            }
        },
        .gep_info => |gi| {
            const ptr_vn = vn_map.get(gi.ptr) orelse 0;
            hasher.update(std.mem.asBytes(&ptr_vn));
            hasher.update(std.mem.asBytes(&gi.result_elem_type));
            for (gi.indices) |idx| {
                const idx_vn = vn_map.get(idx) orelse 0;
                hasher.update(std.mem.asBytes(&idx_vn));
            }
        },
        .sample_info => |si| {
            const tex_vn = vn_map.get(si.tex) orelse 0;
            const sampler_vn = vn_map.get(si.sampler) orelse 0;
            const coord_vn = vn_map.get(si.coord) orelse 0;
            hasher.update(std.mem.asBytes(&tex_vn));
            hasher.update(std.mem.asBytes(&sampler_vn));
            hasher.update(std.mem.asBytes(&coord_vn));
            if (si.lod) |lod| {
                const lod_vn = vn_map.get(lod) orelse 0;
                hasher.update(std.mem.asBytes(&lod_vn));
            }
            if (si.offset) |off| {
                const off_vn = vn_map.get(off) orelse 0;
                hasher.update(std.mem.asBytes(&off_vn));
            }
        },
        else => {},
    }

    for (inst.operands) |op_val| {
        const vn = vn_map.get(op_val) orelse 0;
        hasher.update(std.mem.asBytes(&vn));
    }

    return hasher.final();
}

// ─── Memory optimization passes ───

pub const ForwardStoreToLoadPass = bir.Pass{
    .name = "forward-store-to-load",
    .pass_type = .transform,
    .run = runForwardStoreToLoad,
};

fn runForwardStoreToLoad(module: *Module, allocator: Allocator) anyerror!void {
    module.rebuildUses();

    for (module.functions.items) |*func| {
        if (func.blocks.items.len == 0) continue;

        var cfg = try bir_cfg.buildCFG(allocator, func);
        defer cfg.deinit();

        var dom_tree = try bir_dominators.buildDominators(allocator, &cfg);
        defer dom_tree.deinit();

        var mssa = try bir_memory_ssa.build(allocator, func, &cfg, &dom_tree);
        defer {
            mssa.reaching_def.deinit();
            mssa.stored_val.deinit();
        }

        for (func.blocks.items, 0..) |*block, bi| {
            const bid = @as(bir.BlockId, @intCast(bi));
            for (block.instrs.items, 0..) |*inst, ii| {
                if (inst.op != .load) continue;
                if (inst.result == NO_VALUE) continue;
                const reaching = mssa.getReachingStore(bid, @as(u32, @intCast(ii))) orelse continue;
                const stored = mssa.getStoredValue(reaching) orelse continue;
                if (stored == NO_VALUE) continue;
                replaceAllUsesWith(func, inst.result, stored);
            }
        }
    }
}

pub const DeadStoreEliminationPass = bir.Pass{
    .name = "dead-store-elimination",
    .pass_type = .transform,
    .run = runDeadStoreElimination,
};

fn runDeadStoreElimination(module: *Module, allocator: Allocator) anyerror!void {
    module.rebuildUses();

    for (module.functions.items, 0..) |*func, fid| {
        const func_id = @as(bir.FunctionId, @intCast(fid));
        for (func.blocks.items, 0..) |*block, bid| {
            var written_or_loaded = std.AutoHashMap(bir.ValueId, void).init(allocator);
            defer written_or_loaded.deinit();

            var i: i64 = @as(i64, @intCast(block.instrs.items.len)) - 1;
            while (i >= 0) : (i -= 1) {
                const idx = @as(usize, @intCast(i));
                const inst = &block.instrs.items[idx];
                switch (inst.op) {
                    .store => {
                        if (inst.operands.len != 2) continue;
                        const ptr = inst.operands[0];

                        var needed = false;
                        var it = written_or_loaded.keyIterator();
                        while (it.next()) |key| {
                            if (bir_alias.query(func, ptr, key.*) != .NoAlias) {
                                needed = true;
                                break;
                            }
                        }

                        if (!needed) {
                            module.removeInst(func_id, @as(bir.BlockId, @intCast(bid)), @as(u32, @intCast(idx)));
                        }

                        try written_or_loaded.put(ptr, {});
                    },
                    .load => {
                        if (inst.operands.len < 1) continue;
                        try written_or_loaded.put(inst.operands[0], {});
                    },
                    .call => {
                        written_or_loaded.clearRetainingCapacity();
                    },
                    else => {},
                }
            }
        }
    }
}

// ─── Optimizer Pipeline ───

pub const VerifyPass = bir.Pass{
    .name = "verify",
    .pass_type = .analysis,
    .run = runVerify,
};

fn runVerify(module: *Module, allocator: Allocator) anyerror!void {
    try bir_verify.verifyModule(module, allocator);
}

pub const StandardPasses = struct {
    pub fn init(allocator: Allocator) bir.PassManager {
        var pm = bir.PassManager.init(allocator);
        pm.addPass(VerifyPass) catch {};
        pm.addPass(ConstantFoldingPass) catch {};
        pm.addPass(VerifyPass) catch {};
        pm.addPass(GVNPass) catch {};
        pm.addPass(VerifyPass) catch {};
        pm.addPass(bir_unroll.UnrollPass) catch {};
        pm.addPass(VerifyPass) catch {};
        pm.addPass(bir_licm.LICMPass) catch {};
        pm.addPass(VerifyPass) catch {};
        pm.addPass(ForwardStoreToLoadPass) catch {};
        pm.addPass(VerifyPass) catch {};
        pm.addPass(DeadStoreEliminationPass) catch {};
        pm.addPass(VerifyPass) catch {};
        pm.addPass(DCEPass) catch {};
        pm.addPass(VerifyPass) catch {};
        return pm;
    }
};
