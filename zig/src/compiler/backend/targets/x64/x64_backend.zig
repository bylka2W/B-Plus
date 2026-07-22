/// x64 backend entry point.
/// Orchestrates the MIR → x86-64 machine code pipeline:
///   1. Frame layout
///   2. Register allocation
///   3. Instruction selection & encoding
///   4. Branch fixup resolution
const std = @import("std");
const mir = @import("../../mir/mir.zig");
const mir_verify = @import("../../mir/passes/verify.zig");
const mir_optimizer = @import("../../mir/passes/manager.zig");
const mir_ssa_destroy = @import("../../mir/passes/ssa/ssa_destroy.zig");

const encoder = @import("encoder.zig");
const OpCode = encoder.OpCode;
const Operand = encoder.Operand;
const emit = encoder.emit;
const regalloc = @import("../../regalloc/regalloc.zig");
const frame_mod = @import("../../frame/frame.zig");
const isel = @import("isel.zig");
const regs = @import("registers.zig");
const memory = @import("memory.zig");
const branches = @import("branches.zig");
const debug_mod = @import("debug.zig");

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

pub const EmitCodeResult = struct {
    code: std.ArrayList(u8),
    name_to_offset: std.StringHashMap(usize),
    call_fixups: std.ArrayList(CallFixup),
    func_starts: std.ArrayList(usize),
};

/// Emit all functions in a module.
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

/// Emit code for multiple MIR functions.
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

