const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("bir.zig");
const NO_VALUE = bir.NO_VALUE;

pub const Edge = struct { from: bir.BlockId, to: bir.BlockId };

pub const BlockInfo = struct {
    id: bir.BlockId,
    predecessors: std.ArrayList(bir.BlockId),
    successors: std.ArrayList(bir.BlockId),
    visited: bool,

    pub fn deinit(self: *BlockInfo, _: Allocator) void {
        self.predecessors.deinit();
        self.successors.deinit();
    }
};

pub const CFG = struct {
    allocator: Allocator,
    blocks: std.ArrayList(BlockInfo),
    entry: bir.BlockId,
    rpo: std.ArrayList(bir.BlockId),

    pub fn deinit(self: *CFG) void {
        for (self.blocks.items) |*bi| bi.deinit(self.allocator);
        self.blocks.deinit();
        self.rpo.deinit();
    }

    pub fn get(self: *const CFG, id: bir.BlockId) *const BlockInfo {
        return &self.blocks.items[id];
    }

    pub fn getMut(self: *CFG, id: bir.BlockId) *BlockInfo {
        return &self.blocks.items[id];
    }
};

pub fn buildCFG(allocator: Allocator, func: *const bir.Function) !CFG {
    var cfg = CFG{
        .allocator = allocator,
        .blocks = std.ArrayList(BlockInfo).init(allocator),
        .entry = 0,
        .rpo = std.ArrayList(bir.BlockId).init(allocator),
    };

    for (func.blocks.items, 0..) |_, bi| {
        try cfg.blocks.append(.{
            .id = @as(bir.BlockId, @intCast(bi)),
            .predecessors = std.ArrayList(bir.BlockId).init(allocator),
            .successors = std.ArrayList(bir.BlockId).init(allocator),
            .visited = false,
        });
    }

    for (func.blocks.items, 0..) |*block, bi| {
        const bid = @as(bir.BlockId, @intCast(bi));
        if (block.instrs.items.len == 0) continue;

        const terminator = &block.instrs.items[block.instrs.items.len - 1];
        switch (terminator.op) {
            .br => {
                const target = terminator.data.block_target;
                try cfg.getMut(bid).successors.append(target);
                try cfg.getMut(target).predecessors.append(bid);
            },
            .cond_br => {
                const then_b = terminator.data.cond_branch.then_block;
                const else_b = terminator.data.cond_branch.else_block;
                try cfg.getMut(bid).successors.append(then_b);
                try cfg.getMut(bid).successors.append(else_b);
                try cfg.getMut(then_b).predecessors.append(bid);
                try cfg.getMut(else_b).predecessors.append(bid);
            },
            .ret, .unreachable_op => {},
            else => {},
        }
    }

    try computeRPO(&cfg, func);
    return cfg;
}

fn computeRPO(cfg: *CFG, func: *const bir.Function) !void {
    for (cfg.blocks.items) |*bi| bi.visited = false;
    cfg.rpo.clearRetainingCapacity();

    try dfsPostorder(cfg, func, cfg.entry);

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

fn dfsPostorder(cfg: *CFG, func: *const bir.Function, bid: bir.BlockId) !void {
    if (bid >= func.blocks.items.len) return;
    if (cfg.getMut(bid).visited) return;
    cfg.getMut(bid).visited = true;

    const succs = cfg.get(bid).successors.items;
    for (succs) |succ| {
        try dfsPostorder(cfg, func, succ);
    }

    try cfg.rpo.append(bid);
}

pub fn dumpCFG(cfg: *const CFG, writer: anytype) !void {
    try writer.writeAll("; CFG\n");
    for (cfg.blocks.items) |bi| {
        try writer.print("  block_{d}: preds=[", .{bi.id});
        for (bi.predecessors.items, 0..) |pred, pi| {
            if (pi > 0) try writer.writeAll(", ");
            try writer.print("{d}", .{pred});
        }
        try writer.writeAll("] succs=[");
        for (bi.successors.items, 0..) |succ, si| {
            if (si > 0) try writer.writeAll(", ");
            try writer.print("{d}", .{succ});
        }
        try writer.writeAll("]\n");
    }
    try writer.writeAll("; RPO: ");
    for (cfg.rpo.items, 0..) |bid, i| {
        if (i > 0) try writer.writeAll(" -> ");
        try writer.print("{d}", .{bid});
    }
    try writer.writeAll("\n");
}

pub fn isBackEdge(cfg: *const CFG, from: bir.BlockId, to: bir.BlockId) bool {
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
    if (cfg.entry >= cfg.blocks.items.len) return error.BlockMissingInCFG;
    if (cfg.get(cfg.entry).predecessors.items.len > 0) return error.EntryHasPredecessor;

    for (func.blocks.items, 0..) |*block, bi| {
        const bid = @as(bir.BlockId, @intCast(bi));
        if (bid >= cfg.blocks.items.len) return error.BlockMissingInCFG;

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

    for (cfg.blocks.items) |bi| {
        for (bi.successors.items) |succ| {
            if (succ >= cfg.blocks.items.len) return error.InvalidBranchTarget;
        }
        for (bi.predecessors.items) |pred| {
            if (pred >= cfg.blocks.items.len) return error.InvalidBranchTarget;
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
    const block = &func.blocks.items[bid];
    if (block.instrs.items.len == 0) return &.{};
    const last = &block.instrs.items[block.instrs.items.len - 1];
    return switch (last.op) {
        .br => &.{last.data.block_target},
        .cond_br => &.{ last.data.cond_branch.then_block, last.data.cond_branch.else_block },
        else => &.{},
    };
}

pub fn replaceSuccessor(cfg: *CFG, from: bir.BlockId, old_succ: bir.BlockId, new_succ: bir.BlockId) void {
    const bi = cfg.getMut(from);
    for (bi.successors.items, 0..) |s, i| {
        if (s == old_succ) {
            bi.successors.items[i] = new_succ;
            break;
        }
    }
    const pred_list = cfg.getMut(new_succ);
    for (pred_list.predecessors.items, 0..) |p, i| {
        if (p == from) {
            _ = pred_list.predecessors.swapRemove(i);
            break;
        }
    }
    pred_list.predecessors.append(from) catch {};
}

pub fn removeBlockFromCFG(cfg: *CFG, bid: bir.BlockId) void {
    const bi = cfg.getMut(bid);
    for (bi.predecessors.items) |pred| {
        const pred_bi = cfg.getMut(pred);
        for (pred_bi.successors.items, 0..) |s, i| {
            if (s == bid) {
                _ = pred_bi.successors.swapRemove(i);
                break;
            }
        }
    }
    for (bi.successors.items) |succ| {
        const succ_bi = cfg.getMut(succ);
        for (succ_bi.predecessors.items, 0..) |p, i| {
            if (p == bid) {
                _ = succ_bi.predecessors.swapRemove(i);
                break;
            }
        }
    }
    bi.predecessors.clearRetainingCapacity();
    bi.successors.clearRetainingCapacity();
}
