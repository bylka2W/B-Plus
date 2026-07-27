const std = @import("std");
const Allocator = std.mem.Allocator;
const thir = @import("../thir.zig");
const cfg_mod = @import("cfg.zig");
const BlockId = thir.BlockId;

pub const NaturalLoop = struct {
    header: BlockId,
    latch: BlockId,
    blocks: []const BlockId,
};

pub const LoopNest = struct {
    allocator: Allocator,
    loops: []const NaturalLoop,

    pub fn deinit(self: *LoopNest) void {
        for (self.loops) |loop| {
            if (loop.blocks.len > 0) self.allocator.free(loop.blocks);
        }
        self.allocator.free(self.loops);
    }

    pub fn getLoopContaining(self: *const LoopNest, block: BlockId) ?NaturalLoop {
        for (self.loops) |loop| {
            for (loop.blocks) |b| {
                if (b.index == block.index) return loop;
            }
        }
        return null;
    }

    pub fn isInnermostLoop(self: *const LoopNest, header: BlockId) bool {
        for (self.loops) |loop| {
            if (loop.header.index != header.index) {
                for (loop.blocks) |b| {
                    if (b.index == header.index) return false;
                }
            }
        }
        return true;
    }
};

pub fn findNaturalLoops(allocator: Allocator, cfg: *const cfg_mod.Cfg) !LoopNest {
    var loops = std.ArrayList(NaturalLoop).init(allocator);
    defer loops.deinit();

    // Find back edges: edge (from → to) where to dominates from
    for (cfg.edges) |edge| {
        if (cfg.dominates(edge.to, edge.from)) {
            // This is a back edge. Build the natural loop.
            const loop_blocks = try buildNaturalLoop(allocator, cfg, edge.from, edge.to);
            try loops.append(.{
                .header = edge.to,
                .latch = edge.from,
                .blocks = loop_blocks,
            });
        }
    }

    return LoopNest{
        .allocator = allocator,
        .loops = try loops.toOwnedSlice(),
    };
}

fn buildNaturalLoop(
    allocator: Allocator,
    cfg: *const cfg_mod.Cfg,
    latch: BlockId,
    header: BlockId,
) ![]const BlockId {
    // The natural loop = header + all blocks that can reach latch
    // without going through header.

    var in_loop = std.AutoHashMap(u32, void).init(allocator);
    defer in_loop.deinit();

    var worklist = std.ArrayList(BlockId).init(allocator);
    defer worklist.deinit();

    // Start with latch and header
    try in_loop.put(header.index, {});
    try in_loop.put(latch.index, {});
    try worklist.append(latch);

    while (worklist.items.len > 0) {
        const current = worklist.orderedRemove(0);

        // Add all predecessors of current that are not yet in the loop
        if (current.index < cfg.predecessors.len) {
            for (cfg.predecessors[current.index]) |pred| {
                if (!in_loop.contains(pred.index)) {
                    try in_loop.put(pred.index, {});
                    try worklist.append(pred);
                }
            }
        }
    }

    // Collect blocks
    var blocks = std.ArrayList(BlockId).init(allocator);
    defer blocks.deinit();

    var iter = in_loop.iterator();
    while (iter.next()) |entry| {
        try blocks.append(BlockId.new(entry.key_ptr.*));
    }

    return try blocks.toOwnedSlice();
}

test "LoopNest: simple loop" {
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "header", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = thir.ValueId.new(0), .then = BlockId.new(2), .else_ = BlockId.new(3) } } },
        .{ .label = "body", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "exit", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };

    const body = thir.ThirFunction.Body{
        .blocks = &blocks,
        .entry = BlockId.new(0),
        .values = &.{},
        .exprs = &.{},
        .places = &.{},
    };

    var func = thir.ThirFunction{
        .name = .{ .index = 0 },
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = .{ .index = 0 },
        .body = body,
        .linkage = .internal,
    };

    var cfg = try cfg_mod.buildCfg(std.testing.allocator, &func);
    defer cfg.deinit();

    var nest = try findNaturalLoops(std.testing.allocator, &cfg);
    defer nest.deinit();

    try std.testing.expectEqual(@as(usize, 1), nest.loops.len);
    try std.testing.expectEqual(BlockId.new(1), nest.loops[0].header);
    try std.testing.expectEqual(BlockId.new(2), nest.loops[0].latch);
}

test "LoopNest: no loop in linear CFG" {
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "b1", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
    };

    const body = thir.ThirFunction.Body{
        .blocks = &blocks,
        .entry = BlockId.new(0),
        .values = &.{},
        .exprs = &.{},
        .places = &.{},
    };

    var func = thir.ThirFunction{
        .name = .{ .index = 0 },
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = .{ .index = 0 },
        .body = body,
        .linkage = .internal,
    };

    var cfg = try cfg_mod.buildCfg(std.testing.allocator, &func);
    defer cfg.deinit();

    var nest = try findNaturalLoops(std.testing.allocator, &cfg);
    defer nest.deinit();

    try std.testing.expectEqual(@as(usize, 0), nest.loops.len);
}
