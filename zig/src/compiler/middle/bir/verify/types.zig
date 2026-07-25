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

pub fn verifyTypes(
    module: *const bir.Module,
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
    module: *const bir.Module,
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
            const ty_a = getTypeOfValue(module, func, inst.operands[0]);
            const ty_b = getTypeOfValue(module, func, inst.operands[1]);
            if (ty_a) |ta| {
                if (!isIntType(module, ta) and !isFloatType(module, ta)) {
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
            const ty_target = getTypeOfValue(module, func, inst.operands[0]);
            const ty_val = getTypeOfValue(module, func, inst.operands[1]);
            if (ty_target) |tt| {
                if (!isPtrType(module, tt)) {
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
                    const pointee = getPointeeType(module, tt);
                    if (pointee) |pe| {
                        if (!typesEqual(module, pe, tv)) {
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
            const ty_ptr = getTypeOfValue(module, func, inst.operands[0]);
            if (ty_ptr) |tp| {
                if (!isPtrType(module, tp)) {
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
                    const pointee = getPointeeType(module, tp);
                    if (pointee) |pe| {
                        if (!typesEqual(module, pe, inst.ty)) {
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

fn getTypeOfValue(_: *const bir.Module, func: *const bir.Function, val: ValueId) ?TypeId {
    if (val == bir.NO_VALUE) return null;
    if (val == 0 or val > func.value_info.items.len) return null;
    const vi = &func.value_info.items[val - 1];
    if (vi.def.block == INVALID_ID) return null;
    if (vi.def.block >= func.blocks.items.len) return null;
    const blk = &func.blocks.items[vi.def.block];
    if (vi.def.idx >= blk.instrs.items.len) return null;
    return blk.instrs.items[vi.def.idx].ty;
}

fn isIntType(module: *const bir.Module, tid: TypeId) bool {
    const t = module.types.get(tid);
    return switch (t.kind) {
        .scalar => |sk| switch (sk) {
            .i1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => true,
            else => false,
        },
        else => false,
    };
}

fn isFloatType(module: *const bir.Module, tid: TypeId) bool {
    const t = module.types.get(tid);
    return switch (t.kind) {
        .scalar => |sk| switch (sk) {
            .f16, .bf16, .f32, .f64 => true,
            else => false,
        },
        else => false,
    };
}

fn isBoolType(module: *const bir.Module, tid: TypeId) bool {
    const t = module.types.get(tid);
    return switch (t.kind) {
        .scalar => |sk| sk == .i1,
        else => false,
    };
}

fn isPtrType(module: *const bir.Module, tid: TypeId) bool {
    const t = module.types.get(tid);
    return t.kind == .pointer;
}

fn isVoidType(module: *const bir.Module, tid: TypeId) bool {
    const t = module.types.get(tid);
    return t.kind == .void;
}

fn getPointeeType(module: *const bir.Module, tid: TypeId) ?TypeId {
    const t = module.types.get(tid);
    return switch (t.kind) {
        .pointer => |p| p.elem,
        else => null,
    };
}

fn typesEqual(module: *const bir.Module, a: TypeId, b: TypeId) bool {
    _ = module;
    return a == b;
}

const INVALID_ID = bir.INVALID_ID;
