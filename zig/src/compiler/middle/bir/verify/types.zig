const std = @import("std");
const bir = @import("../bir.zig");
const FunctionId = bir.FunctionId;
const BlockId = bir.BlockId;
const ValueId = bir.ValueId;
const TypeId = bir.TypeId;
const Op = bir.Op;
const ScalarKind = bir.ScalarKind;
const diagnostics = @import("diagnostics.zig");
const DiagnosticList = diagnostics.DiagnosticList;
const addressing = @import("addressing.zig");

pub fn verifyTypes(
    module: *bir.Module,
    func: *const bir.Function,
    func_id: FunctionId,
    errs: *DiagnosticList,
) !void {
    const nblocks = func.blocks.items.len;
    if (nblocks == 0) return;

    for (func.blocks.items, 0..) |block, bid| {
        const block_id = @as(BlockId, @intCast(bid));

        for (block.instrs.items, 0..) |inst, idx| {
            verifyInstTypes(module, func, inst, func_id, block_id, block.label, @intCast(idx), errs) catch {};
        }
    }
}

fn verifyInstTypes(
    module: *bir.Module,
    func: *const bir.Function,
    inst: bir.Inst,
    func_id: FunctionId,
    block_id: BlockId,
    block_name: []const u8,
    idx: u32,
    errs: *DiagnosticList,
) !void {
    switch (inst.op) {
        .add, .sub, .mul, .div, .mod => {
            if (inst.operands.len < 2) return;
            const ty_a = addressing.getTypeOfValue(module, func, inst.operands[0]);
            const ty_b = addressing.getTypeOfValue(module, func, inst.operands[1]);
            const a_ptr = ty_a != null and addressing.isPtrType(module, ty_a.?);
            const b_ptr = ty_b != null and addressing.isPtrType(module, ty_b.?);

            if (a_ptr or b_ptr) {
                                                                               
                                                                                 
                                           
                if (inst.op != .add and inst.op != .sub) {
                    try errs.push(.{
                        .code = .type_not_numeric,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block_name,
                        .inst_idx = idx,
                        .value_id = inst.result,
                        .op = inst.op,
                        .message = "pointer arithmetic only allows + and -",
                    });
                } else if (a_ptr and b_ptr) {
                    try errs.push(.{
                        .code = .type_mismatch,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block_name,
                        .inst_idx = idx,
                        .value_id = inst.result,
                        .type_id = ty_a.?,
                        .other_type_id = ty_b.?,
                        .op = inst.op,
                        .message = "pointer + pointer / pointer - pointer is not allowed",
                    });
                } else {
                    const other_ty = if (b_ptr) ty_a else ty_b;
                    if (other_ty) |ot| {
                        if (!addressing.isIntType(module, ot)) {
                            try errs.push(.{
                                .code = .type_not_numeric,
                                .func_id = func_id,
                                .func_name = func.name,
                                .block_id = block_id,
                                .block_name = block_name,
                                .inst_idx = idx,
                                .value_id = inst.result,
                                .type_id = ot,
                                .op = inst.op,
                                .message = "pointer +/- requires an integer offset",
                            });
                        }
                    }
                }
            } else {
                if (ty_a) |ta| {
                    if (!addressing.isIntType(module, ta) and !addressing.isFloatType(module, ta)) {
                        try errs.push(.{
                            .code = .type_not_numeric,
                            .func_id = func_id,
                            .func_name = func.name,
                            .block_id = block_id,
                            .block_name = block_name,
                            .inst_idx = idx,
                            .value_id = inst.result,
                            .type_id = ta,
                            .op = inst.op,
                            .message = "arithmetic operand is not numeric",
                        });
                    }
                }
                if (ty_a) |ta| {
                    if (ty_b) |tb| {
                        if (!typesEqual(module, ta, tb)) {
                            try errs.push(.{
                                .code = .type_mismatch,
                                .func_id = func_id,
                                .func_name = func.name,
                                .block_id = block_id,
                                .block_name = block_name,
                                .inst_idx = idx,
                                .value_id = inst.result,
                                .type_id = ta,
                                .other_type_id = tb,
                                .op = inst.op,
                                .message = "arithmetic operands have different types",
                            });
                        }
                    }
                }
            }
        },
        .eq, .ne, .lt, .le, .gt, .ge, .feq, .fne, .flt, .fle, .fgt, .fge => {
            if (inst.operands.len < 2) return;
            const ty_a = getTypeOfValue(module, func, inst.operands[0]);
            const ty_b = getTypeOfValue(module, func, inst.operands[1]);
            if (ty_a) |ta| {
                if (ty_b) |tb| {
                    if (!typesEqual(module, ta, tb)) {
                        try errs.push(.{
                            .code = .type_mismatch,
                            .func_id = func_id,
                            .func_name = func.name,
                            .block_id = block_id,
                            .block_name = block_name,
                            .inst_idx = idx,
                            .value_id = inst.result,
                            .type_id = ta,
                            .other_type_id = tb,
                            .op = inst.op,
                            .message = "comparison operands have different types",
                        });
                    }
                }
            }
        },
        .or_op, .and_op, .xor_op, .shl, .shr, .shra => {
            if (inst.operands.len < 2) return;
            const ty_a = getTypeOfValue(module, func, inst.operands[0]);
            if (ty_a) |ta| {
                if (!isIntType(module, ta)) {
                    try errs.push(.{
                        .code = .type_not_integer,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block_name,
                        .inst_idx = idx,
                        .value_id = inst.result,
                        .type_id = ta,
                        .op = inst.op,
                        .message = "bitwise operation operand is not integer",
                    });
                }
            }
        },
        .not => {
            if (inst.operands.len < 1) return;
            const ty_a = getTypeOfValue(module, func, inst.operands[0]);
            if (ty_a) |ta| {
                if (!isIntType(module, ta) and !isBoolType(module, ta)) {
                    try errs.push(.{
                        .code = .type_not_integer,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block_name,
                        .inst_idx = idx,
                        .value_id = inst.result,
                        .type_id = ta,
                        .op = inst.op,
                        .message = "not operation operand is not integer or bool",
                    });
                }
            }
        },
        .store => {
            if (inst.operands.len < 2) return;
            const ty_target = addressing.getTypeOfValue(module, func, inst.operands[0]);
            const ty_val = addressing.getTypeOfValue(module, func, inst.operands[1]);
            if (ty_target) |tt| {
                if (!addressing.isPtrType(module, tt) and !addressing.isAddressValue(module, func, inst.operands[0], 0)) {
                    try errs.push(.{
                        .code = .store_target_not_pointer,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block_name,
                        .inst_idx = idx,
                        .type_id = tt,
                        .op = .store,
                        .message = "store target is not a pointer",
                    });
                } else if (ty_val) |tv| {
                    const pointee = addressing.getPointeeType(module, tt);
                    if (pointee) |pe| {
                        if (!storeValueCompatible(module, func, pe, inst.operands[1], tv)) {
                            try errs.push(.{
                                .code = .store_type_mismatch,
                                .func_id = func_id,
                                .func_name = func.name,
                                .block_id = block_id,
                                .block_name = block_name,
                                .inst_idx = idx,
                                .type_id = pe,
                                .other_type_id = tv,
                                .op = .store,
                                .message = "stored value type does not match pointer pointee type",
                            });
                        }
                    }
                }
            }
        },
        .load => {
            if (inst.operands.len < 1) return;
            const ty_ptr = addressing.getTypeOfValue(module, func, inst.operands[0]);
            if (ty_ptr) |tp| {
                if (!addressing.isPtrType(module, tp) and !addressing.isAddressValue(module, func, inst.operands[0], 0)) {
                    try errs.push(.{
                        .code = .type_not_pointer,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block_name,
                        .inst_idx = idx,
                        .value_id = inst.result,
                        .type_id = tp,
                        .op = .load,
                        .message = "load source is not a pointer",
                    });
                } else if (inst.ty != 0) {
                    const pointee = addressing.getPointeeType(module, tp);
                    if (pointee) |pe| {
                        if (!typesCompatible(module, pe, inst.ty)) {
                            try errs.push(.{
                                .code = .load_type_mismatch,
                                .func_id = func_id,
                                .func_name = func.name,
                                .block_id = block_id,
                                .block_name = block_name,
                                .inst_idx = idx,
                                .value_id = inst.result,
                                .type_id = pe,
                                .other_type_id = inst.ty,
                                .op = .load,
                                .message = "load result type does not match pointer pointee type",
                            });
                        }
                    }
                }
            }
        },
        .neg, .fneg => {
            if (inst.operands.len < 1) return;
            const ty_a = getTypeOfValue(module, func, inst.operands[0]);
            if (ty_a) |ta| {
                if (inst.op == .neg and !isIntType(module, ta) and !isFloatType(module, ta)) {
                    try errs.push(.{
                        .code = .type_not_numeric,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block_name,
                        .inst_idx = idx,
                        .value_id = inst.result,
                        .type_id = ta,
                        .op = inst.op,
                        .message = "neg operand is not numeric",
                    });
                }
                if (inst.op == .fneg and !isFloatType(module, ta)) {
                    try errs.push(.{
                        .code = .type_not_float,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block_name,
                        .inst_idx = idx,
                        .value_id = inst.result,
                        .type_id = ta,
                        .op = inst.op,
                        .message = "fneg operand is not float",
                    });
                }
            }
        },
        .ret => {
            if (inst.operands.len > 0 and func.return_type != 0) {
                const ty_ret = getTypeOfValue(module, func, inst.operands[0]);
                if (ty_ret) |tr| {
                    if (!typesEqual(module, func.return_type, tr)) {
                        try errs.push(.{
                            .code = .type_mismatch,
                            .func_id = func_id,
                            .func_name = func.name,
                            .block_id = block_id,
                            .block_name = block_name,
                            .inst_idx = idx,
                            .type_id = func.return_type,
                            .other_type_id = tr,
                            .op = .ret,
                            .message = "return value type does not match function return type",
                        });
                    }
                }
            }
        },
        .alloca => {
            if (inst.ty != 0 and isVoidType(module, inst.ty)) {
                try errs.push(.{
                    .code = .alloca_type_void,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .alloca,
                    .message = "alloca type is void",
                });
            }
        },
        .@"const" => {
            if (inst.ty != 0 and isVoidType(module, inst.ty)) {
                try errs.push(.{
                    .code = .const_type_void,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .@"const",
                    .message = "constant has void type",
                });
            }
        },
        .select => {
            if (inst.operands.len < 3) return;
            const ty_cond = getTypeOfValue(module, func, inst.operands[0]);
            if (ty_cond) |tc| {
                if (!isBoolType(module, tc)) {
                    try errs.push(.{
                        .code = .type_mismatch,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block_name,
                        .inst_idx = idx,
                        .type_id = tc,
                        .op = .select,
                        .message = "select condition is not i1",
                    });
                }
            }
            const ty_a = getTypeOfValue(module, func, inst.operands[1]);
            const ty_b = getTypeOfValue(module, func, inst.operands[2]);
            if (ty_a) |ta| {
                if (ty_b) |tb| {
                    if (!typesEqual(module, ta, tb)) {
                        try errs.push(.{
                            .code = .type_mismatch,
                            .func_id = func_id,
                            .func_name = func.name,
                            .block_id = block_id,
                            .block_name = block_name,
                            .inst_idx = idx,
                            .type_id = ta,
                            .other_type_id = tb,
                            .op = .select,
                            .message = "select branches have different types",
                        });
                    }
                }
            }
        },
        .cast => {
            if (inst.data == .cast_info) {
                const ci = inst.data.cast_info;
                if (ci.from == ci.to) {
                    try errs.push(.{
                        .code = .type_mismatch,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block_name,
                        .inst_idx = idx,
                        .value_id = inst.result,
                        .type_id = ci.from,
                        .other_type_id = ci.to,
                        .op = .cast,
                        .message = "cast from type to same type is redundant",
                    });
                }
            }
        },
        else => {},
    }
}

