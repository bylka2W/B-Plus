const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SimdPrefix = enum(u8) {
    none = 0,
    ps = 0,       // packed single (none)
    ss = 0xF3,    // scalar single
    sd = 0xF2,    // scalar double
    pd = 0x66,    // packed double
};

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
    ADD_R64_MEM,
    SUB_R64_MEM,
    CMP_R64_R64,
    CMP_R32_R32,
    CMP_R64_MEM,
    CMP_R64_IMM32,
    CMP_R32_IMM32,
    TEST_R64_R64,
    TEST_R32_R32,
    XOR_R64_R64,
    XOR_R32_R32,
    IMUL_R64_R64,
    IMUL_R64_IMM32,
    IMUL_R32_R32,
    IDIV_R64,
    AND_R64_R64,
    AND_R64_IMM32,
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
    CALL_R64,
    PUSH_R64,
    POP_R64,
    PUSHFQ,
    POPFQ,
    CQO,
    RET,
    NOP,
    INT3,
    // SSE packed single (no prefix)
    SSE_MOVUPS_LD, // 0F 10: xmm1 <- xmm2/m128
    SSE_MOVUPS_ST, // 0F 11: xmm2/m128 <- xmm1
    SSE_MOVAPS_LD, // 0F 28: xmm1 <- xmm2/m128 (aligned)
    SSE_MOVAPS_ST, // 0F 29: xmm2/m128 <- xmm1 (aligned)
    SSE_ADDPS,     // 0F 58: xmm1 += xmm2/m128
    SSE_SUBPS,     // 0F 5C: xmm1 -= xmm2/m128
    SSE_MULPS,     // 0F 59: xmm1 *= xmm2/m128
    SSE_DIVPS,     // 0F 5E: xmm1 /= xmm2/m128
    SSE_MINPS,     // 0F 5D: xmm1 = min(xmm1, xmm2/m128)
    SSE_MAXPS,     // 0F 5F: xmm1 = max(xmm1, xmm2/m128)
    SSE_SQRTPS,    // 0F 51: xmm1 = sqrt(xmm2/m128)
    SSE_SHUFPS,    // 0F C6: xmm1 = shuffle(xmm1, xmm2/m128, imm8)
    SSE_MOVLHPS,   // 0F 16: xmm1 <- low xmm2 -> high xmm1
    SSE_HADDPS,    // F2 0F 7C: xmm1 = xmm1[0]+xmm1[1], xmm1[2]+xmm1[3], xmm2[0]+xmm2[1], xmm2[2]+xmm2[3] (SSE3)
    SSE_DPPS,      // 66 0F 3A 40: xmm1 = dot(xmm1, xmm2, imm8) (SSE4.1)
    // SSE scalar single (prefix F3)
    SSE_MOVSS_LD,  // F3 0F 10: xmm1 <- xmm2/m32
    SSE_MOVSS_ST,  // F3 0F 11: xmm2/m32 <- xmm1
    SSE_ADDSS,     // F3 0F 58: xmm1 += xmm2/m32
    SSE_SUBSS,     // F3 0F 5C: xmm1 -= xmm2/m32
    SSE_MULSS,     // F3 0F 59: xmm1 *= xmm2/m32
    SSE_DIVSS,     // F3 0F 5E: xmm1 /= xmm2/m32
    SSE_MINSS,     // F3 0F 5D: xmm1 = min(xmm1, xmm2/m32)
    SSE_MAXSS,     // F3 0F 5F: xmm1 = max(xmm1, xmm2/m32)
    SSE_CVTSI2SS,  // F3 0F 2A: xmm1 <- int2float(r32/m32)
    SSE_CVTTSS2SI, // F3 0F 2C: r32 <- float2int_trunc(xmm2/m32)
    SETCC_R8,      // 0F 9x: reg8 <- condition (operand[1].imm64 = cc byte)
    SSE_UCOMISS,   // 0F 2E: compare scalar single, set flags (no NaN exception)
    SSE_SQRTSS,    // F3 0F 51: xmm1 = sqrt(xmm2/m32) (scalar)
    SSE_RSQRTSS,   // F3 0F 52: xmm1 = 1/sqrt(xmm2/m32) (scalar, approximate)
    SSE_ROUNDSS,   // 66 0F 3A 0A: xmm1 = round(xmm2, imm8) SSE4.1, imm8[1:0]=1==floor
    // SSE with 66 prefix
    SSE_MOVD_LD,   // 66 0F 6E: xmm <- r32/m32
    SSE_MOVD_ST,   // 66 0F 7E: r32/m32 <- xmm
    SSE_MOVQ_LD,   // F3 0F 7E: xmm <- r64/m64 (MOVQ)
    SSE_MOVQ_ST,   // 66 0F D6: r64/m64 <- xmm (MOVQ)
    SSE_MOVSD_LD,  // F2 0F 10: xmm <- xmm/m64 (scalar double load)
    SSE_MOVSD_ST,  // F2 0F 11: xmm/m64 <- xmm (scalar double store)
    SSE_XORPS,     // 0F 57: xmm1 ^= xmm2/m128
};

