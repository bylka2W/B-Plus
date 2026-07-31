const std = @import("std");
const mir = @import("../../mir.zig");

pub fn destroySSA(mfunc: *mir.MFunction) !void {
    const next_vreg = computeNextVReg(mfunc);
    try splitCriticalEdges(mfunc, next_vreg);
    try eliminatePhis(mfunc, next_vreg);
}

fn computeNextVReg(mfunc: *const mir.MFunction) u32 {
    var max_vreg: u32 = 1000;
    for (mfunc.blocks.items) |block| {
        for (block.instrs.items) |inst| {
            if (dstVReg(inst)) |v| {
                if (v >= max_vreg) max_vreg = v + 1;
            }
            var srcs: [8]u32 = undefined;
            const n = srcVregs(inst, &srcs);
            for (0..n) |i| {
                if (srcs[i] >= max_vreg) max_vreg = srcs[i] + 1;
            }
        }
    }
    for (mfunc.params) |p| {
        if (p == .vreg and p.vreg >= max_vreg) max_vreg = p.vreg + 1;
    }
    return max_vreg;
}

fn splitCriticalEdges(mfunc: *mir.MFunction, next_vreg: u32) !void {
    var splits = std.ArrayList(struct {
        pred_idx: usize,
        succ_idx: usize,
        new_block_idx: usize,
    }).init(mfunc.allocator);
    defer splits.deinit();

    var scratch: u32 = next_vreg;

    for (mfunc.blocks.items, 0..) |*block, bi| {
        var succ_count: usize = 0;
        for (block.instrs.items) |inst| {
            switch (inst) {
                .jmp => succ_count += 1,
                .jcc => succ_count += 2,
                else => {},
            }
        }
        if (succ_count <= 1) continue;

        for (block.instrs.items) |inst| {
            const targets: [2]?usize = switch (inst) {
                .jmp => |j| .{ j.target, null },
                .jcc => |j| .{ j.target, null },
                else => continue,
            };
            for (targets) |t_opt| {
                const target = t_opt orelse continue;
                if (target >= mfunc.blocks.items.len) continue;

                var pred_count: usize = 0;
                for (mfunc.blocks.items) |other| {
                    for (other.instrs.items) |oi| {
                        switch (oi) {
                            .jmp => |j| {
                                if (j.target == target) pred_count += 1;
                            },
                            .jcc => |j| {
                                if (j.target == target) pred_count += 1;
                            },
                            else => {},
                        }
                    }
                }

                if (pred_count > 1) {
                    var already_split = false;
                    for (splits.items) |sp| {
                        if (sp.pred_idx == bi and sp.succ_idx == target) {
                            already_split = true;
                            break;
                        }
                    }
                    if (!already_split) {
                        try splits.append(.{
                            .pred_idx = bi,
                            .succ_idx = target,
                            .new_block_idx = mfunc.blocks.items.len + splits.items.len,
                        });
                    }
                }
            }
        }
    }

    for (splits.items) |sp| {
        const new_label = try std.fmt.allocPrint(mfunc.allocator, "crit_edge_{d}", .{scratch});
        scratch += 1;

        var new_block = mir.MBlock{
            .label = new_label,
            .instrs = std.ArrayList(mir.MInst).init(mfunc.allocator),
        };
        try new_block.instrs.append(.{ .jmp = .{ .target = @intCast(sp.succ_idx) } });

        try mfunc.blocks.append(new_block);

        const pred = &mfunc.blocks.items[sp.pred_idx];
        for (pred.instrs.items) |*inst| {
            switch (inst.*) {
                .jmp => |*j| {
                    if (j.target == @as(u32, @intCast(sp.succ_idx))) {
                        j.target = @intCast(sp.new_block_idx);
                    }
                },
                .jcc => |*j| {
                    if (j.target == @as(u32, @intCast(sp.succ_idx))) {
                        j.target = @intCast(sp.new_block_idx);
                    }
                },
                else => {},
            }
        }
    }

    for (mfunc.blocks.items) |*block| {
        for (block.instrs.items) |*inst| {
            switch (inst.*) {
                .jcc => |*j| {
                    for (splits.items) |sp| {
                        if (j.target == @as(u32, @intCast(sp.succ_idx)) and sp.pred_idx == findBlockIndex(mfunc, block)) {
                            j.target = @intCast(sp.new_block_idx);
                        }
                    }
                },
                else => {},
            }
        }
    }
}

fn findBlockIndex(mfunc: *const mir.MFunction, target: *const mir.MBlock) usize {
    for (mfunc.blocks.items, 0..) |b, i| {
        if (b.label.ptr == target.label.ptr) return i;
    }
    return 0;
}

