const std = @import("std");
const machine = @import("../../machine.zig");
const instruction = @import("../../core/instruction.zig");

pub const VerifyError = error{
    DuplicateDefinition,
    UnusedVReg,
    VRegClassConflict,
};

pub fn checkDefUse(func: *const machine.MFunction) VerifyError!void {
    var defined = std.AutoHashMap(u32, void).init(func.allocator);
    defer defined.deinit();

    var used = std.AutoHashMap(u32, void).init(func.allocator);
    defer used.deinit();

    for (func.blocks.items) |*blk| {
        for (blk.instrs.items) |inst| {
            if (instruction.dstVReg(inst)) |dst_id| {
                try defined.put(dst_id, {});
            }
            collectUses(inst, &used);
        }
    }

    var used_it = used.keyIterator();
    while (used_it.next()) |vreg_id| {
        if (!defined.contains(vreg_id.*)) {
            return error.UndefinedVReg;
        }
    }
}

const VerifyError2 = VerifyError || error{};

fn collectUses(inst: instruction.MInst, used: *std.AutoHashMap(u32, void)) void {
    switch (inst) {
        .mov => |m| addUse(m.src, used),
        .add, .sub, .imul, .idiv, .@"and", .@"or", .xor => |bin| {
            addUse(bin.src, used);
        },
        .shl, .shr, .sar => |s| addUse(s.amount, used),
        .fadd, .fsub, .fmul, .fdiv => |f| {
            addUse(f.a, used);
            addUse(f.b, used);
        },
        .fcmp => |c| {
            addUse(c.a, used);
            addUse(c.b, used);
        },
        .sitofp, .fptosi, .fpext, .fptrunc, .sext_op, .zext_op, .trunc_op => |c| {
            addUse(c.src, used);
        },
        .select => |s| addUse(s.src, used),
        .load => |l| addUse(l.ptr, used),
        .store => |s| {
            addUse(s.ptr, used);
            addUse(s.src, used);
        },
        .lea => |l| {
            addUse(l.base, used);
            if (l.index != .imm) addUse(l.index, used);
        },
        .call => |c| {
            for (0..c.arg_count) |i| addUse(c.args[i], used);
        },
        .ret => |r| {
            if (!r.is_void) addUse(r.val, used);
        },
        .test_flags, .cmp_flags => |tf| {
            addUse(tf.a, used);
            addUse(tf.b, used);
        },
        else => {},
    }
}

fn addUse(op: @import("../../core/operand.zig").MOperand, used: *std.AutoHashMap(u32, void)) void {
    switch (op) {
        .vreg => |v| used.put(v.id, {}) catch {},
        else => {},
    }
}
