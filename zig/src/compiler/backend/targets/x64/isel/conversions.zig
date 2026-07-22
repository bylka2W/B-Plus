/// x64 type conversion instruction selection (sext/zext/trunc/sitofp/fptosi/fpext/fptrunc).
const mir = @import("../../../mir/mir.zig");
const enc = @import("../encoder.zig");
const OpCode = enc.OpCode;
const Operand = enc.Operand;
const regalloc = @import("../../../regalloc/regalloc.zig");
const ctx_mod = @import("context.zig");
const Ctx = ctx_mod.Ctx;
const append2 = ctx_mod.append2;
const resolveReg = ctx_mod.resolveReg;

pub fn selectConv(ctx: *Ctx, c: mir.ConvInst, ss32_op: OpCode, sd32_op: OpCode, ss64_op: OpCode, sd64_op: OpCode) !void {
    const dst_vreg = switch (c.dst) { .vreg => |v| v, else => 0 };
    const src_vreg = switch (c.src) { .vreg => |v| v, else => 0 };
    const dst_dtype = ctx.mfunc.getVRegType(dst_vreg);
    const src_dtype = ctx.mfunc.getVRegType(src_vreg);
    const is_single_float = (src_dtype == .f32) or (dst_dtype == .f32);
    const is_64bit_int = (src_dtype == .i64) or (dst_dtype == .i64);

    const dst_spilled = regalloc.isSpilled(ctx.ra, c.dst);
    const src_spilled = regalloc.isSpilled(ctx.ra, c.src);

    const src_reg: i16 = if (src_spilled) blk: {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, c.src, ctx.scratch);
        break :blk ctx.scratch;
    } else switch (c.src) {
        .vreg => resolveReg(ctx.ra, c.src),
        .imm => |v| blk: {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @bitCast(v) });
            break :blk ctx.scratch;
        },
        else => resolveReg(ctx.ra, c.src),
    };
    const dst_reg = if (dst_spilled) ctx.scratch else resolveReg(ctx.ra, c.dst);

    const conv_op: OpCode = blk: {
        if (is_single_float) {
            break :blk if (is_64bit_int) ss64_op else ss32_op;
        } else {
            break :blk if (is_64bit_int) sd64_op else sd32_op;
        }
    };

    try append2(ctx, conv_op, Operand.xmm(dst_reg), Operand.r(src_reg));

    if (dst_spilled) {
        try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, c.dst, ctx.scratch);
    }
}

pub fn selectConvSingle(ctx: *Ctx, c: mir.ConvInst, sse_op: OpCode) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, c.dst);
    const src_spilled = regalloc.isSpilled(ctx.ra, c.src);

    if (src_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, c.src, ctx.scratch);
    }
    if (dst_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, c.dst, ctx.scratch);
    }

    const src_reg = if (src_spilled) ctx.scratch else resolveReg(ctx.ra, c.src);
    const dst_reg = if (dst_spilled) ctx.scratch else resolveReg(ctx.ra, c.dst);

    try append2(ctx, sse_op, Operand.xmm(dst_reg), Operand.xmm(src_reg));

    if (dst_spilled) {
        try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, c.dst, ctx.scratch);
    }
}

pub fn selectSext(ctx: *Ctx, c: mir.ConvInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, c.dst);
    const src_spilled = if (c.src == .vreg) regalloc.isSpilled(ctx.ra, c.src) else false;

    if (src_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, c.src, ctx.scratch);
    }

    const src_reg: i16 = if (src_spilled) ctx.scratch else switch (c.src) {
        .vreg => resolveReg(ctx.ra, c.src),
        .imm => |v| blk: {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @bitCast(v) });
            break :blk ctx.scratch;
        },
        else => resolveReg(ctx.ra, c.src),
    };
    const dst_reg = if (dst_spilled) ctx.scratch else resolveReg(ctx.ra, c.dst);

    try append2(ctx, .MOVSX_R64_R32, Operand.r(dst_reg), Operand.r(src_reg));

    if (dst_spilled) {
        try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, c.dst, ctx.scratch);
    }
}

pub fn selectZext(ctx: *Ctx, c: mir.ConvInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, c.dst);
    const src_spilled = if (c.src == .vreg) regalloc.isSpilled(ctx.ra, c.src) else false;

    if (src_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, c.src, ctx.scratch);
    }

    const src_reg: i16 = if (src_spilled) ctx.scratch else switch (c.src) {
        .vreg => resolveReg(ctx.ra, c.src),
        .imm => |v| blk: {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @bitCast(v) });
            break :blk ctx.scratch;
        },
        else => resolveReg(ctx.ra, c.src),
    };
    const dst_reg = if (dst_spilled) ctx.scratch else resolveReg(ctx.ra, c.dst);

    try append2(ctx, .MOVZX_R64_R32, Operand.r(dst_reg), Operand.r(src_reg));

    if (dst_spilled) {
        try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, c.dst, ctx.scratch);
    }
}

pub fn selectTrunc(ctx: *Ctx, c: mir.ConvInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, c.dst);
    const src_spilled = if (c.src == .vreg) regalloc.isSpilled(ctx.ra, c.src) else false;

    if (src_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, c.src, ctx.scratch);
    }

    const src_reg: i16 = if (src_spilled) ctx.scratch else switch (c.src) {
        .vreg => resolveReg(ctx.ra, c.src),
        .imm => |v| blk: {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @bitCast(v) });
            break :blk ctx.scratch;
        },
        else => resolveReg(ctx.ra, c.src),
    };
    const dst_reg = if (dst_spilled) ctx.scratch else resolveReg(ctx.ra, c.dst);

    try append2(ctx, .MOV_R32_R32, Operand.r(dst_reg), Operand.r(src_reg));

    if (dst_spilled) {
        try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, c.dst, ctx.scratch);
    }
}
