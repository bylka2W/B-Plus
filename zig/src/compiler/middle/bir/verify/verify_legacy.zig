const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../bir.zig");
const bir_types = bir.types;
const bir_cfg = @import("../analysis/cfg/cfg.zig");
const bir_dominators = @import("../analysis/dominator/dominator.zig");
const bir_memory_ssa = @import("../analysis/memoryssa/memoryssa.zig");

const Op = bir.Op;
const BlockId = bir.BlockId;
const ValueId = bir.ValueId;
const FunctionId = bir.FunctionId;
const TypeId = bir_types.TypeId;
const INVALID_TYPE = bir_types.INVALID_TYPE;

pub const VerifyError = struct {
    code: ErrorCode,
    msg: []const u8,
    func_id: FunctionId,
    block: ?BlockId,
    inst_idx: ?u32,
    val: ?ValueId,
};

pub const ErrorCode = enum {
    ok,
    invalid_block_id,
    missing_terminator,
    extra_terminator,
    invalid_branch_target,
    invalid_value_id,
    undefined_value,
    dominance_violation,
    phi_incoming_block_not_pred,
    phi_incoming_count_mismatch,
    phi_duplicate_incoming_block,
    cfgs_symmetry_broken,
    cfgs_entry_has_predecessor,
    domtree_invalid_idom,
    valueinfo_def_mismatch,
    use_def_symmetry_broken,
    data_ref_use_symmetry_broken,
    type_mismatch,
    type_operand_mismatch,
    type_cast_mismatch,
    type_select_mismatch,
    stack_corrupted,
    phi_placement_invalid,
    mssa_no_reaching_def,
    mssa_invalid_reaching_def,
    mssa_stored_val_mismatch,
};

pub const VerifyResult = struct {
    errors: []const VerifyError,
    allocator: Allocator,

    pub fn deinit(self: *VerifyResult) void {
        for (self.errors) |*e| self.allocator.free(e.msg);
        self.allocator.free(self.errors);
    }
};

// ─── Public API — run all checks ───

pub fn verifyModule(module: *bir.Module, allocator: Allocator) !VerifyResult {
    var errs = std.ArrayList(VerifyError).init(allocator);
    errdefer {
        for (errs.items) |*e| allocator.free(e.msg);
        errs.deinit();
    }

    for (module.functions.items, 0..) |*func, fid| {
        const func_id = @as(FunctionId, @intCast(fid));
        try verifyFunction(module, func, func_id, allocator, &errs);
    }

    return VerifyResult{
        .errors = try errs.toOwnedSlice(),
        .allocator = allocator,
    };
}

fn verifyFunction(module: *bir.Module, func: *bir.Function, func_id: FunctionId, allocator: Allocator, errs: *std.ArrayList(VerifyError)) !void {
    const n = func.blocks.items.len;
    if (n == 0) return;

    var cfg = try bir_cfg.buildCFG(allocator, func);
    defer cfg.deinit();

    var dom_tree = try bir_dominators.buildDominators(allocator, &cfg, func);
    defer dom_tree.deinit();

    var dom_frontier = try bir_dominators.buildDominanceFrontiers(allocator, &cfg, func, &dom_tree);
    defer dom_frontier.deinit();

    try checkCFGSymmetry(func, &cfg, func_id, errs);
    try checkEntryBlock(func, &cfg, func_id, errs);
    try checkDominatorTree(&dom_tree, n, func_id, errs);

    for (func.blocks.items, 0..) |*block, bi| {
        const bid = @as(BlockId, @intCast(bi));
        try checkBlockStructure(block, bid, n, func_id, errs);

        for (block.instrs.items, 0..) |*inst, ii| {
            const idx = @as(u32, @intCast(ii));
            try checkInst(module, func, block, bid, inst, idx, &cfg, &dom_tree, &dom_frontier, func_id, errs);
        }
    }

    try checkUseDefSymmetry(func, func_id, errs);
}

fn addError(errs: *std.ArrayList(VerifyError), comptime fmt: []const u8, args: anytype, code: ErrorCode, func_id: FunctionId, block: ?BlockId, inst_idx: ?u32, val: ?ValueId) !void {
    const msg = try std.fmt.allocPrint(errs.allocator, fmt, args);
    errdefer errs.allocator.free(msg);
    try errs.append(.{
        .code = code,
        .msg = msg,
        .func_id = func_id,
        .block = block,
        .inst_idx = inst_idx,
        .val = val,
    });
}

// ─── PassContract ───

pub const PassContract = struct {
    module: *bir.Module,
    func_id: FunctionId,
    func: *bir.Function,

    pub fn before(module: *bir.Module, func_id: FunctionId) !PassContract {
        const func = module.getFunctionMut(func_id);
        return PassContract{ .module = module, .func_id = func_id, .func = func };
    }

    pub fn after(self: *const PassContract) !bir.ChangeSet {
        const allocator = self.module.allocator;
        var result = try verifyModule(self.module, allocator);
        defer result.deinit();
        if (result.errors.len > 0) {
            if (@import("builtin").mode == .Debug) {
                for (result.errors) |e| {
                    std.debug.print("VERIFY: [{s}] func={d} block={?} inst={?} val={?}: {s}\n", .{
                        @tagName(e.code), e.func_id, e.block, e.inst_idx, e.val, e.msg,
                    });
                }
            }
            return error.VerificationFailed;
        }
        return bir.ChangeSet.all();
    }
};

// ─── CFG Checks ───

