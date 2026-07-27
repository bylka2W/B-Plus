const std = @import("std");
const Allocator = std.mem.Allocator;
const thir = @import("../thir.zig");
const cfg_mod = @import("cfg.zig");
const ValueId = thir.ValueId;
const BlockId = thir.BlockId;
const INVALID_BLOCK = thir.INVALID_BLOCK;

pub const DominanceTree = struct {
    allocator: Allocator,
    cfg: cfg_mod.Cfg,

    pub fn deinit(self: *DominanceTree) void {
        self.cfg.deinit();
    }

    pub fn dominates(self: *const DominanceTree, a: BlockId, b: BlockId) bool {
        return self.cfg.dominates(a, b);
    }

    pub fn idom(self: *const DominanceTree, block: BlockId) BlockId {
        return self.cfg.idom[block.index];
    }

    pub fn getDF(self: *const DominanceTree, block: BlockId, df: *const cfg_mod.DominanceFrontier) []const BlockId {
        _ = self;
        return df.get(block);
    }

    pub fn isReachable(self: *const DominanceTree, block: BlockId) bool {
        return self.cfg.isReachable(block);
    }
};

pub fn buildDominatorTree(allocator: Allocator, function: *const thir.ThirFunction) !DominanceTree {
    const cfg = try cfg_mod.buildCfg(allocator, function);

    return DominanceTree{
        .allocator = allocator,
        .cfg = cfg,
    };
}

pub fn isValueReachableAt(
    df: *const cfg_mod.DominanceFrontier,
    dom_tree: *const DominanceTree,
    value_def_block: BlockId,
    use_block: BlockId,
) bool {
    // A value is reachable at use_block if value_def_block dominates use_block,
    // OR if use_block is in the dominance frontier of value_def_block.
    if (dom_tree.dominates(value_def_block, use_block)) return true;

    const df_blocks = df.get(value_def_block);
    for (df_blocks) |df_block| {
        if (df_block.index == use_block.index) return true;
    }
    return false;
}

// ─── Tests ───

fn makeFunction(blocks: []const thir.BasicBlock, entry: BlockId) thir.ThirFunction {
    return .{
        .name = .{ .index = 0 },
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = .{ .index = 0 },
        .body = .{
            .blocks = blocks,
            .entry = entry,
            .values = &.{},
            .exprs = &.{},
            .places = &.{},
        },
        .linkage = .internal,
    };
}

test "DominanceTree: same block dominates itself" {
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunction(&blocks, BlockId.new(0));

    var tree = try buildDominatorTree(std.testing.allocator, &func);
    defer tree.deinit();

    try std.testing.expect(tree.dominates(BlockId.new(0), BlockId.new(0)));
}

test "DominanceTree: linear chain" {
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "b1", .stmts = &.{}, .terminator = .{ .br = BlockId.new(2) } },
        .{ .label = "b2", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunction(&blocks, BlockId.new(0));

    var tree = try buildDominatorTree(std.testing.allocator, &func);
    defer tree.deinit();

    // entry dominates all
    try std.testing.expect(tree.dominates(BlockId.new(0), BlockId.new(1)));
    try std.testing.expect(tree.dominates(BlockId.new(0), BlockId.new(2)));

    // b1 dominates b2
    try std.testing.expect(tree.dominates(BlockId.new(1), BlockId.new(2)));

    // b2 does not dominate b1
    try std.testing.expect(!tree.dominates(BlockId.new(2), BlockId.new(1)));
}

test "DominanceTree: diamond does not dominate merge" {
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(1), .else_ = BlockId.new(2) } } },
        .{ .label = "then", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "else", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "merge", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunction(&blocks, BlockId.new(0));

    var tree = try buildDominatorTree(std.testing.allocator, &func);
    defer tree.deinit();

    // entry dominates all
    try std.testing.expect(tree.dominates(BlockId.new(0), BlockId.new(1)));
    try std.testing.expect(tree.dominates(BlockId.new(0), BlockId.new(2)));
    try std.testing.expect(tree.dominates(BlockId.new(0), BlockId.new(3)));

    // then does NOT dominate merge (else is alternative path)
    try std.testing.expect(!tree.dominates(BlockId.new(1), BlockId.new(3)));
    try std.testing.expect(!tree.dominates(BlockId.new(2), BlockId.new(3)));
}

test "DominanceTree: loop header dominates body" {
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "header", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(2), .else_ = BlockId.new(3) } } },
        .{ .label = "body", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "exit", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunction(&blocks, BlockId.new(0));

    var tree = try buildDominatorTree(std.testing.allocator, &func);
    defer tree.deinit();

    // header dominates body
    try std.testing.expect(tree.dominates(BlockId.new(1), BlockId.new(2)));
    // entry dominates header
    try std.testing.expect(tree.dominates(BlockId.new(0), BlockId.new(1)));
    // entry dominates body
    try std.testing.expect(tree.dominates(BlockId.new(0), BlockId.new(2)));
    // header does NOT dominate exit (exit reachable without going through body)
    // Actually: exit is reachable from header via else branch, so header dominates exit
    try std.testing.expect(tree.dominates(BlockId.new(1), BlockId.new(3)));
}

test "DominanceTree: unreachable block" {
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
        .{ .label = "dead", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunction(&blocks, BlockId.new(0));

    var tree = try buildDominatorTree(std.testing.allocator, &func);
    defer tree.deinit();

    try std.testing.expect(tree.isReachable(BlockId.new(0)));
    try std.testing.expect(!tree.isReachable(BlockId.new(1)));
}

test "DominanceTree: idom values" {
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(1), .else_ = BlockId.new(2) } } },
        .{ .label = "then", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "else", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "merge", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };
    var func = makeFunction(&blocks, BlockId.new(0));

    var tree = try buildDominatorTree(std.testing.allocator, &func);
    defer tree.deinit();

    // idom(entry) = entry
    try std.testing.expectEqual(BlockId.new(0), tree.idom(BlockId.new(0)));
    // idom(then) = entry
    try std.testing.expectEqual(BlockId.new(0), tree.idom(BlockId.new(1)));
    // idom(else) = entry
    try std.testing.expectEqual(BlockId.new(0), tree.idom(BlockId.new(2)));
    // idom(merge) = entry
    try std.testing.expectEqual(BlockId.new(0), tree.idom(BlockId.new(3)));
}