/// Emit a single function.
pub fn emitSingleFunction(
    code: *std.ArrayList(u8),
    call_fixups: *std.ArrayList(CallFixup),
    mfunc: *const mir.MFunction,
) !void {
    const ra = try regalloc.allocRegs(mfunc, mfunc.allocator);
    const scratch: i16 = regs.SCRATCH_REG;

    var block_offsets = std.ArrayList(usize).init(mfunc.allocator);
    defer block_offsets.deinit();

    var fixups = std.ArrayList(Fixup).init(mfunc.allocator);
    defer fixups.deinit();

    var alloca_offsets = OffsetMap.init(mfunc.allocator);
    defer alloca_offsets.deinit();

    var fm = frame_mod.FrameManager.init(mfunc.allocator, .win64);
    defer fm.deinit();

    var local_size: u32 = 0;
    for (mfunc.blocks.items) |*block| {
        for (block.instrs.items) |inst| {
            if (inst == .alloca) {
                const aligned = (inst.alloca.size + 15) & ~@as(u32, 15);
                local_size += aligned;
                const off: i32 = -@as(i32, @intCast(local_size));
                try alloca_offsets.put(switch (inst.alloca.dst) { .vreg => |v| v, else => 0 }, off);
            }
        }
    }
    fm.local_size = local_size;

    var used_callee_saved = std.ArrayList(i16).init(mfunc.allocator);
    defer used_callee_saved.deinit();
    regalloc.getUsedCalleeSaved(&ra, &used_callee_saved);
    for (used_callee_saved.items) |reg| {
        try fm.callee_saved_gprs.append(reg);
    }

    fm.spill_count = if (ra.spill_frame_size > 0) @max(ra.spill_frame_size / 8, 1) else 0;

    try fm.emitPrologue(code);

    const win64_arg_regs = regs.WIN64_ARG_REGS;
    for (mfunc.params, 0..) |p, i| {
        if (i >= 4) break;
        const vreg = switch (p) { .vreg => |v| v, else => continue };
        const dst = ra.regs.get(vreg) orelse continue;
        if (dst != win64_arg_regs[i]) {
            try emit(code, .MOV_R64_R64, &.{ Operand.r(dst), Operand.r(win64_arg_regs[i]) });
        }
    }

    for (mfunc.blocks.items) |*block| {
        try block_offsets.append(code.items.len);

        // Debug dump for loop functions
        if (debug_mod.hasBackEdges(mfunc)) {
            debug_mod.dumpFunction(mfunc);
        }

        for (block.instrs.items) |inst| {
            switch (inst) {
                .mov => |m| try emitMov(code, &ra, m, scratch, mfunc, &alloca_offsets),
                .add => |a| try emitAdd(code, &ra, a, scratch),
                .sub => |s| try emitSub(code, &ra, s, scratch),
                .imul => |m| try emitIMul(code, &ra, m, scratch),
                .idiv => |m| try emitIDiv(code, &ra, m, scratch),
                .@"and" => |a| try emitAnd(code, &ra, a, scratch),
                .@"or" => |o| try emitOr(code, &ra, o, scratch),
                .xor => |x| try emitXor(code, &ra, x, scratch),
                .shl => |s| try emitShift(code, &ra, s, .SHIFT_LEFT_CL, .SHIFT_LEFT, scratch),
                .shr => |s| try emitShift(code, &ra, s, .SHR_R64_CL, .SHIFT_RIGHT, scratch),
                .sar => |s| try emitShift(code, &ra, s, .SAR_R64_CL, .SAR_R64_IMM32, scratch),
                .not_op => |n| try emitNot(code, &ra, n, scratch),
                .neg_op => |n| try emitNeg(code, &ra, n, scratch),
                .test_flags => |tf| try emitTestFlags(code, &ra, tf, scratch),
                .cmp => |c| try emitCmp(code, &ra, c, scratch),
                .cmp_flags => |cf| try emitCmpFlags(code, &ra, cf, scratch),
                .jmp => |j| {
                    const pos = code.items.len;
                    try emit(code, .JMP_REL32, &.{.{ .imm64 = 0 }});
                    try fixups.append(.{ .disp_pos = pos + 1, .target = j.target });
                },
                .jcc => |j| {
                    const pos = code.items.len;
                    const jcc_op = branches.condToJccOp(isel.mirCondToX64(j.cc));
                    try emit(code, jcc_op, &.{.{ .imm64 = 0 }});
                    try fixups.append(.{ .disp_pos = pos + 2, .target = j.target });
                },
                .alloca => |a| try emitAlloca(code, &ra, a, &alloca_offsets, scratch),
                .lea => |l| try emitLea(code, &ra, l, scratch),
                .load => |l| try emitLoad(code, &ra, l, scratch, mfunc),
                .store => |s| try emitStore(code, &ra, s, scratch, mfunc),
                .call => |c| try emitCall(code, call_fixups, &ra, c, scratch, &fm),
                .ret => |r| try emitRet(code, &ra, r, scratch, &fm),
                .phi, .cmp => {},
                .fadd, .fsub, .fmul, .fdiv => |f| try emitFBinOp(code, &ra, f, inst, scratch),
                .fneg_op => |f| try emitFNeg(code, &ra, f, scratch),
                .fsqrt_op => |f| try emitFSqrt(code, &ra, f, scratch),
                .fcmp => |f| try emitFCmp(code, &ra, f, scratch),
                .sitofp, .fptosi, .fpext, .fptrunc => |c| try emitConv(code, &ra, c, inst, scratch),
                .sext_op => |c| try emitSext(code, &ra, c, scratch),
                .zext_op => |c| try emitZext(code, &ra, c, scratch),
                .trunc_op => |c| try emitTrunc(code, &ra, c, scratch),
                .select => |s| try emitSelect(code, &ra, s, scratch),
            }
        }
    }

    // Resolve block-relative fixups
    for (fixups.items) |fx| {
        if (fx.target >= block_offsets.items.len) continue;
        const target_off = block_offsets.items[fx.target];
        const disp: i32 = @intCast(@as(i64, @intCast(target_off)) - @as(i64, @intCast(fx.disp_pos + 4)));
        @memcpy(code.items[fx.disp_pos..][0..4], &@as([4]u8, @bitCast(disp)));
    }
}

// ─── Instruction emission ───

fn emitMov(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, m: mir.MovInst, scratch: i16, mfunc: *const mir.MFunction, alloca_offsets: *const OffsetMap) !void {
    const dst_reg = isel.resolveReg(ra, m.dst);
    if (m.src == .imm) {
        if (m.src.imm == 0) {
            try emit(code, .XOR_R64_R64, &.{ Operand.r(dst_reg), Operand.r(dst_reg) });
        } else {
            try emit(code, .MOV_R64_IMM64, &.{ Operand.r(dst_reg), Operand.imm(m.src.imm) });
        }
        return;
    }
    if (isel.isSpilled(ra, m.src)) {
        try isel.loadSpilledOp(code, ra, m.src, scratch);
        try emit(code, .MOV_R64_R64, &.{ Operand.r(dst_reg), Operand.r(scratch) });
        return;
    }
    const src_reg = isel.resolveReg(ra, m.src);
    try emit(code, .MOV_R64_R64, &.{ Operand.r(dst_reg), Operand.r(src_reg) });
}

