const std = @import("std");
const mir = @import("mir.zig");

const VRegVal = union(enum) {
    copy: u32,
    constant: i64,
};

pub fn optimize(mfunc: *mir.MFunction) !void {
    var map = std.AutoHashMap(u32, VRegVal).init(mfunc.allocator);
    defer map.deinit();

    for (mfunc.blocks.items) |*block| {
        map.clearRetainingCapacity();

        var i: usize = 0;
        while (i < block.instrs.items.len) {
            const inst = block.instrs.items[i];
            switch (inst) {
                .mov => try handleMov(&map, block, &i),
                .add => try handleAddSub(&map, block, &i),
                .sub => try handleAddSub(&map, block, &i),
                .imul => try handleIMul(&map, block, &i),
                .idiv => try handleIDiv(&map, block, &i),
                .cmp => try handleCmp(&map, block, &i),
                .cmp_flags => try handleCmpFlags(&map, block, &i),
                .load => try handleLoad(&map, block, &i),
                .store => try handleStore(&map, block, &i),
                .ret => try handleRet(&map, block, &i),
                .call => try handleCall(&map, block, &i),
                .jmp, .jcc, .alloca => i += 1,
            }
        }
    }
}

fn resolveCopy(map: *std.AutoHashMap(u32, VRegVal), v: u32) u32 {
    var cur = v;
    for (0..16) |_| {
        switch (map.get(cur) orelse break) {
            .copy => |next| {
                if (next == cur) break;
                cur = next;
            },
            else => break,
        }
    }
    return cur;
}

fn resolveConst(map: *std.AutoHashMap(u32, VRegVal), v: u32) ?i64 {
    var cur = v;
    for (0..16) |_| {
        switch (map.get(cur) orelse return null) {
            .copy => |next| {
                if (next == cur) return null;
                cur = next;
            },
            .constant => |c| return c,
        }
    }
    return null;
}

fn resolveCopyOp(map: *std.AutoHashMap(u32, VRegVal), op: mir.MOperand) mir.MOperand {
    return switch (op) {
        .vreg => |v| blk: {
            const rv = resolveCopy(map, v);
            if (rv != v) break :blk .{ .vreg = rv };
            break :blk op;
        },
        else => op,
    };
}

fn resolveConstOp(map: *std.AutoHashMap(u32, VRegVal), op: mir.MOperand) mir.MOperand {
    return switch (op) {
        .vreg => |v| blk: {
            if (resolveConst(map, v)) |c| break :blk .{ .imm = c };
            const rv = resolveCopy(map, v);
            if (rv != v) break :blk .{ .vreg = rv };
            break :blk op;
        },
        else => op,
    };
}

fn redefineVReg(map: *std.AutoHashMap(u32, VRegVal), v: u32) void {
    invalidateEntriesPointingTo(map, v);
    _ = map.remove(v);
}

fn invalidateEntriesPointingTo(map: *std.AutoHashMap(u32, VRegVal), target: u32) void {
    var keys_to_remove: [64]u32 = undefined;
    var count: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .copy => |v| if (v == target) {
                keys_to_remove[count] = entry.key_ptr.*;
                count += 1;
            },
            else => {},
        }
    }
    for (0..count) |i| _ = map.remove(keys_to_remove[i]);
}

fn putVal(map: *std.AutoHashMap(u32, VRegVal), dv: u32, val: VRegVal) !void {
    invalidateEntriesPointingTo(map, dv);
    _ = map.remove(dv);
    try map.put(dv, val);
}

fn handleMov(map: *std.AutoHashMap(u32, VRegVal), block: *mir.MBlock, ip: *usize) !void {
    const m = block.instrs.items[ip.*].mov;
    const dv = vreg(m.dst) orelse { ip.* += 1; return; };

    const new_src = resolveConstOp(map, m.src);

    if (vreg(new_src)) |rsv| {
        if (dv == rsv) {
            _ = block.instrs.orderedRemove(ip.*);
            return;
        }
        try putVal(map, dv, .{ .copy = rsv });
    } else if (new_src == .imm) {
        try putVal(map, dv, .{ .constant = new_src.imm });
    } else {
        redefineVReg(map, dv);
    }

    if (!operandEq(new_src, m.src)) {
        block.instrs.items[ip.*] = .{ .mov = .{ .dst = m.dst, .src = new_src } };
    }
    ip.* += 1;
}

fn handleAddSub(map: *std.AutoHashMap(u32, VRegVal), block: *mir.MBlock, ip: *usize) !void {
    const inst = block.instrs.items[ip.*];
    const tag: u1 = if (@as(std.meta.Tag(mir.MInst), inst) == .add) @as(u1, 0) else @as(u1, 1);

    const dst = if (tag == 0) inst.add.dst else inst.sub.dst;
    const src = if (tag == 0) inst.add.src else inst.sub.src;
    const dv = vreg(dst) orelse { ip.* += 1; return; };

    const new_src = resolveConstOp(map, src);

    if (new_src == .imm and new_src.imm == 0) {
        _ = block.instrs.orderedRemove(ip.*);
        return;
    }

    redefineVReg(map, dv);

    if (!operandEq(new_src, src)) {
        block.instrs.items[ip.*] = if (tag == 0)
            .{ .add = .{ .dst = dst, .src = new_src } }
        else
            .{ .sub = .{ .dst = dst, .src = new_src } };
    }
    ip.* += 1;
}

