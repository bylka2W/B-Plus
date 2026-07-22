/// x64 branch encoding helpers.
const std = @import("std");
const OpCode = @import("encoder.zig").OpCode;
const Operand = @import("encoder.zig").Operand;
const emit = @import("encoder.zig").emit;

/// Mirrors mir.CondCode for x64 Jcc conversion.
pub const CondCode = enum(u8) {
    eq = 4,
    ne = 5,
    lt = 0xC,
    le = 0xE,
    gt = 0xF,
    ge = 0xD,
};

/// Convert generic condition code to x64 Jcc opcode.
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

/// Short jump is encoded as JMP_REL32 (x64 uses rel32 for all forward jumps).
pub fn emitShortJmp(code: *std.ArrayList(u8), target_label: usize) !void {
    _ = target_label;
    // Placeholder for label-based jump; actual fixup done by caller.
    try emit(code, .JMP_REL32, &.{.{ .imm64 = 0 }});
}

/// Long conditional jump (rel32).
pub fn emitCondLongJmp(code: *std.ArrayList(u8), op: OpCode, target_label: usize) !void {
    _ = target_label;
    try emit(code, op, &.{.{ .imm64 = 0 }});
}

/// Long unconditional jump (rel32).
pub fn emitLongJmp(code: *std.ArrayList(u8), target_label: usize) !void {
    _ = target_label;
    try emit(code, .JMP_REL32, &.{.{ .imm64 = 0 }});
}