fn emitAdd(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, a: mir.AddInst, scratch: i16) !void {
    const dst_reg = isel.resolveReg(ra, a.dst);
    if (a.src == .imm) {
        try emit(code, .ADD_R64_IMM32, &.{ Operand.r(dst_reg), Operand.immU32(@intCast(@as(u64, @bitCast(a.src.imm)))) });
        return;
    }
    const src_reg = isel.prepOperand(code, ra, a.src, scratch) catch |e| {
        if (e == error.OutOfMemory) return e;
        const sreg = isel.resolveReg(ra, a.src);
        try emit(code, .ADD_R64_R64, &.{ Operand.r(dst_reg), Operand.r(sreg) });
        return;
    };
    try emit(code, .ADD_R64_R64, &.{ Operand.r(dst_reg), Operand.r(src_reg) });
}

fn emitSub(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, s: mir.SubInst, scratch: i16) !void {
    const dst_reg = isel.resolveReg(ra, s.dst);
    const src_reg = isel.prepOperand(code, ra, s.src, scratch) catch |e| {
        if (e == error.OutOfMemory) return e;
        const sreg = isel.resolveReg(ra, s.src);
        try emit(code, .SUB_R64_R64, &.{ Operand.r(dst_reg), Operand.r(sreg) });
        return;
    };
    if (s.src == .imm) {
        try emit(code, .SUB_R64_IMM32, &.{ Operand.r(dst_reg), Operand.immU32(@intCast(@as(u64, @bitCast(s.src.imm)))) });
        return;
    }
    try emit(code, .SUB_R64_R64, &.{ Operand.r(dst_reg), Operand.r(src_reg) });
}

fn emitIMul(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, m: mir.IMulInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, m.dst);
    const src_reg = isel.resolveReg(ra, m.src);
    try emit(code, .IMUL_R64_R64, &.{ Operand.r(dst_reg), Operand.r(src_reg) });
}

fn emitIDiv(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, m: mir.IDivInst, scratch: i16) !void {
    const dst_reg = isel.resolveReg(ra, m.dst);
    _ = scratch;
    if (dst_reg != 0) {
        try emit(code, .MOV_R64_R64, &.{ Operand.r(0), Operand.r(dst_reg) });
    }
    try emit(code, .CQO, &.{});
    const divisor = isel.resolveReg(ra, m.src);
    if (divisor >= 0) {
        try emit(code, .IDIV_R64, &.{ Operand.r(divisor) });
    }
    if (dst_reg != 0) {
        try emit(code, .MOV_R64_R64, &.{ Operand.r(dst_reg), Operand.r(0) });
    }
}

fn emitCmp(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, c: mir.CmpInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, c.dst);
    const a_reg = isel.resolveReg(ra, c.a);
    const b_reg = isel.resolveReg(ra, c.b);
    try emit(code, .CMP_R64_R64, &.{ Operand.r(a_reg), Operand.r(b_reg) });
    switch (c.cc) {
        .lt => try emit(code, .SETCC_R8, &.{ Operand.r(dst_reg), Operand.immU32(0x9C) }),
        .le => try emit(code, .SETCC_R8, &.{ Operand.r(dst_reg), Operand.immU32(0x9E) }),
        .gt => try emit(code, .SETCC_R8, &.{ Operand.r(dst_reg), Operand.immU32(0x9F) }),
        .ge => try emit(code, .SETCC_R8, &.{ Operand.r(dst_reg), Operand.immU32(0x9D) }),
        .eq => try emit(code, .SETCC_R8, &.{ Operand.r(dst_reg), Operand.immU32(0x94) }),
        .ne => try emit(code, .SETCC_R8, &.{ Operand.r(dst_reg), Operand.immU32(0x95) }),
    }
}

fn emitCmpFlags(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, cf: mir.CmpFlagsInst, scratch: i16) !void {
    const a_reg = isel.prepOperand(code, ra, cf.a, scratch) catch |e| {
        if (e == error.OutOfMemory) return e;
        const areg = isel.resolveReg(ra, cf.a);
        const breg = isel.resolveReg(ra, cf.b);
        try emit(code, .CMP_R64_R64, &.{ Operand.r(areg), Operand.r(breg) });
        return;
    };
    const b_reg = isel.prepOperand(code, ra, cf.b, scratch) catch |e| {
        if (e == error.OutOfMemory) return e;
        const breg2 = isel.resolveReg(ra, cf.b);
        try emit(code, .CMP_R64_R64, &.{ Operand.r(a_reg), Operand.r(breg2) });
        return;
    };
    if (cf.b == .imm) {
        try emit(code, .CMP_R64_IMM32, &.{ Operand.r(a_reg), Operand.immU32(@intCast(@as(u64, @bitCast(cf.b.imm)))) });
        return;
    }
    try emit(code, .CMP_R64_R64, &.{ Operand.r(a_reg), Operand.r(b_reg) });
}