fn checkCFGSymmetry(func: *bir.Function, cfg: *const bir_cfg.CFG, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    _ = cfg;
    for (func.blocks.items, 0..) |*block, bi| {
        const bid = @as(BlockId, @intCast(bi));

        for (block.succs.items) |succ| {
            if (succ >= func.blocks.items.len) {
                try addError(errs, "block {} successor {} out of range", .{ bid, succ }, .invalid_branch_target, func_id, bid, null, null);
                continue;
            }
            const succ_has_bid = for (func.blocks.items[succ].preds.items) |p| {
                if (p == bid) break true;
            } else false;
            if (!succ_has_bid) {
                try addError(errs, "CFG symmetry: block {} has succ {} but {} preds don't include {}", .{ bid, succ, succ, bid }, .cfgs_symmetry_broken, func_id, bid, null, null);
            }
        }

        for (block.preds.items) |pred| {
            if (pred >= func.blocks.items.len) {
                try addError(errs, "block {} predecessor {} out of range", .{ bid, pred }, .invalid_branch_target, func_id, bid, null, null);
                continue;
            }
            const pred_has_bid = for (func.blocks.items[pred].succs.items) |s| {
                if (s == bid) break true;
            } else false;
            if (!pred_has_bid) {
                try addError(errs, "CFG symmetry: block {} has pred {} but {} succs don't include {}", .{ bid, pred, pred, bid }, .cfgs_symmetry_broken, func_id, bid, null, null);
            }
        }
    }
}

fn checkEntryBlock(func: *bir.Function, cfg: *const bir_cfg.CFG, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    if (cfg.entry >= func.blocks.items.len) {
        try addError(errs, "entry block {} out of range (nblocks={})", .{ cfg.entry, func.blocks.items.len }, .invalid_block_id, func_id, null, null, null);
        return;
    }
    if (func.blocks.items[cfg.entry].preds.items.len > 0) {
        try addError(errs, "entry block {} has {} predecessors", .{ cfg.entry, func.blocks.items[cfg.entry].preds.items.len }, .cfgs_entry_has_predecessor, func_id, cfg.entry, null, null);
    }
}

// ─── Block Structure ───

fn checkBlockStructure(block: *bir.BasicBlock, bid: BlockId, nblocks: usize, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    const n = block.instrs.items.len;
    if (n == 0) {
        if (bid != 0) {
            try addError(errs, "block {} has no instructions", .{bid}, .missing_terminator, func_id, bid, null, null);
        }
        return;
    }

    var term_found = false;
    var term_idx: usize = undefined;
    for (block.instrs.items, 0..) |inst, i| {
        if (isTerminator(inst.op)) {
            if (term_found) {
                try addError(errs, "block {} has multiple terminators (at idx {} and {})", .{ bid, term_idx, i }, .extra_terminator, func_id, bid, @as(u32, @intCast(i)), null);
            }
            term_found = true;
            term_idx = i;
            try checkTerminator(inst, bid, nblocks, func_id, errs);
        } else if (term_found) {
            try addError(errs, "block {} has instruction after terminator at idx {}", .{ bid, i }, .extra_terminator, func_id, bid, @as(u32, @intCast(i)), null);
        }
    }

    if (!term_found) {
        try addError(errs, "block {} has no terminator", .{bid}, .missing_terminator, func_id, bid, null, null);
    }
}

fn checkTerminator(inst: bir.Inst, bid: BlockId, nblocks: usize, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    switch (inst.op) {
        .br => {
            const target = inst.data.block_target;
            if (target >= nblocks) {
                try addError(errs, "block {} br target {} out of range", .{ bid, target }, .invalid_branch_target, func_id, bid, null, null);
            }
        },
        .cond_br => {
            const cb = inst.data.cond_branch;
            if (cb.then_block >= nblocks) {
                try addError(errs, "block {} cond_br then_block {} out of range", .{ bid, cb.then_block }, .invalid_branch_target, func_id, bid, null, null);
            }
            if (cb.else_block >= nblocks) {
                try addError(errs, "block {} cond_br else_block {} out of range", .{ bid, cb.else_block }, .invalid_branch_target, func_id, bid, null, null);
            }
        },
        .ret, .unreachable_op => {},
        .branch_on_bit => {
            const bb = inst.data.branch_on_bit;
            if (bb.then_block >= nblocks) {
                try addError(errs, "block {} branch_on_bit then_block {} out of range", .{ bid, bb.then_block }, .invalid_branch_target, func_id, bid, null, null);
            }
            if (bb.else_block >= nblocks) {
                try addError(errs, "block {} branch_on_bit else_block {} out of range", .{ bid, bb.else_block }, .invalid_branch_target, func_id, bid, null, null);
            }
        },
        else => {
            try addError(errs, "block {} has invalid terminator op {s}", .{ bid, @tagName(inst.op) }, .invalid_branch_target, func_id, bid, null, null);
        },
    }
}

// ─── Dominator Tree Checks ───

fn checkDominatorTree(dt: *const bir_dominators.DominatorTree, n: usize, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    if (n == 0) return;

    if (dt.idom.len != n) return;
    if (dt.children.len != n) return;
    if (dt.depth.len != n) return;

    if (dt.idom[0] != bir.INVALID_ID) {
        try addError(errs, "entry block idom must be INVALID_ID, got {}", .{dt.idom[0]}, .domtree_invalid_idom, func_id, 0, null, null);
    }

    for (dt.children, 0..) |child_slice, bid| {
        for (child_slice) |child| {
            if (dt.idom[child] != bid) {
                try addError(errs, "domtree: block {} is child of {} but idom[{}] != {}", .{ child, bid, child, bid }, .domtree_invalid_idom, func_id, @as(BlockId, @intCast(bid)), null, null);
            }
        }
    }

    for (dt.idom, 0..) |parent, bid| {
        if (parent == bir.INVALID_ID) continue;
        if (parent >= n) {
            try addError(errs, "domtree: idom[{}] = {} out of range", .{ bid, parent }, .domtree_invalid_idom, func_id, @as(BlockId, @intCast(bid)), null, null);
            continue;
        }
        if (!dominates(dt, parent, @as(BlockId, @intCast(bid)))) {
            try addError(errs, "domtree: idom[{}] = {} must dominate {}", .{ bid, parent, bid }, .domtree_invalid_idom, func_id, @as(BlockId, @intCast(bid)), null, null);
        }
    }
}

fn dominates(dt: *const bir_dominators.DominatorTree, a: BlockId, b: BlockId) bool {
    if (a == b) return true;
    var cur = b;
    while (cur != bir.INVALID_ID) {
        if (cur == a) return true;
        cur = dt.idom[cur];
    }
    return false;
}

// ─── Instruction Checks ───

