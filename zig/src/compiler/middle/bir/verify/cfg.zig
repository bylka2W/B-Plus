const std = @import("std");
const bir = @import("../bir.zig");
const bir_cfg = @import("../analysis/cfg/cfg.zig");
const FunctionId = bir.FunctionId;
const BlockId = bir.BlockId;
const diagnostics = @import("diagnostics.zig");
const DiagnosticList = diagnostics.DiagnosticList;

pub fn verifyCFG(
    func: *const bir.Function,
    cfg: *const bir_cfg.CFG,
    func_id: FunctionId,
    errs: *DiagnosticList,
) !void {
    const nblocks = func.blocks.items.len;
    if (nblocks == 0) return;

    if (cfg.entry != 0) {
        try errs.push(.{
            .code = .invalid_block_id,
            .func_id = func_id,
            .func_name = func.name,
            .block_id = cfg.entry,
            .message = "CFG entry block is not block 0",
        });
    }

    if (nblocks > 0) {
        const entry = &func.blocks.items[0];
        if (entry.preds.items.len > 0) {
            try errs.push(.{
                .code = .entry_block_has_predecessor,
                .func_id = func_id,
                .func_name = func.name,
                .block_id = 0,
                .block_name = entry.label,
                .message = "entry block has predecessors",
            });
        }
    }

    for (func.blocks.items, 0..) |block, bid| {
        const block_id = @as(BlockId, @intCast(bid));
        if (block.instrs.items.len == 0) continue;

        const last_inst = block.instrs.items[block.instrs.items.len - 1];
        switch (last_inst.op) {
            .br => {
                const target = last_inst.data.block_target;
                if (target >= nblocks) {
                    try errs.push(.{
                        .code = .successor_out_of_range,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .op = .br,
                        .message = "branch target block ID out of range",
                    });
                }
            },
            .cond_br => {
                const cb = last_inst.data.cond_branch;
                if (cb.then_block >= nblocks or cb.else_block >= nblocks) {
                    try errs.push(.{
                        .code = .successor_out_of_range,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .op = .cond_br,
                        .message = "conditional branch target block ID out of range",
                    });
                }
            },
            .branch_on_bit => {
                const bob = last_inst.data.branch_on_bit;
                if (bob.then_block >= nblocks or bob.else_block >= nblocks) {
                    try errs.push(.{
                        .code = .successor_out_of_range,
                        .func_id = func_id,
                        .func_name = func.name,
                        .block_id = block_id,
                        .block_name = block.label,
                        .op = .branch_on_bit,
                        .message = "branch_on_bit target block ID out of range",
                    });
                }
            },
            else => {},
        }
    }

    for (func.blocks.items, 0..) |block, bid| {
        const block_id = @as(BlockId, @intCast(bid));

        for (block.succs.items) |succ| {
            if (succ >= nblocks) {
                try errs.push(.{
                    .code = .successor_out_of_range,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block.label,
                    .message = "successor block ID out of range in CFG edges",
                });
                continue;
            }

            var found = false;
            for (func.blocks.items[succ].preds.items) |pred| {
                if (pred == block_id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try errs.push(.{
                    .code = .predecessor_symmetry_broken,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block.label,
                    .message = "successor does not list this block as predecessor",
                });
            }
        }

        for (block.preds.items) |pred| {
            if (pred >= nblocks) {
                try errs.push(.{
                    .code = .successor_out_of_range,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block.label,
                    .message = "predecessor block ID out of range in CFG edges",
                });
                continue;
            }

            var found = false;
            for (func.blocks.items[pred].succs.items) |succ| {
                if (succ == block_id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try errs.push(.{
                    .code = .predecessor_symmetry_broken,
                    .func_id = func_id,
                    .func_name = func.name,
                    .block_id = block_id,
                    .block_name = block.label,
                    .message = "predecessor does not list this block as successor",
                });
            }
        }
    }

    _ = cfg.rpo;
}
