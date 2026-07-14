const std = @import("std");
const bir = @import("bir.zig");
const mir = @import("mir.zig");
const Op = bir.Op;

const PhiMove = struct {
    pred_block: usize,
    dst: u32,
    src: u32,
};

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
    var phi_moves = std.ArrayList(PhiMove).init(allocator);
    defer phi_moves.deinit();

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
                    for (inc) |incoming| {
                        try phi_moves.append(.{
                            .pred_block = @intCast(incoming.block),
                            .dst = result,
                            .src = incoming.value,
                        });
                    }
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

                .eq => if (result != NO_VALUE and inst.operands.len >= 2) try mblock.instrs.append(.{ .cmp = .{ .cc = .eq, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } }),
                .ne => if (result != NO_VALUE and inst.operands.len >= 2) try mblock.instrs.append(.{ .cmp = .{ .cc = .ne, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } }),
                .lt => if (result != NO_VALUE and inst.operands.len >= 2) try mblock.instrs.append(.{ .cmp = .{ .cc = .lt, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } }),
                .le => if (result != NO_VALUE and inst.operands.len >= 2) try mblock.instrs.append(.{ .cmp = .{ .cc = .le, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } }),
                .gt => if (result != NO_VALUE and inst.operands.len >= 2) try mblock.instrs.append(.{ .cmp = .{ .cc = .gt, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } }),
                .ge => if (result != NO_VALUE and inst.operands.len >= 2) try mblock.instrs.append(.{ .cmp = .{ .cc = .ge, .dst = .{ .vreg = result }, .a = .{ .vreg = inst.operands[0] }, .b = .{ .vreg = inst.operands[1] } } }),

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
                        try mblock.instrs.append(.{ .ret = .{ .val = .{ .vreg = inst.operands[0] } } });
                    } else {
                        try mblock.instrs.append(.{ .ret = .{ .val = .{ .imm = 0 } } });
                    }
                },

                .call => {
                    if (inst.data != .named_call or result == NO_VALUE) continue;
                    const info = inst.data.named_call;
                    var args: [4]mir.MOperand = .{
                        .{ .imm = 0 }, .{ .imm = 0 },
                        .{ .imm = 0 }, .{ .imm = 0 },
                    };
                    const count = @min(@as(u32, @intCast(info.args.len)), 4);
                    for (0..count) |i| args[i] = .{ .vreg = info.args[i] };
                    try mblock.instrs.append(.{ .call = .{
                        .name = try allocator.dupe(u8, info.name),
                        .args = args,
                        .arg_count = count,
                        .dst = .{ .vreg = result },
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
                    try mblock.instrs.append(.{ .load = .{ .dst = .{ .vreg = result }, .ptr = .{ .vreg = inst.operands[0] } } });
                },

                .store => {
                    if (inst.operands.len < 2) continue;
                    try mblock.instrs.append(.{ .store = .{ .ptr = .{ .vreg = inst.operands[0] }, .src = .{ .vreg = inst.operands[1] } } });
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

    // Phi lowering: insert copy moves at end of predecessor blocks before terminators
    for (phi_moves.items) |pm| {
        if (pm.pred_block >= mfunc.blocks.items.len) continue;
        const pred = &mfunc.blocks.items[pm.pred_block];
        const copy_inst = mir.MInst{ .mov = .{ .dst = .{ .vreg = pm.dst }, .src = .{ .vreg = pm.src } } };
        // Find first terminator to insert before it
        var insert_idx: usize = pred.instrs.items.len;
        for (pred.instrs.items, 0..) |mi, i| {
            switch (mi) {
                .jmp, .jcc, .cmp_flags, .ret => {
                    insert_idx = i;
                    break;
                },
                else => {},
            }
        }
        try pred.instrs.insert(insert_idx, copy_inst);
    }

    return mfunc;
}
