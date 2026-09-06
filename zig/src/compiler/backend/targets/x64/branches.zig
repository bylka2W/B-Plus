/// кодирования перехода x64
const std = @import("std");
const OpCode = @import("encoder.zig").OpCode;
const Operand = @import("encoder.zig").Operand;
const emit = @import("encoder.zig").emit;

pub const CondCode = enum(u8) {
    eq = 4,
    ne = 5,
    lt = 0xC,
    le = 0xE,
    gt = 0xF,
    ge = 0xD,
};

pub fn condToJccOp(cc: CondCode) OpCode {
    return switch (cc) {
        .eq => .JE_REL32,
        .ne => .JNE_REL32,
        .lt => .JL_REL32,
        .le => .JLE_REL32,
        .gt => .JG_REL32,
        .ge => .JGE_REL32,
    };
}

pub fn emitShortJmp(code: *std.ArrayList(u8), target_label: usize) !void {
    _ = target_label;
    try emit(code, .JMP_REL32, &.{.{ .imm64 = 0 }});
}

pub fn emitCondLongJmp(code: *std.ArrayList(u8), op: OpCode, target_label: usize) !void {
    _ = target_label;
    try emit(code, op, &.{.{ .imm64 = 0 }});
}

pub fn emitLongJmp(code: *std.ArrayList(u8), target_label: usize) !void {
    _ = target_label;
    try emit(code, .JMP_REL32, &.{.{ .imm64 = 0 }});
}
