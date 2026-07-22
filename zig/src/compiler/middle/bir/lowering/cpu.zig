const std = @import("std");
const bir = @import("../bir.zig");
const mir = @import("../../../backend/mir/mir.zig");
const Op = bir.Op;

const CmpDef = struct { op0: u32, op1: u32, cc: mir.CondCode };

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
    return mfuncs.toOwnedSlice();
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

                .eq => if (result != NO_VALUE and inst.operands.len >= 2) blk: {
                    const tmp = allocValue(&next_vreg);
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .imm = 0 } } });
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = tmp }, .src = .{ .imm = 1 } } });
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .select = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = tmp }, .cc = .eq } });
                    break :blk;
                },
                .ne => if (result != NO_VALUE and inst.operands.len >= 2) blk: {
                    const tmp = allocValue(&next_vreg);
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .imm = 0 } } });
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = tmp }, .src = .{ .imm = 1 } } });
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .select = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = tmp }, .cc = .ne } });
                    break :blk;
                },
                .lt => if (result != NO_VALUE and inst.operands.len >= 2) blk: {
                    const tmp = allocValue(&next_vreg);
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .imm = 0 } } });
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = tmp }, .src = .{ .imm = 1 } } });
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .select = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = tmp }, .cc = .lt } });
                    break :blk;
                },
                .le => if (result != NO_VALUE and inst.operands.len >= 2) blk: {
                    const tmp = allocValue(&next_vreg);
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .imm = 0 } } });
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = tmp }, .src = .{ .imm = 1 } } });
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .select = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = tmp }, .cc = .le } });
                    break :blk;
                },
                .gt => if (result != NO_VALUE and inst.operands.len >= 2) blk: {
                    const tmp = allocValue(&next_vreg);
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .imm = 0 } } });
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = tmp }, .src = .{ .imm = 1 } } });
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .select = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = tmp }, .cc = .gt } });
                    break :blk;
                },
                .ge => if (result != NO_VALUE and inst.operands.len >= 2) blk: {
                    const tmp = allocValue(&next_vreg);
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = result }, .src = .{ .imm = 0 } } });
                    try mblock.instrs.append(.{ .mov = .{ .dst = .{ .vreg = tmp }, .src = .{ .imm = 1 } } });
                    try mblock.instrs.append(.{ .cmp_flags = .{ .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } });
                    try mblock.instrs.append(.{ .select = .{ .dst = .{ .vreg = result }, .src = .{ .vreg = tmp }, .cc = .ge } });
                    break :blk;
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
                    const ty = types.get(inst.ty);
                    const elem_ty = ty.kind.pointer.elem;
                    const size = types.sizeOf(elem_ty);
                    try mblock.instrs.append(.{ .alloca = .{ .size = size, .dst = .{ .vreg = result } } });
                },

                .load => {
                    if (result == NO_VALUE or inst.operands.len < 1) continue;
                    try mblock.instrs.append(.{ .load = .{ .dst = .{ .vreg = result }, .ptr = .{ .vreg = inst.operands[0] }, .size = .u64 } });
                },

                .store => {
                    if (inst.operands.len < 2) continue;
                    try mblock.instrs.append(.{ .store = .{ .ptr = .{ .vreg = inst.operands[0] }, .src = .{ .vreg = inst.operands[1] }, .size = .u64 } });
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
