//! Single source of truth for the numeric part of the B+ type system.
//!
//! Everything that decides "may this value live in that slot" goes through
//! `implicitConversion` here: variable declarations, plain assignments,
//! function arguments and the operands of a binary operator. There is
//! deliberately no `@intFromEnum` ordering anywhere in this file, because the
//! declaration order of `ast.TypeId` (i8..i64, u8..u64, f32, f64) does not
//! describe numeric width, and treating it as if it did is what previously
//! let `i64 -> i8` through as "widening".
//!
//! The model:
//!
//!   * A literal without an annotation has one concrete type: `i64` for
//!     integers, `f64` for floats. It is not "any numeric type".
//!   * A literal in an annotated slot takes the annotated type, but only when
//!     the value actually fits (`literalFits`), so `var b: i8 = 300` is an
//!     error instead of a silent truncation to 44.
//!   * Two concrete types never convert implicitly unless the conversion is
//!     provably lossless and stays inside one numeric class. Narrowing,
//!     signed/unsigned changes and integer/float mixing are all rejected.

const std = @import("std");
const ast = @import("../ast.zig");

const TypeId = ast.TypeId;

pub const Class = enum {
    signed,
    unsigned,
    floating,
};

pub const Info = struct {
    class: Class,
    /// Width in bits. Only comparable inside one class.
    bits: u16,
};

/// The one lookup table for numeric kinds. Anything not listed here is not a
/// number, and therefore has no rank to reason about.
pub fn info(t: TypeId) ?Info {
    return switch (t) {
        .i8_type => .{ .class = .signed, .bits = 8 },
        .i16_type => .{ .class = .signed, .bits = 16 },
        .i32_type => .{ .class = .signed, .bits = 32 },
        .i64_type => .{ .class = .signed, .bits = 64 },
        .u8_type => .{ .class = .unsigned, .bits = 8 },
        .u16_type => .{ .class = .unsigned, .bits = 16 },
        .u32_type => .{ .class = .unsigned, .bits = 32 },
        .u64_type => .{ .class = .unsigned, .bits = 64 },
        .f32_type => .{ .class = .floating, .bits = 32 },
        .f64_type => .{ .class = .floating, .bits = 64 },
        else => null,
    };
}

pub fn isNumeric(t: TypeId) bool {
    return info(t) != null;
}

pub fn isInteger(t: TypeId) bool {
    const i = info(t) orelse return false;
    return i.class != .floating;
}

pub fn isFloat(t: TypeId) bool {
    const i = info(t) orelse return false;
    return i.class == .floating;
}

/// Concrete type of an unannotated literal.
pub fn defaultIntType() TypeId {
    return .i64_type;
}

pub fn defaultFloatType() TypeId {
    return .f64_type;
}

pub const Conversion = enum {
    /// The types are identical.
    same,
    /// Same class, strictly wider target: i8 -> i64, f32 -> f64.
    /// Widening only, never narrowing.
    lossless,
    /// Not allowed: narrowing, signed/unsigned change, int/float mixing,
    /// or anything involving a non-numeric type.
    none,
};

/// The conversion policy. To make B+ reject even lossless widening, delete the
/// `lossless` branch: every other kind of conversion is already refused.
pub fn implicitConversion(from: TypeId, to: TypeId) Conversion {
    if (from == to) return .same;
    const f = info(from) orelse return .none;
    const t = info(to) orelse return .none;
    if (f.class != t.class) return .none;
    if (t.bits > f.bits) return .lossless;
    return .none;
}

/// Whether an integer literal with this value can be written into `target`
/// without losing anything. Guards `var b: i8 = 300`.
pub fn integerLiteralFits(target: TypeId, value: i128) bool {
    const t = info(target) orelse return false;
    return switch (t.class) {
        .signed => blk: {
            const max: i128 = (@as(i128, 1) << @intCast(t.bits - 1)) - 1;
            const min: i128 = -(@as(i128, 1) << @intCast(t.bits - 1));
            break :blk value >= min and value <= max;
        },
        .unsigned => blk: {
            if (value < 0) break :blk false;
            const max: i128 = (@as(i128, 1) << @intCast(t.bits)) - 1;
            break :blk value <= max;
        },
        // Every integer literal is representable as a float type; the exact
        // range of f32 is enforced by the backend, not by the checker.
        .floating => true,
    };
}

