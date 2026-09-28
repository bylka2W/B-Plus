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

    var base_reg: i16 = resolveReg(ctx.ra, l.base);
    if (base_reg < 0 and (l.base == .vreg or l.base == .phys)) {
        try spill.loadSpilledOp(ctx, l.base, regalloc.SCRATCH_REG_2);
        base_reg = regalloc.SCRATCH_REG_2;
    }

    var index_reg: i16 = if (l.index == .vreg or l.index == .phys)
        resolveReg(ctx.ra, l.index)
    else
        -1;
    if (index_reg < 0 and (l.index == .vreg or l.index == .phys)) {
        try spill.loadSpilledOp(ctx, l.index, ctx.scratch);
        index_reg = ctx.scratch;
    }

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

    if (ptr_spilled) {
        try spill.loadSpilledOp(ctx, l.ptr, ctx.scratch);
    }
    const ptr_reg = if (ptr_spilled) ctx.scratch else resolveReg(ctx.ra, l.ptr);

    const is_float = l.size == .f32 or l.size == .f64;
    const load_op: OpCode = switch (l.size) {
        .u8 => .MOVZX_R64_MEM8,
        .u16 => .MOVZX_R64_MEM16,
        .u32 => .MOV_R32_MEM,
        .u64 => .MOV_R64_MEM,
        .f32 => .SSE_MOVSS_LD,
        .f64 => .SSE_MOVSD_LD,
        .xmm128 => .SSE_MOVSD_LD,
    };

    if (is_float) {
        const dst_xmm: i16 = if (dst_spilled) ctx.scratch else resolveReg(ctx.ra, l.dst);
        try append2(ctx, load_op, Operand.xmm(dst_xmm), .{ .base_reg = ptr_reg, .disp = 0 });
        if (dst_spilled) {
            try spill.storeSpilledOp(ctx, l.dst, ctx.scratch);
        }
    } else {
        if (dst_spilled) {
            try append2(ctx, load_op, Operand.r(ctx.scratch), .{ .base_reg = ptr_reg, .disp = 0 });
            try spill.storeSpilledOp(ctx, l.dst, ctx.scratch);
        } else {
            const dst = resolveReg(ctx.ra, l.dst);
            try append2(ctx, load_op, Operand.r(dst), .{ .base_reg = ptr_reg, .disp = 0 });
        }
    }
}

pub fn selectStore(ctx: *Ctx, s: mir.StoreInst) !void {
    const ptr_spilled = regalloc.isSpilled(ctx.ra, s.ptr);
    const src_spilled = regalloc.isSpilled(ctx.ra, s.src);

    if (ptr_spilled) {
        try spill.loadSpilledOp(ctx, s.ptr, ctx.scratch);
    }
    const ptr_reg = if (ptr_spilled) ctx.scratch else resolveReg(ctx.ra, s.ptr);

const is_float = s.size == .f32 or s.size == .f64;
    if (is_float) {
        const store_op: OpCode = if (s.size == .f64) .SSE_MOVSD_ST else .SSE_MOVSS_ST;
        if (s.src == .imm) {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @bitCast(s.src.imm) });
            if (s.size == .f64) {
                try append2(ctx, .SSE_MOVQ_LD, Operand.xmm(ctx.scratch), Operand.r(ctx.scratch));
            } else {
                try append2(ctx, .SSE_MOVD_LD, Operand.xmm(ctx.scratch), Operand.r(ctx.scratch));
            }
            try append2(ctx, store_op, Operand.xmm(ctx.scratch), .{ .base_reg = ptr_reg, .disp = 0 });
        } else if (src_spilled) {
            try spill.loadSpilledOp(ctx, s.src, ctx.scratch);
            try append2(ctx, store_op, Operand.xmm(ctx.scratch), .{ .base_reg = ptr_reg, .disp = 0 });
        } else {
            const src_xmm: i16 = resolveReg(ctx.ra, s.src);
            try append2(ctx, store_op, Operand.xmm(src_xmm), .{ .base_reg = ptr_reg, .disp = 0 });
        }
        return;
    }

    const store_op: OpCode = switch (s.size) {
        .u8 => .MOV_MEM_R8,
        .u16 => .MOV_MEM_R16,
        .u32 => .MOV_MEM_R32,
        .u64 => .MOV_MEM_R64,
        else => .MOV_MEM_R64,
    };
    if (s.src == .imm) {
        try append2(ctx, .MOV_R64_IMM64, Operand.r(regalloc.SCRATCH_REG_2), .{ .imm64 = @bitCast(s.src.imm) });
        try append2(ctx, store_op, .{ .base_reg = ptr_reg, .disp = 0 }, Operand.r(regalloc.SCRATCH_REG_2));
    } else if (src_spilled) {
        try spill.loadSpilledOp(ctx, s.src, ctx.scratch);
        try append2(ctx, store_op, .{ .base_reg = ptr_reg, .disp = 0 }, Operand.r(ctx.scratch));
    } else {
        const src_reg = resolveReg(ctx.ra, s.src);
        try append2(ctx, store_op, .{ .base_reg = ptr_reg, .disp = 0 }, Operand.r(src_reg));
    }
}

