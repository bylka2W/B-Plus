const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../../bir.zig");
const bir_cfg = @import("../cfg/cfg.zig");
const INVALID_ID = bir.INVALID_ID;
const BlockId = bir.BlockId;
const Function = bir.Function;

pub const DominatorTree = struct {
    allocator: ?std.mem.Allocator,
    idom: []const BlockId,
    children: []const []const BlockId,
    depth: []const u32,
    _child_data: []const BlockId,

    pub fn deinit(self: *DominatorTree) void {
        const aa = self.allocator orelse return;
        aa.free(self.idom);
        aa.free(self.children);
        aa.free(self.depth);
        aa.free(self._child_data);
    }

    pub fn dominates(self: *const DominatorTree, a: BlockId, b: BlockId) bool {
        if (a == b) return true;
        var cur = b;
        while (cur != INVALID_ID) {
            if (cur == a) return true;
            cur = self.idom[cur];
        }
        return false;
    }

    pub fn strictlyDominates(self: *const DominatorTree, a: BlockId, b: BlockId) bool {
        if (a == b) return false;
        var cur = self.idom[b];
        while (cur != INVALID_ID) {
            if (cur == a) return true;
            cur = self.idom[cur];
        }
        return false;
    }

    pub fn getImmediateDominator(self: *const DominatorTree, block: BlockId) BlockId {
        return self.idom[block];
    }

    pub fn getDepth(self: *const DominatorTree, block: BlockId) u32 {
        return self.depth[block];
    }
};

pub const DominanceFrontier = struct {
    allocator: ?std.mem.Allocator,
    offsets: []const u32,
    nodes: []const BlockId,

    pub fn deinit(self: *DominanceFrontier) void {
        const aa = self.allocator orelse return;
        aa.free(self.offsets);
        aa.free(self.nodes);
    }

    pub fn get(self: *const DominanceFrontier, block: BlockId) []const BlockId {
        const start = self.offsets[block];
        const end = self.offsets[block + 1];
        return self.nodes[start..end];
    }

    pub fn contains(self: *const DominanceFrontier, block: BlockId, target: BlockId) bool {
        for (self.get(block)) |dfb| if (dfb == target) return true;
        return false;
    }
};

fn compress(anc: []BlockId, best: []BlockId, semi: []u32, dfs_order: []u32, v: BlockId) BlockId {
    if (anc[v] == INVALID_ID) return v;
    if (anc[anc[v]] != INVALID_ID) {
        const root = compress(anc, best, semi, dfs_order, anc[v]);
        if (dfs_order[semi[best[anc[v]]]] < dfs_order[semi[best[v]]]) {
            best[v] = best[anc[v]];
        }
        anc[v] = root;
    }
    return anc[v];
}

