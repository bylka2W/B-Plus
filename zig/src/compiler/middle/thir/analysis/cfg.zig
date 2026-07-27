const std = @import("std");
const Allocator = std.mem.Allocator;
const thir = @import("../thir.zig");
const ValueId = thir.ValueId;
const BlockId = thir.BlockId;
const INVALID_BLOCK = thir.INVALID_BLOCK;

// ─── Edge types ───
pub const EdgeKind = enum {
    normal,
    true_branch,
    false_branch,
    switch_case,
    fallthrough,
};

pub const Edge = struct {
    from: BlockId,
    to: BlockId,
    kind: EdgeKind,
};

// ─── CFG ───
pub const Cfg = struct {
    allocator: Allocator,
    block_count: u32,
    predecessors: []const []const BlockId,
    successors: []const []const BlockId,
    edges: []const Edge,
    reverse_post_order: []const BlockId,
    idom: []const BlockId,
    tree_children: []const []const BlockId,
    dominated_by: []const []const BlockId,

    pub fn deinit(self: *Cfg) void {
        for (self.predecessors) |list| {
            if (list.len > 0) self.allocator.free(list);
        }
        self.allocator.free(self.predecessors);

        for (self.successors) |list| {
            if (list.len > 0) self.allocator.free(list);
        }
        self.allocator.free(self.successors);

        if (self.edges.len > 0) self.allocator.free(self.edges);
        if (self.reverse_post_order.len > 0) self.allocator.free(self.reverse_post_order);
        if (self.idom.len > 0) self.allocator.free(self.idom);

        for (self.tree_children) |list| {
            if (list.len > 0) self.allocator.free(list);
        }
        self.allocator.free(self.tree_children);

        for (self.dominated_by) |list| {
            if (list.len > 0) self.allocator.free(list);
        }
        self.allocator.free(self.dominated_by);
    }

    /// Does block a dominate block b?
    pub fn dominates(self: *const Cfg, a: BlockId, b: BlockId) bool {
        if (a.index == b.index) return true;
        var current = b;
        while (current.isValid()) {
            const dom = self.idom[current.index];
            if (!dom.isValid()) return false;
            if (dom.index == a.index) return true;
            if (dom.index == current.index) break;
            current = dom;
        }
        return false;
    }

    /// Is block a reachable from entry?
    pub fn isReachable(self: *const Cfg, block: BlockId) bool {
        for (self.reverse_post_order) |rpo_block| {
            if (rpo_block.index == block.index) return true;
        }
        return false;
    }
};

// ─── Build ───

pub fn buildCfg(allocator: Allocator, func: *const thir.ThirFunction) !Cfg {
    const body = func.body orelse return emptyCfg(allocator);

    const n: u32 = @intCast(body.blocks.len);
    if (n == 0) return emptyCfg(allocator);
    if (!body.entry.isValid() or body.entry.index >= n) return emptyCfg(allocator);

    // Build successor/predecessor/edge lists
    var succ_lists = try allocator.alloc(std.ArrayList(BlockId), n);
    errdefer {
        for (succ_lists) |*s| s.deinit();
        allocator.free(succ_lists);
    }

    var pred_lists = try allocator.alloc(std.ArrayList(BlockId), n);
    errdefer {
        for (pred_lists) |*p| p.deinit();
        allocator.free(pred_lists);
    }

    var edge_list = std.ArrayList(Edge).init(allocator);
    errdefer edge_list.deinit();

    for (succ_lists) |*s| s.* = std.ArrayList(BlockId).init(allocator);
    for (pred_lists) |*p| p.* = std.ArrayList(BlockId).init(allocator);

    for (body.blocks, 0..) |block, i| {
        const from = BlockId.new(@intCast(i));
        switch (block.terminator) {
            .br => |target| {
                try succ_lists[from.index].append(target);
                try pred_lists[target.index].append(from);
                try edge_list.append(.{ .from = from, .to = target, .kind = .normal });
            },
            .cond_br => |cb| {
                try succ_lists[from.index].append(cb.then);
                try succ_lists[from.index].append(cb.else_);
                try pred_lists[cb.then.index].append(from);
                try pred_lists[cb.else_.index].append(from);
                try edge_list.append(.{ .from = from, .to = cb.then, .kind = .true_branch });
                try edge_list.append(.{ .from = from, .to = cb.else_, .kind = .false_branch });
            },
            .switch_br => |sw| {
                for (sw.cases) |c| {
                    try succ_lists[from.index].append(c.target);
                    try pred_lists[c.target.index].append(from);
                    try edge_list.append(.{ .from = from, .to = c.target, .kind = .switch_case });
                }
                if (sw.default) |d| {
                    try succ_lists[from.index].append(d);
                    try pred_lists[d.index].append(from);
                    try edge_list.append(.{ .from = from, .to = d, .kind = .switch_case });
                }
            },
            .return_ret => {},
            .unreachable_term => {},
            .diverge => {},
        }
    }

    // Convert to owned slices
    var pred_slices = try allocator.alloc([]const BlockId, n);
    errdefer allocator.free(pred_slices);
    for (pred_lists, 0..) |*p, i| {
        pred_slices[i] = try p.toOwnedSlice();
    }

    var succ_slices = try allocator.alloc([]const BlockId, n);
    errdefer allocator.free(succ_slices);
    for (succ_lists, 0..) |*s, i| {
        succ_slices[i] = try s.toOwnedSlice();
    }

    // Free the temporary ArrayList arrays (contents transferred to slices above)
    for (succ_lists) |*s| s.deinit();
    allocator.free(succ_lists);
    for (pred_lists) |*p| p.deinit();
    allocator.free(pred_lists);

    const edges = try edge_list.toOwnedSlice();

    // Compute reverse post order (only reachable blocks)
    const rpo = try computeRpo(allocator, body.entry, succ_slices);
    errdefer if (rpo.len > 0) allocator.free(rpo);

    // Compute immediate dominators using iterative algorithm
    const idom = try computeIdom(allocator, rpo, pred_slices, n);
    errdefer if (idom.len > 0) allocator.free(idom);

    // Build dominator tree children
    const tree_children = try buildDominatorTree(allocator, idom, n);
    errdefer {
        for (tree_children) |list| {
            if (list.len > 0) allocator.free(list);
        }
        allocator.free(tree_children);
    }

    // Build dominated_by lists
    const dominated_by = try buildDominatedBy(allocator, tree_children, n);

    return Cfg{
        .allocator = allocator,
        .block_count = n,
        .predecessors = pred_slices,
        .successors = succ_slices,
        .edges = edges,
        .reverse_post_order = rpo,
        .idom = idom,
        .tree_children = tree_children,
        .dominated_by = dominated_by,
    };
}

