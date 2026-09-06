///выбор инструкций целочисленной арифметики для x64
const mir = @import("../../../mir/mir.zig");
const enc = @import("../encoder.zig");
const OpCode = enc.OpCode;
const Operand = enc.Operand;
const regalloc = @import("../../../regalloc/regalloc.zig");
const spill = @import("spill.zig");
const ctx_mod = @import("context.zig");
const Ctx = ctx_mod.Ctx;
const append2 = ctx_mod.append2;
const append0 = ctx_mod.append0;
const append1 = ctx_mod.append1;
const resolveReg = ctx_mod.resolveReg;
const resolveOp = ctx_mod.resolveOp;
const resolveOpOrSpill = ctx_mod.resolveOpOrSpill;

pub fn selectMov(ctx: *Ctx, m: mir.MovInst) !void {
    if (regalloc.isRemat(ctx.ra, m.dst)) return;

    const dst_spilled = regalloc.isSpilled(ctx.ra, m.dst);
    const src_spilled = regalloc.isSpilled(ctx.ra, m.src);

    const dst_vreg = switch (m.dst) { .vreg => |v| v, else => 0 };
    const dst_is_xmm = dst_vreg != 0 and (ctx.mfunc.getVRegClass(dst_vreg) orelse .gpr) == .xmm;
    const src_vreg = switch (m.src) { .vreg => |v| v, else => 0 };
    const src_is_xmm = src_vreg != 0 and (ctx.mfunc.getVRegClass(src_vreg) orelse .gpr) == .xmm;

    if (dst_spilled and src_spilled) {
        try spill.loadSpilledOp(ctx, m.src, ctx.scratch);
        try spill.storeSpilledOp(ctx, m.dst, ctx.scratch);
    } else if (dst_spilled) {
        const src_val = try resolveOpOrSpill(ctx, m.src);
        const val_reg = if (src_val.reg >= 0) src_val.reg else ctx.scratch;
        if (src_val.reg < 0) {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), src_val);
        }
        try spill.storeSpilledOp(ctx, m.dst, if (src_val.reg >= 0) val_reg else ctx.scratch);
    } else if (src_spilled) {
        if (dst_is_xmm) {
            try spill.loadSpilledOp(ctx, m.src, ctx.scratch);
            const dtype = ctx.mfunc.getVRegType(dst_vreg) orelse .i64;
            const dst_xmm = resolveReg(ctx.ra, m.dst);
            if (dtype == .f64) {
                try append2(ctx, .SSE_MOVQ_LD, Operand.xmm(dst_xmm), Operand.r(ctx.scratch));
            } else {
                try append2(ctx, .SSE_MOVD_LD, Operand.xmm(dst_xmm), Operand.r(ctx.scratch));
            }
        } else {
            try spill.loadSpilledOp(ctx, m.src, ctx.scratch);
            const dst = resolveReg(ctx.ra, m.dst);
            try append2(ctx, .MOV_R64_R64, Operand.r(dst), Operand.r(ctx.scratch));
        }
    } else {
        const dst = resolveReg(ctx.ra, m.dst);
        const src = resolveOp(ctx.ra, m.src);
        if (dst_is_xmm) {
            if (src_is_xmm) {
                const dtype = ctx.mfunc.getVRegType(dst_vreg) orelse .i64;
                if (dtype == .f64) {
                    try append2(ctx, .SSE_MOVSD_LD, Operand.xmm(dst), Operand.xmm(src.reg));
                } else {
                    try append2(ctx, .SSE_MOVSS_LD, Operand.xmm(dst), Operand.xmm(src.reg));
                }
            } else if (src.reg >= 0) {
                const dtype = ctx.mfunc.getVRegType(dst_vreg) orelse .i64;
                if (dtype == .f64) {
                    try append2(ctx, .SSE_MOVQ_LD, Operand.xmm(dst), Operand.r(src.reg));
                } else {
                    try append2(ctx, .SSE_MOVD_LD, Operand.xmm(dst), Operand.r(src.reg));
                }
            } else {
                const dtype = ctx.mfunc.getVRegType(dst_vreg) orelse .i64;
                try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), src);
                if (dtype == .f64) {
                    try append2(ctx, .SSE_MOVQ_LD, Operand.xmm(dst), Operand.r(ctx.scratch));
                } else {
                    try append2(ctx, .SSE_MOVD_LD, Operand.xmm(dst), Operand.r(ctx.scratch));
                }
            }
        } else if (src_is_xmm) {
            const dtype = ctx.mfunc.getVRegType(src_vreg) orelse .i64;
            if (dtype == .f64) {
                try append2(ctx, .SSE_MOVQ_ST, Operand.xmm(src.reg), Operand.r(dst));
            } else {
                try append2(ctx, .SSE_MOVD_ST, Operand.xmm(src.reg), Operand.r(dst));
            }
        } else if (src.reg >= 0) {
            if (dst == src.reg) return;
            try append2(ctx, .MOV_R64_R64, Operand.r(dst), src);
        } else {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(dst), src);
        }
    }
}

