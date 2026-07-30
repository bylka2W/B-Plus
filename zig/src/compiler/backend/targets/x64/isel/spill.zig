/// x64 spill/reload via x64 IR.
/// Replaces raw-byte spill emission with proper x64 IR instructions,
/// so that spill code is verified and encoded through the normal pipeline.
const mir = @import("../../../mir/mir.zig");
const regalloc = @import("../../../regalloc/regalloc.zig");
const ctx_mod = @import("context.zig");
const Ctx = ctx_mod.Ctx;
const Operand = @import("../encoder.zig").Operand;
const append2 = ctx_mod.append2;

pub fn loadSpilledOp(ctx: *Ctx, op: mir.MOperand, scratch: i16) !void {
    const vreg = switch (op) {
        .vreg => |v| v,
        else => return,
    };
    const ra = ctx.ra;
    if (ra.remat.get(vreg)) |r| {
        switch (r) {
            .imm64 => |val| {
                try append2(ctx, .MOV_R64_IMM64, Operand.r(scratch), .{ .imm64 = @bitCast(val) });
            },
            .zero => {
                try append2(ctx, .XOR_R64_R64, Operand.r(scratch), Operand.r(scratch));
            },
        }
        return;
    }
    const off = ra.spills.get(vreg) orelse return;
    const mem = Operand{ .base_reg = 5, .disp = off };
    try append2(ctx, .MOV_R64_MEM, Operand.r(scratch), mem);
}

pub fn storeSpilledOp(ctx: *Ctx, op: mir.MOperand, scratch: i16) !void {
    const vreg = switch (op) {
        .vreg => |v| v,
        else => return,
    };
    const ra = ctx.ra;
    if (ra.remat.contains(vreg)) return;
    const off = ra.spills.get(vreg) orelse return;
    const mem = Operand{ .base_reg = 5, .disp = off };
    try append2(ctx, .MOV_MEM_R64, mem, Operand.r(scratch));
}
