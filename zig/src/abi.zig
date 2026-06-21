const std = @import("std");
const x64 = @import("x64enc.zig");

pub const frame_size: u32 = 0x28;

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
