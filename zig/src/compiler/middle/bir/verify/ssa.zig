const std = @import("std");
const bir = @import("../bir.zig");
const bir_cfg = @import("../analysis/cfg/cfg.zig");
const bir_dominators = @import("../analysis/dominator/dominator.zig");
const FunctionId = bir.FunctionId;
const BlockId = bir.BlockId;
const ValueId = bir.ValueId;
const INVALID_ID = bir.INVALID_ID;
const NO_VALUE = bir.NO_VALUE;
const diagnostics = @import("diagnostics.zig");
const DiagnosticList = diagnostics.DiagnosticList;

pub fn verifySSA(
    _: *const bir.Module,
    func: *const bir.Function,
    func_id: FunctionId,
    _: *const bir_cfg.CFG,
    dom_tree: *const bir_dominators.DominatorTree,
    errs: *DiagnosticList,
) !void {
    const nblocks = func.blocks.items.len;
    if (nblocks == 0) return;

    for (func.blocks.items, 0..) |block, bid| {
        const block_id = @as(BlockId, @intCast(bid));

        for (block.instrs.items, 0..) |inst, idx| {
            if (inst.result == NO_VALUE) continue;

            const val = inst.result;
            if (val == 0 or val > func.value_info.items.len) {
                try errs.push(.{
                    .code = .value_defined_twice,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block.label,
                    .value_id = val,
                    .message = "instruction result value ID out of range",
                });
                continue;
            }

            const vi = &func.value_info.items[val - 1];
            if (vi.def.block != block_id or vi.def.idx != @as(u32, @intCast(idx))) {
                try errs.push(.{
                    .code = .value_defined_twice,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block.label,
                    .value_id = val,
                    .message = "value definition does not match ValueInfo",
                });
            }
        }
    }

    for (func.blocks.items, 0..) |block, bid| {
        const block_id = @as(BlockId, @intCast(bid));

        for (block.instrs.items) |inst| {
            var operands = std.ArrayList(ValueId).init(errs.allocator);
            defer operands.deinit();

            for (inst.operands) |op_val| {
                try operands.append(op_val);
            }

            try collectDataRefs(inst, &operands);

            for (operands.items) |op_val| {
                if (op_val == NO_VALUE) continue;

                if (op_val == 0 or op_val > func.value_info.items.len) {
                    try errs.push(.{
                        .code = .value_used_before_def,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .value_id = op_val,
                        .message = "used value ID out of range",
                    });
                    continue;
                }

                const vi = &func.value_info.items[op_val - 1];
                if (vi.def.block == INVALID_ID) {
                    // Allow function parameters (they have no defining instruction)
                    var is_param = false;
                    for (func.param_values) |pv| {
                        if (pv == op_val) { is_param = true; break; }
                    }
                    if (!is_param) {
                        try errs.push(.{
                            .code = .value_used_before_def,
                            .func_id = func_id,
                            .func_name = func.name,
                            .block_id = block_id,
                            .block_name = block.label,
                            .value_id = op_val,
                            .message = "value has no definition",
                        });
                    }
                    continue;
                }

                if (vi.def.block >= nblocks) {
                    try errs.push(.{
                        .code = .value_used_before_def,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .value_id = op_val,
                        .message = "value defined in invalid block",
                    });
                    continue;
                }

                const def_block = vi.def.block;
                if (def_block == block_id) {
                    if (vi.def.idx >= block.instrs.items.len) {
                        try errs.push(.{
                            .code = .value_used_before_def,
                            .func_id = func_id,
                            .func_name = func.name,
                            .block_id = block_id,
                            .block_name = block.label,
                            .value_id = op_val,
                            .message = "value definition index out of range within same block",
                        });
                    }
                } else {
                    if (!dom_tree.dominates(def_block, block_id)) {
                        try errs.push(.{
                            .code = .value_does_not_dominate_use,
                            .func_id = func_id,
                            .func_name = func.name,
                            .block_id = block_id,
                            .block_name = block.label,
                            .value_id = op_val,
                            .message = "value definition does not dominate use",
                        });
                    }
                }
            }
        }
    }
}