fn checkInst(module: *bir.Module, func: *bir.Function, _: *bir.BasicBlock, bid: BlockId, inst: *const bir.Inst, idx: u32, cfg: *const bir_cfg.CFG, dom_tree: *const bir_dominators.DominatorTree, dom_frontier: *const bir_dominators.DominanceFrontier, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    try checkValueDef(func, inst, bid, idx, func_id, errs);
    try checkTypeConsistency(module, func, inst, func_id, bid, idx, errs);

    const is_phi = inst.op == .phi;
    if (is_phi) {
        try checkPhi(func, inst, bid, cfg, dom_tree, func_id, errs);
        try checkPhiPlacement(func, inst, bid, dom_frontier, func_id, errs);
    } else {
        try checkOperandsDefined(func, inst, bid, dom_tree, cfg, func_id, errs);
    }

    try checkDataRefsDefined(func, inst, bid, dom_tree, cfg, func_id, errs);
}

fn checkValueDef(func: *bir.Function, inst: *const bir.Inst, bid: BlockId, idx: u32, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    if (inst.result == bir.NO_VALUE) return;
    if (inst.result > func.value_info.items.len) {
        try addError(errs, "result {} exceeds value_info len {}", .{ inst.result, func.value_info.items.len }, .invalid_value_id, func_id, bid, idx, inst.result);
        return;
    }
    const vi = func.getValueInfo(inst.result);
    if (vi.def.block != bid or vi.def.idx != idx) {
        try addError(errs, "value_info[{}].def is ({},{}) but inst is at ({},{})", .{ inst.result, vi.def.block, vi.def.idx, bid, idx }, .valueinfo_def_mismatch, func_id, bid, idx, inst.result);
    }
}

fn checkOperandsDefined(func: *bir.Function, inst: *const bir.Inst, use_bid: BlockId, dom_tree: *const bir_dominators.DominatorTree, cfg: *const bir_cfg.CFG, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    for (inst.operands) |op_val| {
        if (op_val == bir.NO_VALUE) continue;
        try checkValueDefined(func, op_val, use_bid, dom_tree, cfg, func_id, errs);
    }
}

fn checkPhi(func: *bir.Function, inst: *const bir.Inst, bid: BlockId, cfg: *const bir_cfg.CFG, dom_tree: *const bir_dominators.DominatorTree, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    if (inst.data != .phi_incoming) {
        try addError(errs, "phi instruction missing phi_incoming data", .{}, .stack_corrupted, func_id, bid, null, inst.result);
        return;
    }
    const incoming = inst.data.phi_incoming;

    if (rpoIndex(cfg, bid) == null) return;

    const preds = func.blocks.items[bid].preds.items;

    if (incoming.len != preds.len) {
        try addError(errs, "phi in block {}: {} incoming values but {} predecessors", .{ bid, incoming.len, preds.len }, .phi_incoming_count_mismatch, func_id, bid, null, inst.result);
    }

    for (incoming) |inc| {
        if (inc.block >= func.blocks.items.len) {
            try addError(errs, "phi incoming block {} out of range", .{inc.block}, .phi_incoming_block_not_pred, func_id, bid, null, inst.result);
            continue;
        }
        var found = false;
        for (preds) |pred| {
            if (pred == inc.block) {
                found = true;
                break;
            }
        }
        if (!found) {
            try addError(errs, "phi incoming block {} is not a predecessor of {}", .{ inc.block, bid }, .phi_incoming_block_not_pred, func_id, bid, null, inst.result);
        }
        if (inc.value != bir.NO_VALUE) {
            try checkPhiValueDefined(func, inc.value, inc.block, dom_tree, cfg, func_id, errs);
        }
    }

    {
        var i: usize = 0;
        while (i < incoming.len) {
            var j: usize = i + 1;
            while (j < incoming.len) {
                if (incoming[i].block == incoming[j].block) {
                    try addError(errs, "phi in block {} has duplicate incoming from block {}", .{ bid, incoming[i].block }, .phi_duplicate_incoming_block, func_id, bid, null, inst.result);
                }
                j += 1;
            }
            i += 1;
        }
    }
}

// ─── Type Consistency (TypeVerifier) ───

