const std = @import("std");
const machine = @import("../../machine.zig");
const instruction = @import("../../core/instruction.zig");

pub const VerifyError = error{
    InvalidBlockTarget,
    EmptyBlock,
    BlockNotTerminated,
    UnreachableBlock,
};

pub fn verifyCFG(func: *const machine.MFunction) VerifyError!void {
    if (func.blocks.items.len == 0) return;

    var reachable = std.AutoHashMap(u32, void).init(func.allocator);
    defer reachable.deinit();

    try reachable.put(0, {});

    for (func.blocks.items, 0..) |*blk, i| {
        if (blk.instrs.items.len == 0) return error.EmptyBlock;

        const last = blk.instrs.items[blk.instrs.items.len - 1];
        const has_term = switch (last) {
            .jmp, .jcc, .ret => true,
            else => false,
        };
        if (!has_term) return error.BlockNotTerminated;

        switch (last) {
            .jmp => |j| {
                if (j.target >= func.blocks.items.len) return error.InvalidBlockTarget;
                try reachable.put(j.target, {});
            },
            .jcc => |j| {
                if (j.target >= func.blocks.items.len) return error.InvalidBlockTarget;
                try reachable.put(j.target, {});
                if (i + 1 < func.blocks.items.len) {
                    try reachable.put(@intCast(i + 1), {});
                }
            },
            else => {},
        }
    }

    for (func.blocks.items, 0..) |_, i| {
        if (i == 0) continue;
        if (!reachable.contains(@intCast(i))) return error.UnreachableBlock;
    }
}
