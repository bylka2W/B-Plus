const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../../bir.zig");
const NO_VALUE = bir.NO_VALUE;

pub const Edge = struct { from: bir.BlockId, to: bir.BlockId };

/// Lightweight CFG wrapper: preds/succs live in BasicBlock directly.
/// buildCFG populates block.preds and block.succs + computes RPO.
/// Consumers access edges via blocks.items[id].preds / .succs.
pub const CFG = struct {
    allocator: Allocator,
    entry: bir.BlockId,
    rpo: std.ArrayList(bir.BlockId),

    pub fn deinit(self: *CFG) void {
        self.rpo.deinit();
    }
};

pub fn buildCFG(allocator: Allocator, func: *bir.Function) !CFG {
    // Clear and rebuild preds/succs
    for (func.blocks.items) |*block| {
        block.preds.clearRetainingCapacity();
        block.succs.clearRetainingCapacity();
    }

    for (func.blocks.items, 0..) |*block, bi| {
        const bid = @as(bir.BlockId, @intCast(bi));
        if (block.instrs.items.len == 0) continue;

        const terminator = &block.instrs.items[block.instrs.items.len - 1];
        switch (terminator.op) {
            .br => {
                const target = terminator.data.block_target;
                if (target < func.blocks.items.len) {
                    try block.succs.append(target);
                    try func.blocks.items[target].preds.append(bid);
                }
            },
            .cond_br => {
                const then_b = terminator.data.cond_branch.then_block;
                const else_b = terminator.data.cond_branch.else_block;
                if (then_b < func.blocks.items.len) {
                    try block.succs.append(then_b);
                    try func.blocks.items[then_b].preds.append(bid);
                }
                if (else_b < func.blocks.items.len) {
                    try block.succs.append(else_b);
                    try func.blocks.items[else_b].preds.append(bid);
                }
            },
            .ret, .unreachable_op => {},
            else => {},
        }
    }

    var cfg = CFG{
        .allocator = allocator,
        .entry = 0,
        .rpo = std.ArrayList(bir.BlockId).init(allocator),
    };

    try computeRPO(&cfg, func);
    return cfg;
}

fn computeRPO(cfg: *CFG, func: *bir.Function) !void {
    cfg.rpo.clearRetainingCapacity();
    var visited = try std.DynamicBitSet.initEmpty(cfg.allocator, func.blocks.items.len);
    defer visited.deinit();

    try dfsPostorder(cfg, func, cfg.entry, &visited);

    var i: usize = 0;
    if (cfg.rpo.items.len > 0) {
        var j: usize = cfg.rpo.items.len - 1;
        while (i < j) {
            const tmp = cfg.rpo.items[i];
            cfg.rpo.items[i] = cfg.rpo.items[j];
            cfg.rpo.items[j] = tmp;
            i += 1;
            j -= 1;
        }
    }
}

fn dfsPostorder(cfg: *CFG, func: *bir.Function, bid: bir.BlockId, visited: *std.DynamicBitSet) !void {
    if (bid >= func.blocks.items.len) return;
    if (visited.isSet(bid)) return;
    visited.set(bid);

    const succs = func.blocks.items[bid].succs.items;
    for (succs) |succ| {
        try dfsPostorder(cfg, func, succ, visited);
    }

    try cfg.rpo.append(bid);
}

pub fn dumpCFG(cfg: *const CFG, func: *const bir.Function, writer: anytype) !void {
    try writer.writeAll("; CFG\n");
    for (func.blocks.items, 0..) |*block, bi| {
        const bid = @as(bir.BlockId, @intCast(bi));
        try writer.print("  block_{d}: preds=[", .{bid});
        for (block.preds.items, 0..) |pred, pi| {
            if (pi > 0) try writer.writeAll(", ");
            try writer.print("{d}", .{pred});
        }
        try writer.writeAll("] succs=[");
        for (block.succs.items, 0..) |succ, si| {
            if (si > 0) try writer.writeAll(", ");
            try writer.print("{d}", .{succ});
        }
        try writer.writeAll("]\n");
    }
    try writer.print("; RPO: ", .{});
    for (cfg.rpo.items, 0..) |bid, i| {
        if (i > 0) try writer.writeAll(" -> ");
        try writer.print("{d}", .{bid});
    }
    try writer.writeAll("\n");
}

