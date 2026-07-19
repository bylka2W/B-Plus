const std = @import("std");
const mir = @import("mir.zig");
const mir_verify = @import("mir_verify.zig");
const mir_optimizer = @import("mir_optimizer.zig");
const x64 = @import("../x64/x64enc.zig");
const regalloc = @import("../x64/regalloc.zig");

const OffsetMap = std.AutoHashMap(u32, i32);

pub const EmitResult = struct {
    code: std.ArrayList(u8),
    entry_offset: usize,
};

const Fixup = struct {
    disp_pos: usize,
    target: usize,
};

const CallFixup = struct {
    name: []const u8,
    disp_pos: usize,
};

pub fn emitModule(mfuncs: []const mir.MFunction) !EmitResult {
    var result = try emitCode(mfuncs);
    defer result.call_fixups.deinit();
    defer result.func_starts.deinit();
    defer result.name_to_offset.deinit();

    var code = result.code;

    for (result.call_fixups.items) |cf| {
        const target_off = result.name_to_offset.get(cf.name) orelse {
            std.debug.print("unresolved call target: {s}\n", .{cf.name});
            return error.UnresolvedCallTarget;
        };
        const disp: i32 = @intCast(@as(i64, @intCast(target_off)) - @as(i64, @intCast(cf.disp_pos + 4)));
        @memcpy(code.items[cf.disp_pos..][0..4], &@as([4]u8, @bitCast(disp)));
    }

    const entry = result.name_to_offset.get("main") orelse result.func_starts.items[0];
    return .{ .code = code, .entry_offset = entry };
}

pub const EmitCodeResult = struct {
    code: std.ArrayList(u8),
    name_to_offset: std.StringHashMap(usize),
    call_fixups: std.ArrayList(CallFixup),
    func_starts: std.ArrayList(usize),
};

pub fn emitCode(mfuncs: []const mir.MFunction) !EmitCodeResult {
    if (mfuncs.len == 0) return error.NoFunctions;
    const allocator = mfuncs[0].allocator;

    for (mfuncs) |*mf| try mir_verify.verifyMir(mf);
    for (mfuncs) |*mf| try mir_optimizer.optimize(@constCast(mf));

    var code = std.ArrayList(u8).init(allocator);
    errdefer code.deinit();
    var name_to_offset = std.StringHashMap(usize).init(allocator);
    var all_call_fixups = std.ArrayList(CallFixup).init(allocator);
    var func_starts = std.ArrayList(usize).init(allocator);
    errdefer {
        name_to_offset.deinit();
        all_call_fixups.deinit();
        func_starts.deinit();
    }

    for (mfuncs) |*mf| {
        const func_start = code.items.len;
        try func_starts.append(func_start);
        try name_to_offset.put(mf.name, func_start);
        try emitSingleFunction(&code, &all_call_fixups, mf);
    }

    return .{
        .code = code,
        .name_to_offset = name_to_offset,
        .call_fixups = all_call_fixups,
        .func_starts = func_starts,
    };
}