pub fn selectAdd(ctx: *Ctx, a: mir.AddInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, a.dst);
    const src_spilled = regalloc.isSpilled(ctx.ra, a.src);

    if (dst_spilled and src_spilled) {
        try spill.loadSpilledOp(ctx, a.dst, ctx.scratch);
        const src_mem = regalloc.spilledMemOp(ctx.ra, a.src);
        try append2(ctx, .ADD_R64_MEM, Operand.r(ctx.scratch), src_mem);
        try spill.storeSpilledOp(ctx, a.dst, ctx.scratch);
    } else if (dst_spilled) {
        try spill.loadSpilledOp(ctx, a.dst, ctx.scratch);
        const src_val = try resolveOpOrSpill(ctx, a.src);
        if (src_val.reg >= 0) {
            if (src_val.reg == ctx.scratch) {
                try append2(ctx, .ADD_R64_R64, Operand.r(ctx.scratch), Operand.r(ctx.scratch));
            } else {
                try append2(ctx, .ADD_R64_R64, Operand.r(ctx.scratch), src_val);
            }
        } else {
            try append2(ctx, .ADD_R64_IMM32, Operand.r(ctx.scratch), src_val);
        }
        try spill.storeSpilledOp(ctx, a.dst, ctx.scratch);
    } else if (src_spilled) {
        const dst = resolveReg(ctx.ra, a.dst);
        try spill.loadSpilledOp(ctx, a.src, ctx.scratch);
        try append2(ctx, .ADD_R64_R64, Operand.r(dst), Operand.r(ctx.scratch));
    } else {
        const dst = resolveReg(ctx.ra, a.dst);
        const src_val = resolveOp(ctx.ra, a.src);
        switch (a.src) {
            .imm => try append2(ctx, .ADD_R64_IMM32, Operand.r(dst), src_val),
            else => try append2(ctx, .ADD_R64_R64, Operand.r(dst), src_val),
        }
    }
}

pub fn selectSub(ctx: *Ctx, s: mir.SubInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, s.dst);
    const src_spilled = regalloc.isSpilled(ctx.ra, s.src);

    if (dst_spilled and src_spilled) {
        try spill.loadSpilledOp(ctx, s.dst, ctx.scratch);
        const src_mem = regalloc.spilledMemOp(ctx.ra, s.src);
        try append2(ctx, .SUB_R64_MEM, Operand.r(ctx.scratch), src_mem);
        try spill.storeSpilledOp(ctx, s.dst, ctx.scratch);
    } else if (dst_spilled) {
        try spill.loadSpilledOp(ctx, s.dst, ctx.scratch);
        const src_val = try resolveOpOrSpill(ctx, s.src);
        if (src_val.reg >= 0) {
            if (src_val.reg == ctx.scratch) {
                try append2(ctx, .SUB_R64_R64, Operand.r(ctx.scratch), Operand.r(ctx.scratch));
            } else {
                try append2(ctx, .SUB_R64_R64, Operand.r(ctx.scratch), src_val);
            }
        } else {
            try append2(ctx, .SUB_R64_IMM32, Operand.r(ctx.scratch), src_val);
        }
        try spill.storeSpilledOp(ctx, s.dst, ctx.scratch);
    } else if (src_spilled) {
        const dst = resolveReg(ctx.ra, s.dst);
        try spill.loadSpilledOp(ctx, s.src, ctx.scratch);
        try append2(ctx, .SUB_R64_R64, Operand.r(dst), Operand.r(ctx.scratch));
    } else {
        const dst = resolveReg(ctx.ra, s.dst);
        const src_val = resolveOp(ctx.ra, s.src);
        switch (s.src) {
            .imm => try append2(ctx, .SUB_R64_IMM32, Operand.r(dst), src_val),
            else => try append2(ctx, .SUB_R64_R64, Operand.r(dst), src_val),
        }
    }
}