/// Result type of `lhs <op> rhs`, or null when the operand pair is rejected.
///
/// Both operands must be the same type, or differ only by a width inside one
/// numeric class: the narrower side widens, so `i32 + i64` and `i64 + i8` are
/// both an `i64`. `i64 + f64` and `i64 + u8` are null, which is what stops them
/// from silently becoming an `f64` store.
pub fn binaryResult(lhs: TypeId, rhs: TypeId) ?TypeId {
    if (lhs == rhs) {
        if (isNumeric(lhs)) return lhs;
        return null;
    }
    switch (implicitConversion(lhs, rhs)) {
        .lossless => return rhs,
        else => {},
    }
    switch (implicitConversion(rhs, lhs)) {
        .lossless => return lhs,
        else => return null,
    }
}

/// Whether `text` is a bare decimal literal such as `300`, `-1` or `20.5`.
///
/// Only these take part in contextual literal typing. Anything else (`a`,
/// `get()`, `0x10`, `arr[0]`) is an ordinary expression whose type must
/// already be known.
pub fn isPlainNumericLiteral(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    var start: usize = 0;
    if (trimmed[0] == '-' or trimmed[0] == '+') start = 1;
    if (start >= trimmed.len) return false;
    var seen_digit = false;
    var seen_dot = false;
    for (trimmed[start..]) |ch| {
        if (ch >= '0' and ch <= '9') {
            seen_digit = true;
            continue;
        }
        if (ch == '.' and !seen_dot) {
            seen_dot = true;
            continue;
        }
        return false;
    }
    return seen_digit;
}

/// Whether the literal in `text` can be written into `target` unchanged.
/// Assumes `isPlainNumericLiteral(text)`; returns false otherwise.
pub fn literalFits(target: TypeId, text: []const u8) bool {
    if (!isPlainNumericLiteral(text)) return false;
    if (!isNumeric(target)) return false;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    // A decimal point makes it a float literal, so only float slots take it.
    if (std.mem.indexOfScalar(u8, trimmed, '.') != null) return isFloat(target);
    // parseInt keeps the sign, so `-1` is rejected by an unsigned target
    // instead of being read as `1`.
    const value = std.fmt.parseInt(i128, trimmed, 10) catch return false;
    return integerLiteralFits(target, value);
}

/// The assignment rule, given the type of the right-hand side and its source
/// text. This is what `var b: i8 = a`, `b = a` and argument passing all use.
///
///   * identical types are fine;
///   * an unannotated literal takes the target type when its value fits, which
///     is what makes `var b: i32 = 10` legal while `var b: i8 = 300` is not;
///   * otherwise only a lossless widening of an already-typed value is legal.
pub fn assignable(declared: TypeId, inferred: TypeId, rhs_text: []const u8) bool {
    if (declared == .unknown or inferred == .unknown) return true;
    if (declared == inferred) return true;
    if (!isNumeric(declared) or !isNumeric(inferred)) return false;
    if (isPlainNumericLiteral(rhs_text)) return literalFits(declared, rhs_text);
    return implicitConversion(inferred, declared) == .lossless;
}

test "numeric: isPlainNumericLiteral accepts bare decimals only" {
    try std.testing.expect(isPlainNumericLiteral("300"));
    try std.testing.expect(isPlainNumericLiteral("-1"));
    try std.testing.expect(isPlainNumericLiteral("+7"));
    try std.testing.expect(isPlainNumericLiteral("20.5"));
    try std.testing.expect(!isPlainNumericLiteral("a"));
    try std.testing.expect(!isPlainNumericLiteral("0x10"));
    try std.testing.expect(!isPlainNumericLiteral("1_000"));
    try std.testing.expect(!isPlainNumericLiteral("get()"));
    try std.testing.expect(!isPlainNumericLiteral(""));
    try std.testing.expect(!isPlainNumericLiteral("-"));
    try std.testing.expect(!isPlainNumericLiteral("1.2.3"));
}