fn eliminatePhis(mfunc: *mir.MFunction, next_vreg: u32) !void {
    for (mfunc.blocks.items) |*block| {
        var has_phi = false;
        for (block.instrs.items) |inst| {
            if (inst == .phi) {
                has_phi = true;
                break;
            }
        }
        if (!has_phi) continue;

        var phis = std.ArrayList(mir.PhiInst).init(mfunc.allocator);
        defer {
            for (phis.items) |p| mfunc.allocator.free(p.incoming);
            phis.deinit();
        }

        var non_phis = std.ArrayList(mir.MInst).init(mfunc.allocator);
        defer non_phis.deinit();

        for (block.instrs.items) |inst| {
            switch (inst) {
                .phi => |p| {
                    const owned_inc = try mfunc.allocator.dupe(mir.PhiIncoming, p.incoming);
                    try phis.append(.{ .dst = p.dst, .incoming = owned_inc });
                },
                else => try non_phis.append(inst),
            }
        }

        block.instrs.clearRetainingCapacity();
        for (non_phis.items) |inst| {
            try block.instrs.append(inst);
        }

        var copies_by_pred = std.AutoHashMap(usize, std.ArrayList(CopyPair)).init(mfunc.allocator);
        defer {
            var it = copies_by_pred.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit();
            copies_by_pred.deinit();
        }

        for (phis.items) |phi| {
            const dst_v = vregOf(phi.dst) orelse continue;
            for (phi.incoming) |inc| {
                const src_v = vregOf(inc.src) orelse continue;
                if (dst_v == src_v) continue;
                if (inc.pred_block >= mfunc.blocks.items.len) continue;

                const gop = try copies_by_pred.getOrPut(inc.pred_block);
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(CopyPair).init(mfunc.allocator);
                try gop.value_ptr.append(.{ .dst = phi.dst, .src = inc.src });
            }
        }

        var pred_it = copies_by_pred.iterator();
        while (pred_it.next()) |entry| {
            const pred_idx = entry.key_ptr.*;
            const copies = entry.value_ptr;
            if (copies.items.len == 0) continue;
            try resolveAndEmitCopies(mfunc, pred_idx, copies.items, next_vreg);
        }
    }
}

const CopyPair = struct {
    dst: mir.MOperand,
    src: mir.MOperand,
};

fn resolveAndEmitCopies(
    mfunc: *mir.MFunction,
    pred_idx: usize,
    copies: []const CopyPair,
    base_scratch: u32,
) !void {
    const pred = &mfunc.blocks.items[pred_idx];

    var resolved = std.ArrayList(ResolvedCopy).init(mfunc.allocator);
    defer resolved.deinit();

    var remaining = std.ArrayList(ResolvedCopy).init(mfunc.allocator);
    defer remaining.deinit();

    for (copies) |cp| {
        if (vregOf(cp.dst)) |dv| {
            if (vregOf(cp.src) == dv) continue;
        }
        try remaining.append(.{ .dst = cp.dst, .src = cp.src });
    }

    var next_scratch = base_scratch;
    while (remaining.items.len > 0) {
        var all_dsts = std.AutoHashMap(u32, void).init(mfunc.allocator);
        defer all_dsts.deinit();
        for (remaining.items) |cp| {
            if (vregOf(cp.dst)) |dv| try all_dsts.put(dv, {});
        }

        var safe_found = false;
        var i: usize = 0;
        while (i < remaining.items.len) {
            const cp = remaining.items[i];
            const src_v = vregOf(cp.src);
            const is_safe = if (src_v) |sv| !all_dsts.contains(sv) else true;

            if (is_safe) {
                try resolved.append(cp);
                _ = remaining.orderedRemove(i);
                safe_found = true;
            } else {
                i += 1;
            }
        }

        if (!safe_found and remaining.items.len > 0) {
            const cp = remaining.orderedRemove(0);
            const tmp_v = next_scratch;
            next_scratch += 1;
            const tmp_op: mir.MOperand = .{ .vreg = tmp_v };

            try resolved.append(.{ .dst = tmp_op, .src = cp.src });
            try resolved.append(.{ .dst = cp.dst, .src = tmp_op });

            if (vregOf(cp.dst)) |dv| {
                for (remaining.items) |*other| {
                    if (vregOf(other.src) == dv) {
                        other.src = tmp_op;
                    }
                }
            }
        }
    }

    var insert_idx: usize = pred.instrs.items.len;
    for (pred.instrs.items, 0..) |mi, i| {
        switch (mi) {
            .jmp, .jcc, .ret => {
                insert_idx = i;
                break;
            },
            else => {},
        }
    }

    var idx: usize = insert_idx;
    for (resolved.items) |rc| {
        if (vregOf(rc.dst)) |dv| {
            if (vregOf(rc.src) == dv) continue;
        }
        try pred.instrs.insert(idx, .{ .mov = .{ .dst = rc.dst, .src = rc.src } });
        idx += 1;
    }
}

