const std = @import("std");
const bir = @import("../bir.zig");
const FunctionId = bir.FunctionId;
const BlockId = bir.BlockId;
const ValueId = bir.ValueId;
const TypeId = bir.TypeId;
const diagnostics = @import("diagnostics.zig");
const DiagnosticList = diagnostics.DiagnosticList;

pub fn verifyCalls(
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
            if (inst.op != .call) continue;

            switch (inst.data) {
                .call_info => |ci| {
                    verifyCallInfo(module, func, ci.callee, ci.args, inst.ty, func_id, block_id, block.label, idx, errs) catch {};
                },
                .named_call => |nc| {
                    for (nc.args) |arg| {
                        if (arg > func.value_info.items.len) {
                            try errs.push(.{
                                .code = .call_argument_count_mismatch,
                                .func_id = func_id,
                                .func_name = func.name,
                                .block_id = block_id,
                                .block_name = block.label,
                                .inst_idx = idx,
                                .value_id = inst.result,
                                .op = .call,
                                .message = "call argument value ID out of range",
                            });
                        }
                    }
                },
                else => {
                    try errs.push(.{
                        .code = .call_callee_not_function,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .inst_idx = idx,
                        .value_id = inst.result,
                        .op = .call,
                        .message = "call instruction has invalid data",
                    });
                },
            }
        }
    }
}

fn verifyCallInfo(
    module: *const bir.Module,
    func: *const bir.Function,
    callee: ValueId,
    args: []const ValueId,
    return_type: TypeId,
    func_id: FunctionId,
    block_id: BlockId,
    block_name: []const u8,
    idx: usize,
    errs: *DiagnosticList,
) !void {
    _ = module;

    if (callee != bir.NO_VALUE) {
        if (callee > func.value_info.items.len) {
            try errs.push(.{
                .code = .call_callee_not_function,
                .func_id = func_id,
                .func_name = func.name,
                .block_id = block_id,
                .block_name = block_name,
                .inst_idx = idx,
                .value_id = callee,
                .op = .call,
                .message = "call callee value ID out of range",
            });
            return;
        }
    }

    for (args) |arg| {
        if (arg == bir.NO_VALUE) continue;
        if (arg > func.value_info.items.len) {
            try errs.push(.{
                .code = .call_argument_count_mismatch,
                .func_id = func_id,
                .func_name = func.name,
                .block_id = block_id,
                .block_name = block_name,
                .inst_idx = idx,
                .op = .call,
                .message = "call argument value ID out of range",
            });
        }
    }

    _ = return_type;
}
