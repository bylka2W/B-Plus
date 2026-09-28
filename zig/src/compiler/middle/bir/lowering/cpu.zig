const std = @import("std");
const bir = @import("../bir.zig");
const mir = @import("../../../backend/mir/mir.zig");
const settings = @import("../../../../compiler/settings.zig");
const Op = bir.Op;

const CmpDef = struct { op0: u32, op1: u32, cc: mir.CondCode };

fn memSizeOfType(types: *const bir.types.TypeTable, ty: bir.types.TypeId) mir.MemSize {
    return switch (birTypeToDataType(types, ty)) {
        .f32 => .f32,
        .f64 => .f64,
        else => switch (types.sizeOf(ty)) {
            1 => .u8,
            2 => .u16,
            4 => .u32,
            8 => .u64,
            else => .u64,
        },
    };
}

fn birValDataType(bir_func: *const bir.Function, types: *const bir.types.TypeTable, val: u32) mir.DataType {
    if (val == 0) return .i64;
    for (bir_func.param_values, 0..) |pv, i| {
        if (pv == val) return birTypeToDataType(types, bir_func.params[i].ty);
    }
    if (val - 1 >= bir_func.value_info.items.len) return .i64;
    const vi = &bir_func.value_info.items[val - 1];
    if (vi.def.block == bir.INVALID_ID or vi.def.idx == bir.INVALID_ID) return .i64;
    if (vi.def.block >= bir_func.blocks.items.len) return .i64;
    const def_block = &bir_func.blocks.items[vi.def.block];
    if (vi.def.idx >= def_block.instrs.items.len) return .i64;
    return birTypeToDataType(types, def_block.instrs.items[vi.def.idx].ty);
}

fn birTypeToDataType(types: *const bir.types.TypeTable, ty: bir.types.TypeId) mir.DataType {
    const t = types.get(ty);
    return switch (t.kind) {
        .scalar => |sk| switch (sk) {
            .i1, .i8, .i16, .i32, .i64 => .i64,
            .u8, .u16, .u32, .u64 => .i64,
            .f16, .f32 => .f32,
            .f64 => .f64,
            .bf16 => .f32,
        },
        .pointer => .i64,
        .void => .void,
        else => .i64,
    };
}

fn birValType(bir_func: *const bir.Function, val: u32) ?bir.types.TypeId {
    if (val == 0) return null;
    for (bir_func.param_values, 0..) |pv, i| {
        if (pv == val) return bir_func.params[i].ty;
    }
    if (val - 1 >= bir_func.value_info.items.len) return null;
    const vi = &bir_func.value_info.items[val - 1];
    if (vi.def.block == bir.INVALID_ID or vi.def.idx == bir.INVALID_ID) return null;
    if (vi.def.block >= bir_func.blocks.items.len) return null;
    const def_block = &bir_func.blocks.items[vi.def.block];
    if (vi.def.idx >= def_block.instrs.items.len) return null;
    return def_block.instrs.items[vi.def.idx].ty;
}

fn isAggregateType(types: *const bir.types.TypeTable, ty: bir.types.TypeId) bool {
    return switch (types.get(ty).kind) {
        .array, .struct_type => true,
        else => false,
    };
}

fn aggregateLoadPointer(bir_func: *const bir.Function, val: u32) ?u32 {
    if (val == 0) return null;
    if (val - 1 >= bir_func.value_info.items.len) return null;
    const vi = &bir_func.value_info.items[val - 1];
    if (vi.def.block == bir.INVALID_ID or vi.def.idx == bir.INVALID_ID) return null;
    if (vi.def.block >= bir_func.blocks.items.len) return null;
    const def_block = &bir_func.blocks.items[vi.def.block];
    if (vi.def.idx >= def_block.instrs.items.len) return null;
    const inst = def_block.instrs.items[vi.def.idx];
    if (inst.op == .load and inst.operands.len >= 1) return inst.operands[0];
    return null;
}