pub fn isBackEdge(cfg: *const CFG, _: *const bir.Function, from: bir.BlockId, to: bir.BlockId) bool {
    const from_rpo = getRPOPos(cfg, from) orelse return false;
    const to_rpo = getRPOPos(cfg, to) orelse return false;
    return from_rpo >= to_rpo;
}

fn getRPOPos(cfg: *const CFG, bid: bir.BlockId) ?usize {
    for (cfg.rpo.items, 0..) |b, i| {
        if (b == bid) return i;
    }
    return null;
}

// ─── Validation ───

pub const ValidationError = error{
    EntryHasPredecessor,
    MissingTerminator,
    ExtraTerminator,
    InvalidBranchTarget,
    UnreachableBlock,
    BlockMissingInCFG,
};

pub fn validate(cfg: *const CFG, func: *const bir.Function) ValidationError!void {
    if (cfg.entry >= func.blocks.items.len) return error.BlockMissingInCFG;
    if (func.blocks.items[cfg.entry].preds.items.len > 0) return error.EntryHasPredecessor;

    for (func.blocks.items, 0..) |*block, bi| {
        const bid = @as(bir.BlockId, @intCast(bi));
        _ = bid;

        const n = block.instrs.items.len;
        if (n == 0) continue;

        var term_count: u32 = 0;
        for (block.instrs.items) |inst| {
            if (isTerminator(inst.op)) {
                term_count += 1;
                if (term_count > 1) return error.ExtraTerminator;

                switch (inst.op) {
                    .br => {
                        const target = inst.data.block_target;
                        if (target >= func.blocks.items.len) return error.InvalidBranchTarget;
                    },
                    .cond_br => {
                        const cb = inst.data.cond_branch;
                        if (cb.then_block >= func.blocks.items.len) return error.InvalidBranchTarget;
                        if (cb.else_block >= func.blocks.items.len) return error.InvalidBranchTarget;
                    },
                    else => {},
                }
            }
        }

        if (n > 0) {
            const last = &block.instrs.items[n - 1];
            if (!isTerminator(last.op)) return error.MissingTerminator;
        }
    }
}

fn isTerminator(op: bir.Op) bool {
    return switch (op) {
        .br, .cond_br, .ret, .unreachable_op => true,
        else => false,
    };
}

// ─── CFG Mutation Helpers ───

pub fn getExitBlocks(cfg: *const CFG, func: *const bir.Function) std.ArrayList(bir.BlockId) {
    var exits = std.ArrayList(bir.BlockId).init(cfg.allocator);
    for (func.blocks.items, 0..) |*block, bi| {
        if (block.instrs.items.len == 0) continue;
        const last = block.instrs.items[block.instrs.items.len - 1];
        if (last.op == .ret or last.op == .unreachable_op) {
            exits.append(@as(bir.BlockId, @intCast(bi))) catch {};
        }
    }
    return exits;
}

pub fn getBlockSuccessors(func: *const bir.Function, bid: bir.BlockId) []const bir.BlockId {
    return func.blocks.items[bid].succs.items;
}

pub fn replaceSuccessor(_: *CFG, func: *bir.Function, from: bir.BlockId, old_succ: bir.BlockId, new_succ: bir.BlockId) void {
    const from_block = &func.blocks.items[from];
    for (from_block.succs.items, 0..) |s, i| {
        if (s == old_succ) {
            from_block.succs.items[i] = new_succ;
            break;
        }
    }
    const new_block = &func.blocks.items[new_succ];
    for (new_block.preds.items, 0..) |p, i| {
        if (p == from) {
            _ = new_block.preds.swapRemove(i);
            break;
        }
    }
    new_block.preds.append(from) catch {};
}

pub fn removeBlockFromCFG(_: *CFG, func: *bir.Function, bid: bir.BlockId) void {
    const block = &func.blocks.items[bid];
    for (block.preds.items) |pred| {
        const pred_block = &func.blocks.items[pred];
        for (pred_block.succs.items, 0..) |s, i| {
            if (s == bid) {
                _ = pred_block.succs.swapRemove(i);
                break;
            }
        }
    }
    for (block.succs.items) |succ| {
        const succ_block = &func.blocks.items[succ];
        for (succ_block.preds.items, 0..) |p, i| {
            if (p == bid) {
                _ = succ_block.preds.swapRemove(i);
                break;
            }
        }
    }
    block.preds.clearRetainingCapacity();
    block.succs.clearRetainingCapacity();
}
