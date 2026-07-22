/// Shared context and helpers for x64 instruction selection sub-modules.
const std = @import("std");
const mir = @import("../../../mir/mir.zig");
const enc = @import("../encoder.zig");
const OpCode = enc.OpCode;
const Operand = enc.Operand;
const regalloc = @import("../../../regalloc/regalloc.zig");
pub const ir = @import("../ir/inst.zig");

pub const OffsetMap = std.AutoHashMap(u32, i32);

pub const BlockFixup = struct {
    disp_pos: usize,
    target: usize,
};

pub const CallFixup = struct {
    name: []const u8,
    disp_pos: usize,
};

pub const SelectResult = struct {
    mf: ir.MachineFunction,
    block_fixups: std.ArrayListUnmanaged(BlockFixup),
    call_fixups: std.ArrayListUnmanaged(CallFixup),

    pub fn deinit(self: *SelectResult, allocator: std.mem.Allocator) void {
        self.mf.deinit();
        self.block_fixups.deinit(allocator);
        self.call_fixups.deinit(allocator);
    }
};

pub const Ctx = struct {
    mf: *ir.MachineFunction,
    bi: usize,
    ra: *const regalloc.RegAllocResult,
    scratch: i16,
    mfunc: *const mir.MFunction,
    block_fixups: *std.ArrayListUnmanaged(BlockFixup),
    call_fixups: *std.ArrayListUnmanaged(CallFixup),
    code_dummy: *std.ArrayList(u8),
};

pub fn resolveReg(ra: *const regalloc.RegAllocResult, op: mir.MOperand) i16 {
    return regalloc.regForOp(ra, op);
}

pub fn resolveOp(ra: *const regalloc.RegAllocResult, op: mir.MOperand) Operand {
    return switch (op) {
        .vreg => |v| blk: {
            if (ra.regs.get(v)) |r| break :blk .{ .reg = r };
            break :blk .{ .reg = -1 };
        },
        .phys => |r| .{ .reg = @as(i16, @intCast(r)) },
        .imm => |v| Operand.imm(v),
        .mem => |m| if (m.index) |idx|
            .{ .base_reg = @as(i16, @intCast(m.base)), .index_reg = @as(i16, @intCast(idx)), .scale = m.scale, .disp = m.offset }
        else
            .{ .base_reg = @as(i16, @intCast(m.base)), .disp = m.offset },
    };
}

pub fn resolveOpOrSpill(ctx: *Ctx, op: mir.MOperand) !Operand {
    return switch (op) {
        .vreg => |v| blk: {
            if (ctx.ra.regs.get(v)) |r| break :blk .{ .reg = r };
            try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, op, ctx.scratch);
            break :blk .{ .reg = ctx.scratch };
        },
        .phys => |r| .{ .reg = @as(i16, @intCast(r)) },
        .imm => |v| Operand.imm(v),
        .mem => |m| if (m.index) |idx|
            .{ .base_reg = @as(i16, @intCast(m.base)), .index_reg = @as(i16, @intCast(idx)), .scale = m.scale, .disp = m.offset }
        else
            .{ .base_reg = @as(i16, @intCast(m.base)), .disp = m.offset },
    };
}

pub fn append(ctx: *Ctx, op: OpCode, operands: []const Operand) !void {
    try ctx.mf.appendInstr(ctx.bi, op, operands);
}

pub fn append2(ctx: *Ctx, op: OpCode, o1: Operand, o2: Operand) !void {
    try ctx.mf.appendInstr2(ctx.bi, op, o1, o2);
}

pub fn append1(ctx: *Ctx, op: OpCode, o1: Operand) !void {
    try ctx.mf.appendInstr1(ctx.bi, op, o1);
}

pub fn append3(ctx: *Ctx, op: OpCode, o1: Operand, o2: Operand, o3: Operand) !void {
    try ctx.mf.appendInstr(ctx.bi, op, &.{ o1, o2, o3 });
}

pub fn condToJccOp(cc: mir.CondCode) OpCode {
    return switch (cc) {
        .eq => .JE_REL32,
        .ne => .JNE_REL32,
        .lt => .JL_REL32,
        .le => .JLE_REL32,
        .gt => .JG_REL32,
        .ge => .JGE_REL32,
    };
}

pub fn xmmScratch() i16 { return 15; }

pub fn moveGprToXmm(ctx: *Ctx, gpr: i16, xmm: i16, dtype: mir.DataType) !void {
    if (dtype == .f64) {
        try append2(ctx, .SSE_MOVQ_LD, Operand.xmm(xmm), Operand.r(gpr));
    } else {
        try append2(ctx, .SSE_MOVD_LD, Operand.xmm(xmm), Operand.r(gpr));
    }
}

pub fn moveXmmToXmm(ctx: *Ctx, src_xmm: i16, dst_xmm: i16, dtype: mir.DataType) !void {
    if (dtype == .f64) {
        try append2(ctx, .SSE_MOVSD_LD, Operand.xmm(dst_xmm), Operand.xmm(src_xmm));
    } else {
        try append2(ctx, .SSE_MOVSS_LD, Operand.xmm(dst_xmm), Operand.xmm(src_xmm));
    }
}

pub fn loadFloatOpToXmm(ctx: *Ctx, op: mir.MOperand, into_xmm: i16, dtype: mir.DataType) !void {
    switch (op) {
        .vreg => {
            if (regalloc.isSpilled(ctx.ra, op)) {
                try regalloc.loadSpilledOp(ctx.code_dummy, ctx.ra, op, ctx.scratch);
                try moveGprToXmm(ctx, ctx.scratch, into_xmm, dtype);
            } else {
                const reg = resolveReg(ctx.ra, op);
                if (reg != into_xmm) {
                    try moveXmmToXmm(ctx, reg, into_xmm, dtype);
                }
            }
        },
        .imm => {
            try append2(ctx, .MOV_R64_IMM64, Operand.r(ctx.scratch), .{ .imm64 = @bitCast(op.imm) });
            try moveGprToXmm(ctx, ctx.scratch, into_xmm, dtype);
        },
        else => {},
    }
}