pub fn verifyPhis(
    module: *const bir.Module,
    func: *const bir.Function,
    func_id: FunctionId,
    _: *const bir_cfg.CFG,
    dom_tree: *const bir_dominators.DominatorTree,
    errs: *DiagnosticList,
) !void {
    const nblocks = func.blocks.items.len;
    if (nblocks == 0) return;

    for (func.blocks.items, 0..) |block, bid| {
        const block_id = @as(BlockId, @intCast(bid));

        if (block.phi_count > 0) {
            for (block.instrs.items[0..block.phi_count]) |inst| {
                if (inst.op != .phi) {
                    try errs.push(.{
                        .code = .phi_not_at_block_start,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .op = inst.op,
                        .message = "non-phi instruction found in phi region",
                    });
                }
            }
        }

        var phi_idx: u32 = 0;
        for (block.instrs.items) |inst| {
            if (inst.op != .phi) break;

            phi_idx += 1;

            const incoming = inst.data.phi_incoming;

            if (incoming.len != block.preds.items.len) {
                try errs.push(.{
                    .code = .phi_incoming_count_mismatch,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block.label,
                    .value_id = inst.result,
                    .message = "phi incoming count does not match predecessor count",
                });
            }

            var seen_blocks = std.AutoHashMap(BlockId, void).init(errs.allocator);
            defer seen_blocks.deinit();

            for (incoming) |inc| {
                if (inc.block >= nblocks) {
                    try errs.push(.{
                        .code = .phi_incoming_block_not_predecessor,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .value_id = inst.result,
                        .message = "phi incoming block ID out of range",
                    });
                    continue;
                }

                var is_pred = false;
                for (block.preds.items) |pred| {
                    if (pred == inc.block) {
                        is_pred = true;
                        break;
                    }
                }
                if (!is_pred) {
                    try errs.push(.{
                        .code = .phi_incoming_block_not_predecessor,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .value_id = inst.result,
                        .message = "phi incoming block is not a predecessor of this block",
                    });
                }

                if (seen_blocks.contains(inc.block)) {
                    try errs.push(.{
                        .code = .phi_duplicate_incoming_block,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .value_id = inst.result,
                        .message = "phi has duplicate incoming block",
                    });
                } else {
                    try seen_blocks.put(inc.block, {});
                }

                if (inc.value == NO_VALUE) continue;

                if (inc.value == 0 or inc.value > func.value_info.items.len) {
                    try errs.push(.{
                        .code = .phi_incoming_value_type_mismatch,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .value_id = inst.result,
                        .message = "phi incoming value ID out of range",
                    });
                    continue;
                }

                const inc_vi = &func.value_info.items[inc.value - 1];
                if (inc_vi.def.block == INVALID_ID) {
                    // Allow function parameters
                    var is_param = false;
                    for (func.param_values) |pv| {
                        if (pv == inc.value) { is_param = true; break; }
                    }
                    if (!is_param) {
                        try errs.push(.{
                            .code = .phi_incoming_value_type_mismatch,
                            .func_id = func_id,
                            .func_name = func.name,
                            .block_id = block_id,
                            .block_name = block.label,
                            .value_id = inst.result,
                            .message = "phi incoming value has no definition",
                        });
                    }
                    continue;
                }

                if (inc_vi.def.block != inc.block) {
                    const inc_def_block = inc_vi.def.block;
                    if (!dom_tree.dominates(inc_def_block, inc.block)) {
                        try errs.push(.{
                            .code = .phi_value_does_not_dominate_pred,
                            .func_id = func_id,
                            .func_name = func.name,
                            .block_id = block_id,
                            .block_name = block.label,
                            .value_id = inst.result,
                            .message = "phi incoming value definition does not dominate the predecessor block",
                        });
                    }
                }

                if (inst.ty != 0) {
                    const inc_type = getTypeOfValue(module, func, inc.value);
                    if (inc_type) |it| {
                        if (!typesEqual(module, inst.ty, it)) {
                            try errs.push(.{
                                .code = .phi_incoming_value_type_mismatch,
                                .func_id = func_id,
                                .func_name = func.name,
                                .block_id = block_id,
                                .block_name = block.label,
                                .value_id = inst.result,
                                .type_id = inst.ty,
                                .other_type_id = it,
                                .message = "phi incoming value type does not match phi result type",
                            });
                        }
                    }
                }
            }
        }
    }
}

fn collectDataRefs(inst: bir.Inst, result: *std.ArrayList(ValueId)) !void {
    switch (inst.data) {
        .cond_branch => |cb| try result.append(cb.cond),
        .gep_info => |gep| {
            try result.append(gep.ptr);
            for (gep.indices) |idx| try result.append(idx);
        },
        .call_info => |ci| {
            try result.append(ci.callee);
            for (ci.args) |arg| try result.append(arg);
        },
        .named_call => |nc| {
            for (nc.args) |arg| try result.append(arg);
        },
        .atomic_info => |ai| {
            try result.append(ai.ptr);
            try result.append(ai.val);
        },
        .sample_info => |si| {
            try result.append(si.tex);
            try result.append(si.sampler);
            try result.append(si.coord);
            if (si.lod) |lod| try result.append(lod);
            if (si.offset) |off| try result.append(off);
        },
        .texture_store_info => |tsi| {
            try result.append(tsi.tex);
            try result.append(tsi.coord_x);
            try result.append(tsi.coord_y);
            try result.append(tsi.val);
        },
        .branch_on_bit => |bob| try result.append(bob.bit),
        else => {},
    }
}

fn getTypeOfValue(_: *const bir.Module, func: *const bir.Function, val: ValueId) ?bir.TypeId {
    if (val == NO_VALUE) return null;
    if (val == 0 or val > func.value_info.items.len) return null;
    const vi = &func.value_info.items[val - 1];
    if (vi.def.block == INVALID_ID) return null;
    if (vi.def.block >= func.blocks.items.len) return null;
    const blk = &func.blocks.items[vi.def.block];
    if (vi.def.idx >= blk.instrs.items.len) return null;
    return blk.instrs.items[vi.def.idx].ty;
}

fn typesEqual(module: *const bir.Module, a: bir.TypeId, b: bir.TypeId) bool {
    _ = module;
    return a == b;
}
