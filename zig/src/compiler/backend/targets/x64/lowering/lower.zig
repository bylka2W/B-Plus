const std = @import("std");
const mir = @import("../../../mir/mir.zig");
const mir_verify = @import("../../../mir/passes/verify.zig");
const mir_optimizer = @import("../../../mir/passes/manager.zig");
const settings = @import("../../../../../compiler/settings.zig");
const x64 = @import("../encoder.zig");
const regalloc = @import("../../../regalloc/regalloc.zig");
const frame_mod = @import("../../../frame/frame.zig");
const isel = @import("../isel.zig");
const x64_verify = @import("../verify/x64_verifier.zig");

const OffsetMap = isel.OffsetMap;
const SelectResult = isel.SelectResult;

const StringDispFixup = struct { disp_pos: usize, str_idx: u32 };

pub const EmitResult = struct {
    code: std.ArrayList(u8),
    entry_offset: usize,
};

pub fn emitModule(mfuncs: []const mir.MFunction) !EmitResult {
    var result = try emitCode(mfuncs);
    defer result.call_fixups.deinit();
    defer result.func_starts.deinit();
    defer result.name_to_offset.deinit();
    defer result.string_pool.deinit();
    defer result.string_disp_fixups.deinit();

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
    string_pool: std.ArrayList([]const u8),
    string_disp_fixups: std.ArrayList(StringDispFixup),
};

pub const IselResult = struct {
    sel: SelectResult,
    ra: regalloc.RegAllocResult,
    alloca_offsets: OffsetMap,
    local_size: u32,
    mfunc: *const mir.MFunction,

    pub fn deinit(self: *IselResult) void {
        self.sel.deinit(self.mfunc.allocator);
        self.ra.regs.deinit();
        self.ra.spills.deinit();
        self.ra.remat.deinit();
        self.alloca_offsets.deinit();
    }
};

pub fn iselFunction(mfunc: *const mir.MFunction, allocator: std.mem.Allocator) !IselResult {
    var ra = try regalloc.allocRegs(mfunc, allocator);

    var used_callee_saved = std.ArrayList(i16).init(allocator);
    defer used_callee_saved.deinit();
    regalloc.getUsedCalleeSaved(&ra, &used_callee_saved);
    const push_base: u32 = if (used_callee_saved.items.len > 0)
        (1 + @as(u32, @intCast(used_callee_saved.items.len))) * 8
    else
        8;

    var spill_it = ra.spills.iterator();
    while (spill_it.next()) |kv| {
        try ra.spills.put(kv.key_ptr.*, kv.value_ptr.* - @as(i32, @intCast(push_base)));
    }

    var alloca_offsets = OffsetMap.init(allocator);
    errdefer alloca_offsets.deinit();
    var local_size: u32 = 0;
    const alloca_base: u32 = push_base + ra.spill_frame_size;
    for (mfunc.blocks.items) |*block| {
        for (block.instrs.items) |inst| {
            if (inst == .alloca) {
                const aligned = (inst.alloca.size + 15) & ~@as(u32, 15);
                local_size += aligned;
                const off: i32 = -@as(i32, @intCast(alloca_base + local_size));
                try alloca_offsets.put(switch (inst.alloca.dst) { .vreg => |v| v, else => 0 }, off);
            }
        }
    }

    const sel = try isel.selectFunction(mfunc, &ra, alloca_offsets);

    return .{
        .sel = sel,
        .ra = ra,
        .alloca_offsets = alloca_offsets,
        .local_size = local_size,
        .mfunc = mfunc,
    };
}

