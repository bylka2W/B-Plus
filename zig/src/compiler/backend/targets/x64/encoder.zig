/// x64 instruction encoder.
/// Pure encoding layer: opcode bytes, REX prefix, ModRM, SIB, displacement, immediate.
/// Re-exports the implementation from x64enc.zig.
const std = @import("std");
const ir = @import("ir/inst.zig");

pub const x64enc = @import("x64enc.zig");

pub const SimdPrefix = x64enc.SimdPrefix;
pub const OpCode = x64enc.OpCode;
pub const Operand = x64enc.Operand;
pub const emit = x64enc.emit;
pub const emitModrmSibDisp = x64enc.emitModrmSibDisp;

/// Encode a single x64 IR instruction to bytes.
pub fn emitInst(code: *std.ArrayList(u8), inst: ir.Instruction) !void {
    try x64enc.emit(code, inst.op, inst.operands[0..inst.olen]);
}

/// Emit an entire MachineFunction, recording block offsets and fixup positions.
pub const EmitInfo = struct {
    block_offsets: std.ArrayListUnmanaged(usize),
    fixup_positions: std.ArrayListUnmanaged(usize),
};

pub fn emitMachineFunc(code: *std.ArrayList(u8), mf: ir.MachineFunction) !EmitInfo {
    const allocator = mf.allocator;
    var info = EmitInfo{
        .block_offsets = .{},
        .fixup_positions = .{},
    };
    errdefer {
        info.block_offsets.deinit(allocator);
        info.fixup_positions.deinit(allocator);
    }

    try info.block_offsets.ensureTotalCapacity(allocator, mf.blocks.items.len);
    try info.fixup_positions.ensureTotalCapacity(allocator, 32);

    for (mf.blocks.items) |*block| {
        info.block_offsets.appendAssumeCapacity(code.items.len);
        for (block.instrs.items) |inst| {
            const fixup_offset: ?usize = switch (inst.op) {
                .JMP_REL32, .CALL_REL32 => code.items.len + 1,
                .JE_REL32, .JNE_REL32, .JG_REL32, .JGE_REL32,
                .JL_REL32, .JLE_REL32, .JA_REL32, .JB_REL32, .JBE_REL32,
                .JAE_REL32 => code.items.len + 2,
                else => null,
            };
            if (fixup_offset) |off| {
                info.fixup_positions.appendAssumeCapacity(off);
            }
            try emitInst(code, inst);
        }
    }

    return info;
}

/// Encode REX prefix byte for 64-bit operation.
/// rex_flags: bit0 = B (extends rm/oprand), bit1 = X (extends SIB index),
///            bit2 = R (extends reg), bit3 = W (64-bit operand size)
pub fn rexByte(w: u1, r: u1, x: u1, b: u1) u8 {
    return 0x40 | (@as(u8, b) << 0) | (@as(u8, x) << 1) | (@as(u8, r) << 2) | (@as(u8, w) << 3);
}

/// Encode ModRM byte.
/// mod: 0=mem, 1=mem+disp8, 2=mem+disp32, 3=register
/// reg: opcode extension or source register
/// rm:  destination register or memory operand
pub fn modrm(mod: u8, reg: u8, rm: u8) u8 {
    return ((mod & 3) << 6) | ((reg & 7) << 3) | (rm & 7);
}

/// Encode SIB byte.
/// scale: 0=1, 1=2, 2=4, 3=8
/// index: index register (4 = none)
/// base:  base register
pub fn sib(scale: u8, index: u8, base: u8) u8 {
    return ((scale & 3) << 6) | ((index & 7) << 3) | (base & 7);
}

/// Emit a 32-bit displacement.
pub fn emitDisp32(code: *std.ArrayList(u8), disp: i32) !void {
    try code.appendSlice(@ptrCast(&@as([4]u8, @bitCast(disp))));
}

/// Emit a 32-bit immediate.
pub fn emitImm32(code: *std.ArrayList(u8), imm: u32) !void {
    try code.appendSlice(@ptrCast(&@as([4]u8, @bitCast(imm))));
}
