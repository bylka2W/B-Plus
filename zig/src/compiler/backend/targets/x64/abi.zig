/// x64 ABI definitions and helpers for Win64 and SystemV calling conventions.
/// This module classifies parameters and return values into their physical
/// register assignments and stack slots according to the target ABI.
const std = @import("std");
const DataType = @import("../../../mir/core/value.zig").DataType;

pub const TargetAbi = enum { win64, system_v };

/// How a value is passed or returned.
pub const ArgLocation = union(enum) {
    /// Passed in a general-purpose register (physical register index).
    gpr: i16,
    /// Passed in an XMM register (physical register index, e.g. 16 = xmm0).
    xmm: i16,
    /// Passed on the stack at the given byte offset from RSP at the point of
    /// the CALL instruction (before the caller pushes the return address).
    stack: i32,
};

/// Classification of a single argument based on its data type.
pub const ArgClass = enum {
    integer,
    sse,
    memory,
};

pub const ShadowSize = 32;
pub const StackAlignment = 16;

// ── Win64 ──────────────────────────────────────────────────────────────────

/// Win64 integer argument registers: RCX, RDX, R8, R9.
pub const win64_int_regs = [_]i16{ 1, 2, 8, 9 };
/// Win64 float argument registers: XMM0–XMM3.
pub const win64_float_regs = [_]i16{ 16, 17, 18, 19 };

/// Win64 callee-saved GPRs (excluding RBP which is the frame pointer).
pub const win64_callee_saved_gpr = [_]i16{ 3, 12, 13, 14, 15 }; // RBX, R12-R15
/// Win64 callee-saved XMMs.
pub const win64_callee_saved_xmm = [_]i16{ 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 }; // xmm6-xmm15

/// Classify a data type for Win64.
pub fn win64Classify(ty: DataType) ArgClass {
    return if (ty.isFloat()) .sse else .integer;
}

/// Assign physical registers for a list of Win64 parameters.
/// Returns the ArgLocation for each parameter, and sets `stack_size` to the
/// number of bytes the caller must reserve for stack-passed arguments.
pub fn win64AssignArgs(
    types: []const DataType,
    stack_size: *u32,
) std.BoundedArray(ArgLocation, 16) {
    var result = std.BoundedArray(ArgLocation, 16){};
    var int_idx: usize = 0;
    var float_idx: usize = 0;
    var stack_off: i32 = @intCast(ShadowSize); // args start after the shadow space

    for (types) |ty| {
        const cls = win64Classify(ty);
        switch (cls) {
            .sse => {
                if (float_idx < win64_float_regs.len) {
                    result.append(.{ .xmm = win64_float_regs[float_idx] }) catch {};
                    float_idx += 1;
                } else {
                    result.append(.{ .stack = stack_off }) catch {};
                    stack_off += 8;
                }
            },
            .integer => {
                if (int_idx < win64_int_regs.len) {
                    result.append(.{ .gpr = win64_int_regs[int_idx] }) catch {};
                    int_idx += 1;
                } else {
                    result.append(.{ .stack = stack_off }) catch {};
                    stack_off += 8;
                }
            },
            .memory => {
                result.append(.{ .stack = stack_off }) catch {};
                stack_off += 8;
            },
        }
    }

    // Stack args region must be 16-byte aligned.
    const raw: u32 = @intCast(stack_off);
    const aligned = (raw + 15) & ~@as(u32, 15);
    stack_size.* = aligned - @as(u32, @intCast(ShadowSize));
    return result;
}

/// Where the return value lives for a Win64 function.
pub fn win64RetLoc(ty: DataType) ArgLocation {
    if (ty == .void) return .{ .gpr = -1 };
    if (ty.isFloat()) return .{ .xmm = 16 }; // xmm0
    return .{ .gpr = 0 }; // rax
}

// ── SystemV (Linux / macOS) ───────────────────────────────────────────────

pub const sysv_int_regs = [_]i16{ 7, 6, 2, 1, 8, 9 }; // RDI, RSI, RDX, RCX, R8, R9
pub const sysv_float_regs = [_]i16{ 16, 17, 18, 19, 20, 21, 22, 23 }; // xmm0-xmm7

pub const sysv_callee_saved_gpr = [_]i16{ 3, 12, 13, 14, 15 }; // RBX, R12-R15
pub const sysv_callee_saved_xmm = [_]i16{ 24, 25, 26, 27, 28, 29, 30, 31 }; // xmm8-xmm15

pub fn sysvClassify(ty: DataType) ArgClass {
    return if (ty.isFloat()) .sse else .integer;
}

