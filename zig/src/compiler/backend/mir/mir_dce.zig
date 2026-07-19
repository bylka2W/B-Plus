const std = @import("std");
const mir = @import("mir.zig");

const Ref = packed struct(u64) {
    block: u31,
    instr: u33,
};

fn dstVreg(inst: mir.MInst) ?u32 {
    return switch (inst) {
        .mov => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .add => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .sub => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .imul => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .idiv => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .cmp => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .call => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .alloca => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .load => |m| if (m.dst == .vreg) m.dst.vreg else null,
        .phi => |p| if (p.dst == .vreg) p.dst.vreg else null,
        .cmp_flags, .jmp, .jcc, .store, .ret => null,
    };
}

fn isSideEffecting(inst: mir.MInst) bool {
    return switch (inst) {
        .call, .store, .ret, .jmp, .jcc, .cmp_flags => true,
        .add, .sub, .imul, .idiv, .cmp, .alloca, .load, .phi => false,
        .mov => |m| m.dst != .vreg,
    };
}

fn srcVregs(inst: mir.MInst, buf: *[8]u32) usize {
    var n: usize = 0;
    switch (inst) {
        .mov => |m| {
            if (m.src == .vreg) { buf[n] = m.src.vreg; n += 1; }
        },
        .add => |m| {
            if (m.dst == .vreg) { buf[n] = m.dst.vreg; n += 1; }
            if (m.src == .vreg) { buf[n] = m.src.vreg; n += 1; }
        },
        .sub => |m| {
            if (m.dst == .vreg) { buf[n] = m.dst.vreg; n += 1; }
            if (m.src == .vreg) { buf[n] = m.src.vreg; n += 1; }
        },
        .imul => |m| {
            if (m.dst == .vreg) { buf[n] = m.dst.vreg; n += 1; }
            if (m.src == .vreg) { buf[n] = m.src.vreg; n += 1; }
        },
        .idiv => |m| {
            if (m.dst == .vreg) { buf[n] = m.dst.vreg; n += 1; }
            if (m.src == .vreg) { buf[n] = m.src.vreg; n += 1; }
        },
        .cmp => |m| {
            if (m.a == .vreg) { buf[n] = m.a.vreg; n += 1; }
            if (m.b == .vreg) { buf[n] = m.b.vreg; n += 1; }
        },
        .cmp_flags => |m| {
            if (m.a == .vreg) { buf[n] = m.a.vreg; n += 1; }
            if (m.b == .vreg) { buf[n] = m.b.vreg; n += 1; }
        },
        .call => |m| {
            for (0..m.arg_count) |j| {
                if (m.args[j] == .vreg) { buf[n] = m.args[j].vreg; n += 1; }
            }
        },
        .load => |m| {
            if (m.ptr == .vreg) { buf[n] = m.ptr.vreg; n += 1; }
        },
        .store => |m| {
            if (m.ptr == .vreg) { buf[n] = m.ptr.vreg; n += 1; }
            if (m.src == .vreg) { buf[n] = m.src.vreg; n += 1; }
        },
        .ret => |m| {
            if (m.val == .vreg) { buf[n] = m.val.vreg; n += 1; }
        },
        .phi => |p| {
            for (p.incoming) |inc| {
                if (inc.src == .vreg) { buf[n] = inc.src.vreg; n += 1; }
            }
        },
        .jmp, .jcc, .alloca => {},
    }
    return n;
}

pub fn dce(mf: *mir.MFunction) !void {
    const allocator = mf.allocator;

    var all_defs = std.AutoHashMap(u32, std.ArrayList(Ref)).init(allocator);
    defer {
        var it = all_defs.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        all_defs.deinit();
    }

    for (mf.blocks.items, 0..) |block, bi| {
        for (block.instrs.items, 0..) |inst, ii| {
            if (dstVreg(inst)) |vr| {
                const gop = try all_defs.getOrPut(vr);
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Ref).init(allocator);
                try gop.value_ptr.append(.{ .block = @intCast(bi), .instr = @intCast(ii) });
            }
        }
    }

    var marked = std.AutoHashMap(Ref, void).init(allocator);
    defer marked.deinit();

    var worklist = std.ArrayList(Ref).init(allocator);
    defer worklist.deinit();

    for (mf.blocks.items, 0..) |block, bi| {
        for (block.instrs.items, 0..) |inst, ii| {
            if (isSideEffecting(inst)) {
                const ref = Ref{ .block = @intCast(bi), .instr = @intCast(ii) };
                try marked.put(ref, {});
                try worklist.append(ref);
            }
        }
    }

    var src_buf: [8]u32 = undefined;
    while (worklist.items.len > 0) {
        const ref = worklist.pop() orelse unreachable;
        const inst = mf.blocks.items[ref.block].instrs.items[ref.instr];
        const n = srcVregs(inst, &src_buf);
        for (0..n) |j| {
            const vr = src_buf[j];
            const def_list = all_defs.get(vr) orelse continue;
            for (def_list.items) |dref| {
                if (!marked.contains(dref)) {
                    try marked.put(dref, {});
                    try worklist.append(dref);
                }
            }
        }
    }

    for (mf.blocks.items, 0..) |*block, bi| {
        var i: isize = @intCast(block.instrs.items.len);
        while (i > 0) {
            i -= 1;
            const ii = @as(usize, @intCast(i));
            if (!marked.contains(.{ .block = @intCast(bi), .instr = @intCast(ii) })) {
                _ = block.instrs.orderedRemove(ii);
            }
        }
    }
}