pub fn emitSingleFunction(
    code: *std.ArrayList(u8),
    call_fixups: *std.ArrayList(CallFixup),
    mfunc: *const mir.MFunction,
) !void {
    const ra = try regalloc.allocRegs(mfunc, mfunc.allocator);
    const scratch: i16 = 11; // r11 reserved for spill scratch

    var block_offsets = std.ArrayList(usize).init(mfunc.allocator);
    defer block_offsets.deinit();

    var fixups = std.ArrayList(Fixup).init(mfunc.allocator);
    defer fixups.deinit();

    var alloca_offsets = OffsetMap.init(mfunc.allocator);
    defer alloca_offsets.deinit();

    var frame_size: u32 = 0;
    for (mfunc.blocks.items) |*block| {
        for (block.instrs.items) |inst| {
            if (inst == .alloca) {
                const aligned = (inst.alloca.size + 15) & ~@as(u32, 15);
                frame_size += aligned;
                const off: i32 = @intCast(-@as(i32, @intCast(frame_size)));
                try alloca_offsets.put(switch (inst.alloca.dst) { .vreg => |v| v, else => 0 }, off);
            }
        }
    }

    const spill_off = ra.spill_frame_size;
    if (spill_off > 0) {
        frame_size += @max(spill_off, 8);
    }

    var used_callee_saved = std.ArrayList(i16).init(mfunc.allocator);
    defer used_callee_saved.deinit();
    regalloc.getUsedCalleeSaved(&ra, &used_callee_saved);

    const push_count: u32 = 1 + @as(u32, @intCast(used_callee_saved.items.len));
    const aligned_frame = (frame_size + 7) & ~@as(u32, 7);
    const total_prologue = push_count * 8 + aligned_frame;
    const final_frame = if (total_prologue % 16 == 0) aligned_frame else aligned_frame + 8;

    try x64.emit(code, .PUSH_R64, &.{.{ .reg = 5 }});
    for (used_callee_saved.items) |reg| {
        try x64.emit(code, .PUSH_R64, &.{.{ .reg = reg }});
    }
    try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = 5 }, .{ .reg = 4 } });
    if (final_frame > 0) {
        try x64.emit(code, .SUB_R64_IMM32, &.{ .{ .reg = 4 }, .{ .imm64 = final_frame } });
    }

    const win64_arg_regs = [_]i16{ 1, 2, 8, 9 };
    for (mfunc.params, 0..) |p, i| {
        if (i >= 4) break;
        const vreg = switch (p) { .vreg => |v| v, else => continue };
        const dst = ra.regs.get(vreg) orelse continue;
        if (dst != win64_arg_regs[i]) {
            try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = dst }, .{ .reg = win64_arg_regs[i] } });
        }
    }

    for (mfunc.blocks.items) |*block| {
        try block_offsets.append(code.items.len);

        for (block.instrs.items) |inst| {
            switch (inst) {
                .mov => |m| try emitMov(code, &ra, m, scratch),
                .add => |a| try emitAdd(code, &ra, a, scratch),
                .sub => |s| try emitSub(code, &ra, s, scratch),
                .imul => |m| try emitIMul(code, &ra, m, scratch),
                .idiv => |m| try emitIDiv(code, &ra, m, scratch),
                .cmp => |c| try emitCmp(code, &ra, c, scratch),
                .cmp_flags => |cf| try emitCmpFlags(code, &ra, cf, scratch),
                .jmp => |j| {
                    const pos = code.items.len;
                    try x64.emit(code, .JMP_REL32, &.{.{ .imm64 = 0 }});
                    try fixups.append(.{ .disp_pos = pos + 1, .target = j.target });
                },
                .jcc => |j| {
                    const pos = code.items.len;
                    const jcc_op = condToJccOp(j.cc);
                    try x64.emit(code, jcc_op, &.{.{ .imm64 = 0 }});
                    try fixups.append(.{ .disp_pos = pos + 2, .target = j.target });
                },
                .alloca => |a| try emitAlloca(code, &ra, a, alloca_offsets, scratch),
                .load => |l| try emitLoad(code, &ra, l, scratch),
                .store => |s| try emitStore(code, &ra, s, scratch),
                .call => |c| try emitCall(code, call_fixups, &ra, c, scratch),
                .ret => |r| try emitRet(code, &ra, r, scratch, used_callee_saved.items),
                .phi => unreachable,
            }
        }
    }

    for (fixups.items) |fx| {
        const target_off = block_offsets.items[fx.target];
        const disp: i32 = @intCast(@as(i64, @intCast(target_off)) - @as(i64, @intCast(fx.disp_pos + 4)));
        @memcpy(code.items[fx.disp_pos..][0..4], &@as([4]u8, @bitCast(disp)));
    }
}

fn resolveReg(ra: *const regalloc.RegAllocResult, op: mir.MOperand) i16 {
    return regalloc.regForOp(ra, op);
}

fn resolveOp(ra: *const regalloc.RegAllocResult, op: mir.MOperand) x64.Operand {
    return switch (op) {
        .vreg => |v| blk: {
            if (ra.regs.get(v)) |r| break :blk .{ .reg = r };
            break :blk .{ .reg = -1 };
        },
        .phys => |r| .{ .reg = @intFromEnum(r) },
        .imm => |v| x64.Operand.imm(v),
        .mem => |m| .{ .base_reg = @intFromEnum(m.base), .disp = m.offset },
    };
}

