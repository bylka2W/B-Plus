const std = @import("std");
const types_mod = @import("../type_system/types.zig");
const BuiltinKind = types_mod.BuiltinKind;

pub const CoercionResult = enum {
    identical,
    numeric_widening,
    numeric_optional,
    no_coercion,
};

pub fn canCoerce(from: BuiltinKind, to: BuiltinKind) CoercionResult {
    if (@as(u8, @intFromEnum(from)) == @intFromEnum(to)) return .identical;
    if (isNumeric(from) and isNumeric(to)) {
        if (@intFromEnum(to) > @intFromEnum(from)) return .numeric_widening;
        return .numeric_optional;
    }
    return .no_coercion;
}

pub fn isNumeric(k: BuiltinKind) bool {
    return switch (k) {
        .i8_type, .i16_type, .i32_type, .i64_type,
        .u8_type, .u16_type, .u32_type, .u64_type,
        .f32_type, .f64_type,
        => true,
        else => false,
    };
}

pub fn isIntegral(k: BuiltinKind) bool {
    return switch (k) {
        .i8_type, .i16_type, .i32_type, .i64_type,
        .u8_type, .u16_type, .u32_type, .u64_type,
        => true,
        else => false,
    };
}

pub fn isFloat(k: BuiltinKind) bool {
    return switch (k) {
        .f32_type, .f64_type => true,
        else => false,
    };
}

pub fn isSigned(k: BuiltinKind) bool {
    return switch (k) {
        .i8_type, .i16_type, .i32_type, .i64_type => true,
        else => false,
    };
}

pub fn canBinOp(op: anytype, lhs: BuiltinKind, rhs: BuiltinKind) ?BuiltinKind {
    const op_name = @tagName(op);
    const is_arith = std.mem.eql(u8, op_name, "add") or
        std.mem.eql(u8, op_name, "sub") or
        std.mem.eql(u8, op_name, "mul") or
        std.mem.eql(u8, op_name, "div") or
        std.mem.eql(u8, op_name, "mod");
    const is_cmp = std.mem.eql(u8, op_name, "eq") or
        std.mem.eql(u8, op_name, "ne") or
        std.mem.eql(u8, op_name, "lt") or
        std.mem.eql(u8, op_name, "gt") or
        std.mem.eql(u8, op_name, "le") or
        std.mem.eql(u8, op_name, "ge");
    const is_bit = std.mem.eql(u8, op_name, "bitwise_and") or
        std.mem.eql(u8, op_name, "bitwise_or") or
        std.mem.eql(u8, op_name, "bitwise_xor") or
        std.mem.eql(u8, op_name, "shl") or
        std.mem.eql(u8, op_name, "shr");
    const is_logic = std.mem.eql(u8, op_name, "and_") or
        std.mem.eql(u8, op_name, "or_");

    if (is_logic) {
        if (lhs == .bool_type and rhs == .bool_type) return .bool_type;
        return null;
    }

    if (is_cmp) {
        if (isNumeric(lhs) and isNumeric(rhs)) return .bool_type;
        if (lhs == .str_type and rhs == .str_type and (std.mem.eql(u8, op_name, "eq") or std.mem.eql(u8, op_name, "ne")))
            return .bool_type;
        return null;
    }

    if (is_arith) {
        if (isNumeric(lhs) and isNumeric(rhs)) {
            if (@intFromEnum(lhs) >= @intFromEnum(rhs)) return lhs;
            return rhs;
        }
        return null;
    }

    if (is_bit) {
        if (isIntegral(lhs) and isIntegral(rhs)) {
            if (@intFromEnum(lhs) >= @intFromEnum(rhs)) return lhs;
            return rhs;
        }
        return null;
    }

    return null;
}

pub fn canUnaryOp(op: anytype, operand: BuiltinKind) ?BuiltinKind {
    const op_name = @tagName(op);
    if (std.mem.eql(u8, op_name, "negate")) {
        if (isNumeric(operand)) return operand;
        return null;
    }
    if (std.mem.eql(u8, op_name, "not")) {
        if (operand == .bool_type) return .bool_type;
        return null;
    }
    if (std.mem.eql(u8, op_name, "bitwise_not")) {
        if (isIntegral(operand)) return operand;
        return null;
    }
    return null;
}

test "coercion: identical" {
    try std.testing.expect(canCoerce(.i32_type, .i32_type) == .identical);
    try std.testing.expect(canCoerce(.bool_type, .bool_type) == .identical);
}

test "coercion: numeric widening" {
    try std.testing.expect(canCoerce(.i32_type, .i64_type) == .numeric_widening);
    try std.testing.expect(canCoerce(.f32_type, .f64_type) == .numeric_widening);
}

test "coercion: no" {
    try std.testing.expect(canCoerce(.bool_type, .i32_type) == .no_coercion);
    try std.testing.expect(canCoerce(.i32_type, .bool_type) == .no_coercion);
}

test "canBinOp: i32+i32 => i32" {
    const result = canBinOp(.add, .i32_type, .i32_type);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .i32_type);
}

test "canBinOp: i32+f64 => f64" {
    const result = canBinOp(.add, .i32_type, .f64_type);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .f64_type);
}

test "canBinOp: bool+bool => null" {
    const result = canBinOp(.add, .bool_type, .bool_type);
    try std.testing.expect(result == null);
}

test "canBinOp: eq returns bool" {
    const result = canBinOp(.eq, .i32_type, .i32_type);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .bool_type);
}

test "canBinOp: and/or bool" {
    const result = canBinOp(.and_, .bool_type, .bool_type);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .bool_type);
}

test "canUnaryOp: negate i32" {
    const result = canUnaryOp(.negate, .i32_type);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .i32_type);
}

test "canUnaryOp: not bool" {
    const result = canUnaryOp(.not, .bool_type);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .bool_type);
}
