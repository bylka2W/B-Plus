///выбор инструкций управления потоком для x64: переходы вызовы возвраты и select
const std = @import("std");
const mir = @import("../../../mir/mir.zig");
const enc = @import("../encoder.zig");
const OpCode = enc.OpCode;
const Operand = enc.Operand;
const regalloc = @import("../../../regalloc/regalloc.zig");
const spill = @import("spill.zig");
const ctx_mod = @import("context.zig");
const Ctx = ctx_mod.Ctx;
const append2 = ctx_mod.append2;
const append1 = ctx_mod.append1;
const append3 = ctx_mod.append3;
const resolveReg = ctx_mod.resolveReg;
const resolveOp = ctx_mod.resolveOp;
const resolveOpOrSpill = ctx_mod.resolveOpOrSpill;
const condToJccOp = ctx_mod.condToJccOp;

pub fn selectJmp(ctx: *Ctx, j: mir.JmpInst, allocator: std.mem.Allocator) !void {
    try ctx.block_fixups.append(allocator, .{ .disp_pos = 0, .target = j.target });
    try append1(ctx, .JMP_REL32, Operand.imm(0));
}

pub fn selectJcc(ctx: *Ctx, j: mir.JccInst, allocator: std.mem.Allocator) !void {
    const jcc_op = condToJccOp(j.cc);
    try ctx.block_fixups.append(allocator, .{ .disp_pos = 0, .target = j.target });
    try append1(ctx, jcc_op, Operand.imm(0));
}

pub fn selectTrap(ctx: *Ctx) !void {
    try append1(ctx, .UD2, Operand.imm(0));
}