fn resolveOpOrSpill(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, op: mir.MOperand, scratch: i16) !x64.Operand {
    return switch (op) {
        .vreg => |v| blk: {
            if (ra.regs.get(v)) |r| break :blk .{ .reg = r };
            try regalloc.loadSpilledOp(code, ra, op, scratch);
            break :blk .{ .reg = scratch };
        },
        .phys => |r| .{ .reg = @intFromEnum(r) },
        .imm => |v| x64.Operand.imm(v),
        .mem => |m| .{ .base_reg = @intFromEnum(m.base), .disp = m.offset },
    };
}

fn emitMov(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, m: mir.MovInst, scratch: i16) !void {
    const dst_spilled = regalloc.isSpilled(ra, m.dst);
    const src_spilled = regalloc.isSpilled(ra, m.src);

    if (dst_spilled and src_spilled) {
        try regalloc.loadSpilledOp(code, ra, m.src, scratch);
        try regalloc.storeSpilledOp(code, ra, m.dst, scratch);
    } else if (dst_spilled) {
        const src_val = try resolveOpOrSpill(code, ra, m.src, scratch);
        const val_reg = if (src_val.reg >= 0) src_val.reg else scratch;
        if (src_val.reg < 0) {
            try x64.emit(code, .MOV_R64_IMM64, &.{ .{ .reg = scratch }, src_val });
        }
        try regalloc.storeSpilledOp(code, ra, m.dst, if (src_val.reg >= 0) val_reg else scratch);
    } else if (src_spilled) {
        try regalloc.loadSpilledOp(code, ra, m.src, scratch);
        const dst = resolveReg(ra, m.dst);
        try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = dst }, .{ .reg = scratch } });
    } else {
        const dst = resolveReg(ra, m.dst);
        const src = resolveOp(ra, m.src);
        if (src.reg >= 0) {
            if (dst == src.reg) return;
            try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = dst }, src });
        } else {
            try x64.emit(code, .MOV_R64_IMM64, &.{ .{ .reg = dst }, src });
        }
    }
}

fn emitAdd(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, a: mir.AddInst, scratch: i16) !void {
    const dst_spilled = regalloc.isSpilled(ra, a.dst);
    const src_spilled = regalloc.isSpilled(ra, a.src);

    if (dst_spilled and src_spilled) {
        try regalloc.loadSpilledOp(code, ra, a.dst, scratch);
        const src_mem = regalloc.spilledMemOp(ra, a.src);
        try x64.emit(code, .ADD_R64_MEM, &.{ .{ .reg = scratch }, src_mem });
        try regalloc.storeSpilledOp(code, ra, a.dst, scratch);
    } else if (dst_spilled) {
        try regalloc.loadSpilledOp(code, ra, a.dst, scratch);
        const src_val = try resolveOpOrSpill(code, ra, a.src, scratch);
        if (src_val.reg >= 0) {
            if (src_val.reg == scratch) {
                try x64.emit(code, .ADD_R64_R64, &.{ .{ .reg = scratch }, .{ .reg = scratch } });
            } else {
                try x64.emit(code, .ADD_R64_R64, &.{ .{ .reg = scratch }, src_val });
            }
        } else {
            try x64.emit(code, .ADD_R64_IMM32, &.{ .{ .reg = scratch }, src_val });
        }
        try regalloc.storeSpilledOp(code, ra, a.dst, scratch);
    } else if (src_spilled) {
        const dst = resolveReg(ra, a.dst);
        try regalloc.loadSpilledOp(code, ra, a.src, scratch);
        try x64.emit(code, .ADD_R64_R64, &.{ .{ .reg = dst }, .{ .reg = scratch } });
    } else {
        const dst = resolveReg(ra, a.dst);
        const src_val = resolveOp(ra, a.src);
        switch (a.src) {
            .imm => try x64.emit(code, .ADD_R64_IMM32, &.{ .{ .reg = dst }, src_val }),
            else => try x64.emit(code, .ADD_R64_R64, &.{ .{ .reg = dst }, src_val }),
        }
    }
}