pub fn encodeFunction(
    code: *std.ArrayList(u8),
    isel_result: *const IselResult,
    mfunc: *const mir.MFunction,
    call_fixups: *std.ArrayList(isel.CallFixup),
    string_pool: *std.ArrayList([]const u8),
    string_disp_fixups: *std.ArrayList(StringDispFixup),
) !void {
    const sel_result = &isel_result.sel;
    const ra = &isel_result.ra;
    const local_size = isel_result.local_size;
    var fm = frame_mod.FrameManager.init(mfunc.allocator, .win64);
    defer fm.deinit();

    var used_callee_saved = std.ArrayList(i16).init(mfunc.allocator);
    defer used_callee_saved.deinit();
    regalloc.getUsedCalleeSaved(ra, &used_callee_saved);
    for (used_callee_saved.items) |reg| {
        try fm.callee_saved_gprs.append(reg);
    }
    const push_base: u32 = if (used_callee_saved.items.len > 0)
        (1 + @as(u32, @intCast(used_callee_saved.items.len))) * 8
    else
        8;
    fm.local_size = local_size + push_base;
    fm.spill_count = if (ra.spill_frame_size > 0) @max(ra.spill_frame_size / 8, 1) else 0;

    try fm.emitPrologue(code);

    const win64_int_arg_regs = [_]i16{ 1, 2, 8, 9 };
    const win64_float_arg_regs = [_]i16{ 0, 1, 2, 3 };
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

    var block_offsets = std.ArrayListUnmanaged(usize){};
    defer block_offsets.deinit(mfunc.allocator);
    var fixup_positions = std.ArrayListUnmanaged(usize){};
    defer fixup_positions.deinit(mfunc.allocator);
    const FixupKind = enum { block, call };
    var fixup_kinds = std.ArrayListUnmanaged(FixupKind){};
    defer fixup_kinds.deinit(mfunc.allocator);
    var string_fixup_idx: usize = 0;

    try block_offsets.ensureTotalCapacity(mfunc.allocator, sel_result.mf.blocks.items.len);
    try fixup_positions.ensureTotalCapacity(mfunc.allocator, 32);
    try fixup_kinds.ensureTotalCapacity(mfunc.allocator, 32);

    for (sel_result.mf.blocks.items, 0..) |*x64_block, bi| {
        block_offsets.appendAssumeCapacity(code.items.len);
        for (x64_block.instrs.items) |inst| {
            const fixup_info: ?struct { offset: usize, kind: FixupKind } = switch (inst.op) {
                .JMP_REL32 => .{ .offset = code.items.len + 1, .kind = .block },
                .CALL_REL32 => .{ .offset = code.items.len + 1, .kind = .call },
                .JE_REL32, .JNE_REL32, .JG_REL32, .JGE_REL32,
                .JL_REL32, .JLE_REL32, .JA_REL32, .JB_REL32, .JBE_REL32,
                .JAE_REL32 => .{ .offset = code.items.len + 2, .kind = .block },
                else => null,
            };
            if (fixup_info) |fi| {
                fixup_positions.appendAssumeCapacity(fi.offset);
                fixup_kinds.appendAssumeCapacity(fi.kind);
            }
            if (inst.op == .LEA_R64_MEM and inst.operands.len >= 2) {
                const mem_op = inst.operands[1];
                if (mem_op.base_reg == 255) {
                    const disp_pos = code.items.len + 3;
                    if (string_fixup_idx < sel_result.string_fixups.items.len) {
                        const sf = sel_result.string_fixups.items[string_fixup_idx];
                        string_fixup_idx += 1;
                        const str_idx = @as(u32, @intCast(string_pool.items.len));
                        try string_pool.append(sf.data);
                        try string_disp_fixups.append(.{ .disp_pos = disp_pos, .str_idx = str_idx });
                    }
                }
            }
            try x64.emitInst(code, inst);
        }

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

    try fm.emitEpilogue(code);

    const block_offsets_slice = block_offsets.items;
    var block_fixup_idx: usize = 0;
    var call_fixup_idx: usize = 0;
    for (fixup_positions.items, 0..) |disp_pos, i| {
        switch (fixup_kinds.items[i]) {
            .block => {
                if (block_fixup_idx >= sel_result.block_fixups.items.len) continue;
                const fx = sel_result.block_fixups.items[block_fixup_idx];
                block_fixup_idx += 1;
                if (fx.target >= block_offsets_slice.len) continue;
                const target_off = block_offsets_slice[fx.target];
                const disp: i32 = @intCast(@as(i64, @intCast(target_off)) - @as(i64, @intCast(disp_pos + 4)));
                @memcpy(code.items[disp_pos..][0..4], &@as([4]u8, @bitCast(disp)));
            },
            .call => {
                if (call_fixup_idx >= sel_result.call_fixups.items.len) continue;
                const cf = sel_result.call_fixups.items[call_fixup_idx];
                call_fixup_idx += 1;
                try call_fixups.append(.{ .name = cf.name, .disp_pos = disp_pos });
            },
        }
    }
}

pub fn emitSingleFunction(
    code: *std.ArrayList(u8),
    call_fixups: *std.ArrayList(isel.CallFixup),
    string_pool: *std.ArrayList([]const u8),
    string_disp_fixups: *std.ArrayList(StringDispFixup),
    mfunc: *const mir.MFunction,
) !void {
    const allocator = mfunc.allocator;

    var isel_result = try iselFunction(mfunc, allocator);
    defer isel_result.deinit();

    const verified = try x64_verify.verifyFunction(&isel_result.sel.mf);

    if (isX64DumpEnabled()) x64_verify.dumpFunction(verified);

    try encodeFunction(code, &isel_result, mfunc, call_fixups, string_pool, string_disp_fixups);
}

pub fn emitCode(mfuncs: []const mir.MFunction) !EmitCodeResult {
    if (mfuncs.len == 0) return error.NoFunctions;
    const allocator = mfuncs[0].allocator;

    for (mfuncs) |*mf| try mir_verify.verifyMir(mf);

    if (settings.debug_ir) {
        for (mfuncs) |*mf| {
            const stderr = std.io.getStdErr().writer();
            stderr.print("\n; === MIR BEFORE OPT: '{s}' ===\n", .{mf.name}) catch {};
            stderr.print(";   params: {d}\n", .{mf.params.len}) catch {};
            for (mf.params, 0..) |param, pi| {
                if (param == .vreg) {
                    stderr.print(";   param[{d}]: vreg={d}\n", .{pi, param.vreg}) catch {};
                } else {
                    stderr.print(";   param[{d}]: (not vreg)\n", .{pi}) catch {};
                }
            }
            for (mf.blocks.items, 0..) |*blk, bi| {
                stderr.print(";   b{d} '{s}' ({d} instrs):\n", .{bi, blk.label, blk.instrs.items.len}) catch {};
                for (blk.instrs.items, 0..) |mi, ii| {
                    stderr.print(";     {d}: {s}", .{ii, @tagName(mi)}) catch {};
                    if (mi == .mov) {
                        if (mi.mov.dst == .vreg) stderr.print(" dst=v{d}", .{mi.mov.dst.vreg}) catch {};
                        if (mi.mov.src == .vreg) stderr.print(" src=v{d}", .{mi.mov.src.vreg}) catch {};
                        if (mi.mov.src == .imm) stderr.print(" imm", .{}) catch {};
                    }
                    if (mi == .add) {
                        if (mi.add.dst == .vreg) stderr.print(" dst=v{d}", .{mi.add.dst.vreg}) catch {};
                        if (mi.add.src == .vreg) stderr.print(" src=v{d}", .{mi.add.src.vreg}) catch {};
                    }
                    if (mi == .ret) {
                        if (mi.ret == .value and mi.ret.value.operand == .vreg) stderr.print(" val=v{d}", .{mi.ret.value.operand.vreg}) catch {};
                    }
                    if (mi == .store) {
                        if (mi.store.ptr == .vreg) stderr.print(" ptr=v{d}", .{mi.store.ptr.vreg}) catch {};
                        if (mi.store.src == .vreg) stderr.print(" src=v{d}", .{mi.store.src.vreg}) catch {};
                    }
                    if (mi == .load) {
                        if (mi.load.dst == .vreg) stderr.print(" dst=v{d}", .{mi.load.dst.vreg}) catch {};
                        if (mi.load.ptr == .vreg) stderr.print(" ptr=v{d}", .{mi.load.ptr.vreg}) catch {};
                    }
                    if (mi == .alloca) {
                        if (mi.alloca.dst == .vreg) stderr.print(" dst=v{d}", .{mi.alloca.dst.vreg}) catch {};
                    }
                    stderr.print("\n", .{}) catch {};
                }
            }
        }
    }

    if (!isNoOptEnabled()) {
        for (mfuncs) |*mf| try mir_optimizer.optimize(@constCast(mf));
    }

    if (settings.debug_ir) {
        for (mfuncs) |*mf| {
            const stderr = std.io.getStdErr().writer();
            stderr.print("; === MIR AFTER OPT: '{s}' ===\n", .{mf.name}) catch {};
            for (mf.blocks.items, 0..) |*blk, bi| {
                stderr.print(";   b{d} '{s}' ({d} instrs):\n", .{bi, blk.label, blk.instrs.items.len}) catch {};
                for (blk.instrs.items, 0..) |mi, ii| {
                    stderr.print(";     {d}: {s}", .{ii, @tagName(mi)}) catch {};
                    if (mi == .mov) {
                        if (mi.mov.dst == .vreg) stderr.print(" dst=v{d}", .{mi.mov.dst.vreg}) catch {};
                        if (mi.mov.src == .vreg) stderr.print(" src=v{d}", .{mi.mov.src.vreg}) catch {};
                        if (mi.mov.src == .imm) stderr.print(" imm", .{}) catch {};
                    }
                    if (mi == .add) {
                        if (mi.add.dst == .vreg) stderr.print(" dst=v{d}", .{mi.add.dst.vreg}) catch {};
                        if (mi.add.src == .vreg) stderr.print(" src=v{d}", .{mi.add.src.vreg}) catch {};
                    }
                    if (mi == .ret) {
                        if (mi.ret == .value and mi.ret.value.operand == .vreg) stderr.print(" val=v{d}", .{mi.ret.value.operand.vreg}) catch {};
                    }
                    if (mi == .load) {
                        if (mi.load.dst == .vreg) stderr.print(" dst=v{d}", .{mi.load.dst.vreg}) catch {};
                        if (mi.load.ptr == .vreg) stderr.print(" ptr=v{d}", .{mi.load.ptr.vreg}) catch {};
                    }
                    if (mi == .alloca) {
                        if (mi.alloca.dst == .vreg) stderr.print(" dst=v{d}", .{mi.alloca.dst.vreg}) catch {};
                    }
                    stderr.print("\n", .{}) catch {};
                }
            }
        }
    }

    var code = std.ArrayList(u8).init(allocator);
    errdefer code.deinit();
    var name_to_offset = std.StringHashMap(usize).init(allocator);
    var all_call_fixups = std.ArrayList(isel.CallFixup).init(allocator);
    var func_starts = std.ArrayList(usize).init(allocator);
    var string_pool = std.ArrayList([]const u8).init(allocator);
    var string_disp_fixups = std.ArrayList(StringDispFixup).init(allocator);
    errdefer {
        name_to_offset.deinit();
        all_call_fixups.deinit();
        func_starts.deinit();
        string_pool.deinit();
        string_disp_fixups.deinit();
    }

    for (mfuncs) |*mf| {
        const func_start = code.items.len;
        try func_starts.append(func_start);
        try name_to_offset.put(mf.name, func_start);
        try emitSingleFunction(&code, &all_call_fixups, &string_pool, &string_disp_fixups, mf);
    }

var needs_dispatch = false;
    for (all_call_fixups.items) |cf| {
        if (std.mem.eql(u8, cf.name, "__plan_event_dispatch")) {
            needs_dispatch = true;
            break;
        }
    }
    if (needs_dispatch) {
        const rt_start = code.items.len;
        try name_to_offset.put("__plan_event_dispatch", rt_start);
        try code.append(0x48);
        try code.append(0x31);
        try code.append(0xC0);
        try code.append(0xC3);
    }

    var needs_plan_runtime = false;
    for (all_call_fixups.items) |cf| {
        if (isPlanRuntimeName(cf.name)) {
            needs_plan_runtime = true;
            break;
        }
    }
    if (needs_plan_runtime) {
        try appendPlanRuntime(&code, &name_to_offset);
    }

    const string_data_start = code.items.len;
    for (string_pool.items, 0..) |sdata, i| {
        _ = i;
        try code.appendSlice(sdata);
        try code.append(0);
    }
    while (code.items.len % 4 != 0) try code.append(0);

    for (string_disp_fixups.items) |sf| {
        var str_off: usize = string_data_start;
        for (0..sf.str_idx) |j| {
            str_off += string_pool.items[j].len + 1;
        }
        const lea_end = sf.disp_pos + 4;
        const disp: i32 = @intCast(@as(i64, @intCast(str_off)) - @as(i64, @intCast(lea_end)));
        @memcpy(code.items[sf.disp_pos..][0..4], &@as([4]u8, @bitCast(disp)));
    }

    return .{
        .code = code,
        .name_to_offset = name_to_offset,
        .call_fixups = all_call_fixups,
        .func_starts = func_starts,
        .string_pool = string_pool,
        .string_disp_fixups = string_disp_fixups,
    };
}

fn isX64DumpEnabled() bool {
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, "BPC_DEBUG") catch return false;
    defer std.heap.page_allocator.free(val);
    return val.len > 0;
}