test "numeric: literalFits keeps the sign" {
    try std.testing.expect(literalFits(.i8_type, "100"));
    try std.testing.expect(!literalFits(.i8_type, "300"));
    try std.testing.expect(!literalFits(.u8_type, "-1"));
    try std.testing.expect(literalFits(.u8_type, "255"));
    try std.testing.expect(literalFits(.i64_type, "-9223372036854775808"));
    try std.testing.expect(!literalFits(.i64_type, "9223372036854775808"));
    try std.testing.expect(literalFits(.f32_type, "1.5"));
    try std.testing.expect(!literalFits(.i64_type, "20.5"));
    try std.testing.expect(!literalFits(.bool_type, "1"));
}

test "numeric: assignable rejects narrowing of a typed value" {
    try std.testing.expect(!assignable(.i8_type, .i64_type, "a"));
    try std.testing.expect(!assignable(.i32_type, .i64_type, "a"));
    try std.testing.expect(!assignable(.f32_type, .f64_type, "a"));
    try std.testing.expect(!assignable(.u8_type, .i64_type, "a"));
    try std.testing.expect(!assignable(.i64_type, .f64_type, "a"));
}

test "numeric: assignable lets an annotated literal take the annotation" {
    try std.testing.expect(assignable(.i32_type, .i64_type, "10"));
    try std.testing.expect(assignable(.i8_type, .i64_type, "100"));
    try std.testing.expect(assignable(.f32_type, .f64_type, "1.5"));
    try std.testing.expect(!assignable(.i8_type, .i64_type, "300"));
    try std.testing.expect(!assignable(.u8_type, .i64_type, "-1"));
    try std.testing.expect(!assignable(.i64_type, .f64_type, "20.5"));
}

test "numeric: assignable allows lossless widening and identical types" {
    try std.testing.expect(assignable(.i64_type, .i8_type, "a"));
    try std.testing.expect(assignable(.f64_type, .f32_type, "a"));
    try std.testing.expect(assignable(.i64_type, .i64_type, "a"));
}

test "numeric: assignable is permissive only for unknown types" {
    try std.testing.expect(assignable(.unknown, .i64_type, "a"));
    try std.testing.expect(assignable(.i8_type, .unknown, "a"));
    try std.testing.expect(!assignable(.bool_type, .i64_type, "a"));
    try std.testing.expect(!assignable(.string_type, .i64_type, "\"x\""));
}

test "numeric: numeric: info covers every numeric kind" {
    try std.testing.expectEqual(Class.signed, info(.i32_type).?.class);
    try std.testing.expectEqual(@as(u16, 32), info(.i32_type).?.bits);
    try std.testing.expectEqual(Class.unsigned, info(.u8_type).?.class);
    try std.testing.expectEqual(Class.floating, info(.f64_type).?.class);
    try std.testing.expect(info(.string_type) == null);
    try std.testing.expect(info(.bool_type) == null);
    try std.testing.expect(info(.unknown) == null);
}

test "numeric: predicates derive from info" {
    try std.testing.expect(isNumeric(.u64_type));
    try std.testing.expect(isInteger(.i8_type));
    try std.testing.expect(!isInteger(.f32_type));
    try std.testing.expect(isFloat(.f32_type));
    try std.testing.expect(!isFloat(.i64_type));
    try std.testing.expect(!isNumeric(.ptr_type));
}

test "numeric: literal defaults are i64 and f64" {
    try std.testing.expectEqual(TypeId.i64_type, defaultIntType());
    try std.testing.expectEqual(TypeId.f64_type, defaultFloatType());
}

test "numeric: identical types convert to themselves" {
    try std.testing.expectEqual(Conversion.same, implicitConversion(.i64_type, .i64_type));
    try std.testing.expectEqual(Conversion.same, implicitConversion(.f32_type, .f32_type));
}