fn emitAlloca(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, a: mir.AllocaInst, alloca_offsets: *const OffsetMap, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, a.dst);
    const off = alloca_offsets.get(switch (a.dst) { .vreg => |v| v, else => 0 }) orelse {
        try emit(code, .XOR_R64_R64, &.{ Operand.r(dst_reg), Operand.r(dst_reg) });
        return;
    };
    try emit(code, .LEA_R64_MEM, &.{ Operand.r(dst_reg), Operand.mem(5, off) });
}

fn emitLea(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, l: mir.LeaInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, l.dst);
    const base_reg = isel.resolveReg(ra, l.base);
    const index = l.index;
    if (index == .imm) {
        try emit(code, .LEA_R64_MEM, &.{ Operand.r(dst_reg), Operand.mem(base_reg, l.disp) });
        return;
    }
    const index_reg = isel.resolveReg(ra, index);
    try emit(code, .LEA_R64_MEM, &.{ Operand.r(dst_reg), Operand.memIdx(base_reg, index_reg, l.scale, l.disp) });
}

fn emitLoad(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, l: mir.LoadInst, scratch: i16, mfunc: *const mir.MFunction) !void {
    const dst_reg = isel.resolveReg(ra, l.dst);
    if (isel.isSpilled(ra, l.ptr)) {
        try isel.loadSpilledOp(code, ra, l.ptr, scratch);
        try emit(code, .MOV_R64_MEM, &.{ Operand.r(dst_reg), Operand.mem(scratch, 0) });
        return;
    }
    const ptr_reg = isel.resolveReg(ra, l.ptr);
    _ = mfunc;
    try emit(code, .MOV_R64_MEM, &.{ Operand.r(dst_reg), Operand.mem(ptr_reg, 0) });
}

fn emitStore(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, s: mir.StoreInst, scratch: i16, mfunc: *const mir.MFunction) !void {
    const src_reg = isel.prepOperand(code, ra, s.src, scratch) catch |e| {
        if (e == error.OutOfMemory) return e;
        const sreg = isel.resolveReg(ra, s.src);
        if (isel.isSpilled(ra, s.ptr)) {
            try isel.loadSpilledOp(code, ra, s.ptr, scratch);
            try emit(code, .MOV_MEM_R64, &.{ Operand.mem(scratch, 0), Operand.r(sreg) });
            return;
        }
        const ptr_reg = isel.resolveReg(ra, s.ptr);
        try emit(code, .MOV_MEM_R64, &.{ Operand.mem(ptr_reg, 0), Operand.r(sreg) });
        return;
    };
    _ = mfunc;
    if (isel.isSpilled(ra, s.ptr)) {
        try isel.loadSpilledOp(code, ra, s.ptr, scratch);
        try emit(code, .MOV_MEM_R64, &.{ Operand.mem(src_reg, 0), Operand.r(scratch) });
        return;
    }
    const ptr_reg = isel.resolveReg(ra, s.ptr);
    try emit(code, .MOV_MEM_R64, &.{ Operand.mem(ptr_reg, 0), Operand.r(src_reg) });
}

fn emitCall(code: *std.ArrayList(u8), call_fixups: *std.ArrayList(CallFixup), ra: *const regalloc.RegAllocResult, c: mir.CallInst, scratch: i16, fm: *const frame_mod.FrameManager) !void {
    _ = scratch;
    const win64_arg_regs = regs.WIN64_ARG_REGS;
    for (0..c.arg_count) |i| {
        if (i >= 4) break;
        const arg = c.args[i];
        const arg_reg = isel.resolveReg(ra, arg);
        if (arg_reg != win64_arg_regs[i]) {
            try emit(code, .MOV_R64_R64, &.{ Operand.r(win64_arg_regs[i]), Operand.r(arg_reg) });
        }
    }

    try emit(code, .SUB_R64_IMM32, &.{ Operand.r(4), Operand.immU32(0x20) });
    const pos = code.items.len;
    try emit(code, .CALL_REL32, &.{.{ .imm64 = 0 }});
    try call_fixups.append(.{ .name = c.name, .disp_pos = pos + 1 });
    try emit(code, .ADD_R64_IMM32, &.{ Operand.r(4), Operand.immU32(0x20) });

    if (c.dst != .vreg or c.dst.vreg != 0) {
        const dst_reg = isel.resolveReg(ra, c.dst);
        if (dst_reg != 0) {
            // RAX contains the return value
        }
    }
}

