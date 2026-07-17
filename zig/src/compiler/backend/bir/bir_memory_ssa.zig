const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("bir.zig");
const bir_cfg = @import("bir_cfg.zig");
const bir_dominators = @import("bir_dominators.zig");
const bir_alias = @import("bir_alias.zig");
const NO_VALUE = bir.NO_VALUE;
const BlockId = bir.BlockId;
const ValueId = bir.ValueId;

pub const MemOpKey = struct { block: BlockId, idx: u32 };

pub const MemorySSA = struct {
    allocator: Allocator,
    func: *const bir.Function,
    cfg: *const bir_cfg.CFG,
    dom_tree: *const bir_dominators.DominatorTree,

    reaching_def: std.AutoHashMap(MemOpKey, MemOpKey),
    stored_val: std.AutoHashMap(MemOpKey, ValueId),

    pub fn getReachingStore(self: *const MemorySSA, block: BlockId, idx: u32) ?MemOpKey {
        return self.reaching_def.get(.{ .block = block, .idx = idx });
    }

    pub fn getStoredValue(self: *const MemorySSA, store: MemOpKey) ?ValueId {
        return self.stored_val.get(store);
    }
};

pub fn build(allocator: Allocator, func: *const bir.Function, cfg: *const bir_cfg.CFG, dom_tree: *const bir_dominators.DominatorTree) !MemorySSA {
    var ssa = MemorySSA{
        .allocator = allocator,
        .func = func,
        .cfg = cfg,
        .dom_tree = dom_tree,
        .reaching_def = std.AutoHashMap(MemOpKey, MemOpKey).init(allocator),
        .stored_val = std.AutoHashMap(MemOpKey, ValueId).init(allocator),
    };

    const nblocks = cfg.blocks.items.len;

    const df = try computeDomFrontiers(allocator, cfg, dom_tree);
    defer {
        for (df) |d| allocator.free(d);
        allocator.free(df);
    }

    var store_sites = try allocator.alloc(std.ArrayList(MemOpKey), nblocks);
    defer {
        for (store_sites) |*sl| sl.deinit();
        allocator.free(store_sites);
    }
    for (0..nblocks) |i| {
        store_sites[i] = std.ArrayList(MemOpKey).init(allocator);
    }

    var load_sites = try allocator.alloc(std.ArrayList(MemOpKey), nblocks);
    defer {
        for (load_sites) |*ll| ll.deinit();
        allocator.free(load_sites);
    }
    for (0..nblocks) |i| {
        load_sites[i] = std.ArrayList(MemOpKey).init(allocator);
    }

    for (func.blocks.items, 0..) |*block, bi| {
        const bid = @as(BlockId, @intCast(bi));
        for (block.instrs.items, 0..) |*inst, ii| {
            const idx = @as(u32, @intCast(ii));
            switch (inst.op) {
                .store => {
                    try store_sites[bid].append(.{ .block = bid, .idx = idx });
                },
                .load => {
                    try load_sites[bid].append(.{ .block = bid, .idx = idx });
                },
                else => {},
            }
        }
    }

    var phi_store = std.AutoHashMap(struct { BlockId, ValueId }, void).init(allocator);
    defer phi_store.deinit();
    var phi_blocks = std.AutoHashMap(BlockId, void).init(allocator);
    defer phi_blocks.deinit();

    for (0..nblocks) |bi| {
        const bid = @as(BlockId, @intCast(bi));
        for (store_sites[bid].items) |sk| {
            const ptr = getStorePtr(func, sk) orelse continue;
            var phi_queue = std.ArrayList(BlockId).init(allocator);
            defer phi_queue.deinit();
            try phi_queue.append(bid);
            var phi_visited = try allocator.alloc(bool, nblocks);
            defer allocator.free(phi_visited);
            @memset(phi_visited, false);
            phi_visited[bid] = true;

            while (phi_queue.items.len > 0) {
                const cur = phi_queue.pop().?;
                for (df[cur]) |dfb| {
                    const key = .{ dfb, ptr };
                    if (!phi_store.contains(key)) {
                        try phi_store.put(key, {});
                        try phi_blocks.put(dfb, {});
                        for (cfg.get(dfb).predecessors.items) |pred| {
                            if (!phi_visited[pred]) {
                                phi_visited[pred] = true;
                                try phi_queue.append(pred);
                            }
                        }
                    }
                }
            }
        }
    }

    var rename_stack = std.AutoHashMap(ValueId, std.ArrayList(MemOpKey)).init(allocator);
    defer {
        var it = rename_stack.valueIterator();
        while (it.next()) |st| st.deinit();
        rename_stack.deinit();
    }

    for (store_sites) |sites| {
        for (sites.items) |sk| {
            const ptr = getStorePtr(func, sk) orelse continue;
            if (!rename_stack.contains(ptr)) {
                try rename_stack.put(ptr, std.ArrayList(MemOpKey).init(allocator));
            }
            try ssa.stored_val.put(sk, getStoreVal(func, sk) orelse NO_VALUE);
        }
    }

    for (load_sites) |sites| {
        for (sites.items) |lk| {
            const ptr = getLoadPtr(func, lk) orelse continue;
            if (!rename_stack.contains(ptr)) {
                try rename_stack.put(ptr, std.ArrayList(MemOpKey).init(allocator));
            }
        }
    }

    var block_phis = try allocator.alloc(std.ArrayList(struct { ValueId, MemOpKey }), nblocks);
    defer {
        for (block_phis) |*bp| bp.deinit();
        allocator.free(block_phis);
    }
    for (0..nblocks) |i| {
        block_phis[i] = std.ArrayList(struct { ValueId, MemOpKey }).init(allocator);
    }

    {
        var phi_it = phi_store.keyIterator();
        while (phi_it.next()) |key| {
            const phi_def = MemOpKey{ .block = key[0], .idx = std.math.maxInt(u32) };
            try block_phis[key[0]].append(.{ key[1], phi_def });
        }
    }

    var visited = try allocator.alloc(bool, nblocks);
    defer allocator.free(visited);
    @memset(visited, false);

    try renameRecursive(&ssa, &rename_stack, &block_phis, cfg.entry, &visited);

    for (load_sites) |sites| {
        for (sites.items) |lk| {
            const ptr = getLoadPtr(func, lk) orelse continue;
            const stack = rename_stack.getPtr(ptr) orelse continue;
            if (stack.items.len > 0) {
                try ssa.reaching_def.put(lk, stack.items[stack.items.len - 1]);
            }
        }
    }

    return ssa;
}