pub fn selectIMul(ctx: *Ctx, m: mir.IMulInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, m.dst);
    const src_spilled = regalloc.isSpilled(ctx.ra, m.src);

    if (dst_spilled and src_spilled) {
        try spill.loadSpilledOp(ctx, m.dst, ctx.scratch);
        const src_mem = regalloc.spilledMemOp(ctx.ra, m.src);
        try append2(ctx, .IMUL_R64_R64, Operand.r(ctx.scratch), src_mem);
        try spill.storeSpilledOp(ctx, m.dst, ctx.scratch);
    } else if (dst_spilled) {
        try spill.loadSpilledOp(ctx, m.dst, ctx.scratch);
        const src_val = try resolveOpOrSpill(ctx, m.src);
        if (src_val.reg >= 0) {
            try append2(ctx, .IMUL_R64_R64, Operand.r(ctx.scratch), src_val);
        } else {
            try append2(ctx, .IMUL_R64_IMM32, Operand.r(ctx.scratch), .{ .reg = ctx.scratch, .imm64 = src_val.imm64 });
        }
        try spill.storeSpilledOp(ctx, m.dst, ctx.scratch);
    } else if (src_spilled) {
        const dst = resolveReg(ctx.ra, m.dst);
        try spill.loadSpilledOp(ctx, m.src, ctx.scratch);
        try append2(ctx, .IMUL_R64_R64, Operand.r(dst), Operand.r(ctx.scratch));
    } else {
        const dst = resolveReg(ctx.ra, m.dst);
        const src_val = resolveOp(ctx.ra, m.src);
        switch (m.src) {
            .imm => try append2(ctx, .IMUL_R64_IMM32, Operand.r(dst), .{ .reg = dst, .imm64 = src_val.imm64 }),
            else => try append2(ctx, .IMUL_R64_R64, Operand.r(dst), src_val),
        }
    }
}

pub fn selectSetCC(ctx: *Ctx, s: mir.SetCCInst) !void {
    const cc: u64 = @intFromEnum(s.cc);
    const dst_spilled = regalloc.isSpilled(ctx.ra, s.dst);

    if (dst_spilled) {
        try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = 0 });
        try append2(ctx, .SETCC_R8, Operand.r(ctx.scratch), .{ .imm64 = cc });
        try spill.storeSpilledOp(ctx, s.dst, ctx.scratch);
    } else {
        const dst_reg = resolveReg(ctx.ra, s.dst);
        try append2(ctx, .MOV_R64_IMM64, Operand.r(dst_reg), .{ .imm64 = 0 });
        try append2(ctx, .SETCC_R8, Operand.r(dst_reg), .{ .imm64 = cc });
    }
}

pub fn selectIDiv(ctx: *Ctx, m: mir.IDivInst) !void {
    const quotient_spilled = regalloc.isSpilled(ctx.ra, m.quotient);
    const quotient_reg = if (quotient_spilled) -1 else resolveReg(ctx.ra, m.quotient);
    const quotient_is_rax = quotient_spilled or quotient_reg == 0 or quotient_reg == -1;

    const remainder_spilled = regalloc.isSpilled(ctx.ra, m.remainder);
    const remainder_reg = if (remainder_spilled) -1 else resolveReg(ctx.ra, m.remainder);

    if (!quotient_is_rax) {
        try append1(ctx, .PUSH_R64, Operand.r(0));
    }
    try append1(ctx, .PUSH_R64, Operand.r(2));

    const raw_src = try resolveOpOrSpill(ctx, m.divisor);
    const src_op = blk: {
        const is_rax_or_rdx = raw_src.reg == 0 or raw_src.reg == 2;
        const is_mem_based = raw_src.base_reg >= 0 or raw_src.index_reg >= 0;
        if (raw_src.reg < 0 and !is_mem_based) {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), raw_src);
            break :blk Operand.r(ctx.scratch);
        } else if (is_rax_or_rdx or is_mem_based) {
            try append2(ctx, .MOV_R64_R64, Operand.r(ctx.scratch), raw_src);
            break :blk Operand.r(ctx.scratch);
        } else {
            break :blk raw_src;
        }
    };

    const dividend_spilled = regalloc.isSpilled(ctx.ra, m.dividend);
    if (dividend_spilled) {
        try spill.loadSpilledOp(ctx, m.dividend, 0);
    } else {
        const dividend_reg = resolveReg(ctx.ra, m.dividend);
        if (dividend_reg != 0) {
            try append2(ctx, .MOV_R64_R64, Operand.r(0), Operand.r(dividend_reg));
        }
    }

    try append0(ctx, .CQO);
    try append1(ctx, .IDIV_R64, src_op);

    if (quotient_spilled) {
        try append2(ctx, .MOV_R64_R64, Operand.r(ctx.scratch), Operand.r(0));
        try spill.storeSpilledOp(ctx, m.quotient, ctx.scratch);
    } else if (!quotient_is_rax) {
        try append2(ctx, .MOV_R64_R64, Operand.r(quotient_reg), Operand.r(0));
    }
    try append2(ctx, .MOV_R64_R64, Operand.r(ctx.scratch), Operand.r(2));

    try append1(ctx, .POP_R64, Operand.r(2));
    if (!quotient_is_rax) {
        try append1(ctx, .POP_R64, Operand.r(0));
    }

    if (remainder_spilled) {
        try spill.storeSpilledOp(ctx, m.remainder, ctx.scratch);
    } else {
        try append2(ctx, .MOV_R64_R64, Operand.r(remainder_reg), Operand.r(ctx.scratch));
    }
}