fn emptyCfg(allocator: Allocator) Cfg {
    return Cfg{
        .allocator = allocator,
        .block_count = 0,
        .predecessors = &.{},
        .successors = &.{},
        .edges = &.{},
        .reverse_post_order = &.{},
        .idom = &.{},
        .tree_children = &.{},
        .dominated_by = &.{},
    };
}

// ─── RPO computation ───
// Postorder: visit children first, then append self.
// RPO: reverse postorder = reverse of postorder.

fn computeRpo(allocator: Allocator, entry: BlockId, succs: []const []const BlockId) ![]const BlockId {
    var visited = std.AutoHashMap(u32, void).init(allocator);
    defer visited.deinit();

    var postorder = std.ArrayList(BlockId).init(allocator);
    defer postorder.deinit();

    try dfsPostorder(entry, succs, &visited, &postorder);

    // Reverse to get RPO
    std.mem.reverse(BlockId, postorder.items);
    return try postorder.toOwnedSlice();
}

fn dfsPostorder(
    current: BlockId,
    succs: []const []const BlockId,
    visited: *std.AutoHashMap(u32, void),
    postorder: *std.ArrayList(BlockId),
) !void {
    if (visited.contains(current.index)) return;
    try visited.put(current.index, {});

    // Visit successors first (postorder)
    if (current.index < succs.len) {
        for (succs[current.index]) |succ| {
            try dfsPostorder(succ, succs, visited, postorder);
        }
    }

    // Then append self
    try postorder.append(current);
}

// ─── Immediate dominator computation ───
// Cooper-Harvey-Kennedy iterative algorithm.

fn computeIdom(allocator: Allocator, rpo: []const BlockId, preds: []const []const BlockId, n: u32) ![]const BlockId {
    // idom[entry] = entry; idom[x] = UNDEFINED for all others
    var idom = try allocator.alloc(BlockId, n);
    for (idom) |*d| d.* = INVALID_BLOCK;
    idom[rpo[0].index] = rpo[0];

    var changed = true;
    while (changed) {
        changed = false;
        // Skip entry block (index 0 in RPO)
        var i: usize = 1;
        while (i < rpo.len) : (i += 1) {
            const b = rpo[i];
            var new_idom: BlockId = INVALID_BLOCK;

            // Find first predecessor with computed idom
            if (b.index < preds.len) {
                for (preds[b.index]) |p| {
                    if (idom[p.index].isValid()) {
                        new_idom = p;
                        break;
                    }
                }
            }

            if (new_idom.isValid()) {
                // Intersect with other predecessors
                if (b.index < preds.len) {
                    for (preds[b.index]) |p| {
                        if (idom[p.index].isValid() and p.index != new_idom.index) {
                            new_idom = intersectIdom(idom, new_idom, p, rpo);
                        }
                    }
                }
            }

            if (!idom[b.index].isValid() or idom[b.index].index != new_idom.index) {
                idom[b.index] = new_idom;
                changed = true;
            }
        }
    }

    return idom;
}