fn isNoOptEnabled() bool {
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, "BPC_NO_OPT") catch return false;
    defer std.heap.page_allocator.free(val);
    return val.len > 0;
}

const PLAN_FIXED_SIZE = 40;                                             
const PLAN_QUEUE_ENTRY = 32;                                
const PLAN_QUEUE_CAP = 64;
const PLAN_QUEUE_BYTES = PLAN_QUEUE_CAP * PLAN_QUEUE_ENTRY;
const PLAN_STATE_DATA_SIZE = 4096;

fn isPlanRuntimeName(name: []const u8) bool {
    const names = [_][]const u8{
        "__plan_event_post",
        "__plan_event_pop",
        "__plan_set_state",
        "__plan_get_state",
        "__plan_set_goto",
        "__plan_consume_goto",
        "__state_base",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn planRel32(code: *std.ArrayList(u8), pos_after: usize, target: usize) void {
    const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(pos_after)));
    @memcpy(code.items[pos_after - 4 ..][0..4], &@as([4]u8, @bitCast(disp)));
}

fn appendPlanRuntime(code: *std.ArrayList(u8), name_to_offset: *std.StringHashMap(usize)) !void {
    const data_base = code.items.len;
    try code.appendNTimes(0, PLAN_FIXED_SIZE + PLAN_QUEUE_BYTES + PLAN_STATE_DATA_SIZE);
    const q_state = data_base + 0;
    const q_goto = data_base + 8;
    const q_head = data_base + 16;
    const q_tail = data_base + 24;
    const q_count = data_base + 32;
    const q_buf = data_base + 40;
    const q_state_data = data_base + PLAN_FIXED_SIZE + PLAN_QUEUE_BYTES;

                                                        
    {
        const start = code.items.len;
        try code.append(0x48);
        try code.append(0x89);
        try code.append(0x0D);
        const pd = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, pd, q_state);
        try code.append(0xC3);
        try name_to_offset.put("__plan_set_state", start);
    }

                                                    
    {
        const start = code.items.len;
        try code.append(0x48);
        try code.append(0x8B);
        try code.append(0x05);
        const pd = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, pd, q_state);
        try code.append(0xC3);
        try name_to_offset.put("__plan_get_state", start);
    }

                                                      
    {
        const start = code.items.len;
        try code.append(0x48);
        try code.append(0x89);
        try code.append(0x0D);
        const pd = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, pd, q_goto);
        try code.append(0xC3);
        try name_to_offset.put("__plan_set_goto", start);
    }

                                                        
    {
        const start = code.items.len;
        try code.append(0x48);
        try code.append(0x8B);
        try code.append(0x05);
        const pd = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, pd, q_goto);
        try code.append(0x49);
        try code.append(0xC7);
        try code.append(0xC0);
        try code.appendSlice(&.{ 0xFF, 0xFF, 0xFF, 0xFF });
        try code.append(0x4C);
        try code.append(0x89);
        try code.append(0x05);
        const pd2 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, pd2, q_goto);
        try code.append(0xC3);
        try name_to_offset.put("__plan_consume_goto", start);
    }

                                               
    {
        const start = code.items.len;
        try code.appendSlice(&.{ 0x48, 0x8B, 0x05 });
        const p0 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p0, q_count);
        try code.appendSlice(&.{ 0x48, 0x83, 0xF8, 0x40 });              
        const jge_pos = code.items.len;
        try code.append(0x7D);
        try code.append(0x00);                       
        try code.appendSlice(&.{ 0x4C, 0x8B, 0x05 });
        const p2 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p2, q_head);
        try code.appendSlice(&.{ 0x4C, 0x01, 0xC0 });                    
        try code.appendSlice(&.{ 0x48, 0x83, 0xE0, 0x3F });              
        try code.appendSlice(&.{ 0x48, 0xC1, 0xE0, 0x05 });             
        try code.appendSlice(&.{ 0x4C, 0x8D, 0x0D });
        const p3 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p3, q_buf);
        try code.appendSlice(&.{ 0x49, 0x01, 0xC1 });              
        try code.appendSlice(&.{ 0x49, 0x89, 0x09 });                
        try code.appendSlice(&.{ 0x49, 0x89, 0x51, 0x08 });                  
        try code.appendSlice(&.{ 0x49, 0x89, 0x41, 0x10 });                  
        try code.appendSlice(&.{ 0x48, 0x8B, 0x05 });
        const p4 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p4, q_count);
        try code.appendSlice(&.{ 0x48, 0xFF, 0xC0 });           
        try code.appendSlice(&.{ 0x48, 0x89, 0x05 });
        const p5 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p5, q_count);
        try code.appendSlice(&.{ 0x48, 0x8B, 0x05 });
        const p6 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p6, q_tail);
        try code.appendSlice(&.{ 0x48, 0xFF, 0xC0 });           
        try code.appendSlice(&.{ 0x48, 0x83, 0xE0, 0x3F });              
        try code.appendSlice(&.{ 0x48, 0x89, 0x05 });
        const p7 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p7, q_tail);
        try code.append(0xC3);              
        const drop_after = code.items.len;
        const disp8: i8 = @intCast(@as(i32, @intCast(drop_after)) - @as(i32, @intCast(jge_pos + 2)));
        code.items[jge_pos + 1] = @bitCast(disp8);
        try name_to_offset.put("__plan_event_post", start);
    }

                                                    
    {
        const start = code.items.len;
        try code.appendSlice(&.{ 0x48, 0x8B, 0x05 });
        const p1 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p1, q_count);
        try code.appendSlice(&.{ 0x48, 0x85, 0xC0 });                
        const jle_pos = code.items.len;
        try code.append(0x7E);
        try code.append(0x00);                        
        try code.appendSlice(&.{ 0x4C, 0x8B, 0x05 });
        const p2 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p2, q_head);
        try code.appendSlice(&.{ 0x4D, 0x8D, 0x0D });
        const p3 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p3, q_buf);
        try code.appendSlice(&.{ 0x49, 0xC1, 0xE0, 0x05 });            
        try code.appendSlice(&.{ 0x4D, 0x01, 0xC1 });             
        try code.appendSlice(&.{ 0x49, 0x8B, 0x01 });                
        try code.appendSlice(&.{ 0x48, 0x89, 0x01 });                 
        try code.appendSlice(&.{ 0x49, 0x8B, 0x41, 0x08 });                  
        try code.appendSlice(&.{ 0x48, 0x89, 0x41, 0x08 });                   
        try code.appendSlice(&.{ 0x49, 0x8B, 0x41, 0x10 });                   
        try code.appendSlice(&.{ 0x48, 0x89, 0x41, 0x10 });                    
        try code.appendSlice(&.{ 0x48, 0x8B, 0x05 });
        const p4 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p4, q_count);
        try code.appendSlice(&.{ 0x48, 0xFF, 0xC8 });           
        try code.appendSlice(&.{ 0x48, 0x89, 0x05 });
        const p5 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p5, q_count);
        try code.appendSlice(&.{ 0x48, 0x8B, 0x05 });
        const p6 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p6, q_head);
        try code.appendSlice(&.{ 0x48, 0xFF, 0xC0 });           
        try code.appendSlice(&.{ 0x48, 0x83, 0xE0, 0x3F });              
        try code.appendSlice(&.{ 0x48, 0x89, 0x05 });
        const p7 = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, p7, q_head);
        try code.appendSlice(&.{ 0x48, 0xC7, 0xC0, 0x01, 0x00, 0x00, 0x00 });             
        try code.append(0xC3);       
        const empty_after = code.items.len;
        try code.appendSlice(&.{ 0x31, 0xC0 });                       
        try code.append(0xC3);
        const disp8: i8 = @intCast(@as(i32, @intCast(empty_after)) - @as(i32, @intCast(jle_pos + 2)));
        code.items[jle_pos + 1] = @bitCast(disp8);
        try name_to_offset.put("__plan_event_pop", start);
    }

                                                       
    {
        const start = code.items.len;
        try code.append(0x48);
        try code.append(0x8D);
        try code.append(0x05);
        const pd = code.items.len + 4;
        try code.appendNTimes(0, 4);
        planRel32(code, pd, q_state_data);
        try code.append(0xC3);
        try name_to_offset.put("__state_base", start);
    }
}

