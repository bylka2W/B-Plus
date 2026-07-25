const std = @import("std");
const bir = @import("../bir.zig");
const FunctionId = bir.FunctionId;
const BlockId = bir.BlockId;
const ValueId = bir.ValueId;
const diagnostics = @import("diagnostics.zig");
const DiagnosticList = diagnostics.DiagnosticList;

pub fn verifyMemory(
    _: *const bir.Module,
    func: *const bir.Function,
    func_id: FunctionId,
    errs: *DiagnosticList,
) !void {
    const nblocks = func.blocks.items.len;
    if (nblocks == 0) return;

    var allocas = std.AutoHashMap(ValueId, void).init(errs.allocator);
    defer allocas.deinit();

    for (func.blocks.items) |block| {
        for (block.instrs.items) |inst| {
            if (inst.op == .alloca and inst.result != bir.NO_VALUE) {
                try allocas.put(inst.result, {});
            }
        }
    }

    for (func.blocks.items, 0..) |block, bid| {
        const block_id = @as(BlockId, @intCast(bid));

        for (block.instrs.items, 0..) |inst, idx| {
            switch (inst.op) {
                .load => {
                    if (inst.operands.len < 1) continue;
                    const ptr_val = inst.operands[0];
                    if (ptr_val == bir.NO_VALUE) continue;

                    if (ptr_val > func.value_info.items.len) continue;
                    const vi = &func.value_info.items[ptr_val - 1];
                    if (vi.def.block == bir.INVALID_ID) continue;
                    if (vi.def.block >= func.blocks.items.len) continue;
                    const def_block = &func.blocks.items[vi.def.block];
                    if (vi.def.idx >= def_block.instrs.items.len) continue;
                    const def_inst = def_block.instrs.items[vi.def.idx];

                    if (def_inst.op != .alloca and def_inst.op != .getelementptr and def_inst.op != .ptr_offset) {
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

                    if (target_val > func.value_info.items.len) continue;
                    const vi = &func.value_info.items[target_val - 1];
                    if (vi.def.block == bir.INVALID_ID) continue;
                    if (vi.def.block >= func.blocks.items.len) continue;
                    const def_block = &func.blocks.items[vi.def.block];
                    if (vi.def.idx >= def_block.instrs.items.len) continue;
                    const def_inst = def_block.instrs.items[vi.def.idx];

                    if (def_inst.op != .alloca and def_inst.op != .getelementptr and def_inst.op != .ptr_offset) {
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
