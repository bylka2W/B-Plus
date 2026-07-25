/// x64 floating-point instruction selection (SSE scalar).
const mir = @import("../../../mir/mir.zig");
const enc = @import("../encoder.zig");
const OpCode = enc.OpCode;
const Operand = enc.Operand;
const regalloc = @import("../../../regalloc/regalloc.zig");
const ctx_mod = @import("context.zig");
const Ctx = ctx_mod.Ctx;
const append2 = ctx_mod.append2;
const resolveReg = ctx_mod.resolveReg;
const xmmScratch = ctx_mod.xmmScratch;
const loadFloatOpToXmm = ctx_mod.loadFloatOpToXmm;
const moveGprToXmm = ctx_mod.moveGprToXmm;

pub fn selectFBinOp(ctx: *Ctx, f: mir.FloatBinOp, ss_op: OpCode, sd_op: OpCode) !void {
    const dst_vreg = switch (f.dst) { .vreg => |v| v, else => 0 };
    const dtype = ctx.mfunc.getVRegType(dst_vreg) orelse .i64;
    const sse_op: OpCode = if (dtype == .f64) sd_op else ss_op;
    const xs = xmmScratch();
    const dst_spilled = regalloc.isSpilled(ctx.ra, f.dst);

    if (dst_spilled) {
        try loadFloatOpToXmm(ctx, f.a, xs, dtype);
        try loadFloatOpToXmm(ctx, f.b, xs, dtype);
        try append2(ctx, sse_op, Operand.xmm(xs), Operand.xmm(xs));
        try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, f.dst, ctx.scratch);
    } else {
        const dst = resolveReg(ctx.ra, f.dst);
        try loadFloatOpToXmm(ctx, f.a, dst, dtype);
        if (f.b == .imm) {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), Operand.imm(@bitCast(f.b.imm)));
            try moveGprToXmm(ctx, ctx.scratch, xs, dtype);
            try append2(ctx, sse_op, Operand.xmm(dst), Operand.xmm(xs));
        } else if (regalloc.isSpilled(ctx.ra, f.b)) {
            try loadFloatOpToXmm(ctx, f.b, xs, dtype);
            try append2(ctx, sse_op, Operand.xmm(dst), Operand.xmm(xs));
        } else {
            const b_reg = resolveReg(ctx.ra, f.b);
            try append2(ctx, sse_op, Operand.xmm(dst), Operand.xmm(b_reg));
        }
    }
}

pub fn selectFNeg(ctx: *Ctx, n: mir.UnaryInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, n.dst);
    const dst_vreg = switch (n.dst) { .vreg => |v| v, else => 0 };
    const dtype = ctx.mfunc.getVRegType(dst_vreg) orelse .i64;
    const xs = xmmScratch();

    if (dst_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, n.dst, ctx.scratch);
        if (dtype == .f64) {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @as(u64, 0x8000000000000000) });
            try append2(ctx, .SSE_MOVQ_LD, Operand.xmm(xs), Operand.r(ctx.scratch));
        } else {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @as(u64, 0x80000000) });
            try append2(ctx, .SSE_MOVD_LD, Operand.xmm(xs), Operand.r(ctx.scratch));
        }
        try append2(ctx, .SSE_XORPS, Operand.xmm(ctx.scratch), Operand.xmm(xs));
        try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, n.dst, ctx.scratch);
    } else {
        const dst = resolveReg(ctx.ra, n.dst);
        if (dtype == .f64) {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @as(u64, 0x8000000000000000) });
            try append2(ctx, .SSE_MOVQ_LD, Operand.xmm(xs), Operand.r(ctx.scratch));
        } else {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @as(u64, 0x80000000) });
            try append2(ctx, .SSE_MOVD_LD, Operand.xmm(xs), Operand.r(ctx.scratch));
        }
        try append2(ctx, .SSE_XORPS, Operand.xmm(dst), Operand.xmm(xs));
    }
}

pub fn selectFSqrt(ctx: *Ctx, s: mir.UnaryInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, s.dst);
    const dst_vreg = switch (s.dst) { .vreg => |v| v, else => 0 };
    const dtype = ctx.mfunc.getVRegType(dst_vreg) orelse .i64;

    if (dst_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, s.dst, ctx.scratch);
        const sqrt_op: OpCode = if (dtype == .f64) .SSE_SQRTSD else .SSE_SQRTSS;
        try append2(ctx, sqrt_op, Operand.xmm(ctx.scratch), Operand.xmm(ctx.scratch));
        try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, s.dst, ctx.scratch);
    } else {
        const dst = resolveReg(ctx.ra, s.dst);
        const sqrt_op: OpCode = if (dtype == .f64) .SSE_SQRTSD else .SSE_SQRTSS;
        try append2(ctx, sqrt_op, Operand.xmm(dst), Operand.xmm(dst));
    }
}

pub fn selectFCmp(ctx: *Ctx, c: mir.FCmpInst) !void {
    const a_spilled = regalloc.isSpilled(ctx.ra, c.a);
    const b_spilled = regalloc.isSpilled(ctx.ra, c.b);
    const a_vreg = switch (c.a) { .vreg => |v| v, else => 0 };
    const dtype = ctx.mfunc.getVRegType(a_vreg) orelse .i64;
    const ucomi_op: OpCode = if (dtype == .f64) .SSE_UCOMISD else .SSE_UCOMISS;

    if (a_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, c.a, ctx.scratch);
    }
    if (b_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, c.b, ctx.scratch);
    }

    const a_reg = if (a_spilled) ctx.scratch else resolveReg(ctx.ra, c.a);
    const b_reg = if (b_spilled) ctx.scratch else resolveReg(ctx.ra, c.b);

    try append2(ctx, ucomi_op, Operand.xmm(a_reg), Operand.xmm(b_reg));

    const dst = resolveReg(ctx.ra, c.dst);
    const setcc_op: u64 = switch (c.cc) {
        .eq => 0x94,
        .ne => 0x95,
        .lt => 0x9C,
        .le => 0x9E,
        .gt => 0x9F,
        .ge => 0x9D,
    };
    try append2(ctx, .SETCC_R8, Operand.r(dst), .{ .imm64 = setcc_op });
    try append2(ctx, .MOVZX_R64_R32, Operand.r(dst), Operand.r(dst));
}
