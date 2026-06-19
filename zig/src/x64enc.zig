const std = @import("std");
const Allocator = std.mem.Allocator;

pub const OpCode = enum(u16) {
    MOV_R64_IMM64,
    MOV_R64_R64,
    MOV_R32_R32,
    MOV_R64_MEM,
    MOV_R32_MEM,
    MOV_MEM_R64,
    MOVZX_R64_R32,
    ADD_R64_R64,
    ADD_R32_R32,
    ADD_R64_IMM32,
    ADD_R32_IMM32,
    SUB_R64_IMM32,
    SUB_R32_IMM32,
    SUB_R64_R64,
    SUB_R32_R32,
    CMP_R64_R64,
    CMP_R32_R32,
    CMP_R64_IMM32,
    CMP_R32_IMM32,
    TEST_R64_R64,
    TEST_R32_R32,
    XOR_R64_R64,
    XOR_R32_R32,
    IMUL_R64_R64,
    IMUL_R32_R32,
    AND_R64_R64,
    AND_R32_R32,
    OR_R64_R64,
    OR_R32_R32,
    SHIFT_LEFT,
    SHIFT_LEFT_32,
    SHIFT_RIGHT,
    SHIFT_RIGHT_32,
    LEA_R64_MEM,
    MOVZX_R64_MEM8,
    CALL_RIPDISP,
    MOV_R64_MEM_RIP,
    PREFETCHT0_RIPREL,
    PREFETCHT1_RIPREL,
    PREFETCHT2_RIPREL,
    MOVZX_R64_MEM16,
    MOVSX_R64_MEM8,
    MOVSX_R64_MEM16,
    MOV_MEM_R8,
    MOV_MEM_R16,
    MOV_MEM_R32,
    JMP_REL32,
    JE_REL32,
    JNE_REL32,
    JG_REL32,
    JGE_REL32,
    JL_REL32,
    JLE_REL32,
    JA_REL32,
    JB_REL32,
    JBE_REL32,
    JAE_REL32,
    CALL_REL32,
    RET,
    NOP,
    INT3,
};

pub const Operand = struct {
    reg: i16 = -1,
    imm64: u64 = 0,
    base_reg: i16 = -1,
    index_reg: i16 = -1,
    scale: u8 = 1,
    disp: i32 = 0,

    pub fn r(reg: i16) Operand {
        return .{ .reg = reg };
    }
    pub fn imm(v: i64) Operand {
        return .{ .imm64 = @bitCast(v) };
    }
    pub fn immU32(v: u32) Operand {
        return .{ .imm64 = v };
    }
    pub fn mem(base: i16, disp: i32) Operand {
        return .{ .base_reg = base, .disp = disp };
    }
    pub fn memIdx(base: i16, index: i16, scale: u8, disp: i32) Operand {
        return .{ .base_reg = base, .index_reg = index, .scale = scale, .disp = disp };
    }
};

