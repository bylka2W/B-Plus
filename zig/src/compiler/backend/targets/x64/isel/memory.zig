/// x64 memory access instruction selection (load/store/lea/alloca).
const mir = @import("../../../mir/mir.zig");
const enc = @import("../encoder.zig");
const OpCode = enc.OpCode;
const Operand = enc.Operand;
const regalloc = @import("../../../regalloc/regalloc.zig");
const spill = @import("spill.zig");
const ctx_mod = @import("context.zig");
const Ctx = ctx_mod.Ctx;
const OffsetMap = ctx_mod.OffsetMap;
const append2 = ctx_mod.append2;
const resolveReg = ctx_mod.resolveReg;
const resolveOp = ctx_mod.resolveOp;
const resolveOpOrSpill = ctx_mod.resolveOpOrSpill;

pub fn selectAlloca(ctx: *Ctx, a: mir.AllocaInst, alloca_offsets: OffsetMap) !void {
    const off = alloca_offsets.get(switch (a.dst) { .vreg => |v| v, else => 0 }) orelse 0;
    const dst_spilled = regalloc.isSpilled(ctx.ra, a.dst);

    if (dst_spilled) {
        try append2(ctx, .LEA_R64_MEM, Operand.r(ctx.scratch), .{ .base_reg = 5, .disp = off });
        try spill.storeSpilledOp(ctx, a.dst, ctx.scratch);
    } else {
        const dst = resolveReg(ctx.ra, a.dst);
        try append2(ctx, .LEA_R64_MEM, Operand.r(dst), .{ .base_reg = 5, .disp = off });
    }
}

pub fn selectLea(ctx: *Ctx, l: mir.LeaInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, l.dst);
    const base_reg = resolveReg(ctx.ra, l.base);
    const index_reg: i16 = if (l.index == .vreg or l.index == .phys)
        resolveReg(ctx.ra, l.index)
    else
        -1;
    const addr_op = Operand{
        .base_reg = base_reg,
        .index_reg = index_reg,
        .scale = l.scale,
        .disp = l.disp,
    };
    if (dst_spilled) {
        try append2(ctx, .LEA_R64_MEM, Operand.r(ctx.scratch), addr_op);
        try spill.storeSpilledOp(ctx, l.dst, ctx.scratch);
    } else {
        const dst = resolveReg(ctx.ra, l.dst);
        try append2(ctx, .LEA_R64_MEM, Operand.r(dst), addr_op);
    }
}

pub fn selectLoad(ctx: *Ctx, l: mir.LoadInst) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, l.dst);
    const ptr_spilled = regalloc.isSpilled(ctx.ra, l.ptr);
    const dst_vreg = switch (l.dst) { .vreg => |v| v, else => 0 };
    const dtype = ctx.mfunc.getVRegType(dst_vreg) orelse .i64;
    const is_float = dtype == .f32 or dtype == .f64;

    if (ptr_spilled) {
        try spill.loadSpilledOp(ctx, l.ptr, ctx.scratch);
        if (is_float) {
            const load_op: OpCode = if (dtype == .f64) .SSE_MOVSD_LD else .SSE_MOVSS_LD;
            const dst_xmm: i16 = if (dst_spilled) ctx.scratch else resolveReg(ctx.ra, l.dst);
            try append2(ctx, load_op, Operand.xmm(dst_xmm), .{ .base_reg = ctx.scratch, .disp = 0 });
            if (dst_spilled) {
                try spill.storeSpilledOp(ctx, l.dst, ctx.scratch);
            }
        } else {
            if (dst_spilled) {
                try append2(ctx, .MOV_R64_MEM, Operand.r(ctx.scratch), .{ .base_reg = ctx.scratch, .disp = 0 });
                try spill.storeSpilledOp(ctx, l.dst, ctx.scratch);
            } else {
                const dst = resolveReg(ctx.ra, l.dst);
                try append2(ctx, .MOV_R64_MEM, Operand.r(dst), .{ .base_reg = ctx.scratch, .disp = 0 });
            }
        }
    } else {
        const ptr_reg = resolveReg(ctx.ra, l.ptr);
        if (is_float) {
            const load_op: OpCode = if (dtype == .f64) .SSE_MOVSD_LD else .SSE_MOVSS_LD;
            const dst_xmm: i16 = if (dst_spilled) ctx.scratch else resolveReg(ctx.ra, l.dst);
            try append2(ctx, load_op, Operand.xmm(dst_xmm), .{ .base_reg = ptr_reg, .disp = 0 });
            if (dst_spilled) {
                try spill.storeSpilledOp(ctx, l.dst, ctx.scratch);
            }
        } else {
            if (dst_spilled) {
                try append2(ctx, .MOV_R64_MEM, Operand.r(ctx.scratch), .{ .base_reg = ptr_reg, .disp = 0 });
                try spill.storeSpilledOp(ctx, l.dst, ctx.scratch);
            } else {
                const dst = resolveReg(ctx.ra, l.dst);
                try append2(ctx, .MOV_R64_MEM, Operand.r(dst), .{ .base_reg = ptr_reg, .disp = 0 });
            }
        }
    }
}

