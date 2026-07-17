const std = @import("std");
const x64 = @import("x64enc.zig");

pub const frame_size: u32 = 0x28;
pub const shadow_size: u32 = 0x20;

pub const CallArg = union(enum) {
    imm: i64,
    reg: i16,
};

fn emitPushR64(code: *std.ArrayList(u8), reg: i16) !void {
    if (reg >= 8) try code.append(0x41);
    try code.append(@as(u8, @intCast(0x50 + (reg & 7))));
}

fn emitPopR64(code: *std.ArrayList(u8), reg: i16) !void {
    if (reg >= 8) try code.append(0x41);
    try code.append(@as(u8, @intCast(0x58 + (reg & 7))));
}

pub fn emitPrologue(code: *std.ArrayList(u8)) !void {
    try x64.emit(code, .SUB_R64_IMM32, &.{
        x64.Operand.r(4),
        x64.Operand.immU32(frame_size),
    });
}

pub fn emitEpilogue(code: *std.ArrayList(u8)) !void {
    try x64.emit(code, .ADD_R64_IMM32, &.{
        x64.Operand.r(4),
        x64.Operand.immU32(frame_size),
    });
    try x64.emit(code, .RET, &.{});
}

pub fn emitFullPrologue(code: *std.ArrayList(u8)) !void {
    // Save non-volatile integer registers: RBX, RBP, RSI, RDI, R12-R15
    try emitPushR64(code, 5);  // RBP
    try emitPushR64(code, 3);  // RBX
    try emitPushR64(code, 6);  // RSI
    try emitPushR64(code, 7);  // RDI
    try emitPushR64(code, 15); // R15
    try emitPushR64(code, 14); // R14
    try emitPushR64(code, 13); // R13
    try emitPushR64(code, 12); // R12
    try x64.emit(code, .SUB_R64_IMM32, &.{
        x64.Operand.r(4),
        x64.Operand.immU32(frame_size),
    });
}

pub fn emitFullEpilogue(code: *std.ArrayList(u8)) !void {
    try x64.emit(code, .ADD_R64_IMM32, &.{
        x64.Operand.r(4),
        x64.Operand.immU32(frame_size),
    });
    try emitPopR64(code, 12); // R12
    try emitPopR64(code, 13); // R13
    try emitPopR64(code, 14); // R14
    try emitPopR64(code, 15); // R15
    try emitPopR64(code, 7);  // RDI
    try emitPopR64(code, 6);  // RSI
    try emitPopR64(code, 3);  // RBX
    try emitPopR64(code, 5);  // RBP
    try x64.emit(code, .RET, &.{});
}

fn emitMovRegImm64(code: *std.ArrayList(u8), reg: i16, val: i64) !void {
    if (val == 0) {
        if (reg >= 8) try code.append(0x45);
        try code.append(0x33);
        try code.append(@as(u8, @intCast(0xC0 + (reg & 7) * 9)));
    } else {
        try x64.emit(code, .MOV_R64_IMM64, &.{ x64.Operand.r(reg), x64.Operand.imm(val) });
    }
}

pub fn emitCallArgs(code: *std.ArrayList(u8), args: []const CallArg) !void {
    const int_regs = [_]i16{ 1, 2, 8, 9 }; // RCX, RDX, R8, R9
    for (args, 0..) |arg, i| {
        if (i >= 4) break;
        switch (arg) {
            .imm => |v| try emitMovRegImm64(code, int_regs[i], v),
            .reg => |r| try x64.emit(code, .MOV_R64_R64, &.{ x64.Operand.r(int_regs[i]), x64.Operand.r(r) }),
        }
    }
    try x64.emit(code, .SUB_R64_IMM32, &.{
        x64.Operand.r(4),
        x64.Operand.immU32(shadow_size),
    });
}

pub fn emitCallCleanup(code: *std.ArrayList(u8)) !void {
    try x64.emit(code, .ADD_R64_IMM32, &.{
        x64.Operand.r(4),
        x64.Operand.immU32(shadow_size),
    });
}