fn checkTypeConsistency(module: *bir.Module, func: *bir.Function, inst: *const bir.Inst, func_id: FunctionId, bid: BlockId, idx: u32, errs: *std.ArrayList(VerifyError)) !void {
    const ops = inst.operands;
    const result_ty = inst.ty;


    switch (inst.op) {
        // ── VOID ops (no meaningful result type) ──
        .br, .cond_br, .ret, .unreachable_op, .branch_on_bit,
        .barrier, .groupshared_barrier,
        .fence,
        .texture_store => {},

        // ── Integer arithmetic — operands == result == integer ──
        .add, .sub, .mul, .div, .mod, .max, .min, .neg,
        .shl, .shr, .shra,
        .or_op, .and_op, .xor_op, .not => {
            if (result_ty == INVALID_TYPE) return;
            if (!isIntType(module, result_ty)) return;
            for (ops) |op_val| {
                if (op_val == bir.NO_VALUE) continue;
                const op_ty = getTypeOfValue(module, func, op_val) orelse continue;
                if (!typesEqual(module, op_ty, result_ty)) {
                    try addError(errs, "{s} operand type mismatch", .{@tagName(inst.op)}, .type_operand_mismatch, func_id, bid, idx, inst.result);
                }
            }
        },

        // ── Float arithmetic — operands == result == float ──
        .fadd, .fsub, .fmul, .fdiv, .fmod, .fneg, .sqrt, .rsqrt, .exp, .log, .sin, .cos,
        .floor, .ceil, .frac, .abs, .saturate, .fma, .lerp => {
            if (result_ty == INVALID_TYPE) return;
            if (!isFloatType(module, result_ty)) return;
            for (ops) |op_val| {
                if (op_val == bir.NO_VALUE) continue;
                const op_ty = getTypeOfValue(module, func, op_val) orelse continue;
                if (!typesEqual(module, op_ty, result_ty)) {
                    try addError(errs, "{s} operand type mismatch", .{@tagName(inst.op)}, .type_operand_mismatch, func_id, bid, idx, inst.result);
                }
            }
        },

        // ── Integer comparison — operands int same, result i1 ──
        .eq, .ne, .lt, .le, .gt, .ge => {
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const op0_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                if (!isIntType(module, op0_ty)) return;
                if (ops.len >= 2 and ops[1] != bir.NO_VALUE) {
                    const op1_ty = getTypeOfValue(module, func, ops[1]) orelse return;
                    if (!typesEqual(module, op0_ty, op1_ty)) {
                        try addError(errs, "{s} comparison operand type mismatch", .{@tagName(inst.op)}, .type_operand_mismatch, func_id, bid, idx, inst.result);
                    }
                }
            }
        },

        // ── Float comparison — operands float same, result i1 ──
        .feq, .fne, .flt, .fle, .fgt, .fge => {
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const op0_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                if (!isFloatType(module, op0_ty)) return;
                if (ops.len >= 2 and ops[1] != bir.NO_VALUE) {
                    const op1_ty = getTypeOfValue(module, func, ops[1]) orelse return;
                    if (!typesEqual(module, op0_ty, op1_ty)) {
                        try addError(errs, "{s} comparison operand type mismatch", .{@tagName(inst.op)}, .type_operand_mismatch, func_id, bid, idx, inst.result);
                    }
                }
            }
        },

        // ── Select — cond bool, true/false same type ──
        .select => {
            if (result_ty == INVALID_TYPE) return;
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const cond_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                if (!isBoolType(module, cond_ty)) {
                    try addError(errs, "select condition is not bool", .{}, .type_select_mismatch, func_id, bid, idx, inst.result);
                }
            }
            if (ops.len >= 2 and ops[1] != bir.NO_VALUE) {
                const op1_ty = getTypeOfValue(module, func, ops[1]) orelse return;
                if (!typesEqual(module, op1_ty, result_ty)) {
                    try addError(errs, "select operand type mismatch with result", .{}, .type_select_mismatch, func_id, bid, idx, inst.result);
                }
                if (ops.len >= 3 and ops[2] != bir.NO_VALUE) {
                    const op2_ty = getTypeOfValue(module, func, ops[2]) orelse return;
                    if (!typesEqual(module, op1_ty, op2_ty)) {
                        try addError(errs, "select operand type mismatch between operands", .{}, .type_select_mismatch, func_id, bid, idx, inst.result);
                    }
                }
            }
        },

        // ── Phi — all incoming values same type as result ──
        .phi => {
            if (result_ty == INVALID_TYPE) return;
            if (inst.data != .phi_incoming) return;
            for (inst.data.phi_incoming) |inc| {
                if (inc.value == bir.NO_VALUE) continue;
                const inc_ty = getTypeOfValue(module, func, inc.value) orelse continue;
                if (!typesEqual(module, inc_ty, result_ty)) {
                    try addError(errs, "phi incoming value type mismatch with result", .{}, .type_mismatch, func_id, bid, idx, inst.result);
                }
            }
        },

        // ── Cast — cast_info.from == operand, cast_info.to == result ──
        .cast, .bitcast, .sext, .zext, .trunc, .fptosi, .sitofp, .fpext, .fptrunc => {
            const ci = switch (inst.data) {
                .cast_info => |c| c,
                else => return,
            };
            if (result_ty != INVALID_TYPE and result_ty != ci.to) {
                try addError(errs, "{s} result type does not match cast_info.to", .{@tagName(inst.op)}, .type_cast_mismatch, func_id, bid, idx, inst.result);
            }
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const op_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                if (!typesEqual(module, op_ty, ci.from)) {
                    try addError(errs, "{s} operand type does not match cast_info.from", .{@tagName(inst.op)}, .type_cast_mismatch, func_id, bid, idx, inst.result);
                }
            }
        },

        // ── Load — ptr operand, pointee type == result type ──
        .load => {
            if (result_ty == INVALID_TYPE) return;
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const ptr_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                if (!isPtrKind(module, ptr_ty)) {
                    try addError(errs, "load operand is not a pointer", .{}, .type_mismatch, func_id, bid, idx, inst.result);
                } else if (!isValidLoadStoreSpace(module, ptr_ty)) {
                    try addError(errs, "load from invalid address space", .{}, .type_mismatch, func_id, bid, idx, inst.result);
                } else {
                    const elem_ty = getPointeeType(module, ptr_ty) orelse return;
                    if (elem_ty != result_ty) {}
                }
            }
        },

        // ── Store — ptr operand, value operand type matches pointee ──
        .store => {
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const ptr_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                if (!isPtrKind(module, ptr_ty)) {
                    try addError(errs, "store ptr operand is not a pointer", .{}, .type_mismatch, func_id, bid, idx, inst.result);
                } else if (!isValidLoadStoreSpace(module, ptr_ty)) {
                    try addError(errs, "store to invalid address space", .{}, .type_mismatch, func_id, bid, idx, inst.result);
                }
            }
        },

        // ── Alloca — result is pointer ──
        .alloca => {
            if (result_ty != INVALID_TYPE and !isPtrKind(module, result_ty)) {
                try addError(errs, "alloca result type must be a pointer", .{}, .type_mismatch, func_id, bid, idx, inst.result);
            }
        },

        // ── GEP — result is pointer, indices are integers ──
        .getelementptr => {
            if (result_ty == INVALID_TYPE) return;
            if (!isPtrKind(module, result_ty)) {
                try addError(errs, "getelementptr result type must be a pointer", .{}, .type_mismatch, func_id, bid, idx, inst.result);
            }
            for (ops) |op_val| {
                if (op_val == bir.NO_VALUE) continue;
                const op_ty = getTypeOfValue(module, func, op_val) orelse continue;
                _ = op_ty;
            }
        },

        // ── Ptr offset — ptr + int → same ptr type ──
        .ptr_offset => {
            if (result_ty == INVALID_TYPE) return;
            if (!isPtrKind(module, result_ty)) {
                try addError(errs, "ptr_offset result type must be a pointer", .{}, .type_mismatch, func_id, bid, idx, inst.result);
            }
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const ptr_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                if (!typesEqual(module, ptr_ty, result_ty)) {
                    try addError(errs, "ptr_offset ptr operand type does not match result", .{}, .type_mismatch, func_id, bid, idx, inst.result);
                }
            }
        },

        // ── Ptr <-> int conversions ──
        .ptr_to_int => {
            if (result_ty == INVALID_TYPE) return;
            if (!isIntType(module, result_ty)) {
                try addError(errs, "ptr_to_int result type must be integer", .{}, .type_mismatch, func_id, bid, idx, inst.result);
            }
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const op_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                if (!isPtrKind(module, op_ty)) {
                    try addError(errs, "ptr_to_int operand must be a pointer", .{}, .type_mismatch, func_id, bid, idx, inst.result);
                }
            }
        },

        .int_to_ptr => {
            if (result_ty == INVALID_TYPE) return;
            if (!isPtrKind(module, result_ty)) {
                try addError(errs, "int_to_ptr result type must be a pointer", .{}, .type_mismatch, func_id, bid, idx, inst.result);
            }
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const op_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                if (!isIntType(module, op_ty)) {
                    try addError(errs, "int_to_ptr operand must be integer", .{}, .type_mismatch, func_id, bid, idx, inst.result);
                }
            }
        },

        // ── Vector ops — all operands same vector type, result same ──
        .vector_add, .vector_sub, .vector_mul, .vector_div,
        .vector_reflect, .vector_refract => {
            if (result_ty == INVALID_TYPE) return;
            if (!isVectorType(module, result_ty)) return;
            for (ops) |op_val| {
                if (op_val == bir.NO_VALUE) continue;
                const op_ty = getTypeOfValue(module, func, op_val) orelse continue;
                if (!typesEqual(module, op_ty, result_ty)) {
                    try addError(errs, "{s} operand type mismatch", .{@tagName(inst.op)}, .type_operand_mismatch, func_id, bid, idx, inst.result);
                }
            }
        },

        // ── Vector dot product — result is scalar (not vector) ──
        .vector_dot => {
            if (result_ty == INVALID_TYPE) return;
            if (!isScalarType(module, result_ty)) return;
        },

        .vector_cross => {
            if (result_ty == INVALID_TYPE) return;
            if (!isVectorType(module, result_ty)) return;
        },

        .vector_normalize => {
            if (result_ty == INVALID_TYPE) return;
            if (!isVectorType(module, result_ty)) return;
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const op_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                if (!typesEqual(module, op_ty, result_ty)) return;
            }
        },

        .vector_length => {
            if (result_ty == INVALID_TYPE) return;
            if (!isScalarType(module, result_ty)) return;
        },

        // ── Splat — scalar → vector ──
        .splat => {
            if (result_ty == INVALID_TYPE) return;
            if (!isVectorType(module, result_ty)) return;
        },

        // ── Extract element — vector → scalar ──
        .extract_element => {
            if (result_ty == INVALID_TYPE) return;
            if (isVectorType(module, result_ty)) return;
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const src_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                if (!isVectorType(module, src_ty)) return;
                if (!scalarKindMatches(module, src_ty, result_ty)) {
                    try addError(errs, "extract_element vector scalar kind does not match result", .{}, .type_mismatch, func_id, bid, idx, inst.result);
                }
            }
        },

        // ── Insert element — vector, scalar → vector ──
        .insert_element => {
            if (result_ty == INVALID_TYPE) return;
            if (!isVectorType(module, result_ty)) return;
        },

        // ── Composite ──
        .composite => {
            if (result_ty == INVALID_TYPE) return;
        },

        // ── Extract ──
        .extract => {
            if (result_ty == INVALID_TYPE) return;
            if (ops.len >= 1 and ops[0] != bir.NO_VALUE) {
                const src_ty = getTypeOfValue(module, func, ops[0]) orelse return;
                _ = src_ty;
            }
        },

        // ── Insert ──
        .insert => {
            if (result_ty == INVALID_TYPE) return;
            if (ops.len >= 2 and ops[1] != bir.NO_VALUE) {
                const val_ty = getTypeOfValue(module, func, ops[1]) orelse return;
                _ = val_ty;
            }
        },

        // ── Shuffle ──
        .shuffle => {
            if (result_ty == INVALID_TYPE) return;
        },

        // ── Const ──
        .@"const" => {},

        // ── Call ──
        .call => {},

        // ── Resource ──
        .resource => {},

        // ── Matrix ops ──
        .matrix_mul, .matrix_transpose, .matrix_inverse, .matrix_determinant => {},

        // ── Atomic ──
        .atomic_add, .atomic_sub, .atomic_min, .atomic_max,
        .atomic_and, .atomic_or, .atomic_xor, .atomic_xchg, .atomic_cmpxchg => {},

        // ── Texture ──
        .texture_sample, .texture_load, .texture_gather,
        .texture_query_dimensions, .texture_query_lod => {
            if (result_ty == INVALID_TYPE) return;
        },

        // ── GPU intrinsics ──
        .thread_id, .block_id, .thread_count, .block_count,
        .wave_get_lane_index, .wave_is_first_lane, .wave_read_lane_first,
        .wave_active_all_equal,
        .quad_read_across_x, .quad_read_across_y,
        .groupshared_alloc => {
            if (result_ty == INVALID_TYPE) return;
        },
    }
}

