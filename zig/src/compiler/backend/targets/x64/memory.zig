/// x64 addressing mode helpers.
const Operand = @import("encoder.zig").Operand;

/// Create a memory operand with base register and displacement.
pub fn mem(base: i16, disp: i32) Operand {
    return Operand.mem(base, disp);
}

/// Create a SIB-scaled memory operand: [base + index*scale + disp].
pub fn memIdx(base: i16, index: i16, scale: u8, disp: i32) Operand {
    return Operand.memIdx(base, index, scale, disp);
}

/// Create a RIP-relative memory operand (base=255 signals RIP).
pub fn memRip(disp: i32) Operand {
    return Operand.mem(255, disp);
}

/// Create a stack-relative memory operand: [rbp + offset].
pub fn stack(offset: i32) Operand {
    return Operand.mem(5, offset);
}

/// Create a register operand.
pub fn reg(r: i16) Operand {
    return Operand.r(r);
}

/// Create an XMM register operand.
pub fn xmm(r: i16) Operand {
    return Operand.xmm(r);
}

/// Create an immediate operand.
pub fn imm(v: i64) Operand {
    return Operand.imm(v);
}

/// Create a zero-extended 32-bit immediate.
pub fn immU32(v: u32) Operand {
    return Operand.immU32(v);
}

/// Estimate addressing mode complexity (0 = simple reg, 1 = base+disp, 2 = indexed).
pub fn addrComplexity(op: Operand) u32 {
    if (op.reg >= 0) return 0;
    if (op.index_reg < 0) return 1;
    return 2;
}

/// Returns true if the operand is a direct register.
pub fn isReg(op: Operand) bool {
    return op.reg >= 0 and !op.is_xmm;
}

/// Returns true if the operand is an XMM register.
pub fn isXmm(op: Operand) bool {
    return op.reg >= 0 and op.is_xmm;
}

/// Returns true if the operand is a memory reference.
pub fn isMem(op: Operand) bool {
    return op.base_reg >= 0;
}

/// Returns true if the operand is an immediate.
pub fn isImm(op: Operand) bool {
    return op.imm64 != 0 or (op.reg < 0 and op.base_reg < 0 and !op.is_xmm);
}
