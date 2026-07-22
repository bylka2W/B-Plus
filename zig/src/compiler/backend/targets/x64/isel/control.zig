/// x64 control-flow instruction selection (branch/call/ret/select).
const std = @import("std");
const mir = @import("../../../mir/mir.zig");
const enc = @import("../encoder.zig");
const OpCode = enc.OpCode;
const Operand = enc.Operand;
const regalloc = @import("../../../regalloc/regalloc.zig");
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
    try append2(ctx, .JMP_REL32, Operand.imm(0), .{});
}

pub fn selectJcc(ctx: *Ctx, j: mir.JccInst, allocator: std.mem.Allocator) !void {
    const jcc_op = condToJccOp(j.cc);
    try ctx.block_fixups.append(allocator, .{ .disp_pos = 0, .target = j.target });
    try append2(ctx, jcc_op, Operand.imm(0), .{});
}

pub fn selectCall(ctx: *Ctx, c: mir.CallInst) !void {
    const win64_args = [_]i16{ 1, 2, 8, 9 };
    var src_regs: [14]i16 = .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };

    for (0..c.arg_count) |i| {
        if (regalloc.isSpilled(ctx.ra, c.args[i])) {
            try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, c.args[i], ctx.scratch);
            src_regs[i] = ctx.scratch;
        } else {
            src_regs[i] = resolveReg(ctx.ra, c.args[i]);
        }
    }

    for (0..@min(c.arg_count, 4)) |i| {
        const src = src_regs[i];
        const dst = win64_args[i];
        if (src == dst) continue;
        for (0..@min(c.arg_count, 4)) |j| {
            if (j != i and src == win64_args[j]) {
                try append2(ctx, .MOV_R64_R64, Operand.r(ctx.scratch), Operand.r(src));
                src_regs[i] = ctx.scratch;
                break;
            }
        }
    }

    for (0..@min(c.arg_count, 4)) |i| {
        const src = src_regs[i];
        const dst = win64_args[i];
        if (src != dst) try append2(ctx, .MOV_R64_R64, Operand.r(dst), Operand.r(src));
    }

    try ctx.call_fixups.append(ctx.mf.allocator, .{ .name = c.name, .disp_pos = 0 });
    try append2(ctx, .CALL_REL32, Operand.imm(0), .{});

    if (!c.is_void) {
        const dst_spilled = regalloc.isSpilled(ctx.ra, c.dst);
        if (dst_spilled) {
            try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, c.dst, 0);
        } else {
            const dst = resolveReg(ctx.ra, c.dst);
            if (dst != 0) try append2(ctx, .MOV_R64_R64, Operand.r(dst), Operand.r(0));
        }
    }
}

pub fn selectRet(ctx: *Ctx, r: mir.RetInst) !void {
    switch (r) {
        .void_ret => {},
        .value => |val| {
            const val_spilled = regalloc.isSpilled(ctx.ra, val);
            if (val_spilled) {
                try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, val, 0);
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
            try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, s.dst, ctx.scratch);
            try append3(ctx, .CMOV_R64_R64, Operand.r(ctx.scratch), Operand.r(regalloc.SCRATCH_REG_2), .{ .imm64 = @intFromEnum(s.cc) });
        } else if (src_spilled) {
            try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, s.dst, ctx.scratch);
            const src_mem = regalloc.spilledMemOp(ctx.ra, s.src);
            try append3(ctx, .CMOV_R64_MEM, Operand.r(ctx.scratch), src_mem, .{ .imm64 = @intFromEnum(s.cc) });
        } else {
            try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, s.dst, ctx.scratch);
            const src_reg = resolveReg(ctx.ra, s.src);
            try append3(ctx, .CMOV_R64_R64, Operand.r(ctx.scratch), Operand.r(src_reg), .{ .imm64 = @intFromEnum(s.cc) });
        }
        try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, s.dst, ctx.scratch);
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
