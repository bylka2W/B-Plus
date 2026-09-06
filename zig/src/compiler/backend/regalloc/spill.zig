const std = @import("std");
const mir = @import("../mir/mir.zig");
const x64 = @import("../targets/x64/encoder.zig");
const classes = @import("classes.zig");

pub const Remat = @import("allocator.zig").Remat;

pub const RegAllocResult = struct {
    regs: std.AutoHashMap(u32, i16),
    spills: std.AutoHashMap(u32, i32),
    spill_frame_size: u32,
    remat: std.AutoHashMap(u32, Remat),
};

pub fn regForOp(ra: *const RegAllocResult, op: mir.MOperand) i16 {
    return switch (op) {
        .vreg => |v| ra.regs.get(v) orelse -1,
        .phys => |r| @as(i16, @intCast(r)),
        .imm => -1,
        .mem => |m| @as(i16, @intCast(m.base)),
    };
}

pub fn isSpilled(ra: *const RegAllocResult, op: mir.MOperand) bool {
    return switch (op) {
        .vreg => |v| ra.spills.contains(v) or ra.remat.contains(v),
        else => false,
    };
}

pub fn isRemat(ra: *const RegAllocResult, op: mir.MOperand) bool {
    return switch (op) {
        .vreg => |v| ra.remat.contains(v),
        else => false,
    };
}

pub fn spilledMemOp(ra: *const RegAllocResult, op: mir.MOperand) x64.Operand {
    const vreg = switch (op) {
        .vreg => |v| v,
        else => return .{},
    };
    if (ra.remat.contains(vreg)) return .{};
    const off = ra.spills.get(vreg) orelse return .{};
    return x64.Operand{ .base_reg = 5, .disp = off };
}

pub fn loadSpilledOp(code: *std.ArrayList(u8), ra: *const RegAllocResult, op: mir.MOperand, scratch: i16) !void {
    const vreg = switch (op) {
        .vreg => |v| v,
        else => return,
    };
    if (ra.remat.get(vreg)) |r| {
        switch (r) {
            .imm64 => |val| {
                try x64.emit(code, .MOV_R64_IMM64, &.{ .{ .reg = scratch }, .{ .imm64 = @bitCast(val) } });
            },
            .zero => {
                try x64.emit(code, .XOR_R64_R64, &.{ .{ .reg = scratch }, .{ .reg = scratch } });
            },
        }
        return;
    }
    const off = ra.spills.get(vreg) orelse return;
    const mem = x64.Operand{ .base_reg = 5, .disp = off };
    try x64.emit(code, .MOV_R64_MEM, &.{ .{ .reg = scratch }, mem });
}

pub fn storeSpilledOp(code: *std.ArrayList(u8), ra: *const RegAllocResult, op: mir.MOperand, scratch: i16) !void {
    const vreg = switch (op) {
        .vreg => |v| v,
        else => return,
    };
    if (ra.remat.contains(vreg)) return;
    const off = ra.spills.get(vreg) orelse return;
    const mem = x64.Operand{ .base_reg = 5, .disp = off };
    try x64.emit(code, .MOV_MEM_R64, &.{ mem, .{ .reg = scratch } });
}

const CALLEE_SAVED_LIST = [_]i16{ 3, 6, 7, 12, 13, 14, 15 };

pub fn getUsedCalleeSaved(ra: *const RegAllocResult, out: *std.ArrayList(i16)) void {
    for (&CALLEE_SAVED_LIST) |reg| {
        if (reg == classes.SCRATCH_REG or reg == classes.SCRATCH_REG_2) continue;
        var it = ra.regs.valueIterator();
        while (it.next()) |r| {
            if (r.* == reg) {
                out.append(reg) catch {};
                break;
            }
        }
    }
}