fn emitSub(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, s: mir.SubInst, scratch: i16) !void {
    const dst_spilled = regalloc.isSpilled(ra, s.dst);
    const src_spilled = regalloc.isSpilled(ra, s.src);

    if (dst_spilled and src_spilled) {
        try regalloc.loadSpilledOp(code, ra, s.dst, scratch);
        const src_mem = regalloc.spilledMemOp(ra, s.src);
        try x64.emit(code, .SUB_R64_MEM, &.{ .{ .reg = scratch }, src_mem });
        try regalloc.storeSpilledOp(code, ra, s.dst, scratch);
    } else if (dst_spilled) {
        try regalloc.loadSpilledOp(code, ra, s.dst, scratch);
        const src_val = try resolveOpOrSpill(code, ra, s.src, scratch);
        if (src_val.reg >= 0) {
            if (src_val.reg == scratch) {
                try x64.emit(code, .SUB_R64_R64, &.{ .{ .reg = scratch }, .{ .reg = scratch } });
            } else {
                try x64.emit(code, .SUB_R64_R64, &.{ .{ .reg = scratch }, src_val });
            }
        } else {
            try x64.emit(code, .SUB_R64_IMM32, &.{ .{ .reg = scratch }, src_val });
        }
        try regalloc.storeSpilledOp(code, ra, s.dst, scratch);
    } else if (src_spilled) {
        const dst = resolveReg(ra, s.dst);
        try regalloc.loadSpilledOp(code, ra, s.src, scratch);
        try x64.emit(code, .SUB_R64_R64, &.{ .{ .reg = dst }, .{ .reg = scratch } });
    } else {
        const dst = resolveReg(ra, s.dst);
        const src_val = resolveOp(ra, s.src);
        switch (s.src) {
            .imm => try x64.emit(code, .SUB_R64_IMM32, &.{ .{ .reg = dst }, src_val }),
            else => try x64.emit(code, .SUB_R64_R64, &.{ .{ .reg = dst }, src_val }),
        }
    }
}

fn emitIMul(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, m: mir.IMulInst, scratch: i16) !void {
    const dst_spilled = regalloc.isSpilled(ra, m.dst);
    const src_spilled = regalloc.isSpilled(ra, m.src);

    if (dst_spilled and src_spilled) {
        try regalloc.loadSpilledOp(code, ra, m.dst, scratch);
        const src_mem = regalloc.spilledMemOp(ra, m.src);
        try x64.emit(code, .IMUL_R64_R64, &.{ .{ .reg = scratch }, src_mem });
        try regalloc.storeSpilledOp(code, ra, m.dst, scratch);
    } else if (dst_spilled) {
        try regalloc.loadSpilledOp(code, ra, m.dst, scratch);
        const src_val = try resolveOpOrSpill(code, ra, m.src, scratch);
        if (src_val.reg >= 0) {
            try x64.emit(code, .IMUL_R64_R64, &.{ .{ .reg = scratch }, src_val });
        } else {
            try x64.emit(code, .IMUL_R64_IMM32, &.{ .{ .reg = scratch }, .{ .reg = scratch, .imm64 = src_val.imm64 } });
        }
        try regalloc.storeSpilledOp(code, ra, m.dst, scratch);
    } else if (src_spilled) {
        const dst = resolveReg(ra, m.dst);
        try regalloc.loadSpilledOp(code, ra, m.src, scratch);
        try x64.emit(code, .IMUL_R64_R64, &.{ .{ .reg = dst }, .{ .reg = scratch } });
    } else {
        const dst = resolveReg(ra, m.dst);
        const src_val = resolveOp(ra, m.src);
        switch (m.src) {
            .imm => try x64.emit(code, .IMUL_R64_IMM32, &.{ .{ .reg = dst }, .{ .reg = dst, .imm64 = src_val.imm64 } }),
            else => try x64.emit(code, .IMUL_R64_R64, &.{ .{ .reg = dst }, src_val }),
        }
    }
}

