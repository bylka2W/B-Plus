const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../../bir.zig");
const bir_cfg = @import("../../analysis/cfg/cfg.zig");
const bir_dominators = @import("../../analysis/dominator/dominator.zig");
const INVALID_ID = bir.INVALID_ID;
const NO_VALUE = bir.NO_VALUE;
const ValueId = bir.ValueId;
const BlockId = bir.BlockId;
const Module = bir.Module;
const PreservedAnalyses = bir.PreservedAnalyses;

const VersionLog = struct { alloca: ValueId, old_version: ValueId };

pub const Mem2RegPass = bir.Pass{
    .name = "mem2reg",
    .run = runMem2Reg,
};

fn runMem2Reg(ctx: *bir.PassContext) anyerror!PreservedAnalyses {
    const module = ctx.module;
    module.rebuildUses();

    for (module.functions.items, 0..) |*func, fid| {
        if (func.blocks.items.len < 1) continue;
        const func_id = @as(bir.FunctionId, @intCast(fid));

        const cfg = try ctx.analysis.getCFG(func_id);
        const dom_tree = try ctx.analysis.getDomTree(func_id);
        const df = try ctx.analysis.getDomFrontier(func_id);

        var allocas = try collectAllocas(func);
        defer {
            for (allocas.items) |*a| a.deinit(func.allocator);
            allocas.deinit();
        }

        for (allocas.items) |*alloca_info| {
            try promoteAlloca(module, func_id, func, cfg, dom_tree, df, alloca_info);
        }
    }
    return PreservedAnalyses.none();
}

const AllocaInfo = struct {
    alloca_val: ValueId,
    ty: bir.TypeId,

    pub fn deinit(_: *AllocaInfo, _: Allocator) void {}
};

fn collectAllocas(func: *bir.Function) !std.ArrayList(AllocaInfo) {
    var result = std.ArrayList(AllocaInfo).init(func.allocator);
    for (func.blocks.items) |*block| {
        for (block.instrs.items) |*inst| {
            if (inst.op != .alloca) continue;
            if (inst.result == NO_VALUE) continue;
            try result.append(.{
                .alloca_val = inst.result,
                .ty = inst.ty,
            });
        }
    }
    return result;
}

fn promoteAlloca(
    module: *Module,
    func_id: bir.FunctionId,
    func: *bir.Function,
    cfg: *const bir_cfg.CFG,
    dom_tree: *const bir_dominators.DominatorTree,
    df: *const bir_dominators.DominanceFrontier,
    alloca_info: *const AllocaInfo,
) !void {
    const alloca_val = alloca_info.alloca_val;

    var store_blocks = std.ArrayList(BlockId).init(module.allocator);
    defer store_blocks.deinit();

    for (func.blocks.items, 0..) |*block, bi| {
        for (block.instrs.items) |*inst| {
            if (inst.op == .store and inst.operands.len >= 2 and inst.operands[0] == alloca_val) {
                try store_blocks.append(@as(BlockId, @intCast(bi)));
            }
        }
    }

    if (store_blocks.items.len == 0) return;

    var phi_blocks = std.AutoHashMap(BlockId, void).init(module.allocator);
    defer phi_blocks.deinit();

    var idf_worklist = std.ArrayList(BlockId).init(module.allocator);
    defer idf_worklist.deinit();

    for (store_blocks.items) |sb| {
        try idf_worklist.append(sb);
    }

    while (idf_worklist.items.len > 0) {
        const b = idf_worklist.pop().?;
        for (df.get(b)) |dfb| {
            if (!phi_blocks.contains(dfb)) {
                try phi_blocks.put(dfb, {});
                try idf_worklist.append(dfb);
            }
        }
    }

    var phi_for_block = std.AutoHashMap(BlockId, ValueId).init(module.allocator);
    defer phi_for_block.deinit();

    var pit = phi_blocks.keyIterator();
    while (pit.next()) |bid_ptr| {
        const bid = bid_ptr.*;
        const phi_val = try module.addPhi(func_id, bid, alloca_info.ty, &.{});
        try phi_for_block.put(bid, phi_val);
    }

    var version_for = std.AutoHashMap(ValueId, ValueId).init(module.allocator);
    defer version_for.deinit();

    var push_log = std.ArrayList(VersionLog).init(module.allocator);
    defer push_log.deinit();

    try renameBlock(module, func, func_id, cfg, dom_tree, &phi_for_block, &version_for, &push_log, cfg.entry, alloca_val);

    var i: usize = func.blocks.items.len;
    while (i > 0) {
        i -= 1;
        const bid = @as(BlockId, @intCast(i));
        const block = func.getBlock(bid);
        var j: usize = block.instrs.items.len;
        while (j > 0) {
            j -= 1;
            const inst = &block.instrs.items[j];
            if (inst.op == .alloca and inst.result == alloca_val) {
                module.removeInst(func_id, bid, @as(u32, @intCast(j)));
                break;
            }
        }
    }

    i = func.blocks.items.len;
    while (i > 0) {
        i -= 1;
        const bid = @as(BlockId, @intCast(i));
        const block = func.getBlock(bid);
        var j: usize = block.instrs.items.len;
        while (j > 0) {
            j -= 1;
            const inst = &block.instrs.items[j];
            if (inst.op == .store and inst.operands.len >= 2 and inst.operands[0] == alloca_val) {
                module.removeInst(func_id, bid, @as(u32, @intCast(j)));
            }
        }
    }

    i = func.blocks.items.len;
    while (i > 0) {
        i -= 1;
        const bid = @as(BlockId, @intCast(i));
        const block = func.getBlock(bid);
        var j: usize = block.instrs.items.len;
        while (j > 0) {
            j -= 1;
            const inst = &block.instrs.items[j];
            if (inst.op == .load and inst.operands.len >= 1 and inst.operands[0] == alloca_val) {
                module.removeInst(func_id, bid, @as(u32, @intCast(j)));
            }
        }
    }

    module.rebuildUses();
}