fn getStorePtr(func: *const bir.Function, key: MemOpKey) ?ValueId {
    const block = &func.blocks.items[key.block];
    if (key.idx >= block.instrs.items.len) return null;
    const inst = &block.instrs.items[key.idx];
    if (inst.op != .store or inst.operands.len < 2) return null;
    return inst.operands[0];
}

fn getStoreVal(func: *const bir.Function, key: MemOpKey) ?ValueId {
    const block = &func.blocks.items[key.block];
    if (key.idx >= block.instrs.items.len) return null;
    const inst = &block.instrs.items[key.idx];
    if (inst.op != .store or inst.operands.len < 2) return null;
    return inst.operands[1];
}

fn getLoadPtr(func: *const bir.Function, key: MemOpKey) ?ValueId {
    const block = &func.blocks.items[key.block];
    if (key.idx >= block.instrs.items.len) return null;
    const inst = &block.instrs.items[key.idx];
    if (inst.op != .load or inst.operands.len < 1) return null;
    return inst.operands[0];
}

fn renameRecursive(ssa: *MemorySSA, rename_stack: *std.AutoHashMap(ValueId, std.ArrayList(MemOpKey)), block_phis: *[]std.ArrayList(struct { ValueId, MemOpKey }), bid: BlockId, visited: *[]bool) !void {
    if (visited.*[bid]) return;
    visited.*[bid] = true;

    for (block_phis.*[bid].items) |phi_item| {
        const ptr = phi_item[0];
        const phi_def = phi_item[1];
        if (rename_stack.getPtr(ptr)) |st| {
            try st.append(phi_def);
        }
    }

    const block = &ssa.func.blocks.items[bid];
    for (block.instrs.items, 0..) |*inst, ii| {
        const idx = @as(u32, @intCast(ii));
        switch (inst.op) {
            .load => {
                const ptr = inst.operands[0];
                if (rename_stack.getPtr(ptr)) |st| {
                    if (st.items.len > 0) {
                        try ssa.reaching_def.put(.{ .block = bid, .idx = idx }, st.items[st.items.len - 1]);
                    }
                }
            },
            .store => {
                const ptr = inst.operands[0];
                const def = MemOpKey{ .block = bid, .idx = idx };
                if (rename_stack.getPtr(ptr)) |st| {
                    try st.append(def);
                }
            },
            else => {},
        }
    }

    for (ssa.cfg.get(bid).successors.items) |succ| {
        _ = succ;
    }

    for (ssa.dom_tree.children[bid]) |child| {
        try renameRecursive(ssa, rename_stack, block_phis, child, visited);
    }

    for (block_phis.*[bid].items) |phi_item| {
        const ptr = phi_item[0];
        if (rename_stack.getPtr(ptr)) |st| {
            _ = st.pop();
        }
    }

    const block2 = &ssa.func.blocks.items[bid];
    for (block2.instrs.items, 0..) |*inst, ii| {
        const idx = @as(u32, @intCast(ii));
        _ = idx;
        if (inst.op == .store) {
            const ptr = inst.operands[0];
            if (rename_stack.getPtr(ptr)) |st| {
                _ = st.pop();
            }
        }
    }
}

fn computeDomFrontiers(allocator: Allocator, cfg: *const bir_cfg.CFG, dom_tree: *const bir_dominators.DominatorTree) ![][]BlockId {
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

    var df_post = try allocator.alloc(BlockId, 0);
    defer allocator.free(df_post);
    {
        var stack = std.ArrayList(BlockId).init(allocator);
        defer stack.deinit();
        var vis = try allocator.alloc(bool, n);
        defer allocator.free(vis);
        @memset(vis, false);
        try stack.append(cfg.entry);
        var po = std.ArrayList(BlockId).init(allocator);
        defer po.deinit();
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
        df_post = try allocator.dupe(BlockId, po.items);
    }

    for (df_post) |bid| {
        for (dom_tree.children[bid]) |child| {
            for (df_lists[child].items) |x| {
                if (!dom_tree.strictlyDominates(bid, x)) {
                    try df_lists[bid].append(x);
                }
            }
        }
    }

    var result = try allocator.alloc([]BlockId, n);
    for (0..n) |i| {
        result[i] = try allocator.dupe(BlockId, df_lists[i].items);
        df_lists[i].deinit();
    }
    allocator.free(df_lists);
    return result;
}
