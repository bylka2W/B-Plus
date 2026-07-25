pub const TypeKind = enum {
    void,
    bool_type,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    string,
    pointer,
    struct_type,
    enum_type,
    array,
    function,

    pub fn isInt(self: TypeKind) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64,
            .u8, .u16, .u32, .u64,
            => true,
            else => false,
        };
    }

    pub fn isFloat(self: TypeKind) bool {
        return self == .f32 or self == .f64;
    }

    pub fn isNumeric(self: TypeKind) bool {
        return self.isInt() or self.isFloat();
    }

    pub fn bitWidth(self: TypeKind) ?u16 {
        return switch (self) {
            .bool_type => 1,
            .i8, .u8 => 8,
            .i16, .u16 => 16,
            .i32, .u32, .f32 => 32,
            .i64, .u64, .f64 => 64,
            else => null,
        };
    }

    pub fn isSigned(self: TypeKind) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64 => true,
            else => false,
        };
    }

    pub fn name(self: TypeKind) []const u8 {
        return switch (self) {
            .void => "void",
            .bool_type => "bool",
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .f32 => "f32",
            .f64 => "f64",
            .string => "string",
            .pointer => "ptr",
            .struct_type => "struct",
            .enum_type => "enum",
            .array => "array",
            .function => "fn",
        };
    }
};