test "numeric: narrowing is never allowed" {
    try std.testing.expectEqual(Conversion.none, implicitConversion(.i64_type, .i8_type));
    try std.testing.expectEqual(Conversion.none, implicitConversion(.i32_type, .i8_type));
    try std.testing.expectEqual(Conversion.none, implicitConversion(.u64_type, .u8_type));
    try std.testing.expectEqual(Conversion.none, implicitConversion(.f64_type, .f32_type));
}

test "numeric: signed/unsigned and int/float mixing is never allowed" {
    try std.testing.expectEqual(Conversion.none, implicitConversion(.i64_type, .u8_type));
    try std.testing.expectEqual(Conversion.none, implicitConversion(.u8_type, .i64_type));
    try std.testing.expectEqual(Conversion.none, implicitConversion(.i64_type, .f64_type));
    try std.testing.expectEqual(Conversion.none, implicitConversion(.f32_type, .i32_type));
}

test "numeric: lossless widening inside one class is allowed" {
    try std.testing.expectEqual(Conversion.lossless, implicitConversion(.i8_type, .i64_type));
    try std.testing.expectEqual(Conversion.lossless, implicitConversion(.u8_type, .u64_type));
    try std.testing.expectEqual(Conversion.lossless, implicitConversion(.f32_type, .f64_type));
}

test "numeric: non-numeric types never convert" {
    try std.testing.expectEqual(Conversion.none, implicitConversion(.bool_type, .i32_type));
    try std.testing.expectEqual(Conversion.none, implicitConversion(.i32_type, .bool_type));
    try std.testing.expectEqual(Conversion.none, implicitConversion(.string_type, .ptr_type));
    try std.testing.expectEqual(Conversion.none, implicitConversion(.ptr_type, .string_type));
}

test "numeric: literal range checks" {
    try std.testing.expect(integerLiteralFits(.i64_type, 300));
    try std.testing.expect(integerLiteralFits(.i64_type, -9223372036854775808));
    try std.testing.expect(!integerLiteralFits(.i64_type, 9223372036854775808));
    try std.testing.expect(integerLiteralFits(.i8_type, 127));
    try std.testing.expect(!integerLiteralFits(.i8_type, 300));
    try std.testing.expect(!integerLiteralFits(.i8_type, -129));
    try std.testing.expect(integerLiteralFits(.u8_type, 255));
    try std.testing.expect(!integerLiteralFits(.u8_type, 256));
    try std.testing.expect(!integerLiteralFits(.u8_type, -1));
}

test "numeric: binaryResult requires the same type" {
    try std.testing.expectEqual(TypeId.i64_type, binaryResult(.i64_type, .i64_type).?);
    try std.testing.expectEqual(TypeId.f32_type, binaryResult(.f32_type, .f32_type).?);
}

test "numeric: binaryResult rejects mixed int and float" {
    try std.testing.expect(binaryResult(.i64_type, .f64_type) == null);
    try std.testing.expect(binaryResult(.i32_type, .f32_type) == null);
    try std.testing.expect(binaryResult(.f64_type, .i64_type) == null);
}

test "numeric: binaryResult rejects mixed signedness" {
    try std.testing.expect(binaryResult(.i64_type, .u8_type) == null);
    try std.testing.expect(binaryResult(.u8_type, .i64_type) == null);
}

test "numeric: binaryResult widens the narrower same-class operand" {
    try std.testing.expectEqual(TypeId.i64_type, binaryResult(.i64_type, .i8_type).?);
    try std.testing.expectEqual(TypeId.i64_type, binaryResult(.i8_type, .i64_type).?);
    try std.testing.expectEqual(TypeId.u32_type, binaryResult(.u8_type, .u32_type).?);
    try std.testing.expectEqual(TypeId.f64_type, binaryResult(.f32_type, .f64_type).?);
}

test "numeric: binaryResult accepts lossless widening either way" {
    try std.testing.expectEqual(TypeId.i64_type, binaryResult(.i32_type, .i64_type).?);
    try std.testing.expectEqual(TypeId.i64_type, binaryResult(.i64_type, .i32_type).?);
}
