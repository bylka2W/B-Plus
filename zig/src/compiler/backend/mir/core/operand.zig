const std = @import("std");

pub const PhysReg = u16;

pub const MOperand = union(enum) {
    vreg: u32,
    phys: PhysReg,
    imm: i64,
    mem: MemOp,
};

pub const MemOp = struct {
    base: PhysReg,
    offset: i32,
    size: u8,
    index: ?PhysReg = null,
    scale: u8 = 1,

    pub fn simple(base: PhysReg, offset: i32, size: u8) MemOp {
        return .{ .base = base, .offset = offset, .size = size };
    }

    pub fn indexed(base: PhysReg, index: PhysReg, scale: u8, offset: i32, size: u8) MemOp {
        return .{ .base = base, .offset = offset, .size = size, .index = index, .scale = scale };
    }
};

pub const CondCode = enum(u8) {
    eq = 4,
    ne = 5,
    lt = 0xC,
    le = 0xE,
    gt = 0xF,
    ge = 0xD,
};