fn findCmpDef(bir_func: *const bir.Function, val: u32) ?CmpDef {
    if (val == bir.NO_VALUE or val == 0) return null;
    if (val - 1 >= bir_func.value_info.items.len) return null;
    const vi = &bir_func.value_info.items[val - 1];
    if (vi.def.block == bir.INVALID_ID or vi.def.idx == bir.INVALID_ID) return null;
    if (vi.def.block >= bir_func.blocks.items.len) return null;
    const def_block = &bir_func.blocks.items[vi.def.block];
    if (vi.def.idx >= def_block.instrs.items.len) return null;
    const def_inst = &def_block.instrs.items[vi.def.idx];
    const ops = def_inst.operands;
    if (ops.len < 2) return null;
    const cc: mir.CondCode = switch (def_inst.op) {
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        else => return null,
    };
    return CmpDef{ .op0 = ops[0], .op1 = ops[1], .cc = cc };
}

pub fn lowerModuleToMir(allocator: std.mem.Allocator, mod: *const bir.Module) ![]mir.MFunction {
    var mfuncs = std.ArrayList(mir.MFunction).init(allocator);
    errdefer for (mfuncs.items) |*mf| mf.deinit();
    for (mod.functions.items) |*func| {
        const mf = try lowerToMir(allocator, &mod.types, func);
        try mfuncs.append(mf);
    }
    for (mod.state_machines.items) |*sm| {
        const mf = try lowerStateMachine(allocator, mod, sm);
        try mfuncs.append(mf);
    }
    return mfuncs.toOwnedSlice();
}

fn allocVreg(next: *u32) u32 {
    const v = next.*;
    next.* += 1;
    return v;
}

const PLAN_EVENT_ARGS = 2;
const PLAN_BUF_SIZE = (1 + PLAN_EVENT_ARGS) * 8;

fn planCallArgs(args: *[14]mir.MOperand, count: u32, a0: mir.MOperand, a1: mir.MOperand) void {
    for (0..count) |i| {
        if (i == 0) {
            args[i] = a0;
        } else if (i == 1) {
            args[i] = a1;
        } else {
            args[i] = .{ .imm = 0 };
        }
    }
}

