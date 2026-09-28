const std = @import("std");
const bir = @import("../bir.zig");
const FunctionId = bir.FunctionId;
const BlockId = bir.BlockId;
const ValueId = bir.ValueId;
const diagnostics = @import("diagnostics.zig");
const DiagnosticList = diagnostics.DiagnosticList;
const addressing = @import("addressing.zig");

pub fn verifyMemory(
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
            switch (inst.op) {
                .load => {
                    if (inst.operands.len < 1) continue;
                    const ptr_val = inst.operands[0];
                    if (ptr_val == bir.NO_VALUE) continue;

                    const ptr_ty = addressing.getTypeOfValue(module, func, ptr_val);
                    const is_ptr = if (ptr_ty) |pt| addressing.isPtrType(module, pt) else false;
                    if (!is_ptr and !addressing.isAddressValue(module, func, ptr_val, 0)) {
                        try errs.push(.{
                            .code = .type_not_pointer,
                            .func_id = func_id,
                            .func_name = func.name,
                            .block_id = block_id,
                            .block_name = block.label,
                            .inst_idx = @intCast(idx),
                            .value_id = inst.result,
                            .op = .load,
                            .message = "load source is not derived from alloca or pointer operation",
                        });
                    }
                },
                .store => {
                    if (inst.operands.len < 2) continue;
                    const target_val = inst.operands[0];
                    if (target_val == bir.NO_VALUE) continue;

                    const target_ty = addressing.getTypeOfValue(module, func, target_val);
                    const is_ptr = if (target_ty) |tt| addressing.isPtrType(module, tt) else false;
                    if (!is_ptr and !addressing.isAddressValue(module, func, target_val, 0)) {
                        try errs.push(.{
                            .code = .store_target_not_pointer,
                            .func_id = func_id,
                            .func_name = func.name,
                            .block_id = block_id,
                            .block_name = block.label,
                            .inst_idx = @intCast(idx),
                            .op = .store,
                            .message = "store target is not derived from alloca or pointer operation",
                        });
                    }
                },
                else => {},
            }
        }
    }
}