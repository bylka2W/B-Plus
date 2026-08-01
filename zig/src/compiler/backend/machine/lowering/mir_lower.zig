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
    const params = try mir_func.allocator.alloc(machine.MOperand, mir_func.params.len);
    for (mir_func.params, 0..) |p, i| {
        params[i] = lowerOp(mir_func, p);
    }

    var mfunc = machine.MFunction{
        .name = mir_func.name,
        .blocks = std.ArrayList(machine.MBlock).init(mir_func.allocator),
        .vreg_info = std.AutoHashMap(u32, machine.VRegInfo).init(mir_func.allocator),
        .params = params,
        .allocator = mir_func.allocator,
    };

    var vreg_it = mir_func.vreg_info.iterator();
    while (vreg_it.next()) |kv| {
        try mfunc.vreg_info.put(kv.key_ptr.*, machine.VRegInfo.init(kv.value_ptr.ty));
    }

    for (mir_func.blocks.items) |*mir_blk| {
        var blk = machine.MBlock{
            .name = mir_blk.label,
            .instrs = std.ArrayList(machine.MInst).init(mir_func.allocator),
        };

        for (mir_blk.instrs.items) |mir_inst| {
            if (mir_inst == .phi) continue;
            try blk.instrs.append(try lowerInst(mir_func, mir_inst));
        }

        try mfunc.blocks.append(blk);
    }

    return mfunc;
}

