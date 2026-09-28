const std = @import("std");
const Allocator = std.mem.Allocator;
const bir = @import("../../bir.zig");
const INVALID_ID = bir.INVALID_ID;
const NO_VALUE = bir.NO_VALUE;
const ValueId = bir.ValueId;
const PreservedAnalyses = bir.PreservedAnalyses;
const Module = bir.Module;

pub const CopyPropagationPass = bir.Pass{
    .name = "copy-propagation",
    .run = runCopyPropagation,
};

fn runCopyPropagation(ctx: *bir.PassContext) anyerror!PreservedAnalyses {
    const module = ctx.module;
    const allocator = ctx.allocator;
    module.rebuildUses();

    for (module.functions.items) |*func| {
        for (func.blocks.items) |*block| {
            var removals = std.ArrayList(u32).init(allocator);
            defer removals.deinit();

            for (block.instrs.items, 0..) |*inst, ii| {
                const src = copySource(inst);
                if (src == null or src.? == NO_VALUE) continue;
                const dst = inst.result;
                if (dst == NO_VALUE or dst == src.?) continue;
                replaceAllUses(func, dst, src.?);
                try removals.append(@intCast(ii));
            }

            var i = removals.items.len;
            while (i > 0) {
                i -= 1;
                const idx = removals.items[i];
                var rm = block.instrs.orderedRemove(idx);
                rm.deinit(allocator);
            }
        }
    }

    module.rebuildUses();
    return PreservedAnalyses.none();
}

fn copySource(inst: *const bir.Inst) ?ValueId {
    switch (inst.op) {
        .cast, .bitcast => {
            const ci = inst.data.cast_info;
            if (ci.from != ci.to) return null;
            if (inst.operands.len != 1) return null;
            return inst.operands[0];
        },
        .select => {
            if (inst.operands.len != 3) return null;
            const a = inst.operands[1];
            const b = inst.operands[2];
            if (a != b) return null;
            return a;
        },
        .phi => {
            const incoming = inst.data.phi_incoming;
            if (incoming.len == 0) return null;
            const first = incoming[0].value;
            for (incoming[1..]) |inc| {
                if (inc.value != first) return null;
            }
            return first;
        },
        else => return null,
    }
}

fn replaceAllUses(func: *bir.Function, old_val: ValueId, new_val: ValueId) void {
    if (old_val == new_val) return;
    if (old_val > func.locals_count) return;
    const old_vi = func.getValueInfo(old_val);
    const uses_copy = func.allocator.dupe(ValueId, old_vi.uses.items) catch return;
    defer func.allocator.free(uses_copy);

    for (uses_copy) |user_val| {
        if (user_val == NO_VALUE or user_val > func.locals_count) continue;
        const user_vi = func.getValueInfo(user_val);
        if (user_vi.def.block == INVALID_ID) continue;
        if (user_vi.def.block >= func.blocks.items.len) continue;
        const block = func.getBlock(user_vi.def.block);
        if (user_vi.def.idx >= block.instrs.items.len) continue;
        const inst = &block.instrs.items[user_vi.def.idx];

        for (inst.operands) |*op| {
            if (op.* == old_val) op.* = new_val;
        }
        switch (inst.data) {
            .phi_incoming => |incoming| {
                for (incoming) |*inc| {
                    if (inc.value == old_val) inc.value = new_val;
                }
            },
            .cond_branch => |*cb| {
                if (cb.cond == old_val) cb.cond = new_val;
            },
            .call_info => |*ci| {
                if (ci.callee == old_val) ci.callee = new_val;
                for (ci.args) |*arg| {
                    if (arg.* == old_val) arg.* = new_val;
                }
            },
            .gep_info => |*gi| {
                if (gi.ptr == old_val) gi.ptr = new_val;
                for (gi.indices) |*idx| {
                    if (idx.* == old_val) idx.* = new_val;
                }
            },
            .texture_store_info => |*tsi| {
                if (tsi.tex == old_val) tsi.tex = new_val;
                if (tsi.coord_x == old_val) tsi.coord_x = new_val;
                if (tsi.coord_y == old_val) tsi.coord_y = new_val;
                if (tsi.val == old_val) tsi.val = new_val;
            },
            .sample_info => |*si| {
                if (si.tex == old_val) si.tex = new_val;
                if (si.sampler == old_val) si.sampler = new_val;
                if (si.coord == old_val) si.coord = new_val;
                if (si.lod) |*lod| {
                    if (lod.* == old_val) lod.* = new_val;
                }
                if (si.offset) |*off| {
                    if (off.* == old_val) off.* = new_val;
                }
            },
            .atomic_info => |*ai| {
                if (ai.ptr == old_val) ai.ptr = new_val;
                if (ai.val == old_val) ai.val = new_val;
            },
            else => {},
        }
    }

    old_vi.uses.clearRetainingCapacity();
}