fn getPointeeType(module: *bir.Module, tid: TypeId) ?TypeId {
    if (tid == INVALID_TYPE) return null;
    const ty = module.types.get(tid);
    return switch (ty.kind) {
        .pointer => |p| p.elem,
        else => null,
    };
}

fn isVectorType(module: *bir.Module, tid: TypeId) bool {
    if (tid == INVALID_TYPE) return false;
    const ty = module.types.get(tid);
    return ty.kind == .vector;
}

fn isScalarType(module: *bir.Module, tid: TypeId) bool {
    if (tid == INVALID_TYPE) return false;
    const ty = module.types.get(tid);
    return ty.kind == .scalar;
}

fn scalarKindMatches(module: *bir.Module, a: TypeId, b: TypeId) bool {
    if (a == INVALID_TYPE or b == INVALID_TYPE) return false;
    const ta = module.types.get(a);
    const tb = module.types.get(b);
    const sk_a: ?bir_types.ScalarKind = switch (ta.kind) {
        .scalar => |sk| sk,
        .vector => |v| v.scalar,
        else => return false,
    };
    const sk_b: ?bir_types.ScalarKind = switch (tb.kind) {
        .scalar => |sk| sk,
        .vector => |v| v.scalar,
        else => return false,
    };
    return sk_a == sk_b;
}