pub const Operand = struct {
    reg: i16 = -1,
    imm64: u64 = 0,
    base_reg: i16 = -1,
    index_reg: i16 = -1,
    scale: u8 = 1,
    disp: i32 = 0,
    is_xmm: bool = false,

    pub fn r(reg: i16) Operand {
        return .{ .reg = reg };
    }
    pub fn xmm(reg: i16) Operand {
        return .{ .reg = reg, .is_xmm = true };
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
        .ADD_R64_MEM => {
            if (operands.len < 2) return error.MissingOperands;
            const reg = operands[0].reg;
            const m = operands[1];
            try emitModrmSibDisp(code, 0x48, 0x03, reg, m, 0);
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
        .SUB_R64_MEM => {
            if (operands.len < 2) return error.MissingOperands;
            const reg = operands[0].reg;
            const m = operands[1];
            try emitModrmSibDisp(code, 0x48, 0x2B, reg, m, 0);
        },
        .CMP_R64_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x39, operands[1].reg, operands[0], 0);
        },
        .CMP_R64_MEM => {
            if (operands.len < 2) return error.MissingOperands;
            const reg = operands[0].reg;
            const m = operands[1];
            try emitModrmSibDisp(code, 0x48, 0x3B, reg, m, 0);
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
        .IMUL_R64_IMM32 => {
            if (operands.len < 2) return error.MissingOperands;
            const dst = operands[0].reg;
            const src = operands[1].reg;
            const v = operands[1].imm64;
            if (dst < 0 or dst > 15 or src < 0 or src > 15) return error.InvalidRegister;
            var rex: u8 = 0x48;
            if (dst >= 8) rex |= 0x04;
            if (src >= 8) rex |= 0x01;
            try code.append(rex);
            try code.append(0x69);
            const modrm: u8 = 0xC0 | (@as(u8, @intCast(dst & 7)) << 3) | @as(u8, @intCast(src & 7));
            try code.append(modrm);
            const imm_bytes: [4]u8 = @bitCast(@as(i32, @bitCast(@as(u32, @truncate(v)))));
            try code.appendSlice(&imm_bytes);
        },
        .IDIV_R64 => {
            if (operands.len < 1) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0xF7, 7, operands[0], 0);
        },
        .IMUL_R32_R32 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0, 0xAF, operands[0].reg, operands[1], 0x0F);
        },
        .AND_R64_R64 => {
            if (operands.len < 2) return error.MissingOperands;
            try emitModrmSibDisp(code, 0x48, 0x21, operands[1].reg, operands[0], 0);
        },
        .AND_R64_IMM32 => {
            if (operands.len < 2) return error.MissingOperands;
            const r = operands[0].reg;
            const imm: i32 = @bitCast(@as(u32, @truncate(operands[1].imm64)));
            var rex: u8 = 0x48;
            if (r >= 8) rex |= 0x01;
            try code.append(rex);
            try code.append(0x81);
            const modrm: u8 = 0xE0 | @as(u8, @intCast(r & 7));
            try code.append(modrm);
            try code.appendSlice(@as(*const [4]u8, @ptrCast(&imm))[0..4]);
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
        .CALL_R64 => {
            if (operands.len < 1) return error.MissingOperands;
            const reg = operands[0].reg;
            if (reg >= 8) try code.append(0x41);
            try code.append(0xFF);
            try code.append(0xD0 | @as(u8, @intCast(reg & 7)));
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
        .PUSH_R64 => {
            if (operands.len < 1) return error.MissingOperands;
            const reg = operands[0].reg;
            if (reg >= 8) try code.append(0x41);
            try code.append(0x50 | @as(u8, @intCast(reg & 7)));
        },
        .POP_R64 => {
            if (operands.len < 1) return error.MissingOperands;
            const reg = operands[0].reg;
            if (reg >= 8) try code.append(0x41);
            try code.append(0x58 | @as(u8, @intCast(reg & 7)));
        },
        .PUSHFQ => {
            try code.append(0x9C);
        },
        .POPFQ => {
            try code.append(0x9D);
        },
        .CQO => {
            try code.append(0x48);
            try code.append(0x99);
        },
        .RET => try code.append(0xC3),
        .NOP => try code.append(0x90),
        .INT3 => try code.append(0xCC),
        // SSE packed single (no simd_prefix)
        .SSE_MOVUPS_LD => try emitSseOp(code, 0, 0x10, operands[0].reg, operands[1]),
        .SSE_MOVUPS_ST => try emitSseOp(code, 0, 0x11, operands[1].reg, operands[0]),
        .SSE_MOVAPS_LD => try emitSseOp(code, 0, 0x28, operands[0].reg, operands[1]),
        .SSE_MOVAPS_ST => try emitSseOp(code, 0, 0x29, operands[1].reg, operands[0]),
        .SSE_ADDPS     => try emitSseOp(code, 0, 0x58, operands[0].reg, operands[1]),
        .SSE_SUBPS     => try emitSseOp(code, 0, 0x5C, operands[0].reg, operands[1]),
        .SSE_MULPS     => try emitSseOp(code, 0, 0x59, operands[0].reg, operands[1]),
        .SSE_DIVPS     => try emitSseOp(code, 0, 0x5E, operands[0].reg, operands[1]),
        .SSE_MINPS     => try emitSseOp(code, 0, 0x5D, operands[0].reg, operands[1]),
        .SSE_MAXPS     => try emitSseOp(code, 0, 0x5F, operands[0].reg, operands[1]),
        .SSE_SQRTPS    => try emitSseOp(code, 0, 0x51, operands[0].reg, operands[1]),
        .SSE_MOVLHPS   => try emitSseOp(code, 0, 0x16, operands[0].reg, operands[1]),
        .SSE_SHUFPS => {
            if (operands.len < 3) return error.MissingOperands;
            try emitSseOp(code, 0, 0xC6, operands[0].reg, operands[1]);
            try code.append(@as(u8, @intCast(operands[2].imm64 & 0xFF)));
        },
        // SSE scalar single (prefix F3)
        .SSE_MOVSS_LD  => try emitSseOp(code, 0xF3, 0x10, operands[0].reg, operands[1]),
        .SSE_MOVSS_ST  => try emitSseOp(code, 0xF3, 0x11, operands[1].reg, operands[0]),
        .SSE_ADDSS     => try emitSseOp(code, 0xF3, 0x58, operands[0].reg, operands[1]),
        .SSE_SUBSS     => try emitSseOp(code, 0xF3, 0x5C, operands[0].reg, operands[1]),
        .SSE_MULSS     => try emitSseOp(code, 0xF3, 0x59, operands[0].reg, operands[1]),
        .SSE_DIVSS     => try emitSseOp(code, 0xF3, 0x5E, operands[0].reg, operands[1]),
        .SSE_MINSS     => try emitSseOp(code, 0xF3, 0x5D, operands[0].reg, operands[1]),
        .SSE_MAXSS     => try emitSseOp(code, 0xF3, 0x5F, operands[0].reg, operands[1]),
        .SETCC_R8 => {
            if (operands.len < 2) return error.MissingOperands;
            const reg = operands[0].reg;
            const cc = @as(u8, @intCast(operands[1].imm64 & 0xF));
            if (reg >= 4) {
                try code.append(0x40 | @as(u8, @intCast((@as(u8, @intCast(reg)) >> 3) & 1)));
            }
            try code.append(0x0F);
            try code.append(0x90 | cc);
            try code.append(0xC0 | @as(u8, @intCast(reg & 7)));
        },
        .SSE_CVTSI2SS  => try emitSseOp(code, 0xF3, 0x2A, operands[0].reg, operands[1]),
        .SSE_CVTTSS2SI => try emitSseOp(code, 0xF3, 0x2C, operands[0].reg, operands[1]),
        .SSE_UCOMISS   => try emitSseOp(code, 0, 0x2E, operands[0].reg, operands[1]),
        .SSE_SQRTSS    => try emitSseOp(code, 0xF3, 0x51, operands[0].reg, operands[1]),
        .SSE_RSQRTSS   => try emitSseOp(code, 0xF3, 0x52, operands[0].reg, operands[1]),
        .SSE_HADDPS    => try emitSseOp(code, 0xF2, 0x7C, operands[0].reg, operands[1]),
        .SSE_DPPS => {
            if (operands.len < 3) return error.MissingOperands;
            try code.append(0x66);
            var rex: u8 = 0;
            if (operands[0].reg >= 8) rex |= 0x04;
            if (operands[1].reg >= 8) rex |= 0x01;
            if (rex != 0) try code.append(0x40 | rex);
            try code.append(0x0F);
            try code.append(0x3A);
            try code.append(0x40);
            const modrm: u8 = 0xC0 | (@as(u8, @intCast(operands[0].reg & 7)) << 3) | @as(u8, @intCast(operands[1].reg & 7));
            try code.append(modrm);
            try code.append(@as(u8, @intCast(operands[2].imm64 & 0xFF)));
        },
        .SSE_ROUNDSS => {
            if (operands.len < 3) return error.MissingOperands;
            try code.append(0x66);
            var rex: u8 = 0;
            if (operands[0].reg >= 8) rex |= 0x04;
            if (operands[1].reg >= 8) rex |= 0x01;
            if (rex != 0) try code.append(0x40 | rex);
            try code.append(0x0F);
            try code.append(0x3A);
            try code.append(0x0A);
            const modrm: u8 = 0xC0 | (@as(u8, @intCast(operands[0].reg & 7)) << 3) | @as(u8, @intCast(operands[1].reg & 7));
            try code.append(modrm);
            try code.append(@as(u8, @intCast(operands[2].imm64 & 0xFF)));
        },
        // SSE with 66 prefix
        .SSE_MOVD_LD   => try emitSseOp(code, 0x66, 0x6E, operands[0].reg, operands[1]),
        .SSE_MOVD_ST   => try emitSseOp(code, 0x66, 0x7E, operands[1].reg, operands[0]),
        .SSE_MOVQ_LD   => try emitSseOp(code, 0xF3, 0x7E, operands[0].reg, operands[1]),
        .SSE_MOVQ_ST   => try emitSseOp(code, 0x66, 0xD6, operands[1].reg, operands[0]),
        .SSE_MOVSD_LD  => try emitSseOp(code, 0xF2, 0x10, operands[0].reg, operands[1]),
        .SSE_MOVSD_ST  => try emitSseOp(code, 0xF2, 0x11, operands[1].reg, operands[0]),
        .SSE_XORPS     => try emitSseOp(code, 0, 0x57, operands[0].reg, operands[1]),
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

fn emitSseOp(code: *std.ArrayList(u8), simd_prefix: u8, opcode: u8, reg: i16, m: Operand) !void {
    if (simd_prefix != 0) try code.append(simd_prefix);
    try emitModrmSibDisp(code, 0, opcode, reg, m, 0x0F);
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

const RegNames = [_][:0]const u8{
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15",
};

fn regName(reg: u8, rex_b: bool) [:0]const u8 {
    const r = if (rex_b) reg | 8 else reg & 7;
    return RegNames[r & 15];
}

fn modRMDecode(byte: u8) struct { mod: u8, reg: u8, rm: u8 } {
    return .{ .mod = byte >> 6, .reg = (byte >> 3) & 7, .rm = byte & 7 };
}

const DecodedInst = struct {
    mnemonic: []const u8,
    ops: []const u8,
    len: usize,
};

fn decodeOne(bytes: []const u8) !DecodedInst {
    if (bytes.len == 0) return error.EndOfStream;
    var pos: usize = 0;

    const rex: u8 = if (pos < bytes.len and bytes[pos] >= 0x40 and bytes[pos] <= 0x4F) blk: {
        const r = bytes[pos];
        pos += 1;
        break :blk r;
    } else 0;
    const rex_w: bool = (rex & 8) != 0;

    const two_byte: bool = if (pos < bytes.len and bytes[pos] == 0x0F) blk: {
        pos += 1;
        break :blk true;
    } else false;

    if (pos >= bytes.len) return error.EndOfStream;
    const op = bytes[pos];
    pos += 1;

    var imm_size: usize = 0;
    var needs_modrm = false;

    const mnemonic: []const u8 = if (two_byte) blk: {
        switch (op) {
            0x10 => { needs_modrm = true; break :blk "movss"; },
            0x11 => { needs_modrm = true; break :blk "movss"; },
            0x28 => { needs_modrm = true; break :blk "movaps"; },
            0x29 => { needs_modrm = true; break :blk "movaps"; },
            0x2A => { needs_modrm = true; break :blk "cvtsi2ss"; },
            0x2C => { needs_modrm = true; break :blk "cvttss2si"; },
            0x2E => { needs_modrm = true; break :blk "ucomiss"; },
            0x51 => { needs_modrm = true; break :blk "sqrtps"; },
            0x52 => { needs_modrm = true; break :blk "rsqrtss"; },
            0x57 => { needs_modrm = true; break :blk "xorps"; },
            0x58 => { needs_modrm = true; break :blk "addps"; },
            0x59 => { needs_modrm = true; break :blk "mulps"; },
            0x5C => { needs_modrm = true; break :blk "subps"; },
            0x5D => { needs_modrm = true; break :blk "minps"; },
            0x5E => { needs_modrm = true; break :blk "divps"; },
            0x5F => { needs_modrm = true; break :blk "maxps"; },
            0x6E => { needs_modrm = true; break :blk "movd"; },
            0x7E => { needs_modrm = true; break :blk "movd"; },
            0x7C => { needs_modrm = true; break :blk "haddps"; },
            0x90 => { needs_modrm = true; break :blk "seto"; },
            0x91 => { needs_modrm = true; break :blk "setno"; },
            0x92 => { needs_modrm = true; break :blk "setb"; },
            0x93 => { needs_modrm = true; break :blk "setae"; },
            0x94 => { needs_modrm = true; break :blk "sete"; },
            0x95 => { needs_modrm = true; break :blk "setne"; },
            0x96 => { needs_modrm = true; break :blk "setbe"; },
            0x97 => { needs_modrm = true; break :blk "seta"; },
            0x98 => { needs_modrm = true; break :blk "sets"; },
            0x99 => { needs_modrm = true; break :blk "setns"; },
            0x9A => { needs_modrm = true; break :blk "setp"; },
            0x9B => { needs_modrm = true; break :blk "setnp"; },
            0x9C => { needs_modrm = true; break :blk "setl"; },
            0x9D => { needs_modrm = true; break :blk "setge"; },
            0x9E => { needs_modrm = true; break :blk "setle"; },
            0x9F => { needs_modrm = true; break :blk "setg"; },
            0xD6 => { needs_modrm = true; break :blk "movq"; },
            0x3A => {
                if (pos >= bytes.len) return error.EndOfStream;
                const op3 = bytes[pos]; pos += 1;
                needs_modrm = true;
                imm_size = 1;
                if (op3 == 0x0A) break :blk "roundss";
                if (op3 == 0x40) break :blk "dpps";
                return error.UnknownInstruction;
            },
            else => return error.UnknownInstruction,
        }
    } else blk: {
        if (op >= 0x88 and op <= 0x8B) { needs_modrm = true;
            break :blk if (op == 0x89 or op == 0x8B) "mov" else "mov"; }
        switch (op) {
            0x00...0x03 => { needs_modrm = true; break :blk "add"; },
            0x04 => { imm_size = 1; break :blk "add"; },
            0x08...0x0B => { needs_modrm = true; break :blk "or"; },
            0x20...0x23 => { needs_modrm = true; break :blk "and"; },
            0x28...0x2B => { needs_modrm = true; break :blk "sub"; },
            0x38...0x3B => { needs_modrm = true; break :blk "cmp"; },
            0x3C => { imm_size = 1; break :blk "cmp"; },
            0x50...0x5F => {
                const r = op & 7;
                _ = r;
                if (op >= 0x58) break :blk "pop";
                break :blk "push";
            },
            0x68 => { imm_size = 4; break :blk "push"; },
            0x6A => { imm_size = 1; break :blk "push"; },
            0x70 => { imm_size = 1; break :blk "jo"; },
            0x71 => { imm_size = 1; break :blk "jno"; },
            0x72 => { imm_size = 1; break :blk "jb"; },
            0x73 => { imm_size = 1; break :blk "jae"; },
            0x74 => { imm_size = 1; break :blk "je"; },
            0x75 => { imm_size = 1; break :blk "jne"; },
            0x76 => { imm_size = 1; break :blk "jbe"; },
            0x77 => { imm_size = 1; break :blk "ja"; },
            0x78 => { imm_size = 1; break :blk "js"; },
            0x79 => { imm_size = 1; break :blk "jns"; },
            0x7A => { imm_size = 1; break :blk "jp"; },
            0x7B => { imm_size = 1; break :blk "jnp"; },
            0x7C => { imm_size = 1; break :blk "jl"; },
            0x7D => { imm_size = 1; break :blk "jge"; },
            0x7E => { imm_size = 1; break :blk "jle"; },
            0x7F => { imm_size = 1; break :blk "jg"; },
            0x85 => { needs_modrm = true; break :blk "test"; },
            0x8D => { needs_modrm = true; break :blk "lea"; },
            0xB0...0xB7 => { imm_size = 1; break :blk "mov"; },
            0xB8...0xBF => {
                if (rex_w) imm_size = 8 else imm_size = 4;
                break :blk "mov";
            },
            0xC3 => break :blk "ret",
            0xC6 => { needs_modrm = true; imm_size = 1; break :blk "mov"; },
            0xC7 => { needs_modrm = true; imm_size = 4; break :blk "mov"; },
            0xE9 => { imm_size = 4; break :blk "jmp"; },
            0xEB => { imm_size = 1; break :blk "jmp"; },
            0xF6...0xF7 => { needs_modrm = true; break :blk "imul"; },
            0x31 => { needs_modrm = true; break :blk "xor"; },
            0x33 => { needs_modrm = true; break :blk "xor"; },
            0x01 => { needs_modrm = true; break :blk "add"; },
            0x29 => { needs_modrm = true; break :blk "sub"; },
            0x09 => { needs_modrm = true; break :blk "or"; },
            0x21 => { needs_modrm = true; break :blk "and"; },
            0x39 => { needs_modrm = true; break :blk "cmp"; },
            0x0F => { break :blk "nop"; },
            0xCC => { break :blk "int3"; },
            else => return error.UnknownInstruction,
        }
    };

    if (pos >= bytes.len) return error.EndOfStream;

    var mr: struct { mod: u8, reg: u8, rm: u8 } = undefined;
    if (needs_modrm) {
        mr = modRMDecode(bytes[pos]); pos += 1;
    }

    if (needs_modrm and mr.mod != 3) {
        if (mr.rm == 4) {
            if (pos >= bytes.len) return error.EndOfStream;
            pos += 1; // skip SIB
        }
        if (mr.mod == 1) { if (pos >= bytes.len) return error.EndOfStream; pos += 1; }
        else if (mr.mod == 2 or (mr.mod == 0 and mr.rm == 5)) { if (pos + 4 > bytes.len) return error.EndOfStream; pos += 4; }
    }

    if (imm_size > 0) {
        if (pos + imm_size > bytes.len) return error.EndOfStream;
        pos += imm_size;
    }

    return .{ .mnemonic = mnemonic, .ops = "", .len = pos };
}

pub fn disassemble(bytes: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(std.heap.page_allocator);
    errdefer result.deinit();
    var pos: usize = 0;
    var writer = result.writer();
    while (pos < bytes.len) {
        const saved = pos;
        const decoded = decodeOne(bytes[pos..]) catch {
            try writer.print("  {x:0>4}: ??\n", .{saved});
            pos += 1;
            continue;
        };
        try writer.print("  {x:0>4}: ", .{saved});
        for (bytes[saved..saved + decoded.len]) |b| try writer.print("{x:0>2} ", .{b});
        try writer.print("  {s}", .{decoded.mnemonic});
        try writer.writeAll("\n");
        pos += decoded.len;
    }
    return result.toOwnedSlice();
}