pub fn buildDominators(allocator: Allocator, cfg: *const bir_cfg.CFG, func: *const Function) !DominatorTree {
    const n = func.blocks.items.len;
    if (n == 0) {
        return DominatorTree{ .allocator = allocator, .idom = &.{}, .children = &.{}, .depth = &.{}, ._child_data = &.{} };
    }

    const Entry = cfg.entry;
    const parent = try allocator.alloc(BlockId, n);
    const semi = try allocator.alloc(u32, n);
    const idom = try allocator.alloc(BlockId, n);
    const vertex = try allocator.alloc(BlockId, n);
    const ancestor = try allocator.alloc(BlockId, n);
    const best = try allocator.alloc(BlockId, n);
    const bucket = try allocator.alloc(std.ArrayList(BlockId), n);
    const preds = try allocator.alloc(std.ArrayList(BlockId), n);

    for (0..n) |i| {
        idom[i] = INVALID_ID;
        semi[i] = @as(u32, @intCast(i));
        parent[i] = INVALID_ID;
        ancestor[i] = INVALID_ID;
        best[i] = @as(BlockId, @intCast(i));
        vertex[i] = INVALID_ID;
        bucket[i] = std.ArrayList(BlockId).init(allocator);
        preds[i] = std.ArrayList(BlockId).init(allocator);
    }

    for (0..n) |i| {
        const bid = @as(BlockId, @intCast(i));
        for (func.blocks.items[bid].succs.items) |succ| {
            try preds[succ].append(bid);
        }
    }

    var stack = std.ArrayList(BlockId).init(allocator);
    defer stack.deinit();
    try stack.append(Entry);

    const vis = try allocator.alloc(bool, n);
    defer allocator.free(vis);
    @memset(vis, false);
    vis[Entry] = true;

    var df_count: u32 = 0;
    while (stack.items.len > 0) {
        const v = stack.pop().?;
        vertex[df_count] = v;
        df_count += 1;
        for (func.blocks.items[v].succs.items) |succ| {
            if (!vis[succ]) {
                vis[succ] = true;
                parent[succ] = v;
                try stack.append(succ);
            }
        }
    }

    const dfs_order = try allocator.alloc(u32, n);
    defer allocator.free(dfs_order);
    for (0..df_count) |i| {
        dfs_order[vertex[i]] = @as(u32, @intCast(i));
    }

    {
        var i: u32 = df_count;
        while (i > 0) {
            i -= 1;
            const w = vertex[i];
            if (w == Entry) continue;

            for (preds[w].items) |v| {
                var u = v;
                if (dfs_order[u] == INVALID_ID) continue;
                if (dfs_order[u] > dfs_order[w]) {
                    _ = compress(ancestor, best, semi, dfs_order, u);
                    u = best[u];
                }
                if (dfs_order[semi[u]] < dfs_order[semi[w]]) {
                    semi[w] = semi[u];
                }
            }

            try bucket[semi[w]].append(w);

            const p = parent[w];
            if (p != INVALID_ID) {
                ancestor[w] = p;
                for (bucket[p].items) |v| {
                    _ = compress(ancestor, best, semi, dfs_order, v);
                    if (semi[best[v]] == semi[v]) {
                        idom[v] = p;
                    } else {
                        idom[v] = best[v];
                    }
                }
                bucket[p].clearRetainingCapacity();
            }
        }
    }

    for (1..df_count) |idx| {
        const w = vertex[idx];
        if (w == Entry) continue;
        if (idom[w] != @as(BlockId, @intCast(semi[w]))) {
            idom[w] = idom[idom[w]];
        }
    }
    idom[Entry] = INVALID_ID;

    for (0..n) |j| {
        bucket[j].deinit();
        preds[j].deinit();
    }
    allocator.free(bucket);
    allocator.free(preds);
    allocator.free(ancestor);
    allocator.free(best);
    allocator.free(semi);
    allocator.free(vertex);
    allocator.free(parent);

    const child_count = try allocator.alloc(usize, n);
    defer allocator.free(child_count);
    @memset(child_count, 0);
    for (idom) |p| {
        if (p != INVALID_ID) child_count[p] = child_count[p] + 1;
    }

    const write_pos = try allocator.alloc(usize, n);
    var total: usize = 0;
    for (0..n) |i| {
        write_pos[i] = total;
        total += child_count[i];
    }

    const flat = try allocator.alloc(BlockId, total);
    for (idom, 0..) |p, bid| {
        if (p == INVALID_ID) continue;
        flat[write_pos[p]] = @as(BlockId, @intCast(bid));
        write_pos[p] += 1;
    }

    const children = try allocator.alloc([]const BlockId, n);
    for (0..n) |i| {
        children[i] = flat[write_pos[i] - child_count[i] .. write_pos[i]];
    }
    allocator.free(write_pos);

    const depth = try allocator.alloc(u32, n);
    @memset(depth, 0);
    for (0..n) |bid| {
        var cur = idom[bid];
        while (cur != INVALID_ID) {
            depth[bid] += 1;
            cur = idom[cur];
        }
    }

    return DominatorTree{ .allocator = allocator, .idom = idom, .children = children, .depth = depth, ._child_data = flat };
}

pub fn buildDominanceFrontiers(allocator: Allocator, cfg: *const bir_cfg.CFG, func: *const Function, dom_tree: *const DominatorTree) !DominanceFrontier {
    const n = func.blocks.items.len;
    if (n == 0) return DominanceFrontier{ .allocator = allocator, .offsets = &.{}, .nodes = &.{} };

    const lists = try allocator.alloc(std.ArrayList(BlockId), n);
    for (0..n) |i| {
        lists[i] = std.ArrayList(BlockId).init(allocator);
    }

    for (0..n) |i| {
        const bid = @as(BlockId, @intCast(i));
        for (func.blocks.items[bid].succs.items) |succ| {
            if (!dom_tree.strictlyDominates(bid, succ)) {
                try lists[bid].append(succ);
            }
        }
    }

    var po = std.ArrayList(BlockId).init(allocator);
    defer po.deinit();
    const vis = try allocator.alloc(bool, n);
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
        for (dom_tree.children[top]) |child| try stack.append(child);
    }
    for (0..po.items.len / 2) |k| {
        const a = po.items[k];
        const b = po.items[po.items.len - 1 - k];
        po.items[k] = b;
        po.items[po.items.len - 1 - k] = a;
    }

    for (po.items) |bid| {
        for (dom_tree.children[bid]) |child| {
            for (lists[child].items) |x| {
                if (!dom_tree.strictlyDominates(bid, x)) {
                    try lists[bid].append(x);
                }
            }
        }
    }

    const offsets = try allocator.alloc(u32, n + 1);
    offsets[0] = 0;
    for (0..n) |i| {
        offsets[i + 1] = offsets[i] + @as(u32, @intCast(lists[i].items.len));
    }
    const nodes = try allocator.alloc(BlockId, offsets[n]);
    for (0..n) |i| {
        @memcpy(nodes[offsets[i]..offsets[i + 1]], lists[i].items);
        lists[i].deinit();
    }
    allocator.free(lists);

    return DominanceFrontier{ .allocator = allocator, .offsets = offsets, .nodes = nodes };
}