fn intersectIdom(idom: []const BlockId, b1: BlockId, b2: BlockId, rpo: []const BlockId) BlockId {
    var finger1 = b1;
    var finger2 = b2;

    while (finger1.index != finger2.index) {
        while (rpoIndex(rpo, finger1) > rpoIndex(rpo, finger2)) {
            finger1 = idom[finger1.index];
            if (!finger1.isValid()) return finger2;
        }
        while (rpoIndex(rpo, finger2) > rpoIndex(rpo, finger1)) {
            finger2 = idom[finger2.index];
            if (!finger2.isValid()) return finger1;
        }
    }
    return finger1;
}

fn rpoIndex(rpo: []const BlockId, block: BlockId) usize {
    for (rpo, 0..) |b, i| {
        if (b.index == block.index) return i;
    }
    return std.math.maxInt(usize);
}

// ─── Dominator tree construction ───

fn buildDominatorTree(allocator: Allocator, idom: []const BlockId, n: u32) ![]const []const BlockId {
    var children = try allocator.alloc(std.ArrayList(BlockId), n);
    errdefer {
        for (children) |*c| c.deinit();
        allocator.free(children);
    }

    for (children) |*c| c.* = std.ArrayList(BlockId).init(allocator);

    for (idom, 0..) |d, i| {
        if (d.isValid() and i != d.index) {
            try children[d.index].append(BlockId.new(@intCast(i)));
        }
    }

    var result = try allocator.alloc([]const BlockId, n);
    for (children, 0..) |*c, i| {
        result[i] = try c.toOwnedSlice();
    }

    for (children) |*c| c.deinit();
    allocator.free(children);

    return result;
}

fn buildDominatedBy(allocator: Allocator, tree_children: []const []const BlockId, n: u32) ![]const []const BlockId {
    var dominated = try allocator.alloc(std.ArrayList(BlockId), n);
    errdefer {
        for (dominated) |*d| d.deinit();
        allocator.free(dominated);
    }

    for (dominated) |*d| d.* = std.ArrayList(BlockId).init(allocator);

    for (tree_children, 0..) |children, i| {
        try collectDominated(@intCast(i), children, tree_children, &dominated[i]);
    }

    var result = try allocator.alloc([]const BlockId, n);
    for (dominated, 0..) |*d, i| {
        result[i] = try d.toOwnedSlice();
    }

    for (dominated) |*d| d.deinit();
    allocator.free(dominated);

    return result;
}

fn collectDominated(
    current: u32,
    children: []const BlockId,
    tree_children: []const []const BlockId,
    result: *std.ArrayList(BlockId),
) !void {
    _ = current;
    for (children) |child| {
        try result.append(child);
        if (child.index < tree_children.len) {
            try collectDominated(child.index, tree_children[child.index], tree_children, result);
        }
    }
}

// ─── Dominance frontier ───

pub const DominanceFrontier = struct {
    df: []const []const BlockId,

    pub fn deinit(self: *DominanceFrontier, allocator: Allocator) void {
        for (self.df) |list| {
            if (list.len > 0) allocator.free(list);
        }
        allocator.free(self.df);
    }

    pub fn get(self: *const DominanceFrontier, block: BlockId) []const BlockId {
        if (block.index < self.df.len) return self.df[block.index];
        return &.{};
    }
};

pub fn computeDF(allocator: Allocator, cfg: *const Cfg) !DominanceFrontier {
    var df_lists = try allocator.alloc(std.ArrayList(BlockId), cfg.block_count);
    errdefer {
        for (df_lists) |*d| d.deinit();
        allocator.free(df_lists);
    }

    for (df_lists) |*d| d.* = std.ArrayList(BlockId).init(allocator);

    for (0..cfg.block_count) |i| {
        const b = BlockId.new(@intCast(i));

        // If b has multiple predecessors, it is a join point
        if (b.index < cfg.predecessors.len and cfg.predecessors[b.index].len >= 2) {
            for (cfg.predecessors[b.index]) |p| {
                // Walk up dominator tree from p until we reach idom(b)
                var runner = p;
                while (runner.isValid() and runner.index != cfg.idom[b.index].index) {
                    try df_lists[runner.index].append(b);
                    runner = cfg.idom[runner.index];
                }
            }
        }
    }

    var result = try allocator.alloc([]const BlockId, cfg.block_count);
    for (df_lists, 0..) |*d, i| {
        result[i] = try d.toOwnedSlice();
    }

    for (df_lists) |*d| d.deinit();
    allocator.free(df_lists);

    return .{ .df = result };
}

