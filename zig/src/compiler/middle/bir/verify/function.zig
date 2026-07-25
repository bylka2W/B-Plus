const std = @import("std");
const bir = @import("../bir.zig");
const FunctionId = bir.FunctionId;
const BlockId = bir.BlockId;
const Op = bir.Op;
const diagnostics = @import("diagnostics.zig");
const DiagnosticList = diagnostics.DiagnosticList;

pub fn verifyFunction(func: *const bir.Function, func_id: FunctionId, errs: *DiagnosticList) !void {
    if (func.blocks.items.len == 0) {
        try errs.push(.{
            .code = .empty_function,
            .func_id = func_id,
            .func_name = func.name,
            .message = "function has no basic blocks",
        });
        return;
    }

    for (func.blocks.items, 0..) |block, bid| {
        const block_id = @as(BlockId, @intCast(bid));

        if (block.instrs.items.len == 0) continue;

        const last_inst = block.instrs.items[block.instrs.items.len - 1];
        const is_terminator = isTerminatorOp(last_inst.op);

        if (!is_terminator) {
            try errs.push(.{
                .code = .block_has_no_terminator,
                .func_id = func_id,
                .func_name = func.name,
                .block_id = block_id,
                .block_name = block.label,
                .inst_idx = @intCast(block.instrs.items.len - 1),
                .op = last_inst.op,
                .message = "block does not end with a terminator instruction",
            });
        }

        var found_terminator = false;
        for (block.instrs.items, 0..) |inst, i| {
            if (isTerminatorOp(inst.op)) {
                if (found_terminator) {
                    try errs.push(.{
                        .code = .instruction_after_terminator,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .inst_idx = @intCast(i),
                        .op = inst.op,
                        .message = "instruction found after terminator",
                    });
                    break;
                }
                found_terminator = true;
            }
        }
    }
}

pub fn isTerminatorOp(op: Op) bool {
    return switch (op) {
        .br, .cond_br, .ret, .unreachable_op, .branch_on_bit => true,
        else => false,
    };
}