fn emitRet(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, r: mir.RetInst, _: i16, fm: *const frame_mod.FrameManager) !void {
    if (r.val == .vreg and r.val.vreg != 0) {
        const val_reg = isel.resolveReg(ra, r.val);
        if (val_reg != 0) {
            try emit(code, .MOV_R64_R64, &.{ Operand.r(0), Operand.r(val_reg) });
        }
    }
    try fm.emitEpilogue(code);
}

fn emitAnd(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, a: mir.AndInst, scratch: i16) !void {
    const dst_reg = isel.resolveReg(ra, a.dst);
    if (a.src == .imm) {
        try emit(code, .AND_R64_IMM32, &.{ Operand.r(dst_reg), Operand.immU32(@intCast(@as(u64, @bitCast(a.src.imm)))) });
        return;
    }
    const src_reg = isel.prepOperand(code, ra, a.src, scratch) catch |e| {
        if (e == error.OutOfMemory) return e;
        const sreg = isel.resolveReg(ra, a.src);
        try emit(code, .AND_R64_R64, &.{ Operand.r(dst_reg), Operand.r(sreg) });
        return;
    };
    try emit(code, .AND_R64_R64, &.{ Operand.r(dst_reg), Operand.r(src_reg) });
}

fn emitOr(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, o: mir.OrInst, scratch: i16) !void {
    const dst_reg = isel.resolveReg(ra, o.dst);
    if (o.src == .imm) {
        try emit(code, .OR_R64_IMM32, &.{ Operand.r(dst_reg), Operand.immU32(@intCast(@as(u64, @bitCast(o.src.imm)))) });
        return;
    }
    const src_reg = isel.prepOperand(code, ra, o.src, scratch) catch |e| {
        if (e == error.OutOfMemory) return e;
        const sreg2 = isel.resolveReg(ra, o.src);
        try emit(code, .OR_R64_R64, &.{ Operand.r(dst_reg), Operand.r(sreg2) });
        return;
    };
    try emit(code, .OR_R64_R64, &.{ Operand.r(dst_reg), Operand.r(src_reg) });
}

fn emitXor(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, x: mir.XorInst, scratch: i16) !void {
    const dst_reg = isel.resolveReg(ra, x.dst);
    if (x.src == .imm) {
        try emit(code, .XOR_R64_IMM32, &.{ Operand.r(dst_reg), Operand.immU32(@intCast(@as(u64, @bitCast(x.src.imm)))) });
        return;
    }
    const src_reg = isel.prepOperand(code, ra, x.src, scratch) catch |e| {
        if (e == error.OutOfMemory) return e;
        const sreg2 = isel.resolveReg(ra, x.src);
        try emit(code, .XOR_R64_R64, &.{ Operand.r(dst_reg), Operand.r(sreg2) });
        return;
    };
    try emit(code, .XOR_R64_R64, &.{ Operand.r(dst_reg), Operand.r(src_reg) });
}

fn emitShift(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, s: mir.ShiftInst, cl_op: OpCode, imm_op: OpCode, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, s.dst);
    const amount = s.amount;
    if (amount == .imm) {
        try emit(code, imm_op, &.{ Operand.r(dst_reg), Operand.immU32(@intCast(@as(u64, @bitCast(amount.imm)))) });
    } else {
        const amount_reg = isel.resolveReg(ra, amount);
        if (amount_reg != 1) {
            try emit(code, .MOV_R64_R64, &.{ Operand.r(1), Operand.r(amount_reg) });
        }
        try emit(code, cl_op, &.{ Operand.r(dst_reg) });
    }
}

fn emitNot(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, n: mir.UnaryInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, n.dst);
    try emit(code, .NOT_R64, &.{ Operand.r(dst_reg) });
}

fn emitNeg(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, n: mir.UnaryInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, n.dst);
    try emit(code, .NEG_R64, &.{ Operand.r(dst_reg) });
}

