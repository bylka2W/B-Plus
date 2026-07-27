const std = @import("std");
const Allocator = std.mem.Allocator;
const thir = @import("../thir.zig");
const BlockId = thir.BlockId;

pub const Reachability = struct {
    reachable: std.AutoHashMap(u32, void),

    pub fn init(allocator: Allocator) Reachability {
        return .{
            .reachable = std.AutoHashMap(u32, void).init(allocator),
        };
    }

    pub fn deinit(self: *Reachability) void {
        self.reachable.deinit();
    }

    pub fn isReachable(self: *const Reachability, block: BlockId) bool {
        return self.reachable.contains(block.index);
    }

    pub fn reachableCount(self: *const Reachability) u32 {
        return @intCast(self.reachable.count());
    }
};

pub fn computeReachability(allocator: Allocator, function: *const thir.ThirFunction) !Reachability {
    var result = Reachability.init(allocator);
    errdefer result.deinit();

    const body = function.body orelse return result;

    if (body.blocks.len == 0) return result;

    // BFS from entry block
    var queue = std.ArrayList(BlockId).init(allocator);
    defer queue.deinit();

    try queue.append(body.entry);
    try result.reachable.put(body.entry.index, {});

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        const block = &body.blocks[current.index];

        switch (block.terminator) {
            .br => |target| {
                if (!result.reachable.contains(target.index)) {
                    try result.reachable.put(target.index, {});
                    try queue.append(target);
                }
            },
            .cond_br => |cb| {
                if (!result.reachable.contains(cb.then.index)) {
                    try result.reachable.put(cb.then.index, {});
                    try queue.append(cb.then);
                }
                if (!result.reachable.contains(cb.else_.index)) {
                    try result.reachable.put(cb.else_.index, {});
                    try queue.append(cb.else_);
                }
            },
            .switch_br => |sw| {
                for (sw.cases) |c| {
                    if (!result.reachable.contains(c.target.index)) {
                        try result.reachable.put(c.target.index, {});
                        try queue.append(c.target);
                    }
                }
                if (sw.default) |d| {
                    if (!result.reachable.contains(d.index)) {
                        try result.reachable.put(d.index, {});
                        try queue.append(d);
                    }
                }
            },
            .return_ret => {},
            .unreachable_term => {},
            .diverge => {},
        }
    }

    return result;
}

pub fn findUnreachableBlocks(allocator: Allocator, function: *const thir.ThirFunction) !std.ArrayList(BlockId) {
    const reach = try computeReachability(allocator, function);
    defer reach.deinit();

    var unreachable_blocks = std.ArrayList(BlockId).init(allocator);

    const body = function.body orelse return unreachable_blocks;

    for (body.blocks, 0..) |_, i| {
        const blk = BlockId.new(@intCast(i));
        if (!reach.isReachable(blk)) {
            try unreachable_blocks.append(blk);
        }
    }

    return unreachable_blocks;
}