pub fn emit(code: *std.ArrayList(u8), op: OpCode, operands: []const Operand) !void {
    switch (op) {
        .MOV_R64_IMM64 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            if (dst < 0 or dst > 15) return error.InvalidRegister;
            const rex: u8 = if (dst >= 8) 0x48 | ((@as(u8, @intCast(dst)) >> 3) & 1) else 0x48;
            try code.append(rex);
            try code.append(0xB8 | (@as(u8, @intCast(dst)) & 7));
            const imm_bytes: [8]u8 = @bitCast(operands[1].imm64);
            try code.appendSlice(&imm_bytes);
        },
        .MOV_R64_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const src = operands[1].reg;
            if (dst < 0 or dst > 15 or src < 0 or src > 15) return error.InvalidRegister;
            const rex_b: u8 = @intCast((@as(u8, @intCast(src)) >> 3) & 1);
            const rex_r: u8 = @intCast((@as(u8, @intCast(dst)) >> 3) & 1);
            try code.append(0x48 | rex_b | (rex_r << 2));
            try code.append(0x8B);
            try code.append(0xC0 | (@as(u8, @intCast(dst & 7)) << 3) | @as(u8, @intCast(src & 7)));
        },
        .MOV_R32_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const src = operands[1].reg;
            if (dst < 0 or dst > 15 or src < 0 or src > 15) return error.InvalidRegister;
            const rex_b: u8 = @intCast((@as(u8, @intCast(src)) >> 3) & 1);
            const rex_r: u8 = @intCast((@as(u8, @intCast(dst)) >> 3) & 1);
            const rex = rex_b | (rex_r << 2);
            if (rex != 0) try code.append(0x40 | rex);
            try code.append(0x8B);
            try code.append(0xC0 | (@as(u8, @intCast(dst & 7)) << 3) | @as(u8, @intCast(src & 7)));
        },
        .MOV_R64_MEM => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x8B, operands[0].reg, operands[1], 0);
        },
        .MOV_R32_MEM => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0x8B, operands[0].reg, operands[1], 0);
        },
        .MOV_MEM_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x89, operands[1].reg, operands[0], 0);
        },
        .MOV_MEM_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0x89, operands[1].reg, operands[0], 0);
        },
        .MOV_MEM_R16 => {
            if (operands.len < 2) return error.MissingOperands;
            try code.append(0x66);
            try emitModrmSibDisp(code, 0, 0x89, operands[1].reg, operands[0], 0);
        },
        .MOV_MEM_R8 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0x88, operands[1].reg, operands[0], 0);
        },
        .MOVZX_R64_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const src = operands[1].reg;
            const rex_b: u8 = @intCast((@as(u8, @intCast(src)) >> 3) & 1);
            const rex_r: u8 = @intCast((@as(u8, @intCast(dst)) >> 3) & 1);
            try code.append(0x48 | rex_b | (rex_r << 2));
            try code.append(0x0F);
            try code.append(0xB7);
            try code.append(0xC0 | (@as(u8, @intCast(dst & 7)) << 3) | @as(u8, @intCast(src & 7)));
        },
        .MOVZX_R64_MEM8 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0xB6, operands[0].reg, operands[1], 0x0F);
        },
        .MOVZX_R64_MEM16 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0xB7, operands[0].reg, operands[1], 0x0F);
        },
        .MOVSX_R64_MEM8 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0xBE, operands[0].reg, operands[1], 0x0F);
        },
        .MOVSX_R64_MEM16 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0xBF, operands[0].reg, operands[1], 0x0F);
        },
        .ADD_R64_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x01, operands[1].reg, operands[0], 0);
        },
        .ADD_R32_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0x01, operands[1].reg, operands[0], 0);
        },
        .ADD_R64_IMM32 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const v = operands[1].imm64;
            if (v == 0) return;
            const rex: u8 = if (dst >= 8) 0x48 | ((@as(u8, @intCast(dst)) >> 3) & 1) else 0x48;
            try code.append(rex);
            try code.append(0x81);
            try code.append(0xC0 | @as(u8, @intCast(dst & 7)));
            const imm_bytes: [4]u8 = @bitCast(@as(i32, @bitCast(@as(u32, @truncate(v)))));
            try code.appendSlice(&imm_bytes);
        },
        .ADD_R32_IMM32 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const v = operands[1].imm64;
            if (v == 0) return;
            const rex: u8 = if (dst >= 8) 0x40 | ((@as(u8, @intCast(dst)) >> 3) & 1) else 0;
            if (rex != 0) try code.append(rex);
            try code.append(0x81);
            try code.append(0xC0 | @as(u8, @intCast(dst & 7)));
            const imm_bytes: [4]u8 = @bitCast(@as(i32, @bitCast(@as(u32, @truncate(v)))));
            try code.appendSlice(&imm_bytes);
        },
        .SUB_R64_IMM32 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const v = operands[1].imm64;
            if (v == 0) return;
            const rex: u8 = if (dst >= 8) 0x48 | ((@as(u8, @intCast(dst)) >> 3) & 1) else 0x48;
            try code.append(rex);
            try code.append(0x81);
            try code.append(0xE8 | @as(u8, @intCast(dst & 7)));
            const imm_bytes: [4]u8 = @bitCast(@as(i32, @bitCast(@as(u32, @truncate(v)))));
            try code.appendSlice(&imm_bytes);
        },
        .SUB_R32_IMM32 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const v = operands[1].imm64;
            if (v == 0) return;
            const rex: u8 = if (dst >= 8) 0x40 | ((@as(u8, @intCast(dst)) >> 3) & 1) else 0;
            if (rex != 0) try code.append(rex);
            try code.append(0x81);
            try code.append(0xE8 | @as(u8, @intCast(dst & 7)));
            const imm_bytes: [4]u8 = @bitCast(@as(i32, @bitCast(@as(u32, @truncate(v)))));
            try code.appendSlice(&imm_bytes);
        },
        .SUB_R64_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x29, operands[1].reg, operands[0], 0);
        },
        .SUB_R32_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0x29, operands[1].reg, operands[0], 0);
        },
        .CMP_R64_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x39, operands[1].reg, operands[0], 0);
        },
        .CMP_R32_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0x39, operands[1].reg, operands[0], 0);
        },
        .CMP_R64_IMM32 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const v = operands[1].imm64;
            const rex: u8 = if (dst >= 8) 0x48 | ((@as(u8, @intCast(dst)) >> 3) & 1) else 0x48;
            try code.append(rex);
            try code.append(0x81);
            try code.append(0xF8 | @as(u8, @intCast(dst & 7)));
            const imm_bytes: [4]u8 = @bitCast(@as(i32, @bitCast(@as(u32, @truncate(v)))));
            try code.appendSlice(&imm_bytes);
        },
        .CMP_R32_IMM32 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const v = operands[1].imm64;
            const rex: u8 = if (dst >= 8) 0x40 | ((@as(u8, @intCast(dst)) >> 3) & 1) else 0;
            if (rex != 0) try code.append(rex);
            try code.append(0x81);
            try code.append(0xF8 | @as(u8, @intCast(dst & 7)));
            const imm_bytes: [4]u8 = @bitCast(@as(i32, @bitCast(@as(u32, @truncate(v)))));
            try code.appendSlice(&imm_bytes);
        },
        .TEST_R64_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x85, operands[1].reg, operands[0], 0);
        },
        .TEST_R32_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0x85, operands[1].reg, operands[0], 0);
        },
        .XOR_R64_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x31, operands[1].reg, operands[0], 0);
        },
        .XOR_R32_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0x31, operands[1].reg, operands[0], 0);
        },
        .IMUL_R64_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0xAF, operands[0].reg, operands[1], 0x0F);
        },
        .IMUL_R32_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0xAF, operands[0].reg, operands[1], 0x0F);
        },
        .AND_R64_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x21, operands[1].reg, operands[0], 0);
        },
        .AND_R32_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0x21, operands[1].reg, operands[0], 0);
        },
        .OR_R64_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x09, operands[1].reg, operands[0], 0);
        },
        .OR_R32_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0x09, operands[1].reg, operands[0], 0);
        },
        .SHIFT_LEFT => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const rex: u8 = if (dst >= 8) 0x48 | ((@as(u8, @intCast(dst)) >> 3) & 1) else 0x48;
            try code.append(rex);
            try code.append(0xC1);
            try code.append(0xE0 | @as(u8, @intCast(dst & 7)));
            const imm_bytes: [1]u8 = @bitCast(@as(i8, @intCast(operands[1].imm64)));
            try code.append(imm_bytes[0]);
        },
        .SHIFT_LEFT_32 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const rex: u8 = if (dst >= 8) 0x40 | ((@as(u8, @intCast(dst)) >> 3) & 1) else 0;
            if (rex != 0) try code.append(rex);
            try code.append(0xC1);
            try code.append(0xE0 | @as(u8, @intCast(dst & 7)));
            const imm_bytes: [1]u8 = @bitCast(@as(i8, @intCast(operands[1].imm64)));
            try code.append(imm_bytes[0]);
        },
        .SHIFT_RIGHT => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const rex: u8 = if (dst >= 8) 0x48 | ((@as(u8, @intCast(dst)) >> 3) & 1) else 0x48;
            try code.append(rex);
            try code.append(0xC1);
            try code.append(0xE8 | @as(u8, @intCast(dst & 7)));
            const imm_bytes: [1]u8 = @bitCast(@as(i8, @intCast(operands[1].imm64)));
            try code.append(imm_bytes[0]);
        },
        .SHIFT_RIGHT_32 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const rex: u8 = if (dst >= 8) 0x40 | ((@as(u8, @intCast(dst)) >> 3) & 1) else 0;
            if (rex != 0) try code.append(rex);
            try code.append(0xC1);
            try code.append(0xE8 | @as(u8, @intCast(dst & 7)));
            const imm_bytes: [1]u8 = @bitCast(@as(i8, @intCast(operands[1].imm64)));
            try code.append(imm_bytes[0]);
        },
        .LEA_R64_MEM => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x8D, operands[0].reg, operands[1], 0);
        },
        .JMP_REL32 => {
            if (operands.len < 1) return error.MissingOperands;
            try code.append(0xE9);
            const disp_bytes: [4]u8 = @bitCast(@as(i32, @bitCast(@as(u32, @truncate(operands[0].imm64)))));
            try code.appendSlice(&disp_bytes);
        },
        .JE_REL32 => try emitJcc(code, 0x0F84, operands),
        .JNE_REL32 => try emitJcc(code, 0x0F85, operands),
        .JG_REL32 => try emitJcc(code, 0x0F8F, operands),
        .JGE_REL32 => try emitJcc(code, 0x0F8D, operands),
        .JL_REL32 => try emitJcc(code, 0x0F8C, operands),
        .JLE_REL32 => try emitJcc(code, 0x0F8E, operands),
        .JA_REL32 => try emitJcc(code, 0x0F87, operands),
        .JAE_REL32 => try emitJcc(code, 0x0F83, operands),
        .JB_REL32 => try emitJcc(code, 0x0F82, operands),
        .JBE_REL32 => try emitJcc(code, 0x0F86, operands),
        .CALL_REL32 => {
            if (operands.len < 1) return error.MissingOperands;
            try code.append(0xE8);
            const disp_bytes: [4]u8 = @bitCast(@as(i32, @bitCast(@as(u32, @truncate(operands[0].imm64)))));
            try code.appendSlice(&disp_bytes);
        },
        .CALL_RIPDISP => {
            if (operands.len < 2) return error.MissingOperands;
            try code.append(0xFF);
            try code.append(0x15);
            const disp: i32 = operands[1].disp;
            const disp_bytes: [4]u8 = @bitCast(disp);
            try code.appendSlice(&disp_bytes);
        },
        .MOV_R64_MEM_RIP => {
            if (operands.len < 2) return error.MissingOperands;
            try code.append(0x48);
            try code.append(0x8B);
            try code.append(0x05 | (@as(u8, @intCast(operands[0].reg & 7)) << 3));
            const disp_bytes: [4]u8 = @bitCast(operands[1].disp);
            try code.appendSlice(&disp_bytes);
        },
        .PREFETCHT0_RIPREL => {
            try prefetchRipRel(code, 1);
        },
        .PREFETCHT1_RIPREL => {
            try prefetchRipRel(code, 2);
        },
        .PREFETCHT2_RIPREL => {
            try prefetchRipRel(code, 3);
        },
        .RET => try code.append(0xC3),
        .NOP => try code.append(0x90),
        .INT3 => try code.append(0xCC),
    }
}