pub fn selectAnd(ctx: *Ctx, a: mir.AndInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, a.dst);
    const src_spilled = regalloc.isSpilled(ctx.ra, a.src);

    if (dst_spilled and src_spilled) {
        try spill.loadSpilledOp(ctx, a.dst, ctx.scratch);
        try spill.loadSpilledOp(ctx, a.src, 1);
        try append2(ctx, .AND_R64_R64, Operand.r(ctx.scratch), Operand.r(1));
        try spill.storeSpilledOp(ctx, a.dst, ctx.scratch);
    } else if (dst_spilled) {
        try spill.loadSpilledOp(ctx, a.dst, ctx.scratch);
        const src_val = try resolveOpOrSpill(ctx, a.src);
        if (src_val.reg >= 0) {
            try append2(ctx, .AND_R64_R64, Operand.r(ctx.scratch), src_val);
        } else {
            try append2(ctx, .AND_R64_IMM32, Operand.r(ctx.scratch), src_val);
        }
        try spill.storeSpilledOp(ctx, a.dst, ctx.scratch);
    } else if (src_spilled) {
        const dst = resolveReg(ctx.ra, a.dst);
        try spill.loadSpilledOp(ctx, a.src, ctx.scratch);
        try append2(ctx, .AND_R64_R64, Operand.r(dst), Operand.r(ctx.scratch));
    } else {
        const dst = resolveReg(ctx.ra, a.dst);
        const src_val = resolveOp(ctx.ra, a.src);
        if (src_val.reg >= 0) {
            try append2(ctx, .AND_R64_R64, Operand.r(dst), src_val);
        } else {
            try append2(ctx, .AND_R64_IMM32, Operand.r(dst), src_val);
        }
    }
}

pub fn selectOr(ctx: *Ctx, o: mir.OrInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, o.dst);
    const src_spilled = regalloc.isSpilled(ctx.ra, o.src);

    if (dst_spilled and src_spilled) {
        try spill.loadSpilledOp(ctx, o.dst, ctx.scratch);
        try spill.loadSpilledOp(ctx, o.src, 1);
        try append2(ctx, .OR_R64_R64, Operand.r(ctx.scratch), Operand.r(1));
        try spill.storeSpilledOp(ctx, o.dst, ctx.scratch);
    } else if (dst_spilled) {
        try spill.loadSpilledOp(ctx, o.dst, ctx.scratch);
        const src_val = try resolveOpOrSpill(ctx, o.src);
        if (src_val.reg >= 0) {
            try append2(ctx, .OR_R64_R64, Operand.r(ctx.scratch), src_val);
        } else {
            try append2(ctx, .OR_R64_IMM32, Operand.r(ctx.scratch), src_val);
        }
        try spill.storeSpilledOp(ctx, o.dst, ctx.scratch);
    } else if (src_spilled) {
        const dst = resolveReg(ctx.ra, o.dst);
        try spill.loadSpilledOp(ctx, o.src, ctx.scratch);
        try append2(ctx, .OR_R64_R64, Operand.r(dst), Operand.r(ctx.scratch));
    } else {
        const dst = resolveReg(ctx.ra, o.dst);
        const src_val = resolveOp(ctx.ra, o.src);
        if (src_val.reg >= 0) {
            try append2(ctx, .OR_R64_R64, Operand.r(dst), src_val);
        } else {
            try append2(ctx, .OR_R64_IMM32, Operand.r(dst), src_val);
        }
    }
}

