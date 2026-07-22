const std = @import("std");

pub const TypeId = enum(u32) {
    invalid = 0,
    void,
    bool_type,

    i8_type,
    i16_type,
    i32_type,
    i64_type,

    u8_type,
    u16_type,
    u32_type,
    u64_type,

    f32_type,
    f64_type,

    string_type,
    ptr_type,

    struct_type,
    enum_type,
    _,

    pub fn fromName(name: []const u8) TypeId {
        if (std.mem.eql(u8, name, "void")) return .void;
        if (std.mem.eql(u8, name, "bool")) return .bool_type;
        if (std.mem.eql(u8, name, "i8")) return .i8_type;
        if (std.mem.eql(u8, name, "i16")) return .i16_type;
        if (std.mem.eql(u8, name, "i32")) return .i32_type;
        if (std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "int")) return .i64_type;
        if (std.mem.eql(u8, name, "u8")) return .u8_type;
        if (std.mem.eql(u8, name, "u16")) return .u16_type;
        if (std.mem.eql(u8, name, "u32")) return .u32_type;
        if (std.mem.eql(u8, name, "u64")) return .u64_type;
        if (std.mem.eql(u8, name, "f32")) return .f32_type;
        if (std.mem.eql(u8, name, "f64")) return .f64_type;
        if (std.mem.eql(u8, name, "string")) return .string_type;
        if (std.mem.eql(u8, name, "ptr")) return .ptr_type;
        return .invalid;
    }

    pub fn isInt(self: TypeId) bool {
        return switch (self) {
            .i8_type, .i16_type, .i32_type, .i64_type,
            .u8_type, .u16_type, .u32_type, .u64_type,
            => true,
            else => false,
        };
    }

    pub fn isFloat(self: TypeId) bool {
        return self == .f32_type or self == .f64_type;
    }

    pub fn isNumeric(self: TypeId) bool {
        return self.isInt() or self.isFloat();
    }

    pub fn isBool(self: TypeId) bool {
        return self == .bool_type or self == .i8_type;
    }

    pub fn isPtr(self: TypeId) bool {
        return self == .ptr_type or self == .string_type;
    }

    pub fn name(self: TypeId) []const u8 {
        return switch (self) {
            .invalid => "invalid",
            .void => "void",
            .bool_type => "bool",
            .i8_type => "i8",
            .i16_type => "i16",
            .i32_type => "i32",
            .i64_type => "i64",
            .u8_type => "u8",
            .u16_type => "u16",
            .u32_type => "u32",
            .u64_type => "u64",
            .f32_type => "f32",
            .f64_type => "f64",
            .string_type => "string",
            .ptr_type => "ptr",
            .struct_type => "struct",
            .enum_type => "enum",
            _ => "custom",
        };
    }

    pub fn isVoid(self: TypeId) bool {
        return self == .void;
    }

    pub fn isReturnCompatible(self: TypeId) bool {
        return self != .invalid;
    }
};

pub const FuncParam = struct {
    name: []const u8,
    ty: TypeId,
};

pub const InferredType = struct {
    pub fn inferBinary(left: TypeId, right: TypeId) TypeId {
        if (left == right) return left;
        if (left == .bool_type or right == .bool_type) return .bool_type;
        if (left == .f64_type or right == .f64_type) return .f64_type;
        if (left == .f32_type or right == .f32_type) return .f32_type;
        if (left == .ptr_type or right == .ptr_type) return .ptr_type;
        if (left == .string_type or right == .string_type) return .string_type;
        return left;
    }

    pub fn inferComparison(left: TypeId, right: TypeId) TypeId {
        _ = right;
        _ = left;
        return .bool_type;
    }

    pub fn inferArithmetic(left: TypeId, right: TypeId) TypeId {
        if (left == .f64_type or right == .f64_type) return .f64_type;
        if (left == .f32_type or right == .f32_type) return .f32_type;
        if (left == right) return left;
        return .i64_type;
    }
};