fn emitIDiv(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, m: mir.IDivInst, scratch: i16) !void {
    const dst_spilled = regalloc.isSpilled(ra, m.dst);

    // IDIV implicitly uses RAX (dividend lsb, quotient) and RDX (dividend msb, remainder).
    // The allocator may have assigned RAX/RDX to live vregs, so save them.
    // When dst is RAX, don't save/restore it (quotient lives in RAX naturally).
    const dst_reg = if (dst_spilled) -1 else resolveReg(ra, m.dst);
    const dst_is_rax = !dst_spilled and dst_reg == 0;

    if (!dst_is_rax) {
        try x64.emit(code, .PUSH_R64, &.{.{ .reg = 0 }});
    }
    try x64.emit(code, .PUSH_R64, &.{.{ .reg = 2 }});

    const raw_src = try resolveOpOrSpill(code, ra, m.src, scratch);
    const src_val = if (raw_src.reg >= 0 or raw_src.base_reg >= 0 or raw_src.index_reg >= 0) raw_src else blk: {
        try x64.emit(code, .MOV_R64_IMM64, &.{ .{ .reg = scratch }, raw_src });
        break :blk x64.Operand.r(scratch);
    };

    if (dst_spilled) {
        try regalloc.loadSpilledOp(code, ra, m.dst, 0);
    } else if (!dst_is_rax) {
        try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = 0 }, .{ .reg = dst_reg } });
    }

    try x64.emit(code, .CQO, &.{});
    try x64.emit(code, .IDIV_R64, &.{src_val});

    if (!dst_is_rax) {
        try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = scratch }, .{ .reg = 0 } });
    }
    try x64.emit(code, .POP_R64, &.{.{ .reg = 2 }});
    if (!dst_is_rax) {
        try x64.emit(code, .POP_R64, &.{.{ .reg = 0 }});
        if (dst_spilled) {
            try regalloc.storeSpilledOp(code, ra, m.dst, scratch);
        } else if (dst_reg != 0) {
            try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = dst_reg }, .{ .reg = scratch } });
        }
    }
}

fn emitCmp(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, c: mir.CmpInst, scratch: i16) !void {
    const dst_spilled = regalloc.isSpilled(ra, c.dst);
    const a_spilled = regalloc.isSpilled(ra, c.a);
    const b_spilled = regalloc.isSpilled(ra, c.b);

    if (a_spilled and b_spilled) {
        try regalloc.loadSpilledOp(code, ra, c.a, scratch);
        const b_mem = regalloc.spilledMemOp(ra, c.b);
        try x64.emit(code, .CMP_R64_MEM, &.{ .{ .reg = scratch }, b_mem });
    } else if (a_spilled) {
        const av = try resolveOpOrSpill(code, ra, c.a, scratch);
        const bv = try resolveOpOrSpill(code, ra, c.b, scratch);
        try x64.emit(code, .CMP_R64_R64, &.{ av, bv });
    } else if (b_spilled) {
        const av = try resolveOpOrSpill(code, ra, c.a, scratch);
        const b_mem = regalloc.spilledMemOp(ra, c.b);
        try x64.emit(code, .CMP_R64_MEM, &.{ av, b_mem });
    } else {
        const av = try resolveOpOrSpill(code, ra, c.a, scratch);
        const bv = try resolveOpOrSpill(code, ra, c.b, scratch);
        try x64.emit(code, .CMP_R64_R64, &.{ av, bv });
    }

    try x64.emit(code, .MOV_R64_IMM64, &.{ .{ .reg = scratch }, .{ .imm64 = 0 } });
    try x64.emit(code, .SETCC_R8, &.{ .{ .reg = scratch }, .{ .imm64 = @intFromEnum(c.cc) } });
    if (dst_spilled) {
        try regalloc.storeSpilledOp(code, ra, c.dst, scratch);
    } else {
        const dst = resolveReg(ra, c.dst);
        if (dst != scratch) {
            try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = dst }, .{ .reg = scratch } });
        }
    }
}