fn renameBlock(
    module: *Module,
    func: *bir.Function,
    func_id: bir.FunctionId,
    cfg: *const bir_cfg.CFG,
    dom_tree: *const bir_dominators.DominatorTree,
    phi_for_block: *const std.AutoHashMap(BlockId, ValueId),
    version_for: *std.AutoHashMap(ValueId, ValueId),
    push_log: *std.ArrayList(VersionLog),
    bid: BlockId,
    alloca_val: ValueId,
) !void {
    if (bid >= func.blocks.items.len) return;

    const saved_len = push_log.items.len;

    const block = func.getBlock(bid);

    for (block.instrs.items) |*inst| {
        if (inst.op == .phi) {
            if (phi_for_block.get(bid)) |phi_val| {
                if (inst.result == phi_val) {
                    const old = version_for.get(alloca_val) orelse NO_VALUE;
                    try version_for.put(alloca_val, phi_val);
                    try push_log.append(.{ .alloca = alloca_val, .old_version = old });
                }
            }
        }
    }

    for (block.instrs.items) |*inst| {
        if (inst.op == .store and inst.operands.len >= 2 and inst.operands[0] == alloca_val) {
            const stored_val = inst.operands[1];
            const old = version_for.get(alloca_val) orelse NO_VALUE;
            try version_for.put(alloca_val, stored_val);
            try push_log.append(.{ .alloca = alloca_val, .old_version = old });
        }
        if (inst.op == .load and inst.operands.len >= 1 and inst.operands[0] == alloca_val) {
            const load_val = inst.result;
            const current_version = version_for.get(alloca_val) orelse alloca_val;
            if (load_val != current_version) {
                replaceAllUses(func, load_val, current_version);
            }
        }
    }

    const current_version = version_for.get(alloca_val) orelse alloca_val;
    const succs = func.blocks.items[bid].succs.items;
    for (succs) |succ| {
        if (phi_for_block.get(succ)) |phi_val| {
            const succ_block = func.getBlock(succ);
            for (succ_block.instrs.items) |*inst| {
                if (inst.op == .phi and inst.result == phi_val) {
                    const old_inc = inst.data.phi_incoming;
                    const new_inc = try func.allocator.alloc(bir.PhiIncoming, old_inc.len + 1);
                    for (old_inc, 0..) |inc, i| {
                        new_inc[i] = inc;
                    }
                    if (old_inc.len > 0) func.allocator.free(old_inc);
                    new_inc[old_inc.len] = .{ .value = current_version, .block = bid };
                    inst.data.phi_incoming = new_inc;
                }
            }
        }
    }

    for (dom_tree.children[bid]) |child| {
        try renameBlock(module, func, func_id, cfg, dom_tree, phi_for_block, version_for, push_log, child, alloca_val);
    }

    while (push_log.items.len > saved_len) {
        const entry = pop(push_log);
        try version_for.put(entry.alloca, entry.old_version);
    }
}

fn pop(list: anytype) @TypeOf(list.items[0]) {
    const idx = list.items.len - 1;
    const val = list.items[idx];
    list.items.len = idx;
    return val;
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
            .vector_shuffle => |*vs| {
                if (vs.a == old_val) vs.a = new_val;
                if (vs.b == old_val) vs.b = new_val;
            },
            else => {},
        }

        const new_vi = func.getValueInfo(new_val);
        new_vi.uses.append(user_val) catch {};
    }

    old_vi.uses.clearRetainingCapacity();
}
