const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("bir.zig");
const bir_cfg = @import("bir_cfg.zig");
const INVALID_ID = bir.INVALID_ID;
const BlockId = bir.BlockId;

pub const DominatorTree = struct {
    allocator: Allocator,
    idom: []BlockId,
    children: [][]BlockId,
    dom_sets: [][]bool,

    pub fn deinit(self: *DominatorTree) void {
        self.allocator.free(self.idom);
        for (self.children) |c| self.allocator.free(c);
        self.allocator.free(self.children);
        for (self.dom_sets) |ds| self.allocator.free(ds);
        self.allocator.free(self.dom_sets);
    }

    pub fn dominates(self: *const DominatorTree, a: BlockId, b: BlockId) bool {
        var cur = b;
        while (true) {
            if (cur == a) return true;
            if (cur == INVALID_ID) return false;
            cur = self.idom[cur];
        }
    }

    pub fn strictlyDominates(self: *const DominatorTree, a: BlockId, b: BlockId) bool {
        if (a == b) return false;
        return self.dominates(a, b);
    }

    pub fn getImmediateDominator(self: *const DominatorTree, block: BlockId) BlockId {
        return self.idom[block];
    }

    pub fn dump(self: *const DominatorTree, writer: anytype, nblocks: usize) !void {
        try writer.writeAll("; Dominator Tree\n");
        for (0..nblocks) |i| {
            const bid = @as(BlockId, @intCast(i));
            try writer.print("  block_{d}: idom=", .{bid});
            if (self.idom[bid] == INVALID_ID) {
                try writer.writeAll("(none)");
            } else {
                try writer.print("{d}", .{self.idom[bid]});
            }
            if (self.children[bid].len > 0) {
                try writer.writeAll(" children=[");
                for (self.children[bid], 0..) |c, ci| {
                    if (ci > 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{c});
                }
                try writer.writeAll("]");
            }
            try writer.writeAll("\n");
        }
    }
};

// ─── Dominance Frontier ───

pub const DominanceFrontier = struct {
    allocator: Allocator,
    df: [][]BlockId,

    pub fn deinit(self: *DominanceFrontier) void {
        for (self.df) |list| self.allocator.free(list);
        self.allocator.free(self.df);
    }

    pub fn get(self: *const DominanceFrontier, block: BlockId) []const BlockId {
        return self.df[block];
    }

    pub fn contains(self: *const DominanceFrontier, block: BlockId, target: BlockId) bool {
        for (self.df[block]) |dfb| {
            if (dfb == target) return true;
        }
        return false;
    }

    pub fn dump(self: *const DominanceFrontier, writer: anytype) !void {
        try writer.writeAll("; Dominance Frontiers\n");
        for (self.df, 0..) |list, i| {
            try writer.print("  block_{d}: [", .{i});
            for (list, 0..) |dfb, di| {
                if (di > 0) try writer.writeAll(", ");
                try writer.print("{d}", .{dfb});
            }
            try writer.writeAll("]\n");
        }
    }
};

pub fn buildDominanceFrontiers(allocator: Allocator, cfg: *const bir_cfg.CFG, dom_tree: *const DominatorTree) !DominanceFrontier {
    const n = cfg.blocks.items.len;
    var df_lists = try allocator.alloc(std.ArrayList(BlockId), n);
    for (0..n) |i| {
        df_lists[i] = std.ArrayList(BlockId).init(allocator);
    }

    for (0..n) |i| {
        const bid = @as(BlockId, @intCast(i));
        for (cfg.get(bid).successors.items) |succ| {
            if (!dom_tree.strictlyDominates(bid, succ)) {
                try df_lists[bid].append(succ);
            }
        }
    }

    var po = std.ArrayList(BlockId).init(allocator);
    defer po.deinit();
    var vis = try allocator.alloc(bool, n);
    defer allocator.free(vis);
    @memset(vis, false);
    var stack = std.ArrayList(BlockId).init(allocator);
    defer stack.deinit();
    try stack.append(cfg.entry);
    while (stack.items.len > 0) {
        const top = stack.pop().?;
        if (vis[top]) continue;
        vis[top] = true;
        try po.append(top);
        for (dom_tree.children[top]) |child| {
            try stack.append(child);
        }
    }
    for (0..po.items.len / 2) |k| {
        const a = po.items[k];
        const b = po.items[po.items.len - 1 - k];
        po.items[k] = b;
        po.items[po.items.len - 1 - k] = a;
    }

    for (po.items) |bid| {
        for (dom_tree.children[bid]) |child| {
            for (df_lists[child].items) |x| {
                if (!dom_tree.strictlyDominates(bid, x)) {
                    try df_lists[bid].append(x);
                }
            }
        }
    }

    var result_df = try allocator.alloc([]BlockId, n);
    for (0..n) |i| {
        result_df[i] = try allocator.dupe(BlockId, df_lists[i].items);
        df_lists[i].deinit();
    }
    allocator.free(df_lists);

    return DominanceFrontier{
        .allocator = allocator,
        .df = result_df,
    };
}