fn emitJcc(code: *std.ArrayList(u8), opcode: u16, operands: []const Operand) !void {
    if (operands.len < 1) return error.MissingOperands;
    const b0: u8 = @intCast(opcode >> 8);
    const b1: u8 = @intCast(opcode & 0xFF);
    try code.append(b0);
    try code.append(b1);
    const disp_bytes: [4]u8 = @bitCast(@as(i32, @bitCast(@as(u32, @truncate(operands[0].imm64)))));
    try code.appendSlice(&disp_bytes);
}

fn prefetchRipRel(code: *std.ArrayList(u8), reg: u8) !void {
    try code.append(0x0F);
    try code.append(0x18);
    try code.append(0x05 | ((reg & 7) << 3));
    const zero: [4]u8 = .{ 0, 0, 0, 0 };
    try code.appendSlice(&zero);
}

fn emitModrmSibDisp(code: *std.ArrayList(u8), rex_base: u8, op: u8, reg: i16, m: Operand, prefix: u8) !void {
    var rex = rex_base;
    if (reg >= 8) rex |= 0x04; // REX.R
    if (m.reg >= 8) {
        rex |= 0x01; // REX.B for register-direct
    } else if (m.base_reg >= 0 and m.base_reg != 255) {
        if (m.base_reg >= 8) rex |= 0x01; // REX.B for base register
    }
    if (m.index_reg >= 8) rex |= 0x02; // REX.X for index register
    if (rex != 0) try code.append(0x40 | rex);
    if (prefix != 0) try code.append(prefix);

    try code.append(op);

    if (m.reg >= 0) {
        // Register-direct: mod=11
        const modrm: u8 = 0xC0 | (@as(u8, @intCast(reg & 7)) << 3) | @as(u8, @intCast(m.reg & 7));
        try code.append(modrm);
    } else if (m.index_reg >= 0 and m.index_reg != 4) {
        // SIB addressing: [base + index*scale + disp]
        const mod: u8 = if (m.disp == 0 and m.base_reg != 5) 0 else if (m.disp >= -128 and m.disp <= 127) 1 else 2;
        const modrm: u8 = mod << 6 | (@as(u8, @intCast(reg & 7)) << 3) | 4;
        try code.append(modrm);
        const scale_enc: u8 = switch (m.scale) { 1 => 0, 2 => 1, 4 => 2, 8 => 3, else => 0 };
        const sib: u8 = (scale_enc << 6) | (@as(u8, @intCast(m.index_reg & 7)) << 3) | @as(u8, @intCast(m.base_reg & 7));
        try code.append(sib);
        if (mod == 1) {
            try code.append(@as(u8, @bitCast(@as(i8, @intCast(m.disp)))));
        } else if (mod == 2) {
            const disp_bytes: [4]u8 = @bitCast(m.disp);
            try code.appendSlice(&disp_bytes);
        }
    } else if (m.base_reg == 255) {
        // RIP-relative
        try code.append(0x05 | (@as(u8, @intCast(reg & 7)) << 3));
        const disp_bytes: [4]u8 = @bitCast(m.disp);
        try code.appendSlice(&disp_bytes);
    } else if (m.base_reg >= 0) {
        const mod: u8 = if (m.disp == 0 and m.base_reg != 5) 0 else if (m.disp >= -128 and m.disp <= 127) 1 else 2;
        const b = @as(u8, @intCast(m.base_reg & 7));
        if (b == 4) {
            // RSP/R12 as base requires SIB byte
            const modrm: u8 = mod << 6 | (@as(u8, @intCast(reg & 7)) << 3) | 4;
            try code.append(modrm);
            try code.append(0x24); // [rsp]
            if (mod == 1) {
                try code.append(@as(u8, @bitCast(@as(i8, @intCast(m.disp)))));
            } else if (mod == 2) {
                const disp_bytes: [4]u8 = @bitCast(m.disp);
                try code.appendSlice(&disp_bytes);
            }
        } else {
            const modrm: u8 = mod << 6 | (@as(u8, @intCast(reg & 7)) << 3) | b;
            try code.append(modrm);
            if (mod == 1) {
                try code.append(@as(u8, @bitCast(@as(i8, @intCast(m.disp)))));
            } else if (mod == 2) {
                const disp_bytes: [4]u8 = @bitCast(m.disp);
                try code.appendSlice(&disp_bytes);
            }
        }
    } else {
        // Absolute displacement with no base (mod=00, rm=101)
        try code.append(0x04 | (@as(u8, @intCast(reg & 7)) << 3));
        const disp_bytes: [4]u8 = @bitCast(m.disp);
        try code.appendSlice(&disp_bytes);
    }
}

pub fn disassemble(bytes: []const u8) ![]u8 {
    _ = bytes;
    return std.fmt.allocPrint(std.heap.page_allocator, "[disassembly not implemented]", .{});
}
