const std = @import("std");
const mir = @import("../../mir.zig");
const MInst = mir.MInst;
const MOperand = mir.MOperand;


const Origin = union(enum) {
    known_imm: i64,
    copy: MOperand,
    scaled: struct {
        source: MOperand,
        scale: u8,
    },
    addr: struct {
        base: MOperand,
        index: MOperand = .{ .imm = 0 },
        scale: u8 = 1,
        disp: i32 = 0,
    },
};

pub const AddrFoldPass = struct {
    pub const name = "addr-fold";
    pub const pass_type = .transform;

    pub fn run(mfunc: *mir.MFunction) !void {
        for (mfunc.blocks.items) |*block| {
            try foldBlock(block, mfunc.allocator);
        }
    }
};

fn foldBlock(block: *mir.MBlock, allocator: std.mem.Allocator) !void {
    var origin = std.AutoHashMap(u32, Origin).init(allocator);
    defer origin.deinit();

    var i: usize = 0;
    while (i < block.instrs.items.len) {
        const inst = block.instrs.items[i];

        switch (inst) {
            .mov => |m| {
                if (vregOf(m.dst)) |dv| {
                    invalidateAliases(&origin, dv);
                    switch (m.src) {
                        .vreg => |sv| {
                            if (origin.get(sv)) |o| {
                                switch (o) {
                                    .scaled, .addr => try origin.put(dv, o),
                                    else => try origin.put(dv, .{ .copy = m.src }),
                                }
                            } else {
                                try origin.put(dv, .{ .copy = m.src });
                            }
                        },
                        .imm => |imm_val| {
                            try origin.put(dv, .{ .known_imm = @intCast(imm_val) });
                        },
                        else => _ = origin.remove(dv),
                    }
                }
                i += 1;
            },

            .shl => |s| {
                if (vregOf(s.dst)) |dv| {
                    invalidateAliases(&origin, dv);
                    const shift_amt = resolveShiftAmount(s.amount, &origin) orelse {
                        _ = origin.remove(dv);
                        i += 1;
                        continue;
                    };
                    if (shift_amt >= 1 and shift_amt <= 3) {
                        const prev = origin.get(dv);
                        const source: MOperand = if (prev) |p| switch (p) {
                            .copy => |cp| cp,
                            .scaled => |sc| sc.source,
                            .addr => .{ .vreg = dv },
                            .known_imm => .{ .vreg = dv },
                        } else .{ .vreg = dv };
                        try origin.put(dv, .{ .scaled = .{
                            .source = source,
                            .scale = @as(u8, 1) << @intCast(shift_amt),
                        } });
                    }
                }
                i += 1;
            },

            .add => |m| {
                const dst_v = vregOf(m.dst) orelse {
                    i += 1;
                    continue;
                };
                invalidateAliases(&origin, dst_v);

                const src_imm: ?i32 = blk: {
                    if (m.src == .imm) {
                        break :blk @intCast(m.src.imm);
                    }
                    if (vregOf(m.src)) |sv| {
                        if (origin.get(sv)) |o| {
                            if (o == .known_imm) {
                                break :blk @intCast(o.known_imm);
                            }
                        }
                    }
                    break :blk null;
                };

                if (src_imm) |imm_val| {
                    const prev = origin.get(dst_v);
                    if (prev) |p| {
                        switch (p) {
                            .scaled => {},
                            .addr => |a| {
                                try origin.put(dst_v, .{ .addr = .{
                                    .base = a.base,
                                    .index = a.index,
                                    .scale = a.scale,
                                    .disp = a.disp +% imm_val,
                                } });
                                i += 1;
                                continue;
                            },
                            .copy => |cp| {
                                if (vregOf(cp)) |base_vreg| {
                                    if (origin.get(base_vreg)) |base_origin| {
                                        if (base_origin == .known_imm) {
                                            try origin.put(dst_v, .{ .known_imm = @intCast(@as(i64, @intCast(base_origin.known_imm)) +% @as(i64, @intCast(imm_val))) });
                                            i += 1;
                                            continue;
                                        }
                                    }
                                }
                                try origin.put(dst_v, .{ .addr = .{
                                    .base = cp,
                                    .disp = imm_val,
                                } });
                                i += 1;
                                continue;
                            },
                            .known_imm => {
                                try origin.put(dst_v, .{ .known_imm = @intCast(@as(i64, @intCast(p.known_imm)) +% @as(i64, @intCast(imm_val))) });
                                i += 1;
                                continue;
                            },
                        }
                    }
                    _ = origin.remove(dst_v);
                    i += 1;
                    continue;
                }

                if (vregOf(m.src)) |sv| {
                    const prev_dst = origin.get(dst_v);
                    const prev_src = origin.get(sv);

                    if (prev_src) |ps| {
                        switch (ps) {
                            .scaled => |sc| {
                                const base: MOperand = if (prev_dst) |pd| switch (pd) {
                                    .copy => |cp| cp,
                                    .addr => |a| a.base,
                                    else => m.dst,
                                } else m.dst;
                                try origin.put(dst_v, .{ .addr = .{
                                    .base = base,
                                    .index = sc.source,
                                    .scale = sc.scale,
                                    .disp = 0,
                                } });
                                i += 1;
                                continue;
                            },
                            .copy => {},
                            .addr => {},
                            .known_imm => unreachable,
                        }
                    }

                    _ = origin.remove(dst_v);
                }
                i += 1;
            },

            .lea => {
                if (vregOf(block.instrs.items[i].lea.dst)) |ldv| {
                    invalidateAliases(&origin, ldv);
                    _ = origin.remove(ldv);
                }
                if (i + 1 < block.instrs.items.len) {
                    const next = block.instrs.items[i + 1];
                    if (next == .add and next.add.src == .imm) {
                        const lea_dst = vregOf(block.instrs.items[i].lea.dst);
                        const add_dst = vregOf(next.add.dst);
                        if (lea_dst != null and lea_dst == add_dst) {
                            block.instrs.items[i].lea.disp +%= @intCast(next.add.src.imm);
                            _ = block.instrs.orderedRemove(i + 1);
                            continue;
                        }
                    }
                }
                i += 1;
            },

            else => {
                if (dstOf(inst)) |dv| {
                    invalidateAliases(&origin, dv);
                    _ = origin.remove(dv);
                }
                i += 1;
            },
        }
    }

    i = 0;
    while (i < block.instrs.items.len) {
        const inst = block.instrs.items[i];
        if (inst == .add) {
            const a = inst.add;
            const is_imm_src = if (a.src == .imm) true else blk: {
                if (vregOf(a.src)) |sv| {
                    if (origin.get(sv)) |o| {
                        if (o == .known_imm) break :blk true;
                    }
                }
                break :blk false;
            };
            if (is_imm_src) {
                if (vregOf(a.dst)) |dv| {
                    if (origin.get(dv)) |o| {
                        if (o == .addr) {
                            const addr = o.addr;
                            block.instrs.items[i] = .{ .lea = .{
                                .dst = a.dst,
                                .base = addr.base,
                                .index = addr.index,
                                .scale = addr.scale,
                                .disp = addr.disp,
                            } };
                        }
                    }
                }
            }
        }
        i += 1;
    }

    i = 0;
    while (i < block.instrs.items.len) {
        const inst = block.instrs.items[i];
        if (inst == .add) {
            const a = inst.add;
            if (vregOf(a.src)) |sv| {
                if (vregOf(a.dst)) |dv| {
                    if (origin.get(sv)) |o| {
                        if (o == .scaled) {
                            const sc = o.scaled;
                            const prev_dst = origin.get(dv);
                            const base: MOperand = if (prev_dst) |pd| switch (pd) {
                                .copy => |cp| cp,
                                .addr => |a2| a2.base,
                                else => a.dst,
                            } else a.dst;
                            block.instrs.items[i] = .{ .lea = .{
                                .dst = a.dst,
                                .base = base,
                                .index = sc.source,
                                .scale = sc.scale,
                                .disp = 0,
                            } };
                        }
                    }
                }
            }
        }
        i += 1;
    }
}

