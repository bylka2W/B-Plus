const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("bir.zig");
const bir_cfg = @import("bir_cfg.zig");
const bir_dominators = @import("bir_dominators.zig");

const Op = bir.Op;
const INVALID_ID = bir.INVALID_ID;
const NO_VALUE = bir.NO_VALUE;
const ValueId = bir.ValueId;
const BlockId = bir.BlockId;

pub const VerifyError = error{
    InvalidBlockId,
    MissingTerminator,
    ExtraTerminator,
    InvalidTerminatorBranch,
    InvalidValueId,
    UndefinedValue,
    DominanceViolation,
    InvalidPhiIncomingBlock,
    UnreachableBlockInRPO,
};

pub fn verifyModule(module: *bir.Module, allocator: Allocator) !void {
    for (module.functions.items, 0..) |*func, fid| {
        const func_id = @as(bir.FunctionId, @intCast(fid));
        try verifyFunction(module, func, func_id, allocator);
    }
}

pub fn verifyFunction(_: *bir.Module, func: *bir.Function, _: bir.FunctionId, allocator: Allocator) !void {
    const nblocks = func.blocks.items.len;
    if (nblocks == 0) return;

    for (func.blocks.items, 0..) |*block, bid| {
        try verifyBlockStructure(block, @as(BlockId, @intCast(bid)), nblocks);
    }

    var cfg = try bir_cfg.buildCFG(allocator, func);
    defer cfg.deinit();

    var dom_tree = try bir_dominators.buildDominators(allocator, &cfg);
    defer dom_tree.deinit();

    for (func.blocks.items, 0..) |*block, bid| {
        const block_id = @as(BlockId, @intCast(bid));
        try verifyInstructions(func, block, block_id, &cfg, &dom_tree);
    }
}

fn verifyBlockStructure(block: *bir.BasicBlock, block_id: BlockId, nblocks: usize) !void {
    _ = block_id;
    const n = block.instrs.items.len;
    if (n == 0) return;

    var term_found = false;
    for (block.instrs.items, 0..) |inst, i| {
        _ = i;
        if (isTerminator(inst.op)) {
            if (term_found) return error.ExtraTerminator;
            term_found = true;
            try verifyTerminator(inst, nblocks);
        } else if (term_found) {
            return error.ExtraTerminator;
        }
    }
}

fn verifyTerminator(inst: bir.Inst, nblocks: usize) !void {
    switch (inst.op) {
        .br => {
            const target = inst.data.block_target;
            if (target >= nblocks) return error.InvalidTerminatorBranch;
        },
        .cond_br => {
            const cb = inst.data.cond_branch;
            if (cb.then_block >= nblocks) return error.InvalidTerminatorBranch;
            if (cb.else_block >= nblocks) return error.InvalidTerminatorBranch;
        },
        .ret, .unreachable_op => {},
        else => return error.InvalidTerminatorBranch,
    }
}

fn verifyInstructions(
    func: *bir.Function,
    block: *bir.BasicBlock,
    block_id: BlockId,
    cfg: *const bir_cfg.CFG,
    dom_tree: *const bir_dominators.DominatorTree,
) !void {
    for (block.instrs.items, 0..) |*inst, i| {
        if (inst.result != NO_VALUE) {
            const def = func.getValueInfo(inst.result).def;
            if (def.block != block_id or def.idx != i) {
                return error.UndefinedValue;
            }
        }

        const is_phi = inst.op == .phi;
        if (is_phi) {
            for (inst.data.phi_incoming) |inc| {
                if (inc.value == NO_VALUE) continue;
                try verifyPhiValueDefined(func, inc.value, inc.block, dom_tree, cfg);
            }
        } else {
            for (inst.operands) |op_val| {
                if (op_val == NO_VALUE) continue;
                try verifyValueDefined(func, op_val, block_id, dom_tree, cfg);
            }
        }

        try verifyInstDataValues(func, inst.*, block_id, dom_tree, cfg);
    }
}

