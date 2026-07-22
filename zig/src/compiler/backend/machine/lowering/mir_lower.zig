const std = @import("std");
const mir = @import("../../mir/mir.zig");
const machine = @import("../machine.zig");

pub fn lowerModule(mir_mod: *const mir.MModule, allocator: std.mem.Allocator) !machine.MModule {
    var mod = machine.MModule.init(allocator);
    errdefer mod.deinit();

    for (mir_mod.functions.items) |*mir_func| {
        const mfunc = try lowerFunction(mir_func);
        try mod.functions.append(mfunc);
    }

    return mod;
}

fn lowerFunction(mir_func: *const mir.MFunction) !machine.MFunction {
    var mfunc = machine.MFunction{
        .name = mir_func.name,
        .blocks = std.ArrayList(machine.MBlock).init(mir_func.allocator),
        .vreg_info = std.AutoHashMap(u32, machine.VRegInfo).init(mir_func.allocator),
        .params = mir_func.params,
        .allocator = mir_func.allocator,
    };

    var vreg_it = mir_func.vreg_info.iterator();
    while (vreg_it.next()) |kv| {
        try mfunc.vreg_info.put(kv.key_ptr.*, machine.VRegInfo.init(kv.value_ptr.ty));
    }

    for (mir_func.blocks.items) |*mir_blk| {
        var blk = machine.MBlock{
            .name = mir_blk.name,
            .instrs = std.ArrayList(machine.MInst).init(mir_func.allocator),
        };

        for (mir_blk.instrs.items) |mir_inst| {
            try blk.instrs.append(lowerInst(mir_inst));
        }

        try mfunc.blocks.append(blk);
    }

    return mfunc;
}

fn lowerInst(mir_inst: mir.MInst) machine.MInst {
    return switch (mir_inst) {
        .mov => |m| .{ .mov = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .add => |m| .{ .add = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .sub => |m| .{ .sub = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .imul => |m| .{ .imul = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .idiv => |m| .{ .idiv = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .@"and" => |m| .{ .@"and" = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .@"or" => |m| .{ .@"or" = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .xor => |m| .{ .xor = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .shl => |m| .{ .shl = .{ .dst = lowerOp(m.dst), .amount = lowerOp(m.amount) } },
        .shr => |m| .{ .shr = .{ .dst = lowerOp(m.dst), .amount = lowerOp(m.amount) } },
        .sar => |m| .{ .sar = .{ .dst = lowerOp(m.dst), .amount = lowerOp(m.amount) } },
        .not_op => |m| .{ .not_op = .{ .dst = lowerOp(m.dst) } },
        .neg_op => |m| .{ .neg_op = .{ .dst = lowerOp(m.dst) } },
        .test_flags => |m| .{ .test_flags = .{ .a = lowerOp(m.a), .b = lowerOp(m.b) } },
        .cmp => |m| .{ .cmp = .{ .cc = m.cc, .dst = lowerOp(m.dst), .a = lowerOp(m.a), .b = lowerOp(m.b) } },
        .cmp_flags => |m| .{ .cmp_flags = .{ .a = lowerOp(m.a), .b = lowerOp(m.b) } },
        .jmp => |m| .{ .jmp = .{ .target = @intCast(m.target) } },
        .jcc => |m| .{ .jcc = .{ .cc = m.cc, .target = @intCast(m.target) } },
        .call => |m| blk: {
            var args: [4]machine.MOperand = .{ .{ .imm = 0 }, .{ .imm = 0 }, .{ .imm = 0 }, .{ .imm = 0 } };
            for (0..m.arg_count) |i| args[i] = lowerOp(m.args[i]);
            break :blk .{ .call = .{ .name = m.name, .args = args, .arg_count = m.arg_count, .dst = lowerOp(m.dst) } };
        },
        .alloca => |m| .{ .alloca = .{ .size = m.size, .dst = lowerOp(m.dst) } },
        .load => |m| .{ .load = .{ .dst = lowerOp(m.dst), .ptr = lowerOp(m.ptr) } },
        .store => |m| .{ .store = .{ .ptr = lowerOp(m.ptr), .src = lowerOp(m.src) } },
        .lea => |m| .{ .lea = .{ .dst = lowerOp(m.dst), .base = lowerOp(m.base), .index = lowerOp(m.index), .scale = m.scale, .disp = m.disp } },
        .ret => |m| .{ .ret = .{ .val = lowerOp(m.val), .is_void = m.is_void } },
        .fadd => |m| .{ .fadd = .{ .dst = lowerOp(m.dst), .a = lowerOp(m.a), .b = lowerOp(m.b) } },
        .fsub => |m| .{ .fsub = .{ .dst = lowerOp(m.dst), .a = lowerOp(m.a), .b = lowerOp(m.b) } },
        .fmul => |m| .{ .fmul = .{ .dst = lowerOp(m.dst), .a = lowerOp(m.a), .b = lowerOp(m.b) } },
        .fdiv => |m| .{ .fdiv = .{ .dst = lowerOp(m.dst), .a = lowerOp(m.a), .b = lowerOp(m.b) } },
        .fneg_op => |m| .{ .fneg_op = .{ .dst = lowerOp(m.dst) } },
        .fsqrt_op => |m| .{ .fsqrt_op = .{ .dst = lowerOp(m.dst) } },
        .fcmp => |m| .{ .fcmp = .{ .setcc_op = m.setcc_op, .dst = lowerOp(m.dst), .a = lowerOp(m.a), .b = lowerOp(m.b) } },
        .sitofp => |m| .{ .sitofp = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .fptosi => |m| .{ .fptosi = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .fpext => |m| .{ .fpext = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .fptrunc => |m| .{ .fptrunc = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .sext_op => |m| .{ .sext_op = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .zext_op => |m| .{ .zext_op = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .trunc_op => |m| .{ .trunc_op = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src) } },
        .select => |m| .{ .select = .{ .dst = lowerOp(m.dst), .src = lowerOp(m.src), .cc = m.cc } },
        .phi => .{ .phi = .{ .dst = .{ .imm = 0 }, .incoming = &.{} } },
    };
}

fn lowerOp(op: mir.MOperand) machine.MOperand {
    return switch (op) {
        .vreg => |v| .{ .vreg = .{ .id = v, .class = .gpr } },
        .phys => |r| .{ .phys = r },
        .imm => |v| .{ .imm = v },
        .mem => |m| .{ .mem = .{ .base = m.base, .offset = m.offset, .size = m.size, .index = m.index, .scale = m.scale } },
    };
}