const ResolvedCopy = struct {
    dst: mir.MOperand,
    src: mir.MOperand,
};

fn dstVReg(inst: mir.MInst) ?u32 {
    return switch (inst) {
        .mov => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .add => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .sub => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .imul => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .idiv => |m| if (m.quotient == .vreg) m.quotient.vreg else null,
        .@"and" => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .@"or" => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .xor => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .shl, .shr, .sar => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .not_op, .neg_op => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .call => |m| if (!m.is_void and m.dst == .vreg) m.dst.vreg else null,
        .alloca => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .load => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .phi => |p| if (p.dst == .vreg) p.dst.vreg else null,
        else => null,
    };
}

fn srcVregs(inst: mir.MInst, buf: *[8]u32) usize {
    var n: usize = 0;
    switch (inst) {
        .mov => |m| {
            if (m.src == .vreg) {
                buf[n] = m.src.vreg;
                n += 1;
            }
        },
        .add => |m| {
            if (m.src == .vreg) {
                buf[n] = m.src.vreg;
                n += 1;
            }
        },
        .sub => |m| {
            if (m.src == .vreg) {
                buf[n] = m.src.vreg;
                n += 1;
            }
        },
        .imul => |m| {
            if (m.src == .vreg) {
                buf[n] = m.src.vreg;
                n += 1;
            }
        },
        .idiv => |m| {
            if (m.divisor == .vreg) {
                buf[n] = m.divisor.vreg;
                n += 1;
            }
        },
        .@"and" => |m| {
            if (m.src == .vreg) {
                buf[n] = m.src.vreg;
                n += 1;
            }
        },
        .@"or" => |m| {
            if (m.src == .vreg) {
                buf[n] = m.src.vreg;
                n += 1;
            }
        },
        .xor => |m| {
            if (m.src == .vreg) {
                buf[n] = m.src.vreg;
                n += 1;
            }
        },
        .shl, .shr, .sar => |m| {
            if (m.amount == .vreg) {
                buf[n] = m.amount.vreg;
                n += 1;
            }
        },
        .not_op, .neg_op => |m| {
            if (m.dst == .vreg) {
                buf[n] = m.dst.vreg;
                n += 1;
            }
        },
        .cmp => |m| {
            if (m.a == .vreg) {
                buf[n] = m.a.vreg;
                n += 1;
            }
            if (m.b == .vreg) {
                buf[n] = m.b.vreg;
                n += 1;
            }
        },
        .cmp_flags => |m| {
            if (m.a == .vreg) {
                buf[n] = m.a.vreg;
                n += 1;
            }
            if (m.b == .vreg) {
                buf[n] = m.b.vreg;
                n += 1;
            }
        },
        .test_flags => |m| {
            if (m.a == .vreg) {
                buf[n] = m.a.vreg;
                n += 1;
            }
            if (m.b == .vreg) {
                buf[n] = m.b.vreg;
                n += 1;
            }
        },
        .call => |m| {
            for (0..m.arg_count) |j| {
                if (m.args[j] == .vreg) {
                    buf[n] = m.args[j].vreg;
                    n += 1;
                }
            }
        },
        .load => |m| {
            if (m.ptr == .vreg) {
                buf[n] = m.ptr.vreg;
                n += 1;
            }
        },
        .store => |m| {
            if (m.ptr == .vreg) {
                buf[n] = m.ptr.vreg;
                n += 1;
            }
            if (m.src == .vreg) {
                buf[n] = m.src.vreg;
                n += 1;
            }
        },
        .ret => |m| {
            switch (m) {
                .void_ret => {},
                .value => |v| {
                    if (v == .vreg) {
                        buf[n] = v.vreg;
                        n += 1;
                    }
                },
            }
        },
        .phi => |p| {
            for (p.incoming) |inc| {
                if (inc.src == .vreg) {
                    buf[n] = inc.src.vreg;
                    n += 1;
                }
            }
        },
        else => {},
    }
    return n;
}

fn vregOf(op: mir.MOperand) ?u32 {
    return switch (op) {
        .vreg => |v| v,
        else => null,
    };
}