pub fn lowerStateMachine(allocator: std.mem.Allocator, mod: *const bir.Module, sm: *const bir.StateMachine) !mir.MFunction {
    var mfunc = mir.MFunction.init(allocator, sm.name);
    errdefer mfunc.deinit();
    var next_vreg: u32 = 2;
    mfunc.setParams(&.{.{ .vreg = 1 }});
    try mfunc.putVReg(1, .i64);

    const v_buf = allocVreg(&next_vreg);
    const v_new = allocVreg(&next_vreg);
    const v_ok = allocVreg(&next_vreg);
    const v_ev = allocVreg(&next_vreg);
    const v_a0 = allocVreg(&next_vreg);
    const v_a1 = allocVreg(&next_vreg);
    const v_p8 = allocVreg(&next_vreg);
    const v_p16 = allocVreg(&next_vreg);
    const v_cur = allocVreg(&next_vreg);
    const v_g = allocVreg(&next_vreg);

    const n_t: u32 = @intCast(sm.transitions.items.len);
    const n_s: u32 = @intCast(sm.states.items.len);
    const has_trans = n_t > 0;

                                     
                
                   
                                                
                                                                             
                                               
                                                   
                                                 
                                               
                                          
    const trans_base: u32 = if (has_trans) 2 else 0;
    const after_base: u32 = if (has_trans) trans_base + n_t else 0;
    const life_base: u32 = if (has_trans) after_base + n_t else 0;
    const disp_base: u32 = if (has_trans) life_base + n_t else 0;
    const enter_idx: u32 = if (has_trans) disp_base + n_t else 2;
    const call_base: u32 = enter_idx + 1;
    const done_idx: u32 = call_base + n_s;
    const loop_target: u32 = 1;

    {
        var block = mir.MBlock{ .label = try allocator.dupe(u8, "entry"), .instrs = std.ArrayList(mir.MInst).init(allocator) };
        errdefer { allocator.free(block.label); block.instrs.deinit(); }

        try block.instrs.append(.{ .alloca = .{ .size = PLAN_BUF_SIZE, .dst = .{ .vreg = v_buf } } });
        {
            var cargs: [14]mir.MOperand = @splat(.{ .imm = 0 });
            cargs[0] = .{ .vreg = 1 };
            try block.instrs.append(.{ .call = .{ .name = try allocator.dupe(u8, "__plan_set_state"), .args = cargs, .arg_count = 1, .dst = .{ .imm = 0 }, .is_void = true } });
        }
        try block.instrs.append(.{ .call = .{ .name = try allocator.dupe(u8, "__plan_consume_goto"), .args = @splat(.{ .imm = 0 }), .arg_count = 0, .dst = .{ .imm = 0 }, .is_void = true } });
        try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = v_new }, .src = .{ .vreg = 1 } } });
        try block.instrs.append(.{ .jmp = .{ .target = enter_idx } });
        try mfunc.blocks.append(block);
    }

    {
        var block = mir.MBlock{ .label = try allocator.dupe(u8, "pump_top"), .instrs = std.ArrayList(mir.MInst).init(allocator) };
        errdefer { allocator.free(block.label); block.instrs.deinit(); }

        {
            var cargs: [14]mir.MOperand = @splat(.{ .imm = 0 });
            cargs[0] = .{ .vreg = v_buf };
            try block.instrs.append(.{ .call = .{ .name = try allocator.dupe(u8, "__plan_event_pop"), .args = cargs, .arg_count = 1, .dst = .{ .vreg = v_ok }, .is_void = false } });
        }
        try block.instrs.append(.{ .cmp = .{ .cc = .eq, .a = .{ .vreg = v_ok }, .b = .{ .imm = 0 } } });
        try block.instrs.append(.{ .jcc = .{ .cc = .eq, .target = done_idx } });

        try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = v_p8 }, .src = .{ .vreg = v_buf } } });
        try block.instrs.append(.{ .add = .{ .dst = .{ .vreg = v_p8 }, .src = .{ .imm = 8 } } });
        try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = v_p16 }, .src = .{ .vreg = v_buf } } });
        try block.instrs.append(.{ .add = .{ .dst = .{ .vreg = v_p16 }, .src = .{ .imm = 16 } } });
        try block.instrs.append(.{ .load = .{ .dst = .{ .vreg = v_ev }, .ptr = .{ .vreg = v_buf }, .size = .u64 } });
        try block.instrs.append(.{ .load = .{ .dst = .{ .vreg = v_a0 }, .ptr = .{ .vreg = v_p8 }, .size = .u64 } });
        try block.instrs.append(.{ .load = .{ .dst = .{ .vreg = v_a1 }, .ptr = .{ .vreg = v_p16 }, .size = .u64 } });
        try block.instrs.append(.{ .call = .{ .name = try allocator.dupe(u8, "__plan_get_state"), .args = @splat(.{ .imm = 0 }), .arg_count = 0, .dst = .{ .vreg = v_cur }, .is_void = false } });
        try block.instrs.append(.{ .jmp = .{ .target = if (has_trans) disp_base else 1 } });
        try mfunc.blocks.append(block);
    }

    if (has_trans) {
        for (sm.transitions.items, 0..) |t, ti| {
            var block = mir.MBlock{ .label = try std.fmt.allocPrint(allocator, "trans_{d}", .{ti}), .instrs = std.ArrayList(mir.MInst).init(allocator) };
            errdefer { allocator.free(block.label); block.instrs.deinit(); }

            if (t.action_fn) |af| {
                const af_fn = &mod.functions.items[af];
                const nparams: u32 = @intCast(af_fn.params.len);
                var aargs: [14]mir.MOperand = @splat(.{ .imm = 0 });
                if (nparams > 0) aargs[0] = .{ .vreg = v_a0 };
                if (nparams > 1) aargs[1] = .{ .vreg = v_a1 };
                try block.instrs.append(.{ .call = .{ .name = try allocator.dupe(u8, af_fn.name), .args = aargs, .arg_count = @min(nparams, 14), .dst = .{ .imm = 0 }, .is_void = true } });
            }

            try block.instrs.append(.{ .call = .{ .name = try allocator.dupe(u8, "__plan_consume_goto"), .args = @splat(.{ .imm = 0 }), .arg_count = 0, .dst = .{ .vreg = v_g }, .is_void = false } });
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = v_new }, .src = .{ .imm = @as(i64, @intCast(t.to_state_idx)) } } });
            try block.instrs.append(.{ .cmp = .{ .cc = .eq, .a = .{ .vreg = v_g }, .b = .{ .imm = -1 } } });
            try block.instrs.append(.{ .jcc = .{ .cc = .eq, .target = after_base + @as(u32, @intCast(ti)) } });
            try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = v_new }, .src = .{ .vreg = v_g } } });
            try block.instrs.append(.{ .jmp = .{ .target = after_base + @as(u32, @intCast(ti)) } });
            try mfunc.blocks.append(block);
        }
    }

    if (has_trans) {
        for (sm.transitions.items, 0..) |t, ti| {
            var block = mir.MBlock{ .label = try std.fmt.allocPrint(allocator, "after_{d}", .{ti}), .instrs = std.ArrayList(mir.MInst).init(allocator) };
            errdefer { allocator.free(block.label); block.instrs.deinit(); }

            try block.instrs.append(.{ .cmp = .{ .cc = .ne, .a = .{ .vreg = v_new }, .b = .{ .imm = @as(i64, @intCast(t.from_state_idx)) } } });
            try block.instrs.append(.{ .jcc = .{ .cc = .ne, .target = life_base + @as(u32, @intCast(ti)) } });
            try block.instrs.append(.{ .jmp = .{ .target = 1 } });
            try mfunc.blocks.append(block);
        }
    }

    if (has_trans) {
        for (sm.transitions.items, 0..) |t, ti| {
            var block = mir.MBlock{ .label = try std.fmt.allocPrint(allocator, "life_{d}", .{ti}), .instrs = std.ArrayList(mir.MInst).init(allocator) };
            errdefer { allocator.free(block.label); block.instrs.deinit(); }

            if (sm.states.items[t.from_state_idx].exit_fn) |exf| {
                const ex = &mod.functions.items[exf];
                try block.instrs.append(.{ .call = .{ .name = try allocator.dupe(u8, ex.name), .args = @splat(.{ .imm = 0 }), .arg_count = 0, .dst = .{ .imm = 0 }, .is_void = true } });
            }
            {
                var cargs: [14]mir.MOperand = @splat(.{ .imm = 0 });
                cargs[0] = .{ .vreg = v_new };
                try block.instrs.append(.{ .call = .{ .name = try allocator.dupe(u8, "__plan_set_state"), .args = cargs, .arg_count = 1, .dst = .{ .imm = 0 }, .is_void = true } });
            }
            try block.instrs.append(.{ .jmp = .{ .target = enter_idx } });
            try mfunc.blocks.append(block);
        }
    }

    if (has_trans) {
        for (sm.transitions.items, 0..) |t, ti| {
            var block = mir.MBlock{ .label = try std.fmt.allocPrint(allocator, "dispatch_{d}", .{ti}), .instrs = std.ArrayList(mir.MInst).init(allocator) };
            errdefer { allocator.free(block.label); block.instrs.deinit(); }
            const next_target: u32 = if (ti + 1 < n_t) disp_base + @as(u32, @intCast(ti + 1)) else 1;

            try block.instrs.append(.{ .cmp = .{ .cc = .eq, .a = .{ .vreg = v_cur }, .b = .{ .imm = @as(i64, @intCast(t.from_state_idx)) } } });
            try block.instrs.append(.{ .jcc = .{ .cc = .ne, .target = next_target } });
            if (t.event_id != 0) {
                try block.instrs.append(.{ .cmp = .{ .cc = .eq, .a = .{ .vreg = v_ev }, .b = .{ .imm = @as(i64, @intCast(t.event_id)) } } });
                try block.instrs.append(.{ .jcc = .{ .cc = .ne, .target = next_target } });
            }
            try block.instrs.append(.{ .jmp = .{ .target = trans_base + @as(u32, @intCast(ti)) } });
            try mfunc.blocks.append(block);
        }
    }

    {
        var block = mir.MBlock{ .label = try allocator.dupe(u8, "enter_chain"), .instrs = std.ArrayList(mir.MInst).init(allocator) };
        errdefer { allocator.free(block.label); block.instrs.deinit(); }
        for (0..n_s) |si| {
            try block.instrs.append(.{ .cmp = .{ .cc = .eq, .a = .{ .vreg = v_new }, .b = .{ .imm = @as(i64, @intCast(si)) } } });
            try block.instrs.append(.{ .jcc = .{ .cc = .eq, .target = call_base + @as(u32, @intCast(si)) } });
        }
        try block.instrs.append(.{ .jmp = .{ .target = loop_target } });
        try mfunc.blocks.append(block);
    }

    for (sm.states.items, 0..) |st, si| {
        var block = mir.MBlock{ .label = try std.fmt.allocPrint(allocator, "call_{s}", .{st.name}), .instrs = std.ArrayList(mir.MInst).init(allocator) };
        errdefer { allocator.free(block.label); block.instrs.deinit(); }
        _ = si;
        const ename = mod.functions.items[st.entry_fn].name;
        try block.instrs.append(.{ .call = .{ .name = try allocator.dupe(u8, ename), .args = @splat(.{ .imm = 0 }), .arg_count = 0, .dst = .{ .imm = 0 }, .is_void = true } });
        try block.instrs.append(.{ .jmp = .{ .target = loop_target } });
        try mfunc.blocks.append(block);
    }

    {
        var block = mir.MBlock{ .label = try allocator.dupe(u8, "done"), .instrs = std.ArrayList(mir.MInst).init(allocator) };
        errdefer { allocator.free(block.label); block.instrs.deinit(); }
        try block.instrs.append(.{ .ret = .void_ret });
        try mfunc.blocks.append(block);
    }

    return mfunc;
}

