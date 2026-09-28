const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../../bir.zig");
const bir_cfg = @import("../../analysis/cfg/cfg.zig");
const BasicBlock = @import("../../core/block.zig").BasicBlock;
const INVALID_ID = bir.INVALID_ID;
const NO_VALUE = bir.NO_VALUE;
const ValueId = bir.ValueId;
const BlockId = bir.BlockId;
const PreservedAnalyses = bir.PreservedAnalyses;
const Module = bir.Module;

pub const DeadBlockElimPass = bir.Pass{
    .name = "dead-block-elimination",
    .run = runDeadBlockElim,
};

fn runDeadBlockElim(ctx: *bir.PassContext) anyerror!PreservedAnalyses {
    const module = ctx.module;
    const allocator = ctx.allocator;

    for (module.functions.items) |*func| {
        if (func.blocks.items.len < 2) continue;
        const n = func.blocks.items.len;

        const reachable = try allocator.alloc(bool, n);
        defer allocator.free(reachable);
        @memset(reachable, false);

        var stack = std.ArrayList(BlockId).init(allocator);
        defer stack.deinit();
        try stack.append(0);
        reachable[0] = true;

        while (stack.pop()) |bid| {
            const block = &func.blocks.items[bid];
            if (block.instrs.items.len == 0) continue;
            const term = &block.instrs.items[block.instrs.items.len - 1];
            switch (term.op) {
                .br => try pushSucc(&stack, reachable, term.data.block_target, n),
                .cond_br => {
                    try pushSucc(&stack, reachable, term.data.cond_branch.then_block, n);
                    try pushSucc(&stack, reachable, term.data.cond_branch.else_block, n);
                },
                .branch_on_bit => {
                    try pushSucc(&stack, reachable, term.data.branch_on_bit.then_block, n);
                    try pushSucc(&stack, reachable, term.data.branch_on_bit.else_block, n);
                },
                else => {},
            }
        }

        var any_dead = false;
        for (reachable) |r| {
            if (!r) {
                any_dead = true;
                break;
            }
        }
        if (!any_dead) continue;

        const new_ids = try allocator.alloc(BlockId, n);
        defer allocator.free(new_ids);
        @memset(new_ids, INVALID_ID);
        var next: BlockId = 0;
        for (reachable, 0..) |r, bi| {
            if (r) {
                new_ids[bi] = next;
                next += 1;
            }
        }

        for (func.blocks.items, 0..) |*block, bi| {
            if (!reachable[bi]) continue;
            if (block.instrs.items.len == 0) continue;

            const last = &block.instrs.items[block.instrs.items.len - 1];
            switch (last.op) {
                .br => last.data.block_target = new_ids[last.data.block_target],
                .cond_br => {
                    last.data.cond_branch.then_block = new_ids[last.data.cond_branch.then_block];
                    last.data.cond_branch.else_block = new_ids[last.data.cond_branch.else_block];
                },
                .branch_on_bit => {
                    last.data.branch_on_bit.then_block = new_ids[last.data.branch_on_bit.then_block];
                    last.data.branch_on_bit.else_block = new_ids[last.data.branch_on_bit.else_block];
                },
                else => {},
            }

            for (block.instrs.items) |*inst| {
                switch (inst.data) {
                    .phi_incoming => |incoming| {
                        for (incoming) |*inc| {
                            inc.block = new_ids[inc.block];
                        }
                    },
                    else => {},
                }
            }
        }

        var new_blocks = std.ArrayList(BasicBlock).init(allocator);
        var moved = false;
        defer if (!moved) new_blocks.deinit();
        for (func.blocks.items, 0..) |*block, bi| {
            if (reachable[bi]) {
                try new_blocks.append(block.*);
            } else {
                block.deinit(allocator);
            }
        }

        func.blocks.deinit();
        func.blocks = new_blocks;
        moved = true;

        var cfg = try bir_cfg.buildCFG(allocator, func);
        cfg.deinit();
    }

    return PreservedAnalyses.none();
}

fn pushSucc(stack: *std.ArrayList(BlockId), reachable: []bool, succ: BlockId, n: usize) !void {
    if (succ >= n) return;
    if (reachable[succ]) return;
    reachable[succ] = true;
    try stack.append(succ);
}