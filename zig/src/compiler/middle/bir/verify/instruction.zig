const std = @import("std");
const bir = @import("../bir.zig");
const FunctionId = bir.FunctionId;
const BlockId = bir.BlockId;
const ValueId = bir.ValueId;
const TypeId = bir.TypeId;
const Op = bir.Op;
const diagnostics = @import("diagnostics.zig");
const DiagnosticList = diagnostics.DiagnosticList;

pub fn verifyInstructions(
    _: *const bir.Module,
    func: *const bir.Function,
    func_id: FunctionId,
    errs: *DiagnosticList,
) !void {
    const nblocks = func.blocks.items.len;
    if (nblocks == 0) return;

    for (func.blocks.items, 0..) |block, bid| {
        const block_id = @as(BlockId, @intCast(bid));

        for (block.instrs.items, 0..) |inst, idx| {
            verifyInst(func, inst, func_id, block_id, block.label, @intCast(idx), errs) catch {};
        }
    }
}

fn verifyInst(
    func: *const bir.Function,
    inst: bir.Inst,
    func_id: FunctionId,
    block_id: BlockId,
    block_name: []const u8,
    idx: u32,
    errs: *DiagnosticList,
) !void {
    switch (inst.op) {
        .add, .sub, .mul, .div, .mod, .and_op, .or_op, .xor_op, .shl, .shr, .shra => {
            if (inst.operands.len < 2) {
                try errs.push(.{
                    .code = .binary_requires_two_operands,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = inst.op,
                    .message = "binary op requires two operands",
                });
            }
        },
        .neg, .fneg, .not, .sext, .zext, .trunc, .fptosi, .sitofp, .fpext, .fptrunc, .bitcast => {
            if (inst.operands.len < 1) {
                try errs.push(.{
                    .code = .unary_requires_operand,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = inst.op,
                    .message = "unary op requires one operand",
                });
            }
        },
        .alloca => {
            if (inst.operands.len != 0) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .alloca,
                    .message = "alloca takes no operands",
                });
            }
        },
        .store => {
            if (inst.operands.len < 2) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .op = .store,
                    .message = "store requires two operands (target, value)",
                });
            }
        },
        .load => {
            if (inst.operands.len < 1) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .load,
                    .message = "load requires one operand (pointer)",
                });
            }
        },
        .ret => {},
        .br => {
            if (inst.data != .block_target) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .op = .br,
                    .message = "br must have block_target data",
                });
            }
        },
        .cond_br => {
            if (inst.data != .cond_branch) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .op = .cond_br,
                    .message = "cond_br must have cond_branch data",
                });
            }
        },
        .phi => {
            if (inst.data != .phi_incoming) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .phi,
                    .message = "phi must have phi_incoming data",
                });
            }
        },
        .@"const" => {
            if (inst.data != .const_data and inst.data != .string) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .@"const",
                    .message = "const must have const_data or string data",
                });
            }
        },
        .call => {
            if (inst.data != .call_info and inst.data != .named_call) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .call,
                    .message = "call must have call_info or named_call data",
                });
            }
        },
        .composite => {
            if (inst.operands.len < 1) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .composite,
                    .message = "composite requires at least one operand",
                });
            }
        },
        .extract => {
            if (inst.operands.len < 1) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .extract,
                    .message = "extract requires one operand",
                });
            }
        },
        .insert => {
            if (inst.operands.len < 2) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .insert,
                    .message = "insert requires two operands (composite, element)",
                });
            }
        },
        .select => {
            if (inst.operands.len < 3) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .select,
                    .message = "select requires three operands (cond, true_val, false_val)",
                });
            }
        },
        .getelementptr => {
            if (inst.data != .gep_info) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .getelementptr,
                    .message = "getelementptr must have gep_info data",
                });
            }
        },
        .fence => {
            if (inst.data != .fence_info) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .op = .fence,
                    .message = "fence must have fence_info data",
                });
            }
        },
        .splat => {
            if (inst.operands.len < 1) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .splat,
                    .message = "splat requires one operand",
                });
            }
        },
        .extract_element => {
            if (inst.operands.len < 1) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .extract_element,
                    .message = "extract_element requires one operand",
                });
            }
        },
        .insert_element => {
            if (inst.operands.len < 2) {
                try errs.push(.{
                    .code = .invalid_operand_count,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block_name,
                    .inst_idx = idx,
                    .value_id = inst.result,
                    .op = .insert_element,
                    .message = "insert_element requires two operands (vector, element)",
                });
            }
        },
        else => {},
    }
}