pub fn selectCall(ctx: *Ctx, c: mir.CallInst) !void {
    const int_arg_regs = [_]i16{ 1, 2, 8, 9 }; // RCX, RDX, R8, R9
    const float_arg_regs = [_]i16{ 0, 1, 2, 3 }; // XMM0-XMM3

    //определяет для каждого аргумента это целое число или float
    var int_idx: usize = 0;
    var float_idx: usize = 0;
    var gpr_src: [14]i16 = .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
    var xmm_src: [14]i16 = .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
    var gpr_dst: [14]i16 = .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
    var xmm_dst: [14]i16 = .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
    var arg_count: usize = 0;

    for (0..c.arg_count) |i| {
        const arg = c.args[i];
        const dtype = c.arg_types[i];
        const is_float = dtype.isFloat();

        if (arg == .imm) {
            if (is_float) {
                try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @bitCast(arg.imm) });
                if (float_idx < float_arg_regs.len) {
                    const xs: i16 = 14;
                    if (dtype == .f64) {
                        try append2(ctx, .SSE_MOVQ_LD, Operand.xmm(xs), Operand.r(ctx.scratch));
                    } else {
                        try append2(ctx, .SSE_MOVD_LD, Operand.xmm(xs), Operand.r(ctx.scratch));
                    }
                    xmm_src[arg_count] = xs;
                    xmm_dst[arg_count] = float_arg_regs[float_idx];
                    float_idx += 1;
                }
            } else {
                if (int_idx < int_arg_regs.len) {
                    const dst = int_arg_regs[int_idx];
                    try append2(ctx, .MOV_R64_IMM64, Operand.r(dst), .{ .imm64 = @bitCast(arg.imm) });
                    gpr_src[arg_count] = dst;
                    gpr_dst[arg_count] = dst;
                    int_idx += 1;
                }
            }
            arg_count += 1;
            continue;
        }

        if (regalloc.isSpilled(ctx.ra, arg)) {
            try spill.loadSpilledOp(ctx, arg, ctx.scratch);
            if (is_float) {
                xmm_src[arg_count] = ctx.scratch;
                const xs: i16 = 14;
                if (dtype == .f64) {
                    try append2(ctx, .SSE_MOVQ_LD, Operand.xmm(xs), Operand.r(ctx.scratch));
                } else {
                    try append2(ctx, .SSE_MOVD_LD, Operand.xmm(xs), Operand.r(ctx.scratch));
                }
                xmm_src[arg_count] = xs;
            } else {
                gpr_src[arg_count] = ctx.scratch;
            }
        } else {
            const reg = resolveReg(ctx.ra, arg);
            if (is_float) {
                xmm_src[arg_count] = reg;
            } else {
                gpr_src[arg_count] = reg;
            }
        }

        if (is_float) {
            if (float_idx < float_arg_regs.len) {
                xmm_dst[arg_count] = float_arg_regs[float_idx];
                float_idx += 1;
            }
        } else {
            if (int_idx < int_arg_regs.len) {
                gpr_dst[arg_count] = int_arg_regs[int_idx];
                int_idx += 1;
            }
        }

        arg_count += 1;
    }

    for (0..arg_count) |i| {
        if (gpr_src[i] == -1) continue;
        const src = gpr_src[i];
        const dst = gpr_dst[i];
        if (dst == -1 or src == dst) continue;
        for (i + 1..arg_count) |j| {
            if (gpr_src[j] == dst) {
                try append2(ctx, .MOV_R64_R64, Operand.r(ctx.scratch), Operand.r(src));
                gpr_src[i] = ctx.scratch;
                break;
            }
        }
    }
    for (0..arg_count) |i| {
        if (gpr_src[i] == -1) continue;
        const src = gpr_src[i];
        const dst = gpr_dst[i];
        if (dst == -1 or src == dst) continue;
        try append2(ctx, .MOV_R64_R64, Operand.r(dst), Operand.r(src));
    }

    for (0..arg_count) |i| {
        if (xmm_src[i] == -1) continue;
        const src = xmm_src[i];
        const dst = xmm_dst[i];
        if (dst == -1 or src == dst) continue;
        for (i + 1..arg_count) |j| {
            if (xmm_src[j] == dst) {
                const xs: i16 = 15;
                try append2(ctx, .SSE_MOVSD_LD, Operand.xmm(xs), Operand.xmm(src));
                xmm_src[i] = xs;
                break;
            }
        }
    }
    for (0..arg_count) |i| {
        if (xmm_src[i] == -1) continue;
        const src = xmm_src[i];
        const dst = xmm_dst[i];
        if (dst == -1 or src == dst) continue;
        try append2(ctx, .SSE_MOVSD_LD, Operand.xmm(dst), Operand.xmm(src));
    }

    try append2(ctx, .SUB_R64_IMM32, Operand.r(4), Operand.imm(32));

    try ctx.call_fixups.append(ctx.mf.allocator, .{ .name = c.name, .disp_pos = 0 });
    try append1(ctx, .CALL_REL32, Operand.imm(0));

    try append2(ctx, .ADD_R64_IMM32, Operand.r(4), Operand.imm(32));

    if (!c.is_void) {
        const dst_spilled = regalloc.isSpilled(ctx.ra, c.dst);
        const dst_vreg = switch (c.dst) { .vreg => |v| v, else => 0 };
        const ret_dtype = ctx.mfunc.getVRegType(dst_vreg) orelse .i64;
        if (ret_dtype.isFloat()) {
            if (dst_spilled) {
                        if (ret_dtype == .f64) {
                            try append2(ctx, .SSE_MOVQ_ST, Operand.r(ctx.scratch), Operand.xmm(0));
                        } else {
                            try append2(ctx, .SSE_MOVD_ST, Operand.r(ctx.scratch), Operand.xmm(0));
                }
                try spill.storeSpilledOp(ctx, c.dst, ctx.scratch);
            } else {
                const dst = resolveReg(ctx.ra, c.dst);
                if (dst != 0) {
                    if (ret_dtype == .f64) {
                        try append2(ctx, .SSE_MOVSD_LD, Operand.xmm(dst), Operand.xmm(0));
                    } else {
                        try append2(ctx, .SSE_MOVSS_LD, Operand.xmm(dst), Operand.xmm(0));
                    }
                }
            }
        } else {
            if (dst_spilled) {
                try spill.storeSpilledOp(ctx, c.dst, 0);
            } else {
                const dst = resolveReg(ctx.ra, c.dst);
                if (dst != 0) try append2(ctx, .MOV_R64_R64, Operand.r(dst), Operand.r(0));
            }
        }
    }
}