fn handleIMul(map: *std.AutoHashMap(u32, VRegVal), block: *mir.MBlock, ip: *usize) !void {
    const m = block.instrs.items[ip.*].imul;
    const dv = vreg(m.dst) orelse { ip.* += 1; return; };

    const new_src = resolveConstOp(map, m.src);

    if (new_src == .imm) {
        if (new_src.imm == 0) {
            block.instrs.items[ip.*] = .{ .mov = .{ .dst = m.dst, .src = .{ .imm = 0 } } };
            try putVal(map, dv, .{ .constant = 0 });
            ip.* += 1;
            return;
        }
        if (new_src.imm == 1) {
            _ = block.instrs.orderedRemove(ip.*);
            return;
        }
    }

    redefineVReg(map, dv);

    if (!operandEq(new_src, m.src)) {
        block.instrs.items[ip.*] = .{ .imul = .{ .dst = m.dst, .src = new_src } };
    }
    ip.* += 1;
}

fn handleIDiv(map: *std.AutoHashMap(u32, VRegVal), block: *mir.MBlock, ip: *usize) !void {
    const m = block.instrs.items[ip.*].idiv;
    const dv = vreg(m.dst) orelse { ip.* += 1; return; };

    const new_src = resolveConstOp(map, m.src);

    if (new_src == .imm and new_src.imm == 1) {
        _ = block.instrs.orderedRemove(ip.*);
        return;
    }

    redefineVReg(map, dv);

    if (!operandEq(new_src, m.src)) {
        block.instrs.items[ip.*] = .{ .idiv = .{ .dst = m.dst, .src = new_src } };
    }
    ip.* += 1;
}

fn handleCmp(map: *std.AutoHashMap(u32, VRegVal), block: *mir.MBlock, ip: *usize) !void {
    const m = block.instrs.items[ip.*].cmp;
    const dv = vreg(m.dst) orelse { ip.* += 1; return; };

    const new_a = resolveCopyOp(map, m.a);
    const new_b = resolveCopyOp(map, m.b);
    redefineVReg(map, dv);

    if (!operandEq(new_a, m.a) or !operandEq(new_b, m.b)) {
        block.instrs.items[ip.*] = .{ .cmp = .{ .cc = m.cc, .dst = m.dst, .a = new_a, .b = new_b } };
    }
    ip.* += 1;
}

fn handleCmpFlags(map: *std.AutoHashMap(u32, VRegVal), block: *mir.MBlock, ip: *usize) !void {
    const m = block.instrs.items[ip.*].cmp_flags;
    const new_a = resolveCopyOp(map, m.a);
    const new_b = resolveCopyOp(map, m.b);
    if (!operandEq(new_a, m.a) or !operandEq(new_b, m.b)) {
        block.instrs.items[ip.*] = .{ .cmp_flags = .{ .a = new_a, .b = new_b } };
    }
    ip.* += 1;
}

fn handleLoad(map: *std.AutoHashMap(u32, VRegVal), block: *mir.MBlock, ip: *usize) !void {
    const m = block.instrs.items[ip.*].load;
    const dv = vreg(m.dst) orelse { ip.* += 1; return; };
    const new_ptr = resolveCopyOp(map, m.ptr);
    redefineVReg(map, dv);
    if (!operandEq(new_ptr, m.ptr)) {
        block.instrs.items[ip.*] = .{ .load = .{ .dst = m.dst, .ptr = new_ptr } };
    }
    ip.* += 1;
}

fn handleStore(map: *std.AutoHashMap(u32, VRegVal), block: *mir.MBlock, ip: *usize) !void {
    const m = block.instrs.items[ip.*].store;
    const new_ptr = resolveCopyOp(map, m.ptr);
    const new_src = resolveCopyOp(map, m.src);
    if (!operandEq(new_ptr, m.ptr) or !operandEq(new_src, m.src)) {
        block.instrs.items[ip.*] = .{ .store = .{ .ptr = new_ptr, .src = new_src } };
    }
    ip.* += 1;
}

fn handleRet(map: *std.AutoHashMap(u32, VRegVal), block: *mir.MBlock, ip: *usize) !void {
    const m = block.instrs.items[ip.*].ret;
    const new_val = resolveConstOp(map, m.val);
    if (!operandEq(new_val, m.val)) {
        block.instrs.items[ip.*] = .{ .ret = .{ .val = new_val, .is_void = m.is_void } };
    }
    ip.* += 1;
}

fn handleCall(map: *std.AutoHashMap(u32, VRegVal), block: *mir.MBlock, ip: *usize) !void {
    const m = block.instrs.items[ip.*].call;
    var changed = false;
    var new_args = m.args;
    for (0..m.arg_count) |j| {
        const ua = resolveCopyOp(map, m.args[j]);
        if (!operandEq(ua, m.args[j])) {
            new_args[j] = ua;
            changed = true;
        }
    }
    if (changed) {
        block.instrs.items[ip.*] = .{ .call = .{ .name = m.name, .args = new_args, .arg_count = m.arg_count, .dst = m.dst } };
    }
    if (vreg(m.dst)) |dv| redefineVReg(map, dv);
    ip.* += 1;
}

fn operandEq(a: mir.MOperand, b: mir.MOperand) bool {
    if (@as(std.meta.Tag(mir.MOperand), a) != @as(std.meta.Tag(mir.MOperand), b)) return false;
    return switch (a) {
        .vreg => |av| b.vreg == av,
        .phys => |ap| b.phys == ap,
        .imm => |ai| b.imm == ai,
        .mem => |am| b.mem.base == am.base and b.mem.offset == am.offset and b.mem.size == am.size,
    };
}

fn vreg(op: mir.MOperand) ?u32 {
    return switch (op) {
        .vreg => |v| v,
        else => null,
    };
}
