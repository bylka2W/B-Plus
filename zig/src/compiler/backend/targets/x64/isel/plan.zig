/// x64 instruction selection for PLAN state machine operations.
const std = @import("std");
const mir = @import("../../../mir/mir.zig");
const enc = @import("../encoder.zig");
const OpCode = enc.OpCode;
const Operand = enc.Operand;
const regalloc = @import("../../../regalloc/regalloc.zig");
const ctx_mod = @import("context.zig");
const Ctx = ctx_mod.Ctx;
const append2 = ctx_mod.append2;
const resolveReg = ctx_mod.resolveReg;

fn storeToStateSlot(ctx: *Ctx, value: i64) !void {
    const state_off = ctx.alloca_offsets.get(1) orelse return;
    try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @bitCast(value) });
    try append2(ctx, .MOV_MEM_R64, Operand.mem(5, state_off), Operand.r(ctx.scratch));
}

fn emitSetcc(ctx: *Ctx, dst: mir.MOperand, cc_byte: u8) !void {
    const dst_spilled = regalloc.isSpilled(ctx.ra, dst);
    if (dst_spilled) {
        try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = 0 });
        try append2(ctx, .SETCC_R8, Operand.r(ctx.scratch), Operand.imm(cc_byte));
        try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, dst, ctx.scratch);
    } else {
        const dst_reg = resolveReg(ctx.ra, dst);
        try append2(ctx, .MOV_R64_IMM64, Operand.r(dst_reg), .{ .imm64 = 0 });
        try append2(ctx, .SETCC_R8, Operand.r(dst_reg), Operand.imm(cc_byte));
    }
}

pub fn selectStateInit(ctx: *Ctx, m: mir.StateInitInst) !void {
    try storeToStateSlot(ctx, m.initial_state.imm);
}

pub fn selectStateEnter(ctx: *Ctx, m: mir.StateEnterInst) !void {
    try storeToStateSlot(ctx, m.state_id.imm);
}

pub fn selectStateExit(_: *Ctx, _: mir.StateExitInst) !void {}

pub fn selectEventDispatch(ctx: *Ctx, m: mir.EventDispatchInst) !void {
    try ctx.call_fixups.append(ctx.mf.allocator, .{ .name = "__plan_event_dispatch", .disp_pos = 0 });
    try append2(ctx, .CALL_REL32, Operand.imm(0), .{});

    const dst_spilled = regalloc.isSpilled(ctx.ra, m.dst);
    if (dst_spilled) {
        try regalloc.storeSpilledOp(ctx.code_dummy, ctx.ra, m.dst, 0);
    } else {
        const dst_reg = resolveReg(ctx.ra, m.dst);
        if (dst_reg != 0) {
            try append2(ctx, .MOV_R64_R64, Operand.r(dst_reg), Operand.r(0));
        }
    }
}

pub fn selectTransitionCheck(ctx: *Ctx, m: mir.TransitionCheckInst) !void {
    const event_spilled = regalloc.isSpilled(ctx.ra, m.event);
    if (event_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, m.event, ctx.scratch);
        try append2(ctx, .CMP_R64_IMM32, Operand.r(ctx.scratch), .{ .imm64 = m.event_id });
    } else {
        const event_reg = resolveReg(ctx.ra, m.event);
        try append2(ctx, .CMP_R64_IMM32, Operand.r(event_reg), .{ .imm64 = m.event_id });
    }
    try emitSetcc(ctx, m.result, 0x94); // sete
}

pub fn selectGuardEval(ctx: *Ctx, m: mir.GuardEvalInst) !void {
    const lhs_spilled = regalloc.isSpilled(ctx.ra, m.lhs);
    const rhs_spilled = regalloc.isSpilled(ctx.ra, m.rhs);

    if (lhs_spilled and rhs_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, m.lhs, ctx.scratch);
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, m.rhs, 1);
        try append2(ctx, .CMP_R64_R64, Operand.r(ctx.scratch), Operand.r(1));
    } else if (lhs_spilled) {
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, m.lhs, ctx.scratch);
        const rhs_reg = resolveReg(ctx.ra, m.rhs);
        try append2(ctx, .CMP_R64_R64, Operand.r(ctx.scratch), Operand.r(rhs_reg));
    } else if (rhs_spilled) {
        const lhs_reg = resolveReg(ctx.ra, m.lhs);
        try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, m.rhs, ctx.scratch);
        try append2(ctx, .CMP_R64_R64, Operand.r(lhs_reg), Operand.r(ctx.scratch));
    } else {
        const lhs_reg = resolveReg(ctx.ra, m.lhs);
        const rhs_reg = resolveReg(ctx.ra, m.rhs);
        try append2(ctx, .CMP_R64_R64, Operand.r(lhs_reg), Operand.r(rhs_reg));
    }

    const cc_byte: u8 = switch (m.cc) {
        .eq => 0x94,
        .ne => 0x95,
        .lt => 0x9C,
        .le => 0x9E,
        .gt => 0x9F,
        .ge => 0x9D,
    };
    try emitSetcc(ctx, m.result, cc_byte);
}