fn lowerInst(mir_func: *const mir.MFunction, mir_inst: mir.MInst) !machine.MInst {
    return switch (mir_inst) {
        .mov => |m| .{ .mov = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .add => |m| .{ .add = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .sub => |m| .{ .sub = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .imul => |m| .{ .imul = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .idiv => |m| .{ .idiv = .{ .dividend = lowerOp(mir_func, m.dividend), .divisor = lowerOp(mir_func, m.divisor), .quotient = lowerOp(mir_func, m.quotient), .remainder = lowerOp(mir_func, m.remainder) } },
        .@"and" => |m| .{ .@"and" = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .@"or" => |m| .{ .@"or" = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .xor => |m| .{ .xor = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .shl => |m| .{ .shl = .{ .dst = lowerOp(mir_func, m.dst), .amount = lowerOp(mir_func, m.amount), .uses_cl = m.uses_cl } },
        .shr => |m| .{ .shr = .{ .dst = lowerOp(mir_func, m.dst), .amount = lowerOp(mir_func, m.amount), .uses_cl = m.uses_cl } },
        .sar => |m| .{ .sar = .{ .dst = lowerOp(mir_func, m.dst), .amount = lowerOp(mir_func, m.amount), .uses_cl = m.uses_cl } },
        .not_op => |m| .{ .not_op = .{ .dst = lowerOp(mir_func, m.dst) } },
        .neg_op => |m| .{ .neg_op = .{ .dst = lowerOp(mir_func, m.dst) } },
        .test_flags => |m| .{ .test_flags = .{ .a = lowerOp(mir_func, m.a), .b = lowerOp(mir_func, m.b) } },
        .cmp => |m| .{ .cmp = .{ .cc = convertCC(m.cc), .a = lowerOp(mir_func, m.a), .b = lowerOp(mir_func, m.b) } },
        .cmp_flags => |m| .{ .cmp_flags = .{ .a = lowerOp(mir_func, m.a), .b = lowerOp(mir_func, m.b) } },
        .setcc => |m| .{ .setcc = .{ .dst = lowerOp(mir_func, m.dst), .cc = convertCC(m.cc) } },
        .jmp => |m| .{ .jmp = .{ .target = @intCast(m.target) } },
        .jcc => |m| .{ .jcc = .{ .cc = convertCC(m.cc), .target = @intCast(m.target) } },
        .trap => .trap,
        .call => |m| blk: {
            var args: [14]machine.MOperand = undefined;
            for (&args) |*a| a.* = .{ .imm = 0 };
            for (0..m.arg_count) |i| args[i] = lowerOp(mir_func, m.args[i]);
            break :blk .{ .call = .{ .name = m.name, .args = args, .arg_count = m.arg_count, .dst = lowerOp(mir_func, m.dst), .is_void = m.is_void } };
        },
        .alloca => |m| .{ .alloca = .{ .size = m.size, .dst = lowerOp(mir_func, m.dst) } },
        .load => |m| .{ .load = .{ .dst = lowerOp(mir_func, m.dst), .ptr = lowerOp(mir_func, m.ptr), .size = convertMemSize(m.size) } },
        .store => |m| .{ .store = .{ .ptr = lowerOp(mir_func, m.ptr), .src = lowerOp(mir_func, m.src), .size = convertMemSize(m.size) } },
        .lea => |m| .{ .lea = .{ .dst = lowerOp(mir_func, m.dst), .base = lowerOp(mir_func, m.base), .index = lowerOp(mir_func, m.index), .scale = m.scale, .disp = m.disp } },
        .ret => |m| switch (m) {
            .void_ret => .{ .ret = .void_ret },
            .value => |v| .{ .ret = .{ .value = lowerOp(mir_func, v) } },
        },
        .phi => unreachable,
        .fadd => |m| .{ .fadd = .{ .dst = lowerOp(mir_func, m.dst), .a = lowerOp(mir_func, m.a), .b = lowerOp(mir_func, m.b) } },
        .fsub => |m| .{ .fsub = .{ .dst = lowerOp(mir_func, m.dst), .a = lowerOp(mir_func, m.a), .b = lowerOp(mir_func, m.b) } },
        .fmul => |m| .{ .fmul = .{ .dst = lowerOp(mir_func, m.dst), .a = lowerOp(mir_func, m.a), .b = lowerOp(mir_func, m.b) } },
        .fdiv => |m| .{ .fdiv = .{ .dst = lowerOp(mir_func, m.dst), .a = lowerOp(mir_func, m.a), .b = lowerOp(mir_func, m.b) } },
        .fneg_op => |m| .{ .fneg_op = .{ .dst = lowerOp(mir_func, m.dst) } },
        .fsqrt_op => |m| .{ .fsqrt_op = .{ .dst = lowerOp(mir_func, m.dst) } },
        .fcmp => |m| .{ .fcmp = .{ .cc = convertCC(m.cc), .dst = lowerOp(mir_func, m.dst), .a = lowerOp(mir_func, m.a), .b = lowerOp(mir_func, m.b) } },
        .sitofp => |m| .{ .sitofp = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .fptosi => |m| .{ .fptosi = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .fpext => |m| .{ .fpext = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .fptrunc => |m| .{ .fptrunc = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .sext_op => |m| .{ .sext_op = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .zext_op => |m| .{ .zext_op = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .trunc_op => |m| .{ .trunc_op = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src) } },
        .select => |m| .{ .select = .{ .dst = lowerOp(mir_func, m.dst), .src = lowerOp(mir_func, m.src), .cc = convertCC(m.cc) } },
        .state_init => |m| .{ .state_init = .{ .initial_state = lowerOp(mir_func, m.initial_state) } },
        .state_enter => |m| .{ .state_enter = .{ .state_id = lowerOp(mir_func, m.state_id) } },
        .state_exit => |m| .{ .state_exit = .{ .state_id = lowerOp(mir_func, m.state_id) } },
        .event_dispatch => |m| .{ .event_dispatch = .{ .dst = lowerOp(mir_func, m.dst), .buf = lowerOp(mir_func, m.buf), .size = lowerOp(mir_func, m.size) } },
        .transition_check => |m| .{ .transition_check = .{ .result = lowerOp(mir_func, m.result), .event = lowerOp(mir_func, m.event), .event_id = m.event_id } },
        .guard_eval => |m| .{ .guard_eval = .{ .result = lowerOp(mir_func, m.result), .lhs = lowerOp(mir_func, m.lhs), .rhs = lowerOp(mir_func, m.rhs), .cc = convertCC(m.cc) } },
        .string_const => |m| .{ .lea = .{ .dst = lowerOp(mir_func, m.dst), .base = .{ .imm = 0 }, .scale = 0, .disp = 0 } },
    };
}

fn lowerOp(mir_func: *const mir.MFunction, op: mir.MOperand) machine.MOperand {
    return switch (op) {
        .vreg => |v| .{ .vreg = .{ .id = v, .class = convertClass(mir_func.getVRegClass(v)) } },
        .phys => |r| .{ .phys = r },
        .imm => |v| .{ .imm = v },
        .mem => |m| .{ .mem = .{ .base = m.base, .offset = m.offset, .size = m.size, .index = m.index, .scale = m.scale } },
    };
}

fn convertClass(cls: ?mir.VRegClass) machine.RegClass {
    if (cls) |c| {
        return switch (c) {
            .gpr => .gpr,
            .xmm => .xmm,
        };
    }
    return .gpr;
}

fn convertCC(cc: mir.CondCode) machine.CondCode {
    return @enumFromInt(@intFromEnum(cc));
}

fn convertMemSize(ms: mir.MemSize) machine.instruction.MemSize {
    return @enumFromInt(@intFromEnum(ms));
}
