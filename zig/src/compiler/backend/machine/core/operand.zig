const std = @import("std");
const RegClass = @import("value.zig").RegClass;

pub const PhysReg = u16;

pub const MOperand = union(enum) {
    vreg: VRegRef,
    phys: PhysReg,
    imm: i64,
    mem: MemOp,

    pub fn vregRef(id: u32, class: RegClass) MOperand {
        return .{ .vreg = .{ .id = id, .class = class } };
    }

    pub fn isVReg(self: MOperand) bool {
        return self == .vreg;
    }

    pub fn vregClass(self: MOperand) ?RegClass {
        return switch (self) {
            .vreg => |v| v.class,
            else => null,
        };
    }
};

pub const VRegRef = struct {
    id: u32,
    class: RegClass,
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
};

pub const CondCode = enum(u8) {
    eq = 4,
    ne = 5,
    lt = 0xC,
    le = 0xE,
    gt = 0xF,
    ge = 0xD,
};
