const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("bir.zig");
const bir_cfg = @import("bir_cfg.zig");
const bir_dominators = @import("bir_dominators.zig");
const INVALID_ID = bir.INVALID_ID;
const BlockId = bir.BlockId;

pub const Loop = struct {
    header: BlockId,
    back_edges: []bir_cfg.Edge,
    body: []BlockId,
    depth: u32,
};

pub fn findLoops(allocator: Allocator, cfg: *const bir_cfg.CFG, dom_tree: *const bir_dominators.DominatorTree) ![]Loop {
    var loops = std.ArrayList(Loop).init(allocator);
    errdefer {
        for (loops.items) |*lp| {
            allocator.free(lp.back_edges);
            allocator.free(lp.body);
        }
        loops.deinit();
    }

    for (0..cfg.blocks.items.len) |i| {
        const bid = @as(BlockId, @intCast(i));
        const bi = cfg.get(bid);
        for (bi.successors.items) |succ| {
            if (succ >= cfg.blocks.items.len) continue;
            if (succ == bid) continue;
            if (dom_tree.dominates(succ, bid)) {
                const header = succ;
                var body = std.ArrayList(BlockId).init(allocator);
                try body.append(header);
                var visited = try allocator.alloc(bool, cfg.blocks.items.len);
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
                    const curb = cfg.get(cur);
                    for (curb.predecessors.items) |pred| {
                        if (!visited[pred]) try stack.append(pred);
                    }
                }
                const body_sorted = try allocator.dupe(BlockId, body.items);
                const be = try allocator.alloc(bir_cfg.Edge, 1);
                be[0] = .{ .from = bid, .to = succ };
                try loops.append(.{
                    .header = header,
                    .back_edges = be,
                    .body = body_sorted,
                    .depth = 1,
                });
            }
        }
    }

    for (loops.items) |*lp| {
        lp.depth = computeDepth(loops.items, lp.header);
    }

    return loops.toOwnedSlice();
}

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

pub fn dumpLoops(loops: []const Loop, writer: anytype) !void {
    if (loops.len == 0) {
        try writer.writeAll("; Loops: (none)\n");
        return;
    }
    try writer.writeAll("; Loops:\n");
    for (loops, 0..) |lp, i| {
        try writer.print("  loop_{d}: header=block_{d} depth={d}\n", .{ i, lp.header, lp.depth });
        try writer.print("    back_edges: ", .{});
        for (lp.back_edges, 0..) |be, ei| {
            if (ei > 0) try writer.writeAll(", ");
            try writer.print("block_{d} -> block_{d}", .{ be.from, be.to });
        }
        try writer.writeAll("\n    body: [");
        for (lp.body, 0..) |b, bi| {
            if (bi > 0) try writer.writeAll(", ");
            try writer.print("block_{d}", .{b});
        }
        try writer.writeAll("]\n");
    }
}
