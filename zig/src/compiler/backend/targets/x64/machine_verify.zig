const std = @import("std");
const mir = @import("../../mir/mir.zig");
const regalloc_mod = @import("regalloc.zig");
const constraints = @import("constraints.zig");

const RegAllocResult = regalloc_mod.RegAllocResult;

pub const VerifyError = error{
    ConstraintViolation,
    OutOfMemory,
};

pub const Diagnostic = struct {
    block: usize,
    instruction_index: usize,
    message: []const u8,
};

pub fn verifyAll(
    mfunc: *const mir.MFunction,
    ra: *const RegAllocResult,
    diagnostics: *std.ArrayList(Diagnostic),
) VerifyError!void {
    for (mfunc.blocks.items, 0..) |*block, bi| {
        for (block.instrs.items, 0..) |inst, ii| {
            try verifyInst(mfunc, ra, bi, ii, inst, diagnostics);
        }
    }
}

fn getReg(vreg: u32, ra: *const RegAllocResult) ?i16 {
    return ra.regs.get(vreg);
}

fn isByteAccessible(reg: i16) bool {
    return switch (reg) {
        4 => false, // RSP - no low byte
        5 => false, // RBP - no low byte
        12 => false, // R12 - requires SIB
        13 => false, // R13 - requires displacement
        else => true,
    };
}

fn isXMM(reg: i16) bool {
    return reg >= 16;
}

fn report(
    diagnostics: *std.ArrayList(Diagnostic),
    bi: usize,
    ii: usize,
    msg: []const u8,
) !void {
    try diagnostics.append(.{
        .block = bi,
        .instruction_index = ii,
        .message = msg,
    });
}

fn verifyInst(
    mfunc: *const mir.MFunction,
    ra: *const RegAllocResult,
    bi: usize,
    ii: usize,
    inst: mir.MInst,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    _ = mfunc;
    switch (inst) {
        .idiv => |m| {
            if (m.quotient == .vreg) {
                if (getReg(m.quotient.vreg, ra)) |reg| {
                    if (reg != 0) {
                        try report(diagnostics, bi, ii, "IDIV quotient must be in RAX (phys reg 0)");
                    }
                }
            }
            if (m.dividend == .vreg) {
                if (getReg(m.dividend.vreg, ra)) |reg| {
                    if (reg != 0) {
                        try report(diagnostics, bi, ii, "IDIV dividend must be loaded into RAX before the instruction");
                    }
                }
            }
            if (m.remainder == .vreg) {
                if (getReg(m.remainder.vreg, ra)) |reg| {
                    if (reg != 2) {
                        try report(diagnostics, bi, ii, "IDIV remainder must be in RDX (phys reg 2)");
                    }
                }
            }
        },
        .shl, .shr, .sar => |m| {
            if (m.amount == .vreg) {
                if (getReg(m.amount.vreg, ra)) |reg| {
                    if (reg != 1) {
                        try report(diagnostics, bi, ii, "Shift count must be in RCX (phys reg 1)");
                    }
                }
            }
        },
        .setcc => |m| {
            if (m.dst == .vreg) {
                if (getReg(m.dst.vreg, ra)) |reg| {
                    if (!isByteAccessible(reg)) {
                        try report(diagnostics, bi, ii, "SETCC destination register has no low-byte encoding (not RSP/RBP/R12/R13)");
                    }
                }
            }
        },
        .call => |m| {
            for (0..m.arg_count) |ai| {
                const arg = m.args[ai];
                if (arg == .vreg) {
                    if (getReg(arg.vreg, ra)) |reg| {
                        if (ai == 0 and reg != 1) {
                            try report(diagnostics, bi, ii, "Win64: first call argument must be in RCX");
                        }
                        if (ai == 1 and reg != 2) {
                            try report(diagnostics, bi, ii, "Win64: second call argument must be in RDX");
                        }
                        if (ai == 2 and reg != 8) {
                            try report(diagnostics, bi, ii, "Win64: third call argument must be in R8");
                        }
                        if (ai == 3 and reg != 9) {
                            try report(diagnostics, bi, ii, "Win64: fourth call argument must be in R9");
                        }
                    }
                }
            }
            if (m.dst == .vreg) {
                if (getReg(m.dst.vreg, ra)) |reg| {
                    if (reg != 0) {
                        try report(diagnostics, bi, ii, "CALL return value must be in RAX");
                    }
                }
            }
        },
        .fadd, .fsub, .fmul, .fdiv => |m| {
            if (m.dst == .vreg) {
                if (getReg(m.dst.vreg, ra)) |reg| {
                    if (!isXMM(reg)) {
                        try report(diagnostics, bi, ii, "Float binary op destination must be XMM register");
                    }
                }
            }
        },
        .fcmp => |m| {
            if (m.dst == .vreg) {
                if (getReg(m.dst.vreg, ra)) |reg| {
                    if (!isXMM(reg)) {
                        try report(diagnostics, bi, ii, "FCMP destination must be XMM register");
                    }
                }
            }
        },
        .fneg_op, .fsqrt_op => |m| {
            if (m.dst == .vreg) {
                if (getReg(m.dst.vreg, ra)) |reg| {
                    if (!isXMM(reg)) {
                        try report(diagnostics, bi, ii, "Float unary op destination must be XMM register");
                    }
                }
            }
        },
        .sitofp, .fptosi, .fpext, .fptrunc => |m| {
            if (m.dst == .vreg) {
                if (getReg(m.dst.vreg, ra)) |reg| {
                    if (!isXMM(reg)) {
                        try report(diagnostics, bi, ii, "Float conversion destination must be XMM register");
                    }
                }
            }
        },
        else => {},
    }
}