fn allocValue(next_vreg: *u32) u32 {
    const v = next_vreg.*;
    next_vreg.* += 1;
    return v;
}

pub fn lowerToMir(allocator: std.mem.Allocator, types: *const bir.types.TypeTable, bir_func: *const bir.Function) !mir.MFunction {
    if (settings.debug_ir) {
        const stderr4 = std.io.getStdErr().writer();
        stderr4.print("; BIR FUNC: '{s}' (blocks={d}, locals={d}, params={d})\n", .{bir_func.name, bir_func.blocks.items.len, bir_func.locals_count, bir_func.param_values.len}) catch {};
        for (bir_func.param_values, 0..) |pv, i| {
            stderr4.print(";   param[{d}]: value={d}\n", .{i, pv}) catch {};
        }
        for (bir_func.blocks.items, 0..) |bir_block, bi| {
            stderr4.print(";   blk {d} '{s}' ({d} instrs):\n", .{bi, bir_block.label, bir_block.instrs.items.len}) catch {};
            for (bir_block.instrs.items, 0..) |inst, ii| {
                stderr4.print(";     {d}: op={s} result={d} operands=[", .{ii, @tagName(inst.op), inst.result}) catch {};
                for (inst.operands, 0..) |op, oi| {
                    if (oi > 0) stderr4.print(",", .{}) catch {};
                    stderr4.print("{d}", .{op}) catch {};
                }
                stderr4.print("]\n", .{}) catch {};
            }
        }
    }

    var mfunc = mir.MFunction.init(allocator, bir_func.name);
    errdefer mfunc.deinit();

    {
        const mir_params = try allocator.alloc(mir.MOperand, bir_func.param_values.len);
        for (bir_func.param_values, 0..) |pv, i| {
            mir_params[i] = .{ .vreg = pv };
            const dt = birTypeToDataType(types, bir_func.params[i].ty);
            mfunc.putVReg(pv, dt) catch {};
        }
        mfunc.setParams(mir_params);
    }

    const NO_VALUE = bir.NO_VALUE;
    var next_vreg: u32 = bir_func.locals_count + 1;

    for (bir_func.blocks.items) |bir_block| {
        var mblock = mir.MBlock{
            .label = try allocator.dupe(u8, bir_block.label),
            .instrs = std.ArrayList(mir.MInst).init(allocator),
        };
        errdefer {
            allocator.free(mblock.label);
            mblock.instrs.deinit();
        }

        for (bir_block.instrs.items) |inst| {
            const result = inst.result;

            switch (inst.op) {
                .@"const" => {
                    if (result == NO_VALUE) continue;
                    switch (inst.data) {
                        .string => |s| {
                            const owned = try allocator.dupe(u8, s);
                            try mblock.instrs.append(.{ .string_const = .{
                                .dst = .{ .vreg = result },
                                .data = owned,
                            } });
                        },
                else => {
                    const val = switch (inst.data) {
                        .const_data => |cd| switch (cd) {
                            .int => |v| @as(i64, v),
                            .float => |v| @as(i64, @bitCast(v)),
                            .bool => |v| @as(i64, @intFromBool(v)),
                            .undefined, .zero => 0,
                        },
                        else => 0,
                    };
                            try mblock.instrs.append(.{ .mov = .{
                                .dst = .{ .vreg = result },
                                .src = .{ .imm = val },
                            } });
                            const dt = birTypeToDataType(types, inst.ty);
                            if (dt != .i64) {
                                try mfunc.putVReg(result, dt);
                            }
                        },
                    }
                },

                .phi => {
                    const inc = inst.data.phi_incoming;
                    const mir_incoming = try allocator.alloc(mir.PhiIncoming, inc.len);
                    for (inc, 0..) |incoming, ii| {
                        mir_incoming[ii] = .{
                            .src = .{ .vreg = incoming.value },
                            .pred_block = @intCast(incoming.block),
                        };
                    }
                    try mblock.instrs.append(.{ .phi = .{
                        .dst = .{ .vreg = result },
                        .incoming = mir_incoming,
                    } });
                },

                .add => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    const lhs = inst.operands[0];
                    const rhs = inst.operands[1];
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = lhs } } });
                    try mblock.instrs.append(.{ .add = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = rhs } } });
                },

                .sub => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    const lhs = inst.operands[0];
                    const rhs = inst.operands[1];
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = lhs } } });
                    try mblock.instrs.append(.{ .sub = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = rhs } } });
                },

                .mul => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    const lhs = inst.operands[0];
                    const rhs = inst.operands[1];
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = lhs } } });
                    try mblock.instrs.append(.{ .imul = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = rhs } } });
                },

                .div => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    const lhs = inst.operands[0];
                    const rhs = inst.operands[1];
                    const rem = allocValue(&next_vreg);
                    try mblock.instrs.append(.{ .idiv = .{ .dividend = .{ .vreg = lhs }, .divisor = .{ .vreg = rhs }, .quotient = .{ .vreg = result }, .remainder = .{ .vreg = rem } } });
                },

                .mod => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    const lhs = inst.operands[0];
                    const rhs = inst.operands[1];
                    const q = allocValue(&next_vreg);
                    try mblock.instrs.append(.{ .idiv = .{ .dividend = .{ .vreg = lhs }, .divisor = .{ .vreg = rhs }, .quotient = .{ .vreg = q }, .remainder = .{ .vreg = result } } });
                },

                .neg => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    const operand = inst.operands[0];
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .imm = 0 } } });
                    try mblock.instrs.append(.{ .sub = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = operand } } });
                },

                .eq => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .setcc = .{ .dst = .{ .vreg = result }, .cc = .eq } });
                },
                .ne => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .setcc = .{ .dst = .{ .vreg = result }, .cc = .ne } });
                },
                .lt => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .setcc = .{ .dst = .{ .vreg = result }, .cc = .lt } });
                },
                .le => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .setcc = .{ .dst = .{ .vreg = result }, .cc = .le } });
                },
                .gt => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .setcc = .{ .dst = .{ .vreg = result }, .cc = .gt } });
                },
                .ge => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .setcc = .{ .dst = .{ .vreg = result }, .cc = .ge } });
                },

                .br => {
                    const target = inst.data.block_target;
                    try mblock.instrs.append(.{ .jmp = .{ .target = target } });
                },

                .cond_br => {
                    const cb = inst.data.cond_branch;
                    const cmp_def = findCmpDef(bir_func, cb.cond);
                    if (cmp_def) |cd| {
                        try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = cd.op0 }, .b = .{ .vreg = cd.op1 } } });
                        try mblock.instrs.append(.{ .jcc = .{ .cc = cd.cc, .target = cb.then_block } });
                        try mblock.instrs.append(.{ .jmp = .{ .target = cb.else_block } });
                    } else {
                        try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = cb.cond }, .b = .{ .imm = 0 } } });
                        try mblock.instrs.append(.{ .jcc = .{ .cc = .ne, .target = cb.then_block } });
                        try mblock.instrs.append(.{ .jmp = .{ .target = cb.else_block } });
                    }
                },

                .ret => {
                    if (inst.operands.len >= 1) {
                        const ret_val = inst.operands[0];
                        const dt = birTypeToDataType(types, inst.ty);
                        try mblock.instrs.append(.{ .ret = .{ .value = .{ .operand = .{ .vreg = ret_val }, .dtype = dt } } });
                        if (dt != .i64) {
                            try mfunc.putVReg(ret_val, dt);
                        }
                    } else {
                        try mblock.instrs.append(.{ .ret = .void_ret });
                    }
                },

                .call => {
                    if (inst.data != .named_call or result == NO_VALUE) continue;
                    const info = inst.data.named_call;
                    var args: [14]mir.MOperand = undefined;
                    for (&args) |*a| a.* = .{ .imm = 0 };
                    const count = @min(@as(u32, @intCast(info.args.len)), 14);
                    var arg_t: [14]mir.DataType = @splat(.i64);
                    for (0..count) |i| {
                        if (birValType(bir_func, info.args[i])) |arg_ty| {
                            if (isAggregateType(types, arg_ty)) {
                                if (aggregateLoadPointer(bir_func, info.args[i])) |ptr| {
                                    args[i] = .{ .vreg = ptr };
                                } else {
                                    args[i] = .{ .vreg = info.args[i] };
                                }
                                arg_t[i] = .i64;
                                continue;
                            }
                        }
                        args[i] = .{ .vreg = info.args[i] };
                        arg_t[i] = birValDataType(bir_func, types, info.args[i]);
                    }
                    const ret_dt = birTypeToDataType(types, inst.ty);
                    const is_void = (ret_dt == .void);
                    try mblock.instrs.append(.{ .call = .{
                        .name = try allocator.dupe(u8, info.name),
                        .args = args,
                        .arg_count = count,
                        .dst = if (is_void) .{ .imm = 0 } else .{ .vreg = result },
                        .is_void = is_void,
                        .arg_types = arg_t,
                    } });
                    if (!is_void) {
                        try mfunc.putVReg(result, ret_dt);
                    }
                },

                .alloca => {
                    if (result == NO_VALUE) continue;
                    const size = types.sizeOf(inst.ty);
                    try mblock.instrs.append(.{ .alloca = .{ .size = size, .dst = .{ .vreg = result } } });
                },

                .load => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    const load_size = memSizeOfType(types, inst.ty);
                    try mblock.instrs.append(.{ .load = .{ .dst = .{ .vreg = result }, .ptr = .{ .vreg = inst.operands[0] }, .size = load_size } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .store => {
                    if (inst.operands.len < 2) continue;
                    const val_ty = inst.ty;
                    const store_size = memSizeOfType(types, val_ty);
                    try mblock.instrs.append(.{ .store = .{ .ptr = .{ .vreg = inst.operands[0] }, .src = .{ .vreg = inst.operands[1] }, .size = store_size } });
                },

                .fadd => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    try mblock.instrs.append(.{ .fadd = .{ .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .fsub => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    try mblock.instrs.append(.{ .fsub = .{ .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .fmul => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    try mblock.instrs.append(.{ .fmul = .{ .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .fdiv => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    try mblock.instrs.append(.{ .fdiv = .{ .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .fneg => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    try mblock.instrs.append(.{ .fneg_op = .{ .dst = .{ .vreg = result } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .sitofp => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    try mblock.instrs.append(.{ .sitofp = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = inst.operands[0] } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .fptosi => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    try mblock.instrs.append(.{ .fptosi = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = inst.operands[0] } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .fpext => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    try mblock.instrs.append(.{ .fpext = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = inst.operands[0] } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .fptrunc => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    try mblock.instrs.append(.{ .fptrunc = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = inst.operands[0] } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .feq => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .fcmp = .{ .cc = .eq, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                },
                .fne => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .fcmp = .{ .cc = .ne, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                },
                .flt => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .fcmp = .{ .cc = .lt, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                },
                .fle => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .fcmp = .{ .cc = .le, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                },
                .fgt => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .fcmp = .{ .cc = .gt, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                },
                .fge => if (result != NO_VALUE and inst.operands.len >= 2) {
                    try mblock.instrs.append(.{ .fcmp = .{ .cc = .ge, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                },

                .and_op => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    const lhs = inst.operands[0];
                    const rhs = inst.operands[1];
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = lhs } } });
                    try mblock.instrs.append(.{ .@"and" = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = rhs } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .or_op => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    const lhs = inst.operands[0];
                    const rhs = inst.operands[1];
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = lhs } } });
                    try mblock.instrs.append(.{ .@"or" = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = rhs } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .xor_op => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    const lhs = inst.operands[0];
                    const rhs = inst.operands[1];
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = lhs } } });
                    try mblock.instrs.append(.{ .xor = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = rhs } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .shl, .shr, .shra => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    const lhs = inst.operands[0];
                    const rhs = inst.operands[1];
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = lhs } } });
                    const shift_inst: mir.MInst = if (inst.op == .shl) .{ .shl = .{ .dst = .{ .vreg = result }, .amount = .{ .vreg = rhs }, .uses_cl = false } } else if (inst.op == .shr) .{ .shr = .{ .dst = .{ .vreg = result }, .amount = .{ .vreg = rhs }, .uses_cl = false } } else .{ .sar = .{ .dst = .{ .vreg = result }, .amount = .{ .vreg = rhs }, .uses_cl = false } };
                    try mblock.instrs.append(shift_inst);
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .not => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    const src = inst.operands[0];
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = src }, .b = .{ .imm = 0 } } });
                    try mblock.instrs.append(.{ .setcc = .{ .dst = .{ .vreg = result }, .cc = .eq } });
                },

                .unreachable_op => {
                    try mblock.instrs.append(.trap);
                },

                .zext => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    try mblock.instrs.append(.{ .zext_op = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = inst.operands[0] } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .sext => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    try mblock.instrs.append(.{ .sext_op = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = inst.operands[0] } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                .trunc => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    try mblock.instrs.append(.{ .trunc_op = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = inst.operands[0] } } });
                    const dt = birTypeToDataType(types, inst.ty);
                    try mfunc.putVReg(result, dt);
                },

                else => {
                    if (@import("builtin").mode == .Debug) {
                        std.debug.print("Unsupported BIR operation in CPU backend: {s}\n", .{@tagName(inst.op)});
                    }
                    return error.UnsupportedBIRInstruction;
                },
            }
        }

        try mfunc.blocks.append(mblock);
    }

    return mfunc;
}