fn getTypeOfValue(_: *bir.Module, func: *bir.Function, val: ValueId) ?TypeId {
    if (val == bir.NO_VALUE) return null;
    const vi = func.getValueInfo(val);
    if (vi.def.block == bir.INVALID_ID) return null;
    if (vi.def.block >= func.blocks.items.len) return null;
    const block = &func.blocks.items[vi.def.block];
    if (vi.def.idx >= block.instrs.items.len) return null;
    const def_inst = &block.instrs.items[vi.def.idx];
    if (def_inst.ty == INVALID_TYPE) return null;
    return def_inst.ty;
}

fn typesEqual(_: *bir.Module, a: TypeId, b: TypeId) bool {
    return a == b;
}

fn isIntType(module: *bir.Module, tid: TypeId) bool {
    if (tid == INVALID_TYPE) return false;
    const ty = module.types.get(tid);
    return switch (ty.kind) {
        .scalar => |sk| switch (sk) {
            .i1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => true,
            .f16, .bf16, .f32, .f64 => false,
        },
        .vector => |v| switch (v.scalar) {
            .i1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => true,
            .f16, .bf16, .f32, .f64 => false,
        },
        else => false,
    };
}

fn isFloatType(module: *bir.Module, tid: TypeId) bool {
    if (tid == INVALID_TYPE) return false;
    const ty = module.types.get(tid);
    return switch (ty.kind) {
        .scalar => |sk| switch (sk) {
            .f16, .bf16, .f32, .f64 => true,
            else => false,
        },
        .vector => |v| switch (v.scalar) {
            .f16, .bf16, .f32, .f64 => true,
            else => false,
        },
        else => false,
    };
}

fn isBoolType(module: *bir.Module, tid: TypeId) bool {
    if (tid == INVALID_TYPE) return false;
    const ty = module.types.get(tid);
    return switch (ty.kind) {
        .scalar => |sk| sk == .i1,
        else => false,
    };
}

fn isPtrKind(module: *bir.Module, tid: TypeId) bool {
    if (tid == INVALID_TYPE) return false;
    const ty = module.types.get(tid);
    return ty.kind == .pointer;
}

fn getPointerAddressSpace(module: *bir.Module, tid: TypeId) ?bir_types.AddressSpace {
    if (tid == INVALID_TYPE) return null;
    const ty = module.types.get(tid);
    return switch (ty.kind) {
        .pointer => |p| p.space,
        else => null,
    };
}

fn isValidLoadStoreSpace(module: *bir.Module, tid: TypeId) bool {
    const space = getPointerAddressSpace(module, tid) orelse return false;
    return switch (space) {
        .generic, .global, .shared, .local, .@"const", .uniform, .device => true,
    };
}

// ─── Phi Placement (DF-based) ───

fn checkPhiPlacement(func: *bir.Function, inst: *const bir.Inst, bid: BlockId, dom_frontier: *const bir_dominators.DominanceFrontier, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    const incoming = inst.data.phi_incoming;
    if (incoming.len <= 1) return;

    var def_blocks = std.AutoHashMap(BlockId, void).init(errs.allocator);
    defer def_blocks.deinit();

    for (incoming) |inc| {
        const val = inc.value;
        if (val == bir.NO_VALUE) continue;
        const vi = func.getValueInfo(val);
        if (vi.def.block == bir.INVALID_ID) continue;
        if (vi.def.block >= func.blocks.items.len) continue;
        if (vi.def.block == bid) continue;
        try def_blocks.put(vi.def.block, {});
    }

    if (def_blocks.count() <= 1) return;

    var any_in_frontier = false;
    var it = def_blocks.keyIterator();
    while (it.next()) |def_b| {
        if (dom_frontier.contains(def_b.*, bid)) {
            any_in_frontier = true;
            break;
        }
    }

    if (!any_in_frontier) {
        try addError(errs, "phi at block {} has incoming values from {} different defining blocks, but {} is not in the dominance frontier of any of them", .{ bid, def_blocks.count(), bid }, .phi_placement_invalid, func_id, bid, null, inst.result);
    }
}

// ─── Data Ref Checks ───