fn emitCmpFlags(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, cf: mir.CmpFlagsInst, scratch: i16) !void {
    const a_spilled = regalloc.isSpilled(ra, cf.a);
    const b_spilled = regalloc.isSpilled(ra, cf.b);

    if (a_spilled and b_spilled) {
        try regalloc.loadSpilledOp(code, ra, cf.a, scratch);
        const b_mem = regalloc.spilledMemOp(ra, cf.b);
        try x64.emit(code, .CMP_R64_MEM, &.{ .{ .reg = scratch }, b_mem });
        return;
    }

    if (a_spilled) {
        const av = try resolveOpOrSpill(code, ra, cf.a, scratch);
        const bv = try resolveOpOrSpill(code, ra, cf.b, scratch);
        if (bv.reg >= 0) {
            try x64.emit(code, .CMP_R64_R64, &.{ av, bv });
        } else {
            try x64.emit(code, .CMP_R64_IMM32, &.{ av, bv });
        }
        return;
    }

    if (b_spilled) {
        const av = try resolveOpOrSpill(code, ra, cf.a, scratch);
        const b_mem = regalloc.spilledMemOp(ra, cf.b);
        try x64.emit(code, .CMP_R64_MEM, &.{ av, b_mem });
        return;
    }

    const a_val = try resolveOpOrSpill(code, ra, cf.a, scratch);
    const b_val = try resolveOpOrSpill(code, ra, cf.b, scratch);

    if (b_val.reg >= 0) {
        if (a_val.reg >= 0) {
            try x64.emit(code, .CMP_R64_R64, &.{ a_val, b_val });
        } else {
            try x64.emit(code, .CMP_R64_IMM32, &.{ b_val, a_val });
        }
    } else {
        if (a_val.reg >= 0) {
            try x64.emit(code, .CMP_R64_IMM32, &.{ a_val, b_val });
        } else {
            try x64.emit(code, .MOV_R64_IMM64, &.{ .{ .reg = scratch }, a_val });
            try x64.emit(code, .CMP_R64_IMM32, &.{ .{ .reg = scratch }, b_val });
        }
    }
}

fn emitAlloca(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, a: mir.AllocaInst, alloca_offsets: OffsetMap, scratch: i16) !void {
    const off = alloca_offsets.get(switch (a.dst) { .vreg => |v| v, else => 0 }) orelse 0;
    const dst_spilled = regalloc.isSpilled(ra, a.dst);

    if (dst_spilled) {
        try x64.emit(code, .LEA_R64_MEM, &.{ .{ .reg = scratch }, .{ .base_reg = 5, .disp = off } });
        try regalloc.storeSpilledOp(code, ra, a.dst, scratch);
    } else {
        const dst = resolveReg(ra, a.dst);
        try x64.emit(code, .LEA_R64_MEM, &.{ .{ .reg = dst }, .{ .base_reg = 5, .disp = off } });
    }
}

fn emitLoad(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, l: mir.LoadInst, scratch: i16) !void {
    const dst_spilled = regalloc.isSpilled(ra, l.dst);
    const ptr_spilled = regalloc.isSpilled(ra, l.ptr);

    if (ptr_spilled) {
        try regalloc.loadSpilledOp(code, ra, l.ptr, scratch);
        if (dst_spilled) {
            try x64.emit(code, .MOV_R64_MEM, &.{ .{ .reg = scratch }, .{ .base_reg = scratch, .disp = 0 } });
            try regalloc.storeSpilledOp(code, ra, l.dst, scratch);
        } else {
            const dst = resolveReg(ra, l.dst);
            try x64.emit(code, .MOV_R64_MEM, &.{ .{ .reg = dst }, .{ .base_reg = scratch, .disp = 0 } });
        }
    } else {
        const ptr_reg = resolveReg(ra, l.ptr);
        if (dst_spilled) {
            try x64.emit(code, .MOV_R64_MEM, &.{ .{ .reg = scratch }, .{ .base_reg = ptr_reg, .disp = 0 } });
            try regalloc.storeSpilledOp(code, ra, l.dst, scratch);
        } else {
            const dst = resolveReg(ra, l.dst);
            try x64.emit(code, .MOV_R64_MEM, &.{ .{ .reg = dst }, .{ .base_reg = ptr_reg, .disp = 0 } });
        }
    }
}