// ─── Loop detection ───

pub const LoopInfo = struct {
    header: BlockId,
    back_edges: []const Edge,
};

pub fn findLoops(allocator: Allocator, cfg: *const Cfg) ![]const LoopInfo {
    var loops = std.ArrayList(LoopInfo).init(allocator);
    defer loops.deinit();

    for (cfg.edges) |edge| {
        // A back edge: target dominates source
        if (cfg.dominates(edge.to, edge.from)) {
            try loops.append(.{
                .header = edge.to,
                .back_edges = &.{},
            });
        }
    }

    return try loops.toOwnedSlice();
}

// ─── Tests ───

test "Cfg: empty function" {
    const func = thir.ThirFunction{
        .name = .{ .index = 0 },
        .def_id = .{ .index = 0 },
        .params = &.{},
        .return_type = .{ .index = 0 },
        .body = null,
        .linkage = .internal,
    };

    var cfg = try buildCfg(std.testing.allocator, &func);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 0), cfg.block_count);
}

test "Cfg: linear chain entry -> b1 -> exit" {
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

    var cfg = try buildCfg(std.testing.allocator, &func);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 2), cfg.block_count);
    try std.testing.expectEqual(@as(usize, 2), cfg.reverse_post_order.len);

    // idom[entry] = entry
    try std.testing.expectEqual(BlockId.new(0), cfg.idom[0]);
}

test "Cfg: if-merge diamond" {
    // entry -> then, entry -> else, then -> merge, else -> merge
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(1), .else_ = BlockId.new(2) } } },
        .{ .label = "then", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "else", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "merge", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
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

    var cfg = try buildCfg(std.testing.allocator, &func);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 4), cfg.block_count);

    // idom[then] = entry, idom[else] = entry, idom[merge] = entry
    try std.testing.expectEqual(BlockId.new(0), cfg.idom[1]);
    try std.testing.expectEqual(BlockId.new(0), cfg.idom[2]);
    try std.testing.expectEqual(BlockId.new(0), cfg.idom[3]);

    // entry dominates all
    try std.testing.expect(cfg.dominates(BlockId.new(0), BlockId.new(1)));
    try std.testing.expect(cfg.dominates(BlockId.new(0), BlockId.new(2)));
    try std.testing.expect(cfg.dominates(BlockId.new(0), BlockId.new(3)));
}

test "Cfg: loop header dominates body" {
    // entry -> header, header -> body, body -> header, header -> exit
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .br = BlockId.new(1) } },
        .{ .label = "header", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(2), .else_ = BlockId.new(3) } } },
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

    var cfg = try buildCfg(std.testing.allocator, &func);
    defer cfg.deinit();

    // header dominates body
    try std.testing.expect(cfg.dominates(BlockId.new(1), BlockId.new(2)));
    // entry dominates header
    try std.testing.expect(cfg.dominates(BlockId.new(0), BlockId.new(1)));
    // entry dominates body
    try std.testing.expect(cfg.dominates(BlockId.new(0), BlockId.new(2)));
}

test "Cfg: unreachable block not in RPO" {
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
        .{ .label = "dead", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
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

    var cfg = try buildCfg(std.testing.allocator, &func);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.reverse_post_order.len);
    try std.testing.expect(cfg.isReachable(BlockId.new(0)));
    try std.testing.expect(!cfg.isReachable(BlockId.new(1)));
}

test "Cfg: edges have correct kinds" {
    const blocks = [_]thir.BasicBlock{
        .{ .label = "entry", .stmts = &.{}, .terminator = .{ .cond_br = .{ .cond = ValueId.new(0), .then = BlockId.new(1), .else_ = BlockId.new(2) } } },
        .{ .label = "then", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "else", .stmts = &.{}, .terminator = .{ .br = BlockId.new(3) } },
        .{ .label = "merge", .stmts = &.{}, .terminator = .{ .return_ret = .{ .value = null } } },
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

    var cfg = try buildCfg(std.testing.allocator, &func);
    defer cfg.deinit();

    // Should have 5 edges: entry->then, entry->else, then->merge, else->merge
    try std.testing.expectEqual(@as(usize, 4), cfg.edges.len);
    try std.testing.expectEqual(EdgeKind.true_branch, cfg.edges[0].kind);
    try std.testing.expectEqual(EdgeKind.false_branch, cfg.edges[1].kind);
    try std.testing.expectEqual(EdgeKind.normal, cfg.edges[2].kind);
    try std.testing.expectEqual(EdgeKind.normal, cfg.edges[3].kind);
}