pub fn selectRet(ctx: *Ctx, r: mir.RetInst) !void {
    switch (r) {
        .void_ret => {
            try append2(ctx, .XOR_R64_R64, Operand.r(0), Operand.r(0));
        },
        .value => |val| {
            const val_vreg = switch (val) { .vreg => |v| v, else => 0 };
            const dtype = ctx.mfunc.getVRegType(val_vreg) orelse .i64;

            if (dtype.isFloat()) {
                const val_spilled = regalloc.isSpilled(ctx.ra, val);
                if (val_spilled) {
                    try spill.loadSpilledOp(ctx, val, ctx.scratch);
                    const xs: i16 = if (ctx.scratch == 15) 14 else 15; 
                    if (dtype == .f64) {
                        try append2(ctx, .SSE_MOVQ_LD, Operand.xmm(xs), Operand.r(ctx.scratch));
                    } else {
                        try append2(ctx, .SSE_MOVD_LD, Operand.xmm(xs), Operand.r(ctx.scratch));
                    }
                    if (xs != 0) {
                        if (dtype == .f64) {
                            try append2(ctx, .SSE_MOVSD_LD, Operand.xmm(0), Operand.xmm(xs));
                        } else {
                            try append2(ctx, .SSE_MOVSS_LD, Operand.xmm(0), Operand.xmm(xs));
                        }
                    }
                } else {
                    const val_r = resolveReg(ctx.ra, val);
                    if (val_r != 0) {
                        if (dtype == .f64) {
                            try append2(ctx, .SSE_MOVSD_LD, Operand.xmm(0), Operand.xmm(val_r));
                        } else {
                            try append2(ctx, .SSE_MOVSS_LD, Operand.xmm(0), Operand.xmm(val_r));
                        }
                    }
                }
            } else {
                const val_spilled = regalloc.isSpilled(ctx.ra, val);
                if (val_spilled) {
                    try spill.loadSpilledOp(ctx, val, 0);
                } else {
                    const val_r = resolveOp(ctx.ra, val);
                    if (val_r.reg >= 0) {
                        if (val_r.reg != 0) {
                            try append2(ctx, .MOV_R64_R64, Operand.r(0), val_r);
                        }
                    } else {
                        try append2(ctx, .MOV_R64_IMM64, Operand.r(0), val_r);
                    }
                }
            }
        },
    }
}

pub fn selectSelect(ctx: *Ctx, s: mir.SelectInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, s.dst);
    const src_is_imm = s.src == .imm;
    const src_spilled = if (s.src == .vreg) regalloc.isSpilled(ctx.ra, s.src) else false;

    if (dst_spilled) {
        if (src_is_imm) {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(regalloc.SCRATCH_REG_2), .{ .imm64 = @bitCast(s.src.imm) });
            try spill.loadSpilledOp(ctx, s.dst, ctx.scratch);
            try append3(ctx, .CMOV_R64_R64, Operand.r(ctx.scratch), Operand.r(regalloc.SCRATCH_REG_2), .{ .imm64 = @intFromEnum(s.cc) });
        } else if (src_spilled) {
            try spill.loadSpilledOp(ctx, s.dst, ctx.scratch);
            const src_mem = regalloc.spilledMemOp(ctx.ra, s.src);
            try append3(ctx, .CMOV_R64_MEM, Operand.r(ctx.scratch), src_mem, .{ .imm64 = @intFromEnum(s.cc) });
        } else {
            try spill.loadSpilledOp(ctx, s.dst, ctx.scratch);
            const src_reg = resolveReg(ctx.ra, s.src);
            try append3(ctx, .CMOV_R64_R64, Operand.r(ctx.scratch), Operand.r(src_reg), .{ .imm64 = @intFromEnum(s.cc) });
        }
        try spill.storeSpilledOp(ctx, s.dst, ctx.scratch);
    } else if (src_spilled) {
        const dst_reg = resolveReg(ctx.ra, s.dst);
        const src_mem = regalloc.spilledMemOp(ctx.ra, s.src);
        try append3(ctx, .CMOV_R64_MEM, Operand.r(dst_reg), src_mem, .{ .imm64 = @intFromEnum(s.cc) });
    } else if (src_is_imm) {
        const dst_reg = resolveReg(ctx.ra, s.dst);
        try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @bitCast(s.src.imm) });
        try append3(ctx, .CMOV_R64_R64, Operand.r(dst_reg), Operand.r(ctx.scratch), .{ .imm64 = @intFromEnum(s.cc) });
    } else {
        const dst_reg = resolveReg(ctx.ra, s.dst);
        const src_reg = resolveReg(ctx.ra, s.src);
        try append3(ctx, .CMOV_R64_R64, Operand.r(dst_reg), Operand.r(src_reg), .{ .imm64 = @intFromEnum(s.cc) });
    }
}