fn emitTestFlags(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, tf: mir.TestFlagsInst, scratch: i16) !void {
    const a_reg = isel.prepOperand(code, ra, tf.a, scratch) catch |e| {
        if (e == error.OutOfMemory) return e;
        const a2 = isel.resolveReg(ra, tf.a);
        const b2 = isel.resolveReg(ra, tf.b);
        try emit(code, .TEST_R64_R64, &.{ Operand.r(a2), Operand.r(b2) });
        return;
    };
    const b_reg = isel.resolveReg(ra, tf.b);
    try emit(code, .TEST_R64_R64, &.{ Operand.r(a_reg), Operand.r(b_reg) });
}

fn emitFBinOp(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, f: anytype, inst: mir.MInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, f.dst);
    const src_reg = isel.resolveReg(ra, f.b);
    const op: OpCode = switch (inst) {
        .fadd => .SSE_ADDSS,
        .fsub => .SSE_SUBSS,
        .fmul => .SSE_MULSS,
        .fdiv => .SSE_DIVSS,
        else => return,
    };
    try emit(code, op, &.{ Operand.xmm(dst_reg), Operand.xmm(src_reg) });
}

fn emitFNeg(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, f: mir.UnaryInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, f.dst);
    const sign_mask: i64 = 0x8000000000000000;
    try emit(code, .MOV_R64_IMM64, &.{ Operand.r(scratch), Operand.imm(sign_mask) });
    try emit(code, .SSE_MOVD_LD, &.{ Operand.xmm(dst_reg), Operand.r(scratch) });
    try emit(code, .SSE_XORPS, &.{ Operand.xmm(dst_reg), Operand.xmm(dst_reg) });
}

fn emitFSqrt(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, f: mir.UnaryInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, f.dst);
    try emit(code, .SSE_SQRTSS, &.{ Operand.xmm(dst_reg), Operand.xmm(dst_reg) });
}

fn emitFCmp(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, f: mir.FBinOp, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, f.dst);
    const a_reg = isel.resolveReg(ra, f.a);
    const b_reg = isel.resolveReg(ra, f.b);
    try emit(code, .SSE_UCOMISS, &.{ Operand.xmm(a_reg), Operand.xmm(b_reg) });
    // Set byte based on condition (simplified: always PF=1 for unordered)
    try emit(code, .SETCC_R8, &.{ Operand.r(dst_reg), Operand.immU32(0x9B) });
}

fn emitConv(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, c: anytype, inst: mir.MInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, c.dst);
    const src_reg = isel.resolveReg(ra, c.src);
    const op: OpCode = switch (inst) {
        .sitofp => .SSE_CVTSI2SS,
        .fptosi => .SSE_CVTTSS2SI,
        .fpext => .SSE_CVTSS2SD,
        .fptrunc => .SSE_CVTSD2SS,
        else => return,
    };
    if (inst == .sitofp) {
        try emit(code, op, &.{ Operand.xmm(dst_reg), Operand.r(src_reg) });
    } else if (inst == .fptosi) {
        try emit(code, op, &.{ Operand.r(dst_reg), Operand.xmm(src_reg) });
    } else {
        try emit(code, op, &.{ Operand.xmm(dst_reg), Operand.xmm(src_reg) });
    }
}

fn emitSext(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, c: mir.ConvInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, c.dst);
    const src_reg = isel.resolveReg(ra, c.src);
    try emit(code, .MOVSX_R64_R32, &.{ Operand.r(dst_reg), Operand.r(src_reg) });
}

fn emitZext(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, c: mir.ConvInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, c.dst);
    const src_reg = isel.resolveReg(ra, c.src);
    try emit(code, .MOVZX_R64_R32, &.{ Operand.r(dst_reg), Operand.r(src_reg) });
}

fn emitTrunc(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, c: mir.ConvInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, c.dst);
    const src_reg = isel.resolveReg(ra, c.src);
    // 32-bit mov zero-extends, effectively truncating the upper 32 bits
    try emit(code, .MOV_R32_R32, &.{ Operand.r(dst_reg), Operand.r(src_reg) });
}

fn emitSelect(code: *std.ArrayList(u8), ra: *const regalloc.RegAllocResult, s: mir.SelectInst, scratch: i16) !void {
    _ = scratch;
    const dst_reg = isel.resolveReg(ra, s.dst);
    const src_reg = isel.resolveReg(ra, s.src);
    // Simplification: for now just mov src → dst (select condition not tested)
    try emit(code, .MOV_R64_R64, &.{ Operand.r(dst_reg), Operand.r(src_reg) });
}
