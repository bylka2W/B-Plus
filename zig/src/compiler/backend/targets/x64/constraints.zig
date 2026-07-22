const mir = @import("../../mir/mir.zig");
const MInst = mir.MInst;

pub const ConstraintType = enum {
    none,
    fixed_reg,
    fixed_pair,
    byte_register,
    xmm_register,
    memory_operand,
};

pub const RegRequirement = struct {
    operand: OperandRole,
    constraint: ConstraintType,
    reg: i16 = 0,
    message: []const u8 = "",
};

pub const OperandRole = enum {
    dividend,
    divisor,
    quotient,
    remainder,
    shift_count,
    dst,
    src,
    a,
    b,
    ptr,
    base,
    index,
};

pub const InstConstraints = struct {
    requirements: []const RegRequirement,
};

pub fn getConstraints(inst: MInst) InstConstraints {
    return switch (inst) {
        .idiv => .{ .requirements = &idiv_constraints },
        .shl, .shr, .sar => .{ .requirements = &shift_constraints },
        .setcc => .{ .requirements = &setcc_constraints },
        .call => .{ .requirements = &call_constraints_win64 },
        .imul => .{ .requirements = &imul_constraints },
        .fcmp => .{ .requirements = &fcmp_constraints },
        .fadd, .fsub, .fmul, .fdiv => .{ .requirements = &xmm_binop_constraints },
        .fneg_op, .fsqrt_op => .{ .requirements = &xmm_unop_constraints },
        .sitofp, .fptosi, .fpext, .fptrunc => .{ .requirements = &conversion_constraints },
        else => .{ .requirements = &.{ } },
    };
}

const idiv_constraints = [_]RegRequirement{
    .{ .operand = .dividend, .constraint = .fixed_reg, .reg = 0, .message = "IDIV dividend must be in RAX" },
    .{ .operand = .quotient, .constraint = .fixed_reg, .reg = 0, .message = "IDIV quotient result must be in RAX" },
};

const shift_constraints = [_]RegRequirement{
    .{ .operand = .shift_count, .constraint = .fixed_reg, .reg = 1, .message = "Shift count must be in RCX" },
};

const setcc_constraints = [_]RegRequirement{
    .{ .operand = .dst, .constraint = .byte_register, .message = "SETCC destination must be a byte-accessible register (not RSP, RBP, R12, R13)" },
};

const call_constraints_win64 = [_]RegRequirement{
    .{ .operand = .a, .constraint = .fixed_reg, .reg = 1, .message = "Win64 CALL arg0 must be in RCX" },
};

const imul_constraints = [_]RegRequirement{
    .{ .operand = .dst, .constraint = .fixed_reg, .reg = 0, .message = "IMUL 2-operand form: dst must be in RAX" },
};

const fcmp_constraints = [_]RegRequirement{
    .{ .operand = .a, .constraint = .xmm_register, .message = "FCMP operand A must be XMM" },
    .{ .operand = .b, .constraint = .xmm_register, .message = "FCMP operand B must be XMM" },
};

const xmm_binop_constraints = [_]RegRequirement{
    .{ .operand = .dst, .constraint = .xmm_register, .message = "Float binop destination must be XMM" },
    .{ .operand = .a, .constraint = .xmm_register, .message = "Float binop operand A must be XMM" },
    .{ .operand = .b, .constraint = .xmm_register, .message = "Float binop operand B must be XMM" },
};

const xmm_unop_constraints = [_]RegRequirement{
    .{ .operand = .dst, .constraint = .xmm_register, .message = "Float unop destination must be XMM" },
};

const conversion_constraints = [_]RegRequirement{
    .{ .operand = .dst, .constraint = .xmm_register, .message = "Float conversion destination must be XMM" },
};
