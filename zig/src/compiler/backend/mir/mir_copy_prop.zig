const std = @import("std");
const mir = @import("mir.zig");

const CopyEntry = union(enum) {
    vreg: u32,
    constant: i64,
};

pub fn propagateCopies(mfunc: *mir.MFunction) !void {
    for (mfunc.blocks.items) |*block| {
        var map = std.AutoHashMap(u32, CopyEntry).init(mfunc.allocator);
        defer map.deinit();

        var i: usize = 0;
        while (i < block.instrs.items.len) {
            const inst = block.instrs.items[i];
            switch (inst) {
                .mov => |m| {
                    const dv = vregOf(m.dst);
                    const sv = vregOf(m.src);
                    const resolved_src = resolve(map, m.src);

                    if (dv) |d| {
                        if (sv == dv or (resolved_src == .vreg and resolved_src.vreg == d)) {
                            _ = block.instrs.orderedRemove(i);
                            continue;
                        }
                        _ = map.remove(d);
                        if (resolved_src == .vreg) {
                            try map.put(d, .{ .vreg = resolved_src.vreg });
                        } else if (resolved_src == .imm) {
                            try map.put(d, .{ .constant = resolved_src.imm });
                        }
                    }

                    if (!operandEq(resolved_src, m.src)) {
                        block.instrs.items[i] = .{ .mov = .{ .dst = m.dst, .src = resolved_src } };
                    }
                    i += 1;
                },
                .add, .sub, .imul, .idiv => {
                    replaceOpWithResolved(map, &block.instrs.items[i]);
                    if (dstOf(block.instrs.items[i])) |dv| invalidatePointers(&map, dv);
                    i += 1;
                },
                .cmp => {
                    const c = &block.instrs.items[i].cmp;
                    c.a = resolve(map, c.a);
                    c.b = resolve(map, c.b);
                    if (c.dst == .vreg) invalidatePointers(&map, c.dst.vreg);
                    i += 1;
                },
                .cmp_flags => {
                    const cf = &block.instrs.items[i].cmp_flags;
                    cf.a = resolve(map, cf.a);
                    cf.b = resolve(map, cf.b);
                    i += 1;
                },
                .load => {
                    const l = &block.instrs.items[i].load;
                    l.ptr = resolve(map, l.ptr);
                    if (l.dst == .vreg) invalidatePointers(&map, l.dst.vreg);
                    i += 1;
                },
                .store => {
                    const s = &block.instrs.items[i].store;
                    s.ptr = resolve(map, s.ptr);
                    s.src = resolve(map, s.src);
                    i += 1;
                },
                .ret => {
                    const r = &block.instrs.items[i].ret;
                    r.val = resolve(map, r.val);
                    i += 1;
                },
                .call => {
                    const c = &block.instrs.items[i].call;
                    for (0..c.arg_count) |j| {
                        c.args[j] = resolve(map, c.args[j]);
                    }
                    if (c.dst == .vreg) invalidatePointers(&map, c.dst.vreg);
                    i += 1;
                },
                .jmp, .jcc, .alloca, .phi => i += 1,
            }
        }
    }
}

fn resolve(map: std.AutoHashMap(u32, CopyEntry), op: mir.MOperand) mir.MOperand {
    if (op != .vreg) return op;
    var cur = op.vreg;
    for (0..16) |_| {
        switch (map.get(cur) orelse return .{ .vreg = cur }) {
            .vreg => |v| {
                if (v == cur) return .{ .vreg = cur };
                cur = v;
            },
            .constant => |c| return .{ .imm = c },
        }
    }
    return .{ .vreg = cur };
}

fn invalidatePointers(map: *std.AutoHashMap(u32, CopyEntry), target: u32) void {
    var keys: [64]u32 = undefined;
    var count: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .vreg => |v| if (v == target) {
                keys[count] = entry.key_ptr.*;
                count += 1;
            },
            else => {},
        }
    }
    for (0..count) |i| _ = map.remove(keys[i]);
    _ = map.remove(target);
}

fn operandEq(a: mir.MOperand, b: mir.MOperand) bool {
    if (@as(std.meta.Tag(mir.MOperand), a) != @as(std.meta.Tag(mir.MOperand), b)) return false;
    return switch (a) {
        .vreg => |av| b.vreg == av,
        .phys => |ap| b.phys == ap,
        .imm => |ai| b.imm == ai,
        .mem => |am| b.mem.base == am.base and b.mem.offset == am.offset,
    };
}

fn vregOf(op: mir.MOperand) ?u32 {
    return switch (op) {
        .vreg => |v| v,
        else => null,
    };
}

fn dstOf(inst: mir.MInst) ?u32 {
    return switch (inst) {
        .mov => |m| vregOf(m.dst),
        .add => |m| vregOf(m.dst),
        .sub => |m| vregOf(m.dst),
        .imul => |m| vregOf(m.dst),
        .idiv => |m| vregOf(m.dst),
        .cmp => |m| vregOf(m.dst),
        .load => |m| vregOf(m.dst),
        else => null,
    };
}

fn replaceOpWithResolved(map: std.AutoHashMap(u32, CopyEntry), inst: *mir.MInst) void {
    switch (inst.*) {
        .add => |*m| { m.src = resolve(map, m.src); },
        .sub => |*m| { m.src = resolve(map, m.src); },
        .imul => |*m| { m.src = resolve(map, m.src); },
        .idiv => |*m| { m.src = resolve(map, m.src); },
        else => {},
    }
}
