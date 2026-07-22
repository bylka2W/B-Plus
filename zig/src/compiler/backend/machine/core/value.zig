pub const DataType = @import("../../mir/core/value.zig").DataType;

pub const RegClass = enum {
    gpr,
    xmm,
    flags,

    pub fn forType(ty: DataType) RegClass {
        return if (ty.isFloat()) .xmm else .gpr;
    }
};