fn checkDataRefsDefined(func: *bir.Function, inst: *const bir.Inst, use_bid: BlockId, dom_tree: *const bir_dominators.DominatorTree, cfg: *const bir_cfg.CFG, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    switch (inst.data) {
        .phi_incoming => {},
        .cond_branch => |cb| {
            if (cb.cond != bir.NO_VALUE) try checkValueDefined(func, cb.cond, use_bid, dom_tree, cfg, func_id, errs);
        },
        .call_info => |ci| {
            if (ci.callee != bir.NO_VALUE) try checkValueDefined(func, ci.callee, use_bid, dom_tree, cfg, func_id, errs);
            for (ci.args) |arg| {
                if (arg != bir.NO_VALUE) try checkValueDefined(func, arg, use_bid, dom_tree, cfg, func_id, errs);
            }
        },
        .gep_info => |gi| {
            if (gi.ptr != bir.NO_VALUE) try checkValueDefined(func, gi.ptr, use_bid, dom_tree, cfg, func_id, errs);
            for (gi.indices) |idx| {
                if (idx != bir.NO_VALUE) try checkValueDefined(func, idx, use_bid, dom_tree, cfg, func_id, errs);
            }
        },
        .atomic_info => |ai| {
            if (ai.ptr != bir.NO_VALUE) try checkValueDefined(func, ai.ptr, use_bid, dom_tree, cfg, func_id, errs);
            if (ai.val != bir.NO_VALUE) try checkValueDefined(func, ai.val, use_bid, dom_tree, cfg, func_id, errs);
        },
        .sample_info => |si| {
            if (si.tex != bir.NO_VALUE) try checkValueDefined(func, si.tex, use_bid, dom_tree, cfg, func_id, errs);
            if (si.sampler != bir.NO_VALUE) try checkValueDefined(func, si.sampler, use_bid, dom_tree, cfg, func_id, errs);
            if (si.coord != bir.NO_VALUE) try checkValueDefined(func, si.coord, use_bid, dom_tree, cfg, func_id, errs);
            if (si.lod) |v| if (v != bir.NO_VALUE) try checkValueDefined(func, v, use_bid, dom_tree, cfg, func_id, errs);
            if (si.offset) |v| if (v != bir.NO_VALUE) try checkValueDefined(func, v, use_bid, dom_tree, cfg, func_id, errs);
        },
        .texture_store_info => |tsi| {
            if (tsi.tex != bir.NO_VALUE) try checkValueDefined(func, tsi.tex, use_bid, dom_tree, cfg, func_id, errs);
            if (tsi.coord_x != bir.NO_VALUE) try checkValueDefined(func, tsi.coord_x, use_bid, dom_tree, cfg, func_id, errs);
            if (tsi.coord_y != bir.NO_VALUE) try checkValueDefined(func, tsi.coord_y, use_bid, dom_tree, cfg, func_id, errs);
            if (tsi.val != bir.NO_VALUE) try checkValueDefined(func, tsi.val, use_bid, dom_tree, cfg, func_id, errs);
        },
        .named_call => |nc| {
            for (nc.args) |arg| {
                if (arg != bir.NO_VALUE) try checkValueDefined(func, arg, use_bid, dom_tree, cfg, func_id, errs);
            }
        },
        .branch_on_bit => |bb| {
            if (bb.bit != bir.NO_VALUE) try checkValueDefined(func, bb.bit, use_bid, dom_tree, cfg, func_id, errs);
        },
        .none, .string, .block_target, .const_data, .vector_shuffle,
        .cast_info, .barrier_kind, .extract_info, .group_info, .fence_info, .groupshared_size => {},
    }
}

fn checkValueDefined(func: *bir.Function, val: ValueId, use_block: BlockId, dom_tree: *const bir_dominators.DominatorTree, cfg: *const bir_cfg.CFG, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    if (val == bir.NO_VALUE) return;
    if (val > func.value_info.items.len) {
        try addError(errs, "value {} referenced but value_info has {} entries", .{ val, func.value_info.items.len }, .invalid_value_id, func_id, use_block, null, val);
        return;
    }
    const vi = func.getValueInfo(val);
    if (vi.def.block == bir.INVALID_ID) {
        try addError(errs, "value {} has no definition", .{val}, .undefined_value, func_id, use_block, null, val);
        return;
    }
    if (vi.def.block >= func.blocks.items.len) {
        try addError(errs, "value {} defined in block {} which is out of range", .{ val, vi.def.block }, .invalid_block_id, func_id, use_block, null, val);
        return;
    }
    const def_block = vi.def.block;

    if (def_block == use_block) {
        if (vi.def.idx >= func.blocks.items[use_block].instrs.items.len) {
            try addError(errs, "value {} def idx {} exceeds instrs in block {}", .{ val, vi.def.idx, use_block }, .undefined_value, func_id, use_block, null, val);
        }
        return;
    }

    const def_rpo = rpoIndex(cfg, def_block);
    const use_rpo = rpoIndex(cfg, use_block);
    if (def_rpo == null or use_rpo == null) {
        try addError(errs, "value {} defined in unreachable block {}", .{ val, def_block }, .dominance_violation, func_id, use_block, null, val);
        return;
    }

    if (!dom_tree.dominates(def_block, use_block)) {
        try addError(errs, "value {} defined in block {} does not dominate use in block {}", .{ val, def_block, use_block }, .dominance_violation, func_id, use_block, null, val);
    }
}

fn checkPhiValueDefined(func: *bir.Function, val: ValueId, pred_block: BlockId, dom_tree: *const bir_dominators.DominatorTree, cfg: *const bir_cfg.CFG, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    if (val > func.value_info.items.len) {
        try addError(errs, "phi value {} exceeds value_info len {}", .{ val, func.value_info.items.len }, .invalid_value_id, func_id, pred_block, null, val);
        return;
    }
    const vi = func.getValueInfo(val);
    if (vi.def.block == bir.INVALID_ID) return;
    if (vi.def.block >= func.blocks.items.len) return;
    const def_block = vi.def.block;

    if (def_block == pred_block) return;

    const def_rpo = rpoIndex(cfg, def_block);
    const pred_rpo = rpoIndex(cfg, pred_block);
    if (def_rpo == null or pred_rpo == null) return;

    if (!dom_tree.dominates(def_block, pred_block)) {
        try addError(errs, "phi value {} defined in {} does not dominate predecessor {}", .{ val, def_block, pred_block }, .dominance_violation, func_id, pred_block, null, val);
    }
}

// ─── Use-Def Symmetry ───

fn checkUseDefSymmetry(func: *bir.Function, func_id: FunctionId, errs: *std.ArrayList(VerifyError)) !void {
    const vi_len = func.value_info.items.len;
    for (func.blocks.items, 0..) |*block, bi| {
        const bid = @as(BlockId, @intCast(bi));
        for (block.instrs.items, 0..) |*inst, ii| {
            const inst_result = inst.result;
            if (inst_result == bir.NO_VALUE) continue;
            if (inst_result > vi_len) continue;

            for (inst.operands) |op_val| {
                if (op_val == bir.NO_VALUE or op_val > vi_len) continue;
                const vi = func.getValueInfo(op_val);
                const has_use = for (vi.uses.items) |u| {
                    if (u == inst_result) break true;
                } else false;
                if (!has_use) {
                    try addError(errs, "inst {} uses value {} but {}'s uses don't include {}", .{ inst_result, op_val, op_val, inst_result }, .use_def_symmetry_broken, func_id, bid, @as(u32, @intCast(ii)), inst_result);
                }
            }

            var ref_list = std.ArrayList(ValueId).init(errs.allocator);
            defer ref_list.deinit();
            bir.collectDataRefs(&inst.data, &ref_list) catch {};
            for (ref_list.items) |ref| {
                if (ref == bir.NO_VALUE or ref > vi_len) continue;
                const vi = func.getValueInfo(ref);
                const has_use = for (vi.uses.items) |u| {
                    if (u == inst_result) break true;
                } else false;
                if (!has_use) {
                    try addError(errs, "inst {} (data ref) uses value {} but {}'s uses don't include {}", .{ inst_result, ref, ref, inst_result }, .data_ref_use_symmetry_broken, func_id, bid, @as(u32, @intCast(ii)), inst_result);
                }
            }
        }
    }
}