pub fn buildDominators(allocator: Allocator, cfg: *const bir_cfg.CFG) !DominatorTree {
    const n = cfg.blocks.items.len;
    if (n == 0) {
        return DominatorTree{
            .allocator = allocator,
            .idom = &.{},
            .children = &.{},
            .dom_sets = &.{},
        };
    }

    var dom_sets = try allocator.alloc([]bool, n);
    for (0..n) |i| {
        dom_sets[i] = try allocator.alloc(bool, n);
        if (i == cfg.entry) {
            @memset(dom_sets[i], false);
            dom_sets[i][cfg.entry] = true;
        } else {
            @memset(dom_sets[i], true);
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (cfg.rpo.items) |bid| {
            if (bid == cfg.entry) continue;
            const preds = cfg.get(bid).predecessors.items;
            if (preds.len == 0) continue;

            var new_dom = try allocator.alloc(bool, n);
            @memcpy(new_dom, dom_sets[preds[0]]);
            for (preds[1..]) |pred| {
                for (0..n) |d| {
                    new_dom[d] = new_dom[d] and dom_sets[pred][d];
                }
            }
            new_dom[bid] = true;

            var eq = true;
            for (0..n) |d| {
                if (new_dom[d] != dom_sets[bid][d]) {
                    eq = false;
                    break;
                }
            }
            if (!eq) {
                @memcpy(dom_sets[bid], new_dom);
                changed = true;
            }
            allocator.free(new_dom);
        }
    }

    var idom = try allocator.alloc(BlockId, n);
    @memset(idom, INVALID_ID);
    idom[cfg.entry] = INVALID_ID;

    for (cfg.rpo.items) |bid| {
        if (bid == cfg.entry) continue;
        var best_depth: usize = 0;
        var best: BlockId = INVALID_ID;
        for (0..n) |d| {
            if (!dom_sets[bid][d] or d == bid) continue;
            const dbid = @as(BlockId, @intCast(d));
            var depth: usize = 0;
            for (0..n) |dd| {
                if (dom_sets[dbid][dd]) depth += 1;
            }
            if (depth > best_depth) {
                best_depth = depth;
                best = dbid;
            }
        }
        idom[bid] = best;
    }

    var children = try allocator.alloc([]BlockId, n);
    var child_counts = try allocator.alloc(usize, n);
    @memset(child_counts, 0);
    defer allocator.free(child_counts);

    for (0..n) |i| {
        const p = idom[i];
        if (p != INVALID_ID and p < n) child_counts[p] += 1;
    }
    for (0..n) |i| {
        children[i] = try allocator.alloc(BlockId, child_counts[i]);
    }
    @memset(child_counts, 0);
    for (0..n) |i| {
        const p = idom[i];
        if (p != INVALID_ID and p < n) {
            children[p][child_counts[p]] = @as(BlockId, @intCast(i));
            child_counts[p] += 1;
        }
    }

    return DominatorTree{
        .allocator = allocator,
        .idom = idom,
        .children = children,
        .dom_sets = dom_sets,
    };
}