fn vregOf(op: MOperand) ?u32 {
    return switch (op) {
        .vreg => |v| v,
        else => null,
    };
}

fn dstOf(inst: MInst) ?u32 {
    return switch (inst) {
        .mov => |m| vregOf(m.dst),
        .add => |m| vregOf(m.dst),
        .sub => |m| vregOf(m.dst),
        .imul => |m| vregOf(m.dst),
        .idiv => |m| vregOf(m.quotient),
        .@"and" => |m| vregOf(m.dst),
        .@"or" => |m| vregOf(m.dst),
        .xor => |m| vregOf(m.dst),
        .shl => |m| vregOf(m.dst),
        .shr => |m| vregOf(m.dst),
        .sar => |m| vregOf(m.dst),
        .not_op, .neg_op => |m| vregOf(m.dst),
        .lea => |m| vregOf(m.dst),
        .load => |m| vregOf(m.dst),
        .alloca => |m| vregOf(m.dst),
        .string_const => |m| vregOf(m.dst),
        else => null,
    };
}

fn invalidateAliases(origin: *std.AutoHashMap(u32, Origin), target: u32) void {
    var keys: [256]u32 = undefined;
    var count: usize = 0;
    var it = origin.iterator();
    while (it.next()) |e| {
        const o = e.value_ptr.*;
        const refs_target = switch (o) {
            .copy => |c| vregOf(c) == target,
            .scaled => |s| vregOf(s.source) == target,
            .addr => |a| vregOf(a.base) == target or vregOf(a.index) == target,
            else => false,
        };
        if (refs_target) {
            keys[count] = e.key_ptr.*;
            count += 1;
        }
    }
    for (0..count) |i| _ = origin.remove(keys[i]);
}

fn resolveShiftAmount(amount: MOperand, origin: *const std.AutoHashMap(u32, Origin)) ?u8 {
    if (amount == .imm) {
        const v = amount.imm;
        if (v >= 0 and v <= 31) return @intCast(v);
        return null;
    }
    if (amount == .vreg) {
        if (origin.get(amount.vreg)) |o| {
            if (o == .known_imm) {
                const v: i64 = o.known_imm;
                if (v >= 0 and v <= 31) return @intCast(v);
            }
        }
    }
    return null;
}