// ─── MemorySSA Verification ───

pub fn verifyMemorySSA(allocator: Allocator, func: *bir.Function, func_id: FunctionId, cfg: *const bir_cfg.CFG, dom_tree: *const bir_dominators.DominatorTree, errs: *std.ArrayList(VerifyError)) !void {
    var mssa = try bir_memory_ssa.build(allocator, func, cfg, dom_tree);
    defer {
        mssa.reaching_def.deinit();
        mssa.stored_val.deinit();
    }

    for (func.blocks.items, 0..) |*block, bi| {
        const bid = @as(BlockId, @intCast(bi));
        for (block.instrs.items, 0..) |*inst, ii| {
            const idx = @as(u32, @intCast(ii));

            switch (inst.op) {
                .load => {
                    const key = bir_memory_ssa.MemOpKey{ .block = bid, .idx = idx };
                    const reaching = mssa.getReachingStore(key) orelse {
                        try addError(errs, "load at ({},{}) has no reaching memory definition", .{ bid, idx }, .mssa_no_reaching_def, func_id, bid, idx, inst.result);
                        continue;
                    };
                    if (reaching.block >= func.blocks.items.len or reaching.idx >= func.blocks.items[reaching.block].instrs.items.len) {
                        try addError(errs, "load at ({},{}) has invalid reaching def ({},{})", .{ bid, idx, reaching.block, reaching.idx }, .mssa_invalid_reaching_def, func_id, bid, idx, inst.result);
                        continue;
                    }
                    const reaching_inst = &func.blocks.items[reaching.block].instrs.items[reaching.idx];
                    if (reaching_inst.op != .store) {
                        try addError(errs, "load at ({},{}) reaching def ({},{}) is not a store (op={s})", .{ bid, idx, reaching.block, reaching.idx, @tagName(reaching_inst.op) }, .mssa_invalid_reaching_def, func_id, bid, idx, inst.result);
                        continue;
                    }
                    if (!dom_tree.dominates(reaching.block, bid)) {
                        try addError(errs, "load at ({},{}) reaching def ({},{}) does not dominate the load", .{ bid, idx, reaching.block, reaching.idx }, .mssa_invalid_reaching_def, func_id, bid, idx, inst.result);
                    }

                    // Check that reaching def forms a valid SSA chain: def dominates all uses
                    const stored_val = mssa.getStoredValue(reaching) orelse bir.NO_VALUE;
                    if (stored_val != bir.NO_VALUE and stored_val <= func.value_info.items.len) {
                        const sv_vi = func.getValueInfo(stored_val);
                        if (sv_vi.def.block != bir.INVALID_ID and sv_vi.def.block < func.blocks.items.len) {
                            if (!dom_tree.dominates(sv_vi.def.block, reaching.block)) {
                                try addError(errs, "store at ({},{}) stored value def does not dominate the store", .{ reaching.block, reaching.idx }, .mssa_stored_val_mismatch, func_id, reaching.block, reaching.idx, stored_val);
                            }
                        }
                    }
                },
                .store => {
                    const key = bir_memory_ssa.MemOpKey{ .block = bid, .idx = idx };
                    if (mssa.stored_val.contains(key)) {
                        const sv = mssa.getStoredValue(key) orelse bir.NO_VALUE;
                        if (sv != bir.NO_VALUE) {
                            if (sv > func.value_info.items.len) {
                                try addError(errs, "store at ({},{}) has invalid stored value {}", .{ bid, idx, sv }, .mssa_stored_val_mismatch, func_id, bid, idx, sv);
                                continue;
                            }
                            const sv_vi = func.getValueInfo(sv);
                            if (sv_vi.def.block != bir.INVALID_ID and sv_vi.def.block < func.blocks.items.len) {
                                if (!dom_tree.dominates(sv_vi.def.block, bid)) {
                                    try addError(errs, "store at ({},{}) stored value def does not dominate the store", .{ bid, idx }, .mssa_stored_val_mismatch, func_id, bid, idx, sv);
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Check no cycles in reaching def chains
    var visited = std.AutoHashMap(bir_memory_ssa.MemOpKey, void).init(allocator);
    defer visited.deinit();

    var it = mssa.reaching_def.keyIterator();
    while (it.next()) |key| {
        var cur = key.*;
        var chain = std.AutoHashMap(bir_memory_ssa.MemOpKey, void).init(allocator);
        defer chain.deinit();

        while (mssa.reaching_def.get(cur)) |next| {
            if (chain.contains(cur)) {
                try addError(errs, "cycle in MemorySSA reaching def chain starting at ({},{})", .{ key.block, key.idx }, .mssa_invalid_reaching_def, func_id, key.block, key.idx, null);
                break;
            }
            try chain.put(cur, {});
            cur = next;
            if (mssa.stored_val.contains(cur) and !mssa.reaching_def.contains(cur)) break;
        }
    }
}

fn rpoIndex(cfg: *const bir_cfg.CFG, bid: BlockId) ?usize {
    for (cfg.rpo.items, 0..) |b, i| if (b == bid) return i;
    return null;
}

fn isTerminator(op: Op) bool {
    return switch (op) {
        .br, .cond_br, .ret, .unreachable_op, .branch_on_bit => true,
        else => false,
    };
}
