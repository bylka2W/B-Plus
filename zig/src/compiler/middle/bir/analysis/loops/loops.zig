const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../../bir.zig");
const bir_cfg = @import("../cfg/cfg.zig");
const bir_dominators = @import("../dominator/dominator.zig");
const BlockId = bir.BlockId;
const Function = bir.Function;

pub const Loop = struct {
    header: BlockId,
    back_edges: []const bir_cfg.Edge,
    body: []const BlockId,
    depth: u32,
};

pub const LoopInfo = struct {
    loops: []const Loop,
    top_level: []const usize,
    block_map: []const ?usize,
    depth_map: []const u32,

    pub fn contains(self: *const LoopInfo, block: BlockId, loop_idx: usize) bool {
        if (block >= self.block_map.len) return false;
        return self.block_map[block] == loop_idx;
    }

    pub fn getLoopDepth(self: *const LoopInfo, block: BlockId) u32 {
        if (block >= self.depth_map.len) return 0;
        return self.depth_map[block];
    }

    pub fn get(self: *const LoopInfo, idx: usize) *const Loop {
        return &self.loops[idx];
    }

    pub fn deinit(self: *const LoopInfo, allocator: Allocator) void {
        for (self.loops) |lp| {
            allocator.free(lp.back_edges);
            allocator.free(lp.body);
        }
        allocator.free(self.loops);
        allocator.free(self.top_level);
        allocator.free(self.block_map);
        allocator.free(self.depth_map);
    }
};

fn computeDepth(loops: []const Loop, header: BlockId) u32 {
    var depth: u32 = 1;
    for (loops) |other| {
        if (other.header == header) continue;
        for (other.body) |b| {
            if (b == header) {
                const d = computeDepth(loops, other.header) + 1;
                if (d > depth) depth = d;
                break;
            }
        }
    }
    return depth;
}

fn isNested(loops: []const Loop, header: BlockId) bool {
    for (loops) |other| {
        if (other.header == header) continue;
        for (other.body) |b| if (b == header) return true;
    }
    return false;
}

pub fn findLoops(allocator: Allocator, _: *const bir_cfg.CFG, func: *const Function, dom_tree: *const bir_dominators.DominatorTree) !LoopInfo {
    const n = func.blocks.items.len;
    if (n == 0) {
        return LoopInfo{
            .loops = &.{},
            .top_level = &.{},
            .block_map = &.{},
            .depth_map = &.{},
        };
    }

    var raw_loops = std.ArrayList(Loop).init(allocator);
    errdefer {
        for (raw_loops.items) |lp| {
            allocator.free(lp.back_edges);
            allocator.free(lp.body);
        }
        raw_loops.deinit();
    }

    for (0..n) |i| {
        const bid = @as(BlockId, @intCast(i));
        for (func.blocks.items[bid].succs.items) |succ| {
            if (succ >= n or succ == bid) continue;
            if (dom_tree.dominates(succ, bid)) {
                const header = succ;
                var body = std.ArrayList(BlockId).init(allocator);
                try body.append(header);
                const visited = try allocator.alloc(bool, n);
                defer allocator.free(visited);
                @memset(visited, false);
                visited[header] = true;
                var stack = std.ArrayList(BlockId).init(allocator);
                defer stack.deinit();
                try stack.append(bid);
                while (stack.items.len > 0) {
                    const cur = stack.pop().?;
                    if (visited[cur]) continue;
                    visited[cur] = true;
                    try body.append(cur);
                    for (func.blocks.items[cur].preds.items) |pred| {
                        if (!visited[pred]) try stack.append(pred);
                    }
                }
                const body_sorted = try allocator.dupe(BlockId, body.items);
                const be = try allocator.dupe(bir_cfg.Edge, &.{.{ .from = bid, .to = succ }});
                try raw_loops.append(.{
                    .header = header,
                    .back_edges = be,
                    .body = body_sorted,
                    .depth = 1,
                });
            }
        }
    }

    for (raw_loops.items) |*lp| lp.depth = computeDepth(raw_loops.items, lp.header);

    // Pre-allocate the arrays that LoopInfo will own.
    // These may fail; raw_loops errdefer still covers loop bodies.
    const block_map = try allocator.alloc(?usize, n);
    errdefer allocator.free(block_map);
    for (0..n) |j| block_map[j] = null;

    const depth_map = try allocator.alloc(u32, n);
    errdefer allocator.free(depth_map);
    @memset(depth_map, 0);

    for (raw_loops.items, 0..) |lp, idx| {
        for (lp.body) |b| {
            if (block_map[b] == null) block_map[b] = idx;
        }
    }

    for (raw_loops.items) |lp| {
        for (lp.body) |b| {
            if (lp.depth > depth_map[b]) depth_map[b] = lp.depth;
        }
    }

    var top_level = std.ArrayList(usize).init(allocator);
    for (raw_loops.items, 0..) |lp, idx| {
        if (!isNested(raw_loops.items, lp.header)) try top_level.append(idx);
    }

    const top_level_slice = try top_level.toOwnedSlice();
    // raw_loops.toOwnedSlice() is the LAST fallible call — after this,
    // all memory is owned by the returned LoopInfo or is already freed.
    const loops = try raw_loops.toOwnedSlice();

    return LoopInfo{
        .loops = loops,
        .top_level = top_level_slice,
        .block_map = block_map,
        .depth_map = depth_map,
    };
}
