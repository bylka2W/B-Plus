/// x64 lowering orchestrator.
/// Orchestrates: regalloc → isel → encode → fixup.
const std = @import("std");
const mir = @import("../../../mir/mir.zig");
const mir_verify = @import("../../../mir/passes/verify.zig");
const mir_optimizer = @import("../../../mir/passes/manager.zig");
const x64 = @import("../encoder.zig");
const regalloc = @import("../../../regalloc/regalloc.zig");
const frame_mod = @import("../../../frame/frame.zig");
const isel = @import("../isel.zig");

const OffsetMap = isel.OffsetMap;

pub const EmitResult = struct {
    code: std.ArrayList(u8),
    entry_offset: usize,
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
    call_fixups: std.ArrayList(isel.CallFixup),
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
    var all_call_fixups = std.ArrayList(isel.CallFixup).init(allocator);
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
    call_fixups: *std.ArrayList(isel.CallFixup),
    mfunc: *const mir.MFunction,
) !void {
    const ra = try regalloc.allocRegs(mfunc, mfunc.allocator);

    // Compute alloca offsets.
    var alloca_offsets = OffsetMap.init(mfunc.allocator);
    defer alloca_offsets.deinit();
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

    // Instruction selection → x64 IR.
    var sel_result = try isel.selectFunction(mfunc, &ra, alloca_offsets);
    defer sel_result.deinit(mfunc.allocator);

    // Compute callee-saved regs and frame.
    var fm = frame_mod.FrameManager.init(mfunc.allocator, .win64);
    defer fm.deinit();

    var used_callee_saved = std.ArrayList(i16).init(mfunc.allocator);
    defer used_callee_saved.deinit();
    regalloc.getUsedCalleeSaved(&ra, &used_callee_saved);
    for (used_callee_saved.items) |reg| {
        try fm.callee_saved_gprs.append(reg);
    }
    fm.local_size = local_size;
    fm.spill_count = if (ra.spill_frame_size > 0) @max(ra.spill_frame_size / 8, 1) else 0;

    // Emit prologue.
    try fm.emitPrologue(code);

    // Move arguments from win64 arg regs (integer and float).
    const win64_int_arg_regs = [_]i16{ 1, 2, 8, 9 }; // RCX, RDX, R8, R9
    const win64_float_arg_regs = [_]i16{ 16, 17, 18, 19 }; // XMM0-XMM3
    var int_arg_idx: usize = 0;
    var float_arg_idx: usize = 0;
    for (mfunc.params) |p| {
        const vreg = switch (p) { .vreg => |v| v, else => continue };
        const dtype = mfunc.getVRegType(vreg) orelse .i64;
        const dst = ra.regs.get(vreg) orelse continue;
        if (dtype.isFloat()) {
            if (float_arg_idx < win64_float_arg_regs.len) {
                const src_xmm = win64_float_arg_regs[float_arg_idx];
                float_arg_idx += 1;
                if (dst != src_xmm) {
                    if (dtype == .f64) {
                        try x64.emit(code, .SSE_MOVSD_LD, &.{ .{ .reg = dst, .is_xmm = true }, .{ .reg = src_xmm, .is_xmm = true } });
                    } else {
                        try x64.emit(code, .SSE_MOVSS_LD, &.{ .{ .reg = dst, .is_xmm = true }, .{ .reg = src_xmm, .is_xmm = true } });
                    }
                }
            }
        } else {
            if (int_arg_idx < win64_int_arg_regs.len) {
                const src_gpr = win64_int_arg_regs[int_arg_idx];
                int_arg_idx += 1;
                if (dst != src_gpr) {
                    try x64.emit(code, .MOV_R64_R64, &.{ .{ .reg = dst }, .{ .reg = src_gpr } });
                }
            }
        }
    }

    // Encode x64 IR → bytes, emitting epilogue after each block that ends
    // with a MIR `ret`.  Without this, control would fall through into
    // subsequent blocks (e.g. critical‑edge split blocks), causing infinite
    // loops when those blocks jump back to the ret block.
    var block_offsets = std.ArrayListUnmanaged(usize){};
    defer block_offsets.deinit(mfunc.allocator);
    var fixup_positions = std.ArrayListUnmanaged(usize){};
    defer fixup_positions.deinit(mfunc.allocator);

    try block_offsets.ensureTotalCapacity(mfunc.allocator, sel_result.mf.blocks.items.len);
    try fixup_positions.ensureTotalCapacity(mfunc.allocator, 32);

    for (sel_result.mf.blocks.items, 0..) |*x64_block, bi| {
        block_offsets.appendAssumeCapacity(code.items.len);
        for (x64_block.instrs.items) |inst| {
            const fixup_offset: ?usize = switch (inst.op) {
                .JMP_REL32, .CALL_REL32 => code.items.len + 1,
                .JE_REL32, .JNE_REL32, .JG_REL32, .JGE_REL32,
                .JL_REL32, .JLE_REL32, .JA_REL32, .JB_REL32, .JBE_REL32,
                .JAE_REL32 => code.items.len + 2,
                else => null,
            };
            if (fixup_offset) |off| {
                fixup_positions.appendAssumeCapacity(off);
            }
            try x64.emitInst(code, inst);
        }

        // If the corresponding MIR block ends with `ret`, emit the epilogue
        // right here so that control cannot fall through into a later block.
        if (bi < mfunc.blocks.items.len) {
            const mir_block = mfunc.blocks.items[bi];
            if (mir_block.instrs.items.len > 0) {
                const last = mir_block.instrs.items[mir_block.instrs.items.len - 1];
                if (last == .ret) {
                    try fm.emitEpilogue(code);
                }
            }
        }
    }

    // Emit a trailing epilogue for paths that don't end with `ret`
    // (e.g. infinite loops or functions that fall off the end).
    try fm.emitEpilogue(code);

    // Patch block fixups.
    const fixup_positions_slice = fixup_positions.items;
    const block_offsets_slice = block_offsets.items;
    for (sel_result.block_fixups.items, 0..) |fx, i| {
        const disp_pos = if (i < fixup_positions_slice.len) fixup_positions_slice[i] else continue;
        if (fx.target >= block_offsets_slice.len) continue;
        const target_off = block_offsets_slice[fx.target];
        const disp: i32 = @intCast(@as(i64, @intCast(target_off)) - @as(i64, @intCast(disp_pos + 4)));
        @memcpy(code.items[disp_pos..][0..4], &@as([4]u8, @bitCast(disp)));
    }

    // Patch call fixups.
    const num_block_fixups = sel_result.block_fixups.items.len;
    for (sel_result.call_fixups.items, 0..) |cf, i| {
        const fixup_idx = num_block_fixups + i;
        const disp_pos = if (fixup_idx < fixup_positions_slice.len) fixup_positions_slice[fixup_idx] else continue;
        try call_fixups.append(.{ .name = cf.name, .disp_pos = disp_pos });
    }
}