fn emitStore(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, s: mir.StoreInst, scratch: i16) !void {
    const ptr_spilled = regalloc.isSpilled(ra, s.ptr);
    const src_spilled = regalloc.isSpilled(ra, s.src);

    if (ptr_spilled) {
        try regalloc.loadSpilledOp(code, ra, s.ptr, scratch);
        const src_val = try resolveOpOrSpill(code, ra, s.src, scratch);
        try x64.emit(code, .MOV_MEM_R64, &.{ .{ .base_reg = scratch, .disp = 0 }, src_val });
    } else if (src_spilled) {
        try regalloc.loadSpilledOp(code, ra, s.src, scratch);
        const ptr_reg = resolveReg(ra, s.ptr);
        try x64.emit(code, .MOV_MEM_R64, &.{ .{ .base_reg = ptr_reg, .disp = 0 }, .{ .reg = scratch } });
    } else {
        const ptr_reg = resolveReg(ra, s.ptr);
        const src_val = resolveOp(ra, s.src);
        try x64.emit(code, .MOV_MEM_R64, &.{ .{ .base_reg = ptr_reg, .disp = 0 }, src_val });
    }
}

fn emitCall(code: *std.ArrayList(u8), call_fixups: *std.ArrayList(CallFixup), ra: *const regalloc.RegAllocResult, c: mir.CallInst, scratch: i16) !void {
    const win64_args = [_]i16{ 1, 2, 8, 9 };
    var src_regs: [4]i16 = .{ -1, -1, -1, -1 };

    for (0..c.arg_count) |i| {
        if (regalloc.isSpilled(ra, c.args[i])) {
            try regalloc.loadSpilledOp(code, ra, c.args[i], scratch);
            src_regs[i] = scratch;
        } else {
            src_regs[i] = resolveReg(ra, c.args[i]);
        }
    }

    for (0..c.arg_count) |i| {
        const src = src_regs[i];
        const dst = win64_args[i];
        if (src == dst) continue;
        for (0..c.arg_count) |j| {
            if (j != i and src == win64_args[j]) {
                try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = scratch }, .{ .reg = src } });
                src_regs[i] = scratch;
                break;
            }
        }
    }

    for (0..c.arg_count) |i| {
        const src = src_regs[i];
        const dst = win64_args[i];
        if (src != dst) try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = dst }, .{ .reg = src } });
    }

    try x64.emit(code, .SUB_R64_IMM32, &.{ .{ .reg = 4 }, .{ .imm64 = 32 } });
    const pos = code.items.len;
    try x64.emit(code, .CALL_REL32, &.{.{ .imm64 = 0 }});
    try call_fixups.append(.{ .name = c.name, .disp_pos = pos + 1 });
    try x64.emit(code, .ADD_R64_IMM32, &.{ .{ .reg = 4 }, .{ .imm64 = 32 } });

    const dst_spilled = regalloc.isSpilled(ra, c.dst);
    if (dst_spilled) {
        try regalloc.storeSpilledOp(code, ra, c.dst, 0);
    } else {
        const dst = resolveReg(ra, c.dst);
        if (dst != 0) try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = dst }, .{ .reg = 0 } });
    }
}

fn emitRet(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, r: mir.RetInst, _: i16, callee_saved: []const i16) !void {
    if (!r.is_void) {
        const val_spilled = regalloc.isSpilled(ra, r.val);
        if (val_spilled) {
            try regalloc.loadSpilledOp(code, ra, r.val, 0);
        } else {
            const val = resolveOp(ra, r.val);
            if (val.reg >= 0) {
                if (val.reg != 0) {
                    try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = 0 }, val });
                }
            } else {
                try x64.emit(code, .MOV_R64_IMM64, &.{ .{ .reg = 0 }, val });
            }
        }
    }
    try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = 4 }, .{ .reg = 5 } });
    var i: usize = callee_saved.len;
    while (i > 0) {
        i -= 1;
        try x64.emit(code, .POP_R64, &.{.{ .reg = callee_saved[i] }});
    }
    try x64.emit(code, .POP_R64, &.{.{ .reg = 5 }});
    try x64.emit(code, .RET, &.{});
}

fn condToJccOp(cc: mir.CondCode) x64.OpCode {
    return switch (cc) {
        .eq => .JE_REL32,
        .ne => .JNE_REL32,
        .lt => .JL_REL32,
        .le => .JLE_REL32,
        .gt => .JG_REL32,
        .ge => .JGE_REL32,
    };
}