pub fn selectStore(ctx: *Ctx, s: mir.StoreInst) !void {
    const ptr_spilled = regalloc.isSpilled(ctx.ra, s.ptr);
    const src_spilled = regalloc.isSpilled(ctx.ra, s.src);
    const src_vreg = switch (s.src) { .vreg => |v| v, else => 0 };
    const dtype = ctx.mfunc.getVRegType(src_vreg) orelse .i64;
    const is_float = dtype == .f32 or dtype == .f64;

    if (ptr_spilled) {
        try spill.loadSpilledOp(ctx, s.ptr, ctx.scratch);
        if (is_float) {
            const store_op: OpCode = if (dtype == .f64) .SSE_MOVSD_ST else .SSE_MOVSS_ST;
            const src_xmm: i16 = if (src_spilled) ctx.scratch else resolveReg(ctx.ra, s.src);
            try append2(ctx, store_op, Operand.xmm(src_xmm), .{ .base_reg = ctx.scratch, .disp = 0 });
        } else {
            if (s.src == .imm) {
                try append2(ctx, .MOV_R64_IMM64, Operand.r(regalloc.SCRATCH_REG_2), .{ .imm64 = @bitCast(s.src.imm) });
                try append2(ctx, .MOV_MEM_R64, .{ .base_reg = ctx.scratch, .disp = 0 }, Operand.r(regalloc.SCRATCH_REG_2));
            } else {
                const src_reg = resolveReg(ctx.ra, s.src);
                try append2(ctx, .MOV_MEM_R64, .{ .base_reg = ctx.scratch, .disp = 0 }, Operand.r(src_reg));
            }
        }
    } else if (src_spilled) {
        try spill.loadSpilledOp(ctx, s.src, ctx.scratch);
        const ptr_reg = resolveReg(ctx.ra, s.ptr);
        if (is_float) {
            const store_op: OpCode = if (dtype == .f64) .SSE_MOVSD_ST else .SSE_MOVSS_ST;
            try append2(ctx, store_op, Operand.xmm(ctx.scratch), .{ .base_reg = ptr_reg, .disp = 0 });
        } else {
            try append2(ctx, .MOV_MEM_R64, .{ .base_reg = ptr_reg, .disp = 0 }, Operand.r(ctx.scratch));
        }
    } else {
        const ptr_reg = resolveReg(ctx.ra, s.ptr);
        if (is_float) {
            const store_op: OpCode = if (dtype == .f64) .SSE_MOVSD_ST else .SSE_MOVSS_ST;
            const src_xmm: i16 = resolveReg(ctx.ra, s.src);
            try append2(ctx, store_op, Operand.xmm(src_xmm), .{ .base_reg = ptr_reg, .disp = 0 });
        } else {
            if (s.src == .imm) {
                try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @bitCast(s.src.imm) });
                try append2(ctx, .MOV_MEM_R64, .{ .base_reg = ptr_reg, .disp = 0 }, Operand.r(ctx.scratch));
            } else {
                const src_reg = resolveReg(ctx.ra, s.src);
                try append2(ctx, .MOV_MEM_R64, .{ .base_reg = ptr_reg, .disp = 0 }, Operand.r(src_reg));
            }
        }
    }
}
