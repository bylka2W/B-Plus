const std = @import("std");
const mir = @import("../../mir.zig");

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
                .add, .sub, .imul, .idiv, .@"and", .@"or", .xor => {
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
                .test_flags => {
                    const tf = &block.instrs.items[i].test_flags;
                    tf.a = resolve(map, tf.a);
                    tf.b = resolve(map, tf.b);
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
                .lea => {
                    const l = &block.instrs.items[i].lea;
                    l.base = resolveVregOnly(map, l.base);
                    l.index = resolveVregOnly(map, l.index);
                    if (dstOf(block.instrs.items[i])) |dv| invalidatePointers(&map, dv);
                    i += 1;
                },
                .shl, .shr, .sar => {
                    replaceShiftAmount(map, &block.instrs.items[i]);
                    if (dstOf(block.instrs.items[i])) |dv| invalidatePointers(&map, dv);
                    i += 1;
                },
                .not_op, .neg_op => {
                    if (dstOf(block.instrs.items[i])) |dv| invalidatePointers(&map, dv);
                    i += 1;
                },
                .fadd, .fsub, .fmul, .fdiv => {
                    const f = &block.instrs.items[i];
                    const fb = switch (f.*) {
                        .fadd => |*v| v,
                        .fsub => |*v| v,
                        .fmul => |*v| v,
                        .fdiv => |*v| v,
                        else => unreachable,
                    };
                    fb.a = resolve(map, fb.a);
                    fb.b = resolve(map, fb.b);
                    if (fb.dst == .vreg) invalidatePointers(&map, fb.dst.vreg);
                    i += 1;
                },
                .fneg_op, .fsqrt_op => {
                    if (dstOf(block.instrs.items[i])) |dv| invalidatePointers(&map, dv);
                    i += 1;
                },
                .fcmp => {
                    const c = &block.instrs.items[i].fcmp;
                    c.a = resolve(map, c.a);
                    c.b = resolve(map, c.b);
                    if (c.dst == .vreg) invalidatePointers(&map, c.dst.vreg);
                    i += 1;
                },
                .sitofp, .fptosi, .fpext, .fptrunc, .sext_op, .zext_op, .trunc_op => {
                    const c = &block.instrs.items[i];
                    const ci = switch (c.*) {
                        .sitofp => |*v| v,
                        .fptosi => |*v| v,
                        .fpext => |*v| v,
                        .fptrunc => |*v| v,
                        .sext_op => |*v| v,
                        .zext_op => |*v| v,
                        .trunc_op => |*v| v,
                        else => unreachable,
                    };
                    ci.src = resolve(map, ci.src);
                    if (ci.dst == .vreg) invalidatePointers(&map, ci.dst.vreg);
                    i += 1;
                },
                .select => {
                    const s = &block.instrs.items[i].select;
                    s.src = resolve(map, s.src);
                    if (s.dst == .vreg) invalidatePointers(&map, s.dst.vreg);
                    i += 1;
                },
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

/// Like resolve(), but never resolves to a constant — only vreg→vreg.
/// Used for LEA base/index which must remain register operands.
fn resolveVregOnly(map: std.AutoHashMap(u32, CopyEntry), op: mir.MOperand) mir.MOperand {
    if (op != .vreg) return op;
    var cur = op.vreg;
    for (0..16) |_| {
        switch (map.get(cur) orelse return .{ .vreg = cur }) {
            .vreg => |v| {
                if (v == cur) return .{ .vreg = cur };
                cur = v;
            },
            .constant => return .{ .vreg = cur },
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
        .@"and" => |m| vregOf(m.dst),
        .@"or" => |m| vregOf(m.dst),
        .xor => |m| vregOf(m.dst),
        .shl, .shr, .sar => |m| vregOf(m.dst),
        .not_op, .neg_op => |m| vregOf(m.dst),
        .fneg_op, .fsqrt_op => |m| vregOf(m.dst),
        .fadd, .fsub, .fmul, .fdiv => |m| vregOf(m.dst),
        .fcmp => |m| vregOf(m.dst),
        .sitofp, .fptosi, .fpext, .fptrunc, .sext_op, .zext_op, .trunc_op => |m| vregOf(m.dst),
        .select => |s| vregOf(s.dst),
        .cmp => |m| vregOf(m.dst),
        .load => |m| vregOf(m.dst),
        .lea => |m| vregOf(m.dst),
        else => null,
    };
}

fn replaceOpWithResolved(map: std.AutoHashMap(u32, CopyEntry), inst: *mir.MInst) void {
    switch (inst.*) {
        .add => |*m| { m.src = resolve(map, m.src); },
        .sub => |*m| { m.src = resolve(map, m.src); },
        .imul => |*m| { m.src = resolve(map, m.src); },
        .idiv => |*m| { m.src = resolve(map, m.src); },
        .@"and" => |*m| { m.src = resolve(map, m.src); },
        .@"or" => |*m| { m.src = resolve(map, m.src); },
        .xor => |*m| { m.src = resolve(map, m.src); },
        else => {},
    }
}

fn replaceShiftAmount(map: std.AutoHashMap(u32, CopyEntry), inst: *mir.MInst) void {
    switch (inst.*) {
        .shl => |*m| { m.amount = resolve(map, m.amount); },
        .shr => |*m| { m.amount = resolve(map, m.amount); },
        .sar => |*m| { m.amount = resolve(map, m.amount); },
        else => {},
    }
}