fn getTypeOfValue(module: *bir.Module, func: *const bir.Function, val: ValueId) ?TypeId {
    return addressing.getTypeOfValue(module, func, val);
}

fn isIntType(module: *const bir.Module, tid: TypeId) bool {
    return addressing.isIntType(module, tid);
}

fn isFloatType(module: *const bir.Module, tid: TypeId) bool {
    return addressing.isFloatType(module, tid);
}

fn isBoolType(module: *const bir.Module, tid: TypeId) bool {
    return addressing.isBoolType(module, tid);
}

fn isPtrType(module: *const bir.Module, tid: TypeId) bool {
    return addressing.isPtrType(module, tid);
}

fn isVoidType(module: *const bir.Module, tid: TypeId) bool {
    return addressing.isVoidType(module, tid);
}

fn getPointeeType(module: *const bir.Module, tid: TypeId) ?TypeId {
    return addressing.getPointeeType(module, tid);
}

fn typesEqual(module: *const bir.Module, a: TypeId, b: TypeId) bool {
    _ = module;
    return a == b;
}

fn typesCompatible(module: *const bir.Module, a: TypeId, b: TypeId) bool {
    if (typesEqual(module, a, b)) return true;
    if (isIntType(module, a) and isIntType(module, b)) return true;
    if (isPtrType(module, a) and isPtrType(module, b)) return true;
    return false;
}

fn storeValueCompatible(module: *bir.Module, func: *const bir.Function, pe: TypeId, val: bir.ValueId, tv: TypeId) bool {
    if (typesCompatible(module, pe, tv)) return true;
    if (isAggregateType(module, pe) and addressing.isAddressValue(module, func, val, 0)) return true;
    return false;
}

fn isAggregateType(module: *const bir.Module, tid: TypeId) bool {
    const t = module.types.get(tid);
    return switch (t.kind) {
        .struct_type, .array, .vector, .matrix => true,
        else => false,
    };
}

fn isScalarType(module: *const bir.Module, tid: TypeId) bool {
    return isIntType(module, tid) or isFloatType(module, tid) or isPtrType(module, tid) or isVoidType(module, tid);
}