fn verifyInstDataValues(
    func: *bir.Function,
    inst: bir.Inst,
    block_id: BlockId,
    dom_tree: *const bir_dominators.DominatorTree,
    cfg: *const bir_cfg.CFG,
) !void {
    switch (inst.data) {
        .phi_incoming => |incoming| {
            if (rpoIndex(cfg, block_id) == null) return;
            const preds = cfg.get(block_id).predecessors.items;
            for (incoming) |inc| {
                if (inc.block >= func.blocks.items.len) return error.InvalidPhiIncomingBlock;
                var found = false;
                for (preds) |pred| {
                    if (pred == inc.block) { found = true; break; }
                }
                if (!found) return error.InvalidPhiIncomingBlock;
            }
        },
        .cond_branch => |cb| {
            if (cb.cond != NO_VALUE) {
                try verifyValueDefined(func, cb.cond, block_id, dom_tree, cfg);
            }
        },
        .texture_store_info => |tsi| {
            if (tsi.tex != NO_VALUE) try verifyValueDefined(func, tsi.tex, block_id, dom_tree, cfg);
            if (tsi.coord_x != NO_VALUE) try verifyValueDefined(func, tsi.coord_x, block_id, dom_tree, cfg);
            if (tsi.coord_y != NO_VALUE) try verifyValueDefined(func, tsi.coord_y, block_id, dom_tree, cfg);
            if (tsi.val != NO_VALUE) try verifyValueDefined(func, tsi.val, block_id, dom_tree, cfg);
        },
        .sample_info => |si| {
            if (si.tex != NO_VALUE) try verifyValueDefined(func, si.tex, block_id, dom_tree, cfg);
            if (si.sampler != NO_VALUE) try verifyValueDefined(func, si.sampler, block_id, dom_tree, cfg);
            if (si.coord != NO_VALUE) try verifyValueDefined(func, si.coord, block_id, dom_tree, cfg);
            if (si.lod) |lod| { if (lod != NO_VALUE) try verifyValueDefined(func, lod, block_id, dom_tree, cfg); }
            if (si.offset) |off| { if (off != NO_VALUE) try verifyValueDefined(func, off, block_id, dom_tree, cfg); }
        },
        .named_call => |nc| {
            for (nc.args) |arg| {
                if (arg != NO_VALUE) try verifyValueDefined(func, arg, block_id, dom_tree, cfg);
            }
        },
        .gep_info => |gi| {
            if (gi.ptr != NO_VALUE) try verifyValueDefined(func, gi.ptr, block_id, dom_tree, cfg);
            for (gi.indices) |idx| {
                if (idx != NO_VALUE) try verifyValueDefined(func, idx, block_id, dom_tree, cfg);
            }
        },
        .atomic_info => |ai| {
            if (ai.ptr != NO_VALUE) try verifyValueDefined(func, ai.ptr, block_id, dom_tree, cfg);
            if (ai.val != NO_VALUE) try verifyValueDefined(func, ai.val, block_id, dom_tree, cfg);
        },
        .call_info => |ci| {
            if (ci.callee != NO_VALUE) try verifyValueDefined(func, ci.callee, block_id, dom_tree, cfg);
            for (ci.args) |arg| {
                if (arg != NO_VALUE) try verifyValueDefined(func, arg, block_id, dom_tree, cfg);
            }
        },
        else => {},
    }
}

fn verifyValueDefined(
    func: *bir.Function,
    val: ValueId,
    use_block: BlockId,
    dom_tree: *const bir_dominators.DominatorTree,
    cfg: *const bir_cfg.CFG,
) !void {
    if (val > func.locals_count) return error.InvalidValueId;
    const vi = func.getValueInfo(val);
    if (vi.def.block == INVALID_ID) return error.UndefinedValue;
    if (vi.def.block >= func.blocks.items.len) return error.InvalidBlockId;
    const def_block = vi.def.block;

    if (def_block == use_block) {
        if (vi.def.idx >= func.blocks.items[use_block].instrs.items.len) return error.UndefinedValue;
        return;
    }

    const def_in_rpo = rpoIndex(cfg, def_block);
    const use_in_rpo = rpoIndex(cfg, use_block);
    if (def_in_rpo == null or use_in_rpo == null) return;

    if (!dom_tree.dominates(def_block, use_block)) return error.DominanceViolation;
}

fn verifyPhiValueDefined(
    func: *bir.Function,
    val: ValueId,
    pred_block: BlockId,
    dom_tree: *const bir_dominators.DominatorTree,
    cfg: *const bir_cfg.CFG,
) !void {
    if (val > func.locals_count) return error.InvalidValueId;
    const vi = func.getValueInfo(val);
    if (vi.def.block == INVALID_ID) return error.UndefinedValue;
    if (vi.def.block >= func.blocks.items.len) return error.InvalidBlockId;
    const def_block = vi.def.block;

    if (def_block == pred_block) return;

    const def_in_rpo = rpoIndex(cfg, def_block);
    const pred_in_rpo = rpoIndex(cfg, pred_block);
    if (def_in_rpo == null or pred_in_rpo == null) return;

    if (!dom_tree.dominates(def_block, pred_block)) return error.DominanceViolation;
}

fn rpoIndex(cfg: *const bir_cfg.CFG, bid: BlockId) ?usize {
    for (cfg.rpo.items, 0..) |b, i| {
        if (b == bid) return i;
    }
    return null;
}

fn isTerminator(op: Op) bool {
    return switch (op) {
        .br, .cond_br, .ret, .unreachable_op => true,
        else => false,
    };
}