pub fn sysvAssignArgs(
    types: []const DataType,
    stack_size: *u32,
) std.BoundedArray(ArgLocation, 16) {
    var result = std.BoundedArray(ArgLocation, 16){};
    var int_idx: usize = 0;
    var float_idx: usize = 0;
    var stack_off: i32 = 0;

    for (types) |ty| {
        const cls = sysvClassify(ty);
        switch (cls) {
            .sse => {
                if (float_idx < sysv_float_regs.len) {
                    result.append(.{ .xmm = sysv_float_regs[float_idx] }) catch {};
                    float_idx += 1;
                } else {
                    result.append(.{ .stack = stack_off }) catch {};
                    stack_off += 8;
                }
            },
            .integer => {
                if (int_idx < sysv_int_regs.len) {
                    result.append(.{ .gpr = sysv_int_regs[int_idx] }) catch {};
                    int_idx += 1;
                } else {
                    result.append(.{ .stack = stack_off }) catch {};
                    stack_off += 8;
                }
            },
            .memory => {
                result.append(.{ .stack = stack_off }) catch {};
                stack_off += 8;
            },
        }
    }

    const raw: u32 = @intCast(stack_off);
    stack_size.* = (raw + 15) & ~@as(u32, 15);
    return result;
}

pub fn sysvRetLoc(ty: DataType) ArgLocation {
    if (ty == .void) return .{ .gpr = -1 };
    if (ty.isFloat()) return .{ .xmm = 16 }; // xmm0
    return .{ .gpr = 0 }; // rax
}

// ── Unified helpers ────────────────────────────────────────────────────────

pub fn assignArgs(abi: TargetAbi, types: []const DataType, stack_size: *u32) std.BoundedArray(ArgLocation, 16) {
    return switch (abi) {
        .win64 => win64AssignArgs(types, stack_size),
        .system_v => sysvAssignArgs(types, stack_size),
    };
}

pub fn retLoc(abi: TargetAbi, ty: DataType) ArgLocation {
    return switch (abi) {
        .win64 => win64RetLoc(ty),
        .system_v => sysvRetLoc(ty),
    };
}

pub fn calleeSavedGpr(abi: TargetAbi) []const i16 {
    return switch (abi) {
        .win64 => &win64_callee_saved_gpr,
        .system_v => &sysv_callee_saved_gpr,
    };
}

pub fn calleeSavedXmm(abi: TargetAbi) []const i16 {
    return switch (abi) {
        .win64 => &win64_callee_saved_xmm,
        .system_v => &sysv_callee_saved_xmm,
    };
}

test "win64 integer arg assignment" {
    const types = [_]DataType{ .i64, .i64, .i64, .i64 };
    var stack_size: u32 = 0;
    const locs = win64AssignArgs(&types, &stack_size);
    try std.testing.expectEqual(@as(usize, 4), locs.len);
    try std.testing.expectEqual(@as(i16, 1), locs.buffer[0].gpr); // RCX
    try std.testing.expectEqual(@as(i16, 2), locs.buffer[1].gpr); // RDX
    try std.testing.expectEqual(@as(i16, 8), locs.buffer[2].gpr); // R8
    try std.testing.expectEqual(@as(i16, 9), locs.buffer[3].gpr); // R9
    try std.testing.expectEqual(@as(u32, 0), stack_size);
}

test "win64 mixed int+float arg assignment" {
    const types = [_]DataType{ .i64, .f64, .i64, .f32 };
    var stack_size: u32 = 0;
    const locs = win64AssignArgs(&types, &stack_size);
    try std.testing.expectEqual(@as(usize, 4), locs.len);
    try std.testing.expectEqual(@as(i16, 1), locs.buffer[0].gpr); // RCX
    try std.testing.expectEqual(@as(i16, 16), locs.buffer[1].xmm); // xmm0
    try std.testing.expectEqual(@as(i16, 8), locs.buffer[2].gpr); // R8
    try std.testing.expectEqual(@as(i16, 17), locs.buffer[3].xmm); // xmm1
}

test "win64 5th int arg goes to stack" {
    const types = [_]DataType{ .i64, .i64, .i64, .i64, .i64 };
    var stack_size: u32 = 0;
    const locs = win64AssignArgs(&types, &stack_size);
    try std.testing.expectEqual(@as(usize, 5), locs.len);
    try std.testing.expectEqual(@as(i16, 9), locs.buffer[3].gpr); // R9
    try std.testing.expect(locs.buffer[4] == .stack);
    try std.testing.expect(stack_size > 0);
}

test "win64 void return" {
    const loc = win64RetLoc(.void);
    try std.testing.expectEqual(@as(i16, -1), loc.gpr);
}

test "win64 int return" {
    const loc = win64RetLoc(.i64);
    try std.testing.expectEqual(@as(i16, 0), loc.gpr); // rax
}

test "win64 float return" {
    const loc = win64RetLoc(.f64);
    try std.testing.expectEqual(@as(i16, 16), loc.xmm); // xmm0
}
