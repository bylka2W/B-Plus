const std = @import("std");
const machine = @import("../../machine.zig");
const MInst = machine.MInst;
const MOperand = machine.MOperand;

pub const VerifyError = error{
    UndefinedVReg,
    OperandTypeMismatch,
    MissingDst,
    UnusedDst,
};

pub fn verifyInst(
    inst: MInst,
    func: *const machine.MFunction,
    defined_vregs: *const std.AutoHashMap(u32, void),
) VerifyError!void {
    switch (inst) {
        .add => |bin| {
            try verifyOperand(func, bin.dst, defined_vregs);
            try verifyOperand(func, bin.src, defined_vregs);
        },
        .sub => |bin| {
            try verifyOperand(func, bin.dst, defined_vregs);
            try verifyOperand(func, bin.src, defined_vregs);
        },
        .imul => |bin| {
            try verifyOperand(func, bin.dst, defined_vregs);
            try verifyOperand(func, bin.src, defined_vregs);
        },
        .@"and" => |bin| {
            try verifyOperand(func, bin.dst, defined_vregs);
            try verifyOperand(func, bin.src, defined_vregs);
        },
        .@"or" => |bin| {
            try verifyOperand(func, bin.dst, defined_vregs);
            try verifyOperand(func, bin.src, defined_vregs);
        },
        .xor => |bin| {
            try verifyOperand(func, bin.dst, defined_vregs);
            try verifyOperand(func, bin.src, defined_vregs);
        },
        .idiv => |d| {
            try verifyOperand(func, d.dividend, defined_vregs);
            try verifyOperand(func, d.divisor, defined_vregs);
            try verifyOperand(func, d.quotient, defined_vregs);
            try verifyOperand(func, d.remainder, defined_vregs);
        },
        .shl, .shr, .sar => |s| {
            try verifyOperand(func, s.dst, defined_vregs);
            try verifyOperand(func, s.amount, defined_vregs);
        },
        .mov => |m| {
            try verifyOperand(func, m.dst, defined_vregs);
            try verifyOperand(func, m.src, defined_vregs);
        },
        .cmp => |c| {
            try verifyOperand(func, c.a, defined_vregs);
            try verifyOperand(func, c.b, defined_vregs);
        },
        .not_op, .neg_op, .fneg_op, .fsqrt_op => |u| {
            try verifyOperand(func, u.dst, defined_vregs);
        },
        .fadd, .fsub, .fmul, .fdiv => |f| {
            try verifyOperand(func, f.dst, defined_vregs);
            try verifyOperand(func, f.a, defined_vregs);
            try verifyOperand(func, f.b, defined_vregs);
        },
        .fcmp => |c| {
            try verifyOperand(func, c.dst, defined_vregs);
            try verifyOperand(func, c.a, defined_vregs);
            try verifyOperand(func, c.b, defined_vregs);
        },
        .sitofp, .fptosi, .fpext, .fptrunc, .sext_op, .zext_op, .trunc_op => |c| {
            try verifyOperand(func, c.dst, defined_vregs);
            try verifyOperand(func, c.src, defined_vregs);
        },
        .select => |s| {
            try verifyOperand(func, s.dst, defined_vregs);
            try verifyOperand(func, s.src, defined_vregs);
        },
        .alloca => |a| {
            try verifyOperand(func, a.dst, defined_vregs);
        },
        .load => |l| {
            try verifyOperand(func, l.dst, defined_vregs);
            try verifyOperand(func, l.ptr, defined_vregs);
        },
        .store => |s| {
            try verifyOperand(func, s.ptr, defined_vregs);
            try verifyOperand(func, s.src, defined_vregs);
        },
        .lea => |l| {
            try verifyOperand(func, l.dst, defined_vregs);
            try verifyOperand(func, l.base, defined_vregs);
            if (l.index != .imm) {
                try verifyOperand(func, l.index, defined_vregs);
            }
        },
        .call => |c| {
            if (c.dst != .imm) {
                try verifyOperand(func, c.dst, defined_vregs);
            }
            for (0..c.arg_count) |i| {
                try verifyOperand(func, c.args[i], defined_vregs);
            }
        },
        .ret => |r| switch (r) {
            .void_ret => {},
            .value => |val| try verifyOperand(func, val, defined_vregs),
        },
        .test_flags => |tf| {
            try verifyOperand(func, tf.a, defined_vregs);
            try verifyOperand(func, tf.b, defined_vregs);
        },
        .cmp_flags => |cf| {
            try verifyOperand(func, cf.a, defined_vregs);
            try verifyOperand(func, cf.b, defined_vregs);
        },
        .jmp, .jcc => {},
        .setcc => |s| {
            try verifyOperand(func, s.dst, defined_vregs);
        },
        .state_init => |s| {
            try verifyOperand(func, s.initial_state, defined_vregs);
        },
        .state_enter => |s| {
            try verifyOperand(func, s.state_id, defined_vregs);
        },
        .state_exit => |s| {
            try verifyOperand(func, s.state_id, defined_vregs);
        },
        .event_dispatch => |e| {
            try verifyOperand(func, e.dst, defined_vregs);
            try verifyOperand(func, e.buf, defined_vregs);
            try verifyOperand(func, e.size, defined_vregs);
        },
        .transition_check => |t| {
            try verifyOperand(func, t.result, defined_vregs);
            try verifyOperand(func, t.event, defined_vregs);
        },
        .guard_eval => |g| {
            try verifyOperand(func, g.result, defined_vregs);
            try verifyOperand(func, g.lhs, defined_vregs);
            try verifyOperand(func, g.rhs, defined_vregs);
        },
    }
}

fn verifyOperand(
    _: *const machine.MFunction,
    op: MOperand,
    defined_vregs: *const std.AutoHashMap(u32, void),
) VerifyError!void {
    switch (op) {
        .vreg => |v| {
            if (!defined_vregs.contains(v.id)) return error.UndefinedVReg;
        },
        .phys, .imm, .mem => {},
    }
}