pub fn selectXor(ctx: *Ctx, x: mir.XorInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, x.dst);
    const src_spilled = regalloc.isSpilled(ctx.ra, x.src);

    if (dst_spilled and src_spilled) {
        try spill.loadSpilledOp(ctx, x.dst, ctx.scratch);
        try spill.loadSpilledOp(ctx, x.src, 1);
        try append2(ctx, .XOR_R64_R64, Operand.r(ctx.scratch), Operand.r(1));
        try spill.storeSpilledOp(ctx, x.dst, ctx.scratch);
    } else if (dst_spilled) {
        try spill.loadSpilledOp(ctx, x.dst, ctx.scratch);
        const src_val = try resolveOpOrSpill(ctx, x.src);
        if (src_val.reg >= 0) {
            try append2(ctx, .XOR_R64_R64, Operand.r(ctx.scratch), src_val);
        } else {
            try append2(ctx, .XOR_R64_IMM32, Operand.r(ctx.scratch), src_val);
        }
        try spill.storeSpilledOp(ctx, x.dst, ctx.scratch);
    } else if (src_spilled) {
        const dst = resolveReg(ctx.ra, x.dst);
        try spill.loadSpilledOp(ctx, x.src, ctx.scratch);
        try append2(ctx, .XOR_R64_R64, Operand.r(dst), Operand.r(ctx.scratch));
    } else {
        const dst = resolveReg(ctx.ra, x.dst);
        const src_val = resolveOp(ctx.ra, x.src);
        if (src_val.reg >= 0) {
            try append2(ctx, .XOR_R64_R64, Operand.r(dst), src_val);
        } else {
            try append2(ctx, .XOR_R64_IMM32, Operand.r(dst), src_val);
        }
    }
}

pub fn selectShift(ctx: *Ctx, s: mir.ShiftInst, cl_op: OpCode, imm_op: OpCode) !void {
    if (s.amount == .imm) {
        const dst_spilled = regalloc.isSpilled(ctx.ra, s.dst);
        if (dst_spilled) {
            try spill.loadSpilledOp(ctx, s.dst, ctx.scratch);
            try append2(ctx, imm_op, Operand.r(ctx.scratch), .{ .imm64 = @bitCast(s.amount.imm) });
            try spill.storeSpilledOp(ctx, s.dst, ctx.scratch);
        } else {
            const dst = resolveReg(ctx.ra, s.dst);
            try append2(ctx, imm_op, Operand.r(dst), .{ .imm64 = @bitCast(s.amount.imm) });
        }
        return;
    }

    const dst_spilled = regalloc.isSpilled(ctx.ra, s.dst);
    const amt_spilled = regalloc.isSpilled(ctx.ra, s.amount);

    if (amt_spilled) {
        try spill.loadSpilledOp(ctx, s.amount, 1);
    } else {
        const amt = resolveReg(ctx.ra, s.amount);
        if (amt != 1) {
            try append2(ctx, .MOV_R64_R64, Operand.r(1), Operand.r(amt));
        }
    }

    if (dst_spilled) {
        try spill.loadSpilledOp(ctx, s.dst, ctx.scratch);
        try append1(ctx, cl_op, Operand.r(ctx.scratch));
        try spill.storeSpilledOp(ctx, s.dst, ctx.scratch);
    } else {
        const dst = resolveReg(ctx.ra, s.dst);
        try append1(ctx, cl_op, Operand.r(dst));
    }
}

pub fn selectNot(ctx: *Ctx, n: mir.UnaryInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, n.dst);
    if (dst_spilled) {
        try spill.loadSpilledOp(ctx, n.dst, ctx.scratch);
        try append1(ctx, .NOT_R64, Operand.r(ctx.scratch));
        try spill.storeSpilledOp(ctx, n.dst, ctx.scratch);
    } else {
        const dst = resolveReg(ctx.ra, n.dst);
        try append1(ctx, .NOT_R64, Operand.r(dst));
    }
}

