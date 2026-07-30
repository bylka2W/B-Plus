const std = @import("std");
const mir = @import("../mir.zig");

pub const VerifyError = error{
    InvalidBlockTarget,
    MissingTerminator,
    UnreachableBlock,
    UndefinedVReg,
    PhiNotEliminated,
};

fn checkDefined(defs: *std.AutoHashMap(u32, void), op: mir.MOperand) !void {
    if (op == .vreg and !defs.contains(op.vreg)) return error.UndefinedVReg;
}

fn collectDefinedVRegs(mfunc: *const mir.MFunction) std.AutoHashMap(u32, void) {
    var defs = std.AutoHashMap(u32, void).init(std.heap.page_allocator);
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
                .idiv => |m| m.quotient,
                .@"and" => |a| a.dst,
                .@"or" => |o| o.dst,
                .xor => |x| x.dst,
                .shl => |s| s.dst,
                .shr => |s| s.dst,
                .sar => |s| s.dst,
                .not_op => |n| n.dst,
                .neg_op => |n| n.dst,
                .setcc => |s| s.dst,
                .call => |c| if (c.is_void) continue else c.dst,
                .alloca => |a| a.dst,
                .load => |l| l.dst,
                .lea => |l| l.dst,
                .phi => |p| p.dst,
                .fadd => |f| f.dst,
                .fsub => |f| f.dst,
                .fmul => |f| f.dst,
                .fdiv => |f| f.dst,
                .fneg_op => |f| f.dst,
                .fsqrt_op => |f| f.dst,
                .fcmp => |f| f.dst,
                .sitofp => |c| c.dst,
                .fptosi => |c| c.dst,
                .fpext => |c| c.dst,
                .fptrunc => |c| c.dst,
                .sext_op => |c| c.dst,
                .zext_op => |c| c.dst,
                .trunc_op => |c| c.dst,
                .select => |s| s.dst,
                .event_dispatch => |m| m.dst,
                .transition_check => |m| m.result,
                .guard_eval => |m| m.result,
                .string_const => |s| s.dst,
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
        .idiv => |m| {
            try checkDefined(defs, m.dividend);
            try checkDefined(defs, m.divisor);
        },
        .@"and" => |a| try checkDefined(defs, a.src),
        .@"or" => |o| try checkDefined(defs, o.src),
        .xor => |x| try checkDefined(defs, x.src),
        .shl => |s| try checkDefined(defs, s.amount),
        .shr => |s| try checkDefined(defs, s.amount),
        .sar => |s| try checkDefined(defs, s.amount),
        .not_op => |n| try checkDefined(defs, n.dst),
        .neg_op => |n| try checkDefined(defs, n.dst),
        .test_flags => |tf| {
            try checkDefined(defs, tf.a);
            try checkDefined(defs, tf.b);
        },
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
        .lea => |l| {
            try checkDefined(defs, l.base);
            if (l.index != .imm) try checkDefined(defs, l.index);
        },
        .store => |s| {
            try checkDefined(defs, s.ptr);
            try checkDefined(defs, s.src);
        },
        .ret => |r| switch (r) {
            .void_ret => {},
            .value => |v| try checkDefined(defs, v),
        },
        .phi => |p| {
            for (p.incoming) |inc| {
                try checkDefined(defs, inc.src);
            }
        },
        .fadd => |f| {
            try checkDefined(defs, f.a);
            try checkDefined(defs, f.b);
        },
        .fsub => |f| {
            try checkDefined(defs, f.a);
            try checkDefined(defs, f.b);
        },
        .fmul => |f| {
            try checkDefined(defs, f.a);
            try checkDefined(defs, f.b);
        },
        .fdiv => |f| {
            try checkDefined(defs, f.a);
            try checkDefined(defs, f.b);
        },
        .fneg_op => |f| try checkDefined(defs, f.dst),
        .fsqrt_op => |f| try checkDefined(defs, f.dst),
        .fcmp => |f| {
            try checkDefined(defs, f.a);
            try checkDefined(defs, f.b);
        },
        .sitofp => |c| try checkDefined(defs, c.src),
        .fptosi => |c| try checkDefined(defs, c.src),
        .fpext => |c| try checkDefined(defs, c.src),
        .fptrunc => |c| try checkDefined(defs, c.src),
        .sext_op => |c| try checkDefined(defs, c.src),
        .zext_op => |c| try checkDefined(defs, c.src),
        .trunc_op => |c| try checkDefined(defs, c.src),
        .select => |s| {
            try checkDefined(defs, s.dst);
            try checkDefined(defs, s.src);
        },
        .event_dispatch => |m| {
            try checkDefined(defs, m.buf);
            try checkDefined(defs, m.size);
        },
        .transition_check => |m| {
            try checkDefined(defs, m.event);
        },
        .guard_eval => |m| {
            try checkDefined(defs, m.lhs);
            try checkDefined(defs, m.rhs);
        },
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

    var visited = std.AutoHashMap(usize, void).init(std.heap.page_allocator);
    defer visited.deinit();
    var queue = std.ArrayList(usize).init(std.heap.page_allocator);
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

pub fn verifyNoPhis(mfunc: *const mir.MFunction) !void {
    for (mfunc.blocks.items) |*block| {
        for (block.instrs.items) |inst| {
            if (inst == .phi) return error.PhiNotEliminated;
        }
    }
}
