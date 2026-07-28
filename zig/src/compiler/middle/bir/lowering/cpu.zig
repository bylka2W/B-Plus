const std = @import("std");
const bir = @import("../bir.zig");
const mir = @import("../../../backend/mir/mir.zig");
const Op = bir.Op;

const CmpDef = struct { op0: u32, op1: u32, cc: mir.CondCode };

fn sizeToMemSize(size: u32) mir.MemSize {
    return switch (size) {
        1 => .u8,
        2 => .u16,
        4 => .u32,
        8 => .u64,
        else => .u64,
    };
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

pub fn lowerStateMachine(allocator: std.mem.Allocator, mod: *const bir.Module, sm: *const bir.StateMachine) !mir.MFunction {
    var mfunc = mir.MFunction.init(allocator, sm.name);
    errdefer mfunc.deinit();
    var next_vreg: u32 = 1;

    const state_slot = allocVreg(&next_vreg);  // vreg 1 = state slot

    const init_st = &sm.states.items[sm.initial_state_idx];

    // Block 0: entry — state_init, enter initial state, call entry function
    {
        var block = mir.MBlock{ .label = try allocator.dupe(u8, "entry"), .instrs = std.ArrayList(mir.MInst).init(allocator) };
        errdefer { allocator.free(block.label); block.instrs.deinit(); }

        try block.instrs.append(.{ .alloca = .{ .size = 8, .dst = .{ .vreg = state_slot } } });
        try block.instrs.append(.{ .state_init = .{ .initial_state = .{ .imm = @as(i64, @intCast(sm.initial_state_idx)) } } });
        try block.instrs.append(.{ .state_enter = .{ .state_id = .{ .imm = @as(i64, @intCast(sm.initial_state_idx)) } } });

        const entry_name = try std.fmt.allocPrint(allocator, "state_{s}_entry", .{init_st.name});
        const cargs: [14]mir.MOperand = @splat(.{ .imm = 0 });
        try block.instrs.append(.{ .call = .{ .name = entry_name, .args = cargs, .arg_count = 0, .dst = .{ .imm = 0 }, .is_void = true } });

        try block.instrs.append(.{ .jmp = .{ .target = 1 } });
        try mfunc.blocks.append(block);
    }

    // Block 1: event_loop — dispatch event, check transitions via cmp+jcc
    {
        var block = mir.MBlock{ .label = try allocator.dupe(u8, "event_loop"), .instrs = std.ArrayList(mir.MInst).init(allocator) };
        errdefer { allocator.free(block.label); block.instrs.deinit(); }

        const event_val = allocVreg(&next_vreg);
        const buf_val = allocVreg(&next_vreg);
        const size_val = allocVreg(&next_vreg);
        try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = buf_val }, .src = .{ .imm = 0 } } });
        try block.instrs.append(.{ .mov = .{ .dst = .{ .vreg = size_val }, .src = .{ .imm = 0 } } });
        try block.instrs.append(.{ .event_dispatch = .{ .dst = .{ .vreg = event_val }, .buf = .{ .vreg = buf_val }, .size = .{ .vreg = size_val } } });

        // For each transition: cmp event, event_id → jcc to transition block
        for (sm.transitions.items, 0..) |t, ti| {
            const block_idx: u32 = @as(u32, @intCast(2 + ti));
            _ = try allocator.dupe(u8, "");  // keep errdefer happy — no free needed
            try block.instrs.append(.{ .cmp = .{ .cc = .eq, .a = .{ .vreg = event_val }, .b = .{ .imm = @as(i64, @intCast(t.event_id)) } } });
            try block.instrs.append(.{ .jcc = .{ .cc = .eq, .target = block_idx } });
        }

        try block.instrs.append(.{ .jmp = .{ .target = 1 } });
        try mfunc.blocks.append(block);
    }

    // Blocks 2+: transition blocks — state_exit, state_enter, call action, jmp back
    for (sm.transitions.items, 0..) |t, ti| {
        var block = mir.MBlock{ .label = try std.fmt.allocPrint(allocator, "trans_{d}", .{ti}), .instrs = std.ArrayList(mir.MInst).init(allocator) };
        errdefer { allocator.free(block.label); block.instrs.deinit(); }

        try block.instrs.append(.{ .state_exit = .{ .state_id = .{ .imm = @as(i64, @intCast(t.from_state_idx)) } } });
        try block.instrs.append(.{ .state_enter = .{ .state_id = .{ .imm = @as(i64, @intCast(t.to_state_idx)) } } });

        if (t.action_fn) |af| {
            const act_name = try allocator.dupe(u8, mod.functions.items[af].name);
            const aargs: [14]mir.MOperand = @splat(.{ .imm = 0 });
            try block.instrs.append(.{ .call = .{ .name = act_name, .args = aargs, .arg_count = 0, .dst = .{ .imm = 0 }, .is_void = true } });
        }

        try block.instrs.append(.{ .jmp = .{ .target = 1 } });
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
    var mfunc = mir.MFunction.init(allocator, bir_func.name);
    errdefer mfunc.deinit();

    // Convert BIR function params to MIR params
    if (bir_func.param_values.len > 0) {
        const mir_params = try allocator.alloc(mir.MOperand, bir_func.param_values.len);
        for (bir_func.param_values, 0..) |pv, i| {
            mir_params[i] = .{ .vreg = pv };
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
                    const val = switch (inst.data) {
                        .const_data => |cd| switch (cd) {
                            .int => |v| @as(i64, v),
                            .float => |v| @as(i64, @intCast(@as(i64, @intFromFloat(v)))),
                            .bool => |v| @as(i64, @intFromBool(v)),
                            .undefined, .zero => 0,
                        },
                        else => 0,
                    };
                    try mblock.instrs.append(.{ .mov = .{
                        .dst = .{ .vreg = result },
                        .src = .{ .imm = val },
                    } });
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
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = lhs } } });
                    try mblock.instrs.append(.{ .idiv = .{ .dividend = .{ .vreg = result }, .divisor = .{ .vreg = rhs }, .quotient = .{ .vreg = result }, .remainder = .{ .vreg = rem } } });
                },

                .mod => {
                    if (result == NO_VALUE or inst.operands.len < 2) continue;
                    const lhs = inst.operands[0];
                    const rhs = inst.operands[1];
                    const q = allocValue(&next_vreg);
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = q }, .src = .{ .vreg = lhs } } });
                    try mblock.instrs.append(.{ .idiv = .{ .dividend = .{ .vreg = q }, .divisor = .{ .vreg = rhs }, .quotient = .{ .vreg = q }, .remainder = .{ .vreg = result } } });
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
                        try mblock.instrs.append(.{ .ret = .{ .value = .{ .vreg = inst.operands[0] } } });
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
                    for (0..count) |i| args[i] = .{ .vreg = info.args[i] };
                    try mblock.instrs.append(.{ .call = .{
                        .name = try allocator.dupe(u8, info.name),
                        .args = args,
                        .arg_count = count,
                        .dst = .{ .vreg = result },
                        .is_void = false,
                    } });
                },

                .alloca => {
                    if (result == NO_VALUE) continue;
                    const size = types.sizeOf(inst.ty);
                    try mblock.instrs.append(.{ .alloca = .{ .size = size, .dst = .{ .vreg = result } } });
                },

                .load => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    const load_size = sizeToMemSize(types.sizeOf(inst.ty));
                    try mblock.instrs.append(.{ .load = .{ .dst = .{ .vreg = result }, .ptr = .{ .vreg = inst.operands[0] }, .size = load_size } });
                },

                .store => {
                    if (inst.operands.len < 2) continue;
                    const val_ty = inst.ty;
                    const store_size = sizeToMemSize(types.sizeOf(val_ty));
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
