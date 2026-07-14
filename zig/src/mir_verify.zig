const std = @import("std");
const mir = @import("mir.zig");

pub const VerifyError = error{
    InvalidBlockTarget,
    MissingTerminator,
    UnreachableBlock,
    UndefinedVReg,
};

fn checkDefined(defs: *std.AutoHashMap(u32, void), op: mir.MOperand) !void {
    if (op == .vreg and !defs.contains(op.vreg)) return error.UndefinedVReg;
}

fn collectDefinedVRegs(mfunc: *const mir.MFunction) std.AutoHashMap(u32, void) {
    var defs = std.AutoHashMap(u32, void).init(mfunc.allocator);
    for (mfunc.params) |p| {
        if (p == .vreg) defs.put(p.vreg, {}) catch {};
    }
    for (mfunc.blocks.items) |*block| {
        for (block.instrs.items) |inst| {
            const dst = switch (inst) {
                .mov => |m| m.dst,
                .add => |a| a.dst,
                .sub => |s| s.dst,
                .imul => |m| m.dst,
                .idiv => |m| m.dst,
                .cmp => |c| c.dst,
                .call => |c| c.dst,
                .alloca => |a| a.dst,
                .load => |l| l.dst,
                else => continue,
            };
            if (dst == .vreg) defs.put(dst.vreg, {}) catch {};
        }
    }
    return defs;
}

fn checkUsedVRegs(inst: mir.MInst, defs: *std.AutoHashMap(u32, void)) !void {
    switch (inst) {
        .mov => |m| try checkDefined(defs, m.src),
        .add => |a| try checkDefined(defs, a.src),
        .sub => |s| try checkDefined(defs, s.src),
        .imul => |m| try checkDefined(defs, m.src),
        .idiv => |m| try checkDefined(defs, m.src),
        .cmp => |c| {
            try checkDefined(defs, c.a);
            try checkDefined(defs, c.b);
        },
        .cmp_flags => |cf| {
            try checkDefined(defs, cf.a);
            try checkDefined(defs, cf.b);
        },
        .call => |c| {
            for (c.args[0..c.arg_count]) |arg| try checkDefined(defs, arg);
        },
        .load => |l| try checkDefined(defs, l.ptr),
        .store => |s| {
            try checkDefined(defs, s.ptr);
            try checkDefined(defs, s.src);
        },
        .ret => |r| try checkDefined(defs, r.val),
        else => {},
    }
}

fn isTerminator(inst: mir.MInst) bool {
    return switch (inst) {
        .jmp, .jcc, .ret => true,
        else => false,
    };
}

fn checkBlockTargets(block: *const mir.MBlock, num_blocks: usize) !void {
    for (block.instrs.items) |inst| {
        switch (inst) {
            .jmp => |j| if (j.target >= num_blocks) return error.InvalidBlockTarget,
            .jcc => |j| if (j.target >= num_blocks) return error.InvalidBlockTarget,
            else => {},
        }
    }
}

pub fn verifyMir(mfunc: *const mir.MFunction) !void {
    const num_blocks = mfunc.blocks.items.len;
    if (num_blocks == 0) return;

    var defs = collectDefinedVRegs(mfunc);
    defer defs.deinit();

    for (mfunc.blocks.items) |*block| {
        try checkBlockTargets(block, num_blocks);
    }

    for (mfunc.blocks.items) |*block| {
        if (block.instrs.items.len > 0) {
            if (!isTerminator(block.instrs.items[block.instrs.items.len - 1])) {
                return error.MissingTerminator;
            }
        }
    }

    for (mfunc.blocks.items) |*block| {
        for (block.instrs.items) |inst| {
            try checkUsedVRegs(inst, &defs);
        }
    }

    var visited = std.AutoHashMap(usize, void).init(mfunc.allocator);
    defer visited.deinit();
    var queue = std.ArrayList(usize).init(mfunc.allocator);
    defer queue.deinit();
    try queue.append(0);

    var front: usize = 0;
    while (front < queue.items.len) {
        const b = queue.items[front];
        front += 1;
        if (visited.contains(b)) continue;
        try visited.put(b, {});
        const block = &mfunc.blocks.items[b];
        for (block.instrs.items) |inst| {
            const target = switch (inst) {
                .jmp => |j| j.target,
                .jcc => |j| j.target,
                else => continue,
            };
            if (!visited.contains(target)) {
                try queue.append(target);
            }
        }
    }

    for (0..num_blocks) |i| {
        if (!visited.contains(i)) return error.UnreachableBlock;
    }
}
