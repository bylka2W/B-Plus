pub const DataType = enum(u8) {
    void = 0,
    i1 = 1,
    i8 = 8,
    i16 = 16,
    i32 = 32,
    i64 = 64,
    f32 = 128,
    f64 = 129,

    pub fn size(self: DataType) u8 {
        return switch (self) {
            .void => 0,
            .i1 => 1,
            .i8 => 1,
            .i16 => 2,
            .i32 => 4,
            .i64 => 8,
            .f32 => 4,
            .f64 => 8,
        };
    }

    pub fn isFloat(self: DataType) bool {
        return switch (self) {
            .f32, .f64 => true,
            else => false,
        };
    }

    pub fn isInteger(self: DataType) bool {
        return switch (self) {
            .i1, .i8, .i16, .i32, .i64 => true,
            else => false,
        };
    }
};

pub const VRegClass = enum {
    gpr,
    xmm,

    pub fn forType(ty: DataType) VRegClass {
        return if (ty.isFloat()) .xmm else .gpr;
    }
};

pub const VRegInfo = struct {
    ty: DataType,
    class: VRegClass,

    pub fn init(ty: DataType) VRegInfo {
        return .{ .ty = ty, .class = VRegClass.forType(ty) };
    }
};