pub fn selectNeg(ctx: *Ctx, n: mir.UnaryInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, n.dst);
    if (dst_spilled) {
        try spill.loadSpilledOp(ctx, n.dst, ctx.scratch);
        try append1(ctx, .NEG_R64, Operand.r(ctx.scratch));
        try spill.storeSpilledOp(ctx, n.dst, ctx.scratch);
    } else {
        const dst = resolveReg(ctx.ra, n.dst);
        try append1(ctx, .NEG_R64, Operand.r(dst));
    }
}

pub fn selectTestFlags(ctx: *Ctx, tf: mir.TestFlagsInst) !void {
    const av = try resolveOpOrSpill(ctx, tf.a);
    const bv = try resolveOpOrSpill(ctx, tf.b);

    if (bv.reg >= 0) {
        try append2(ctx, .TEST_R64_R64, av, bv);
    } else {
        try append2(ctx, .TEST_R64_IMM32, av, bv);
    }
}

pub fn selectCmp(ctx: *Ctx, c: mir.CmpInst) !void {
    const a_spilled = regalloc.isSpilled(ctx.ra, c.a);
    const b_spilled = regalloc.isSpilled(ctx.ra, c.b);

    if (a_spilled and b_spilled) {
        try spill.loadSpilledOp(ctx, c.a, ctx.scratch);
        const b_mem = regalloc.spilledMemOp(ctx.ra, c.b);
        try append2(ctx, .CMP_R64_MEM, Operand.r(ctx.scratch), b_mem);
    } else if (a_spilled) {
        const av = try resolveOpOrSpill(ctx, c.a);
        const bv = try resolveOpOrSpill(ctx, c.b);
        if (bv.reg >= 0) {
            try append2(ctx, .CMP_R64_R64, av, bv);
        } else {
            try append2(ctx, .CMP_R64_IMM32, av, bv);
        }
    } else if (b_spilled) {
        const av = try resolveOpOrSpill(ctx, c.a);
        const b_mem = regalloc.spilledMemOp(ctx.ra, c.b);
        try append2(ctx, .CMP_R64_MEM, av, b_mem);
    } else {
        const av = try resolveOpOrSpill(ctx, c.a);
        const bv = try resolveOpOrSpill(ctx, c.b);
        if (bv.reg >= 0) {
            try append2(ctx, .CMP_R64_R64, av, bv);
        } else {
            try append2(ctx, .CMP_R64_IMM32, av, bv);
        }
    }
}

pub fn selectCmpFlags(ctx: *Ctx, cf: mir.CmpFlagsInst) !void {
    const a_spilled = regalloc.isSpilled(ctx.ra, cf.a);
    const b_spilled = regalloc.isSpilled(ctx.ra, cf.b);

    if (a_spilled and b_spilled) {
        try spill.loadSpilledOp(ctx, cf.a, ctx.scratch);
        const b_mem = regalloc.spilledMemOp(ctx.ra, cf.b);
        try append2(ctx, .CMP_R64_MEM, Operand.r(ctx.scratch), b_mem);
        return;
    }

    if (a_spilled) {
        const av = try resolveOpOrSpill(ctx, cf.a);
        const bv = try resolveOpOrSpill(ctx, cf.b);
        if (bv.reg >= 0) {
            try append2(ctx, .CMP_R64_R64, av, bv);
        } else {
            try append2(ctx, .CMP_R64_IMM32, av, bv);
        }
        return;
    }

    if (b_spilled) {
        const av = try resolveOpOrSpill(ctx, cf.a);
        const b_mem = regalloc.spilledMemOp(ctx.ra, cf.b);
        try append2(ctx, .CMP_R64_MEM, av, b_mem);
        return;
    }

    const a_val = try resolveOpOrSpill(ctx, cf.a);
    const b_val = try resolveOpOrSpill(ctx, cf.b);

    if (b_val.reg >= 0) {
        if (a_val.reg >= 0) {
            try append2(ctx, .CMP_R64_R64, a_val, b_val);
        } else {
            try append2(ctx, .CMP_R64_IMM32, b_val, a_val);
        }
    } else {
        if (a_val.reg >= 0) {
            try append2(ctx, .CMP_R64_IMM32, a_val, b_val);
        } else {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), a_val);
            try append2(ctx, .CMP_R64_IMM32, Operand.r(ctx.scratch), b_val);
        }
    }
}
