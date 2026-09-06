
const Operand = @import("encoder.zig").Operand;


pub fn mem(base: i16, disp: i32) Operand {
    return Operand.mem(base, disp);
}


pub fn memIdx(base: i16, index: i16, scale: u8, disp: i32) Operand {
    return Operand.memIdx(base, index, scale, disp);
}


pub fn memRip(disp: i32) Operand {
    return Operand.mem(255, disp);
}


pub fn stack(offset: i32) Operand {
    return Operand.mem(5, offset);
}


pub fn reg(r: i16) Operand {
    return Operand.r(r);
}

pub fn xmm(r: i16) Operand {
    return Operand.xmm(r);
}

pub fn imm(v: i64) Operand {
    return Operand.imm(v);
}


pub fn immU32(v: u32) Operand {
    return Operand.immU32(v);
}


pub fn addrComplexity(op: Operand) u32 {
    if (op.reg >= 0) return 0;
    if (op.index_reg < 0) return 1;
    return 2;
}


pub fn isReg(op: Operand) bool {
    return op.reg >= 0 and !op.is_xmm;
}


pub fn isXmm(op: Operand) bool {
    return op.reg >= 0 and op.is_xmm;
}


pub fn isMem(op: Operand) bool {
    return op.base_reg >= 0;
}

pub fn isImm(op: Operand) bool {
    return op.imm64 != 0 or (op.reg < 0 and op.base_reg < 0 and !op.is_xmm);
}
