const std = @import("std");
const ast = @import("ast.zig");
const x64 = @import("x64enc.zig");
const rt = @import("runtime.zig");
const Allocator = std.mem.Allocator;

pub const X64Output = struct {
    code: []u8,
    import_dir_rva: u32,
    idat_size: u32,
};

const Reg = struct {
    const RAX: i16 = 0; const RCX: i16 = 1; const RDX: i16 = 2; const RBX: i16 = 3;
    const RSP: i16 = 4; const RBP: i16 = 5; const RSI: i16 = 6; const RDI: i16 = 7;
    const R8: i16 = 8; const R9: i16 = 9; const R10: i16 = 10; const R11: i16 = 11;
    const R12: i16 = 12; const R13: i16 = 13; const R14: i16 = 14; const R15: i16 = 15;
};

const IMPORT_FNS = [_][]const u8{
    "GetStdHandle", "WriteFile", "ReadFile", "ExitProcess",
    "GetProcessHeap", "HeapAlloc", "HeapFree", "SetThreadAffinityMask",
    "GetCurrentThread", "GetNumaHighestNodeNumber", "GetNumaNodeProcessorMask",
    "VirtualAlloc", "VirtualFree", "CreateFileW", "GetFileSizeEx",
    "CreateFileMappingW", "MapViewOfFile", "UnmapViewOfFile", "CloseHandle",
};

const SectionRva: u32 = 0x1000;

const ContextVarInfo = struct { name: []const u8, type_name: []const u8, default_value: []const u8 };
const StateVarInfo = struct { name: []const u8, type_name: []const u8, default_value: []const u8, stack_offset: i32, size: u32, cache_policy: ?[]const u8 };
const Fixup = struct { offset: usize, disp_size: u32, label_id: u32 };
const StateBounds = struct { start: usize, end: usize };

const Trace = struct {
    start_state: usize,
    len: usize,
    hot_weight: f64,
};

const PendingOutput = struct {
    code: std.ArrayList(u8),
    pending_fixups: std.ArrayList(Fixup),
    label_off: std.ArrayList(?usize),
    label_names: std.ArrayList([]const u8),
    label_name_map: std.StringHashMap(u32),
    string_pool: std.StringHashMap(usize),
    string_list: std.ArrayList([]const u8),
    state_names: std.ArrayList([]const u8),
    state_index_map: std.StringHashMap(usize),
    ctx_vars: std.ArrayList(ContextVarInfo),
    state_vars: std.StringHashMap(std.ArrayList(StateVarInfo)),
    state_code_bounds: std.StringHashMap(StateBounds),
    stack_frame_size: u32,
    off_hstdin: i32, off_hstdout: i32,
    off_chars_read: i32, off_chars_written: i32,
    off_cur_state: i32, off_cursor: i32, off_remaining: i32, off_abudget: i32,
    off_buf: i32,
    off_ctx_var_start: i32, off_state_data_base: i32,
    off_core_type: i32, off_numa_highest_node: i32, off_numa_node_mask: i32,
    off_l1_base: i32, off_l1_ptr: i32, off_l1_end: i32, off_l1_buf_start: i32,
    off_l2_base: i32, off_l2_ptr: i32, off_l2_end: i32, off_l2_buf_start: i32,
    off_l3_base: i32, off_l3_ptr: i32, off_l3_end: i32, off_l3_buf_start: i32,
    off_pool_head: i32,
    off_state_hits: i32,
    off_epoch: i32,
    off_ht_tiers: i32,
    off_ht_states: i32,
    off_ht_heats: i32,
    off_ht_ptrs: i32,
    off_ht_generations: i32,
    off_ht_sizes: i32,
    off_ht_free_next: i32,
    off_ht_free_head: i32,
    off_telem_l1_spill: i32,
    off_telem_l2_spill: i32,
    off_telem_l1_peak: i32,
    off_telem_l2_peak: i32,
    off_telem_l3_peak: i32,
    off_telem_l1_allocs: i32,
    off_telem_l2_allocs: i32,
    off_telem_l3_allocs: i32,
    arena_l1_size: u32,
    arena_l2_size: u32,
    arena_l3_size: u32,
    l3_block_size: u32,
    l3_num_blocks: u32,
    has_hot_states: bool,
    dp_id: []u32,
    en_id: []u32,
    allocator: Allocator,
};


pub fn generate(allocator: Allocator, program: ast.ProgramNode) !X64Output {
    var p = PendingOutput{
        .code = std.ArrayList(u8).init(allocator),
        .pending_fixups = std.ArrayList(Fixup).init(allocator),
        .label_off = std.ArrayList(?usize).init(allocator),
        .label_names = std.ArrayList([]const u8).init(allocator),
        .label_name_map = std.StringHashMap(u32).init(allocator),
        .string_pool = std.StringHashMap(usize).init(allocator),
        .string_list = std.ArrayList([]const u8).init(allocator),
        .state_names = std.ArrayList([]const u8).init(allocator),
        .state_index_map = std.StringHashMap(usize).init(allocator),
        .ctx_vars = std.ArrayList(ContextVarInfo).init(allocator),
        .state_vars = std.StringHashMap(std.ArrayList(StateVarInfo)).init(allocator),
        .state_code_bounds = std.StringHashMap(StateBounds).init(allocator),
        .stack_frame_size = 0,
        .off_hstdin = -8, .off_hstdout = -16,
        .off_chars_read = -24, .off_chars_written = -32,
        .off_cur_state = -40, .off_cursor = -48, .off_remaining = -56, .off_abudget = 0,
        .off_buf = -64,
        .off_ctx_var_start = -72, .off_state_data_base = -80,
        .off_core_type = -88, .off_numa_highest_node = -92, .off_numa_node_mask = -100,
        .off_l1_base = -108, .off_l1_ptr = -116, .off_l1_end = -124, .off_l1_buf_start = 0,
        .off_l2_base = 0, .off_l2_ptr = 0, .off_l2_end = 0, .off_l2_buf_start = 0,
        .off_l3_base = 0, .off_l3_ptr = 0, .off_l3_end = 0, .off_l3_buf_start = 0,
        .off_pool_head = -132,
        .off_state_hits = 0,
        .off_epoch = 0,
        .off_ht_tiers = 0,
        .off_ht_states = 0,
        .off_ht_heats = 0,
        .off_ht_ptrs = 0,
        .off_ht_generations = 0,
        .off_ht_sizes = 0,
        .off_ht_free_next = 0,
        .off_ht_free_head = 0,
        .off_telem_l1_spill = 0, .off_telem_l2_spill = 0,
        .off_telem_l1_peak = 0, .off_telem_l2_peak = 0, .off_telem_l3_peak = 0,
        .off_telem_l1_allocs = 0, .off_telem_l2_allocs = 0, .off_telem_l3_allocs = 0,
        .arena_l1_size = 0,
        .arena_l2_size = 0,
        .arena_l3_size = 0,
        .l3_block_size = 0,
        .l3_num_blocks = 0,
        .has_hot_states = false,
        .dp_id = &.{},
        .en_id = &.{},
        .allocator = allocator,
    };
    for (program.states.items) |s| try p.state_names.append(s.name);
    for (program.states.items, 0..) |s, i| try p.state_index_map.put(s.name, i);
    for (program.states.items) |s| {
        if (s.hot_weight) |hw| { if (hw >= 0.8) { p.has_hot_states = true; break; } }
    }
    p.dp_id = try allocator.alloc(u32, program.states.items.len);
    p.en_id = try allocator.alloc(u32, program.states.items.len);
    for (0..program.states.items.len) |i| {
        p.dp_id[i] = try allocLabelId(&p, "dp_{d}", .{i});
        p.en_id[i] = try allocLabelId(&p, "en_{d}", .{i});
    }
    if (program.context) |ctx| {
        for (ctx.variables.items) |v| try p.ctx_vars.append(.{
            .name = v.name, .type_name = v.type_name, .default_value = v.default_value orelse "0",
        });
    }
    computeArenaSizes(&p, program);
    try computeStackLayout(&p, program);
    try emitPrologueAndInit(&p, program);
    try emitRuntimeSection(&p);
    try emitStateEnterFuncs(&p, program);
    try padForCacheAssociativity(&p, program);
    try emitEventLoop(&p, program);
    try emitCacheBudgetChecks(&p, program);
    try embedStringPool(&p);
    const import_dir_rva = try emitImportTable(&p);
    try applyFixups(&p);
    // Fill jump table entries (base-relative disp = dp_N - jmp_table)
    {
        const jt_id = try allocLabelId(&p, "jmp_table", .{});
        const jt_off = getLabel(&p, jt_id) orelse 0;
        if (jt_off != 0) {
            for (p.dp_id, 0..) |dpid, i| {
                const dp_off = getLabel(&p, dpid) orelse continue;
                const disp: i32 = @intCast(@as(i64, @intCast(dp_off)) - @as(i64, @intCast(jt_off)));
                const entry_off = jt_off + i * 4;
                const db: [4]u8 = @bitCast(disp);
                p.code.items[entry_off + 0] = db[0];
                p.code.items[entry_off + 1] = db[1];
                p.code.items[entry_off + 2] = db[2];
                p.code.items[entry_off + 3] = db[3];
            }
        }
    }
    // Cleanup allocations
    p.allocator.free(p.dp_id);
    p.allocator.free(p.en_id);
    p.label_off.deinit();
    p.label_name_map.deinit();
    for (p.label_names.items) |n| p.allocator.free(n);
    p.label_names.deinit();
    {
        var sit = p.state_vars.iterator();
        while (sit.next()) |e| e.value_ptr.deinit();
        p.state_vars.deinit();
    }
    p.state_code_bounds.deinit();
    p.pending_fixups.deinit();
    for (p.string_list.items) |s| p.allocator.free(s);
    p.string_list.deinit();
    p.string_pool.deinit();
    p.state_names.deinit();
    p.ctx_vars.deinit();
    const idat_size = computeImportTableSize();
    return X64Output{ .code = try p.code.toOwnedSlice(), .import_dir_rva = @intCast(import_dir_rva), .idat_size = idat_size };
}

fn allocLabelId(p: *PendingOutput, comptime fmt: []const u8, args: anytype) !u32 {
    var buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, fmt, args);
    if (p.label_name_map.get(name)) |id| return id;
    const id = @as(u32, @intCast(p.label_names.items.len));
    const owned = try p.allocator.dupe(u8, name);
    try p.label_names.append(owned);
    try p.label_name_map.put(owned, id);
    try p.label_off.append(null);
    return id;
}

fn setLabel(p: *PendingOutput, id: u32) !void {
    while (p.label_off.items.len <= id) try p.label_off.append(null);
    p.label_off.items[id] = p.code.items.len;
}

fn setLabelAt(p: *PendingOutput, id: u32, off: usize) !void {
    while (p.label_off.items.len <= id) try p.label_off.append(null);
    p.label_off.items[id] = off;
}

fn getLabel(p: *const PendingOutput, id: u32) ?usize {
    return if (id < p.label_off.items.len) p.label_off.items[id] else null;
}

fn getTypeSize(t: []const u8) u32 {
    if (std.mem.eql(u8, t, "int8") or std.mem.eql(u8, t, "i8") or std.mem.eql(u8, t, "u8") or std.mem.eql(u8, t, "byte") or std.mem.eql(u8, t, "bool")) return 1;
    if (std.mem.eql(u8, t, "int16") or std.mem.eql(u8, t, "i16") or std.mem.eql(u8, t, "u16") or std.mem.eql(u8, t, "short") or std.mem.eql(u8, t, "half")) return 2;
    if (std.mem.eql(u8, t, "int32") or std.mem.eql(u8, t, "i32") or std.mem.eql(u8, t, "u32") or std.mem.eql(u8, t, "int") or std.mem.eql(u8, t, "uint") or std.mem.eql(u8, t, "float")) return 4;
    return 8;
}

fn getTypeAlign(t: []const u8) u32 {
    const s = getTypeSize(t);
    return if (s <= 4) s else 8;
}

fn computeArenaSizes(p: *PendingOutput, program: ast.ProgramNode) void {
    const MIGRATION_BUDGET: u32 = 4;
    const MIN_ARENA: u32 = 256;
    var max_data_size: u32 = 16;
    for (program.states.items) |state| {
        for (state.variables.items) |v| {
            const sz = getTypeSize(v.type_name);
            if (sz > max_data_size) max_data_size = sz;
        }
    }
    p.arena_l1_size = @max(max_data_size * (8 + MIGRATION_BUDGET), MIN_ARENA);
    p.arena_l2_size = @max(max_data_size * MIGRATION_BUDGET, MIN_ARENA);
    p.arena_l3_size = @max(max_data_size * MIGRATION_BUDGET, MIN_ARENA);
    p.l3_block_size = max_data_size + 16;
    p.l3_num_blocks = p.arena_l3_size / p.l3_block_size;
    if (p.l3_num_blocks < 2) { p.l3_num_blocks = 2; p.arena_l3_size = p.l3_block_size * p.l3_num_blocks; }
}

fn computeStackLayout(p: *PendingOutput, program: ast.ProgramNode) !void {
    var off: i32 = -8;
    p.off_hstdin = off; off -= 8; p.off_hstdout = off; off -= 8;
    p.off_chars_read = off; off -= 8; p.off_chars_written = off; off -= 8;
    p.off_cur_state = off; off -= 8; p.off_cursor = off; off -= 8; p.off_remaining = off; off -= 8;
    p.off_abudget = off; off -= 4;
    p.off_ctx_var_start = off;
    for (p.ctx_vars.items) |_| off -= 8;
    p.off_state_data_base = off;
    p.state_vars.clearRetainingCapacity();
    var shared = std.StringHashMap(i32).init(p.allocator);
    defer shared.deinit();
    for (program.states.items) |state| {
        const isL1 = if (state.cache_policy) |cp| std.mem.eql(u8, cp, "L1") else false;
        if (!isL1) continue;
        var sv = std.ArrayList(StateVarInfo).init(p.allocator);
        for (state.variables.items) |v| {
            const g = shared.get(v.name);
            if (g) |eo| { try sv.append(.{ .name = v.name, .type_name = v.type_name, .default_value = v.default_value orelse "0", .stack_offset = eo, .size = getTypeSize(v.type_name), .cache_policy = v.cache_policy }); }
            else { const a = getTypeAlign(v.type_name); const sz = getTypeSize(v.type_name); off = @divFloor(off, @as(i32, @intCast(a))) * @as(i32, @intCast(a)) - @as(i32, @intCast(sz)); try shared.put(v.name, off); try sv.append(.{ .name = v.name, .type_name = v.type_name, .default_value = v.default_value orelse "0", .stack_offset = off, .size = sz, .cache_policy = v.cache_policy }); }
        }
        try p.state_vars.put(state.name, sv);
    }
    for (program.states.items) |state| {
        const isL1 = if (state.cache_policy) |cp| std.mem.eql(u8, cp, "L1") else false;
        if (isL1) continue;
        var sv = std.ArrayList(StateVarInfo).init(p.allocator);
        for (state.variables.items) |v| {
            const g = shared.get(v.name);
            if (g) |eo| { try sv.append(.{ .name = v.name, .type_name = v.type_name, .default_value = v.default_value orelse "0", .stack_offset = eo, .size = getTypeSize(v.type_name), .cache_policy = v.cache_policy }); }
            else { const sz = getTypeSize(v.type_name); off -= @as(i32, @intCast(sz)); try shared.put(v.name, off); try sv.append(.{ .name = v.name, .type_name = v.type_name, .default_value = v.default_value orelse "0", .stack_offset = off, .size = sz, .cache_policy = v.cache_policy }); }
        }
        try p.state_vars.put(state.name, sv);
    }
    p.off_core_type = off; off -= 4;
    p.off_numa_highest_node = off; off -= 4;
    p.off_numa_node_mask = off; off -= 8;
    p.off_pool_head = off; off -= 8;
    p.off_l1_base = off; off -= 8;
    p.off_l1_ptr = off; off -= 8;
    p.off_l1_end = off; off -= 8;
    p.off_l2_base = off; off -= 8;
    p.off_l2_ptr = off; off -= 8;
    p.off_l2_end = off; off -= 8;
    p.off_l3_base = off; off -= 8;
    p.off_l3_ptr = off; off -= 8;
    p.off_l3_end = off; off -= 8;
    p.off_telem_l1_spill = off; off -= 8;
    p.off_telem_l2_spill = off; off -= 8;
    p.off_telem_l1_peak = off; off -= 8;
    p.off_telem_l2_peak = off; off -= 8;
    p.off_telem_l3_peak = off; off -= 8;
    p.off_telem_l1_allocs = off; off -= 8;
    p.off_telem_l2_allocs = off; off -= 8;
    p.off_telem_l3_allocs = off; off -= 8;
    p.off_state_hits = off - @as(i32, @intCast(program.states.items.len * 8)); off -= @as(i32, @intCast(program.states.items.len * 8));
    p.off_buf = off - 256; off -= 256;
    p.off_l1_buf_start = off - @as(i32, @intCast(p.arena_l1_size)); off -= @as(i32, @intCast(p.arena_l1_size));
    p.off_l2_buf_start = off - @as(i32, @intCast(p.arena_l2_size)); off -= @as(i32, @intCast(p.arena_l2_size));
    p.off_l3_buf_start = off - @as(i32, @intCast(p.arena_l3_size)); off -= @as(i32, @intCast(p.arena_l3_size));
    p.off_epoch = off; off -= 8;
    p.off_ht_states = off - 64; off -= 64;
    p.off_ht_tiers = off - 64; off -= 64;
    p.off_ht_heats = off - 256; off -= 256;
    p.off_ht_generations = off - 256; off -= 256;
    p.off_ht_sizes = off - 256; off -= 256;
    p.off_ht_free_next = off - 256; off -= 256;
    p.off_ht_ptrs = off - 512; off -= 512;
    p.off_ht_free_head = off - 8; off -= 8;
    const neg = -off;
    p.stack_frame_size = @as(u32, @intCast(neg + 15)) & ~@as(u32, 15);
    if (p.stack_frame_size < 40) p.stack_frame_size = 40;
}

fn emitPrologueAndInit(p: *PendingOutput, program: ast.ProgramNode) !void {
    try p.code.append(0x55);
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBP), x64.Operand.r(Reg.RSP) });
    try emitPushR64(p, Reg.RBX); try emitPushR64(p, Reg.R12);
    try emitPushR64(p, Reg.R13); try emitPushR64(p, Reg.R14); try emitPushR64(p, Reg.R15);
    try x64.emit(&p.code, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(p.stack_frame_size) });
    var off = p.off_ctx_var_start;
    for (p.ctx_vars.items) |v| {
        try emitLoadImm(p, Reg.RAX, parseNumber(v.default_value));
        try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, off), x64.Operand.r(Reg.RAX) });
        off -= 8;
    }
    var it = p.state_vars.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.items) |sv| {
            try emitLoadImm(p, Reg.RAX, parseNumber(sv.default_value));
            try emitStoreVarFromReg(p, sv.stack_offset, Reg.RAX, sv.size);
        }
    }
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l1_buf_start) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_base), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_ptr), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(p.arena_l1_size) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_end), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l2_buf_start) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_base), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(p.arena_l2_size) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_end), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l3_buf_start) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l3_base), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l3_ptr), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(p.arena_l3_size) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l3_end), x64.Operand.r(Reg.RAX) });
    // L3 block pool init: link all blocks into free list
    // L3 block pool init: link all blocks into free list
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l3_buf_start) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.RAX) });
    if (p.l3_num_blocks > 1) {
        const pl_lp = try allocLabelId(p, "pl_lp", .{});
        try emitMovRegImm32(p, Reg.RCX, p.l3_num_blocks - 1);
        try emitMovRegImm32(p, Reg.RDX, p.l3_block_size);
        try setLabel(p, pl_lp);
        try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDX) });
        try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RAX, 0), x64.Operand.r(Reg.R8) });
        try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R8) });
        try emitDec(p, Reg.RCX);
        try emitCondLongJmp(p, .JNE_REL32, pl_lp);
    }
    try emitXorReg(p, Reg.R8);
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RAX, 0), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.code, .XOR_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_cur_state), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_epoch), x64.Operand.r(Reg.RAX) });
    // Zero telemetry counters (RAX = 0 from XOR above)
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_spill), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_spill), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_peak), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_peak), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_peak), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_allocs), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_allocs), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs), x64.Operand.r(Reg.RAX) });
    // Zero handle table metadata arrays (RAX=0 from earlier XOR)
    // Start at ptrs (lowest address), zero upward through free_next/sizes/gens/heats/states
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
    try emitMovRegImm32(p, Reg.RCX, 512 + 256 + 256 + 256 + 256 + 64 + 64); // ptrs + free_next + sizes + gens + heats + tiers + states
    try p.code.append(0xF3); try p.code.append(0xAA); // REP STOSB
    // Init free list: free_next[slot] = slot + 1, last = -1
    try emitXorReg(p, Reg.RCX); // slot = 0
    const fl_loop = try allocLabelId(p, "fl_loop", .{});
    const fl_done = try allocLabelId(p, "fl_done", .{});
    const fl_last = try allocLabelId(p, "fl_last", .{});
    const fl_next = try allocLabelId(p, "fl_next", .{});
    try setLabel(p, fl_loop);
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
    try emitCondLongJmp(p, .JAE_REL32, fl_done);
    // R11 = &free_next[0], R10 = slot, SHL R10, 2, ADD R11, R10 → &free_next[slot]
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_free_next) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
    // R10 = slot + 1
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.RCX, 1) });
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(64) });
    try emitCondLongJmp(p, .JAE_REL32, fl_last);
    try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) }); // free_next[slot] = slot+1
    try emitShortJmp(p, .JMP_REL32, fl_next);
    try setLabel(p, fl_last);
    try emitMovRegImm32(p, Reg.R10, 0xFFFFFFFF);
    try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) }); // free_next[63] = -1
    try setLabel(p, fl_next);
    try emitInc(p, Reg.RCX);
    try emitShortJmp(p, .JMP_REL32, fl_loop);
    try setLabel(p, fl_done);
    try emitXorReg(p, Reg.RAX); // free_head = 0
    try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_ht_free_head), x64.Operand.r(Reg.RAX) });

    try emitWin32Call(p, 0, -10);
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_hstdin), x64.Operand.r(Reg.RAX) });
    try emitWin32Call(p, 0, -11);
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_hstdout), x64.Operand.r(Reg.RAX) });
    try emitAffinityInit(p);
    if (program.entries.items.len > 0) {
        const entry = &program.entries.items[0];
        if (entry.body_lines.items.len > 0) {
            var buf = std.ArrayList(u8).init(p.allocator);
            for (entry.body_lines.items, 0..) |line, i| {
                const t = std.mem.trim(u8, line, " \t{}");
                if (t.len > 0) { if (i > 0) try buf.append(';'); try buf.appendSlice(t); }
            }
            try emitAction(p, buf.items, "");
            buf.deinit();
        }
    }
    if (program.states.items.len > 0) {
        try emitMovRegImm32(p, Reg.RAX, 4);
        try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_abudget), x64.Operand.r(Reg.RAX) });
        try emitCallToLabel(p, p.en_id[0]); try emitLongJmp(p, try allocLabelId(p, "always_entry", .{}));
    }
}

fn emitOneIntrinsic(p: *PendingOutput, intrinsic: rt.Intrinsic) !void {
    try setLabel(p, try allocLabelId(p, "rt_{d}", .{@intFromEnum(intrinsic)}));
    // Pre‑allocate all labels needed for this intrinsic subroutine.
    // The caller (emitRuntimeSection) iterates the Intrinsic enum and each
    // invocation of emitOneIntrinsic produces one self‑contained subroutine.
    // Labels are allocated ONCE and reused for both jump targets and definitions.
    switch (intrinsic) {
        .arena_l1_alloc => {
            const al1_ok = try allocLabelId(p, "al1_ok", .{});
            const al2_ok = try allocLabelId(p, "al2_ok", .{});
            const pk_0_2 = try allocLabelId(p, "pk0_2", .{});
            const pk_0_1 = try allocLabelId(p, "pk0_1", .{});
            // try L1
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_l1_ptr) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l1_end) });
            try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
            try emitShortJmp(p, .JBE_REL32, al1_ok);
            // spill to L2 → l1_spill++
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l1_spill) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_spill), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_l2_ptr) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l2_end) });
            try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
            try emitShortJmp(p, .JBE_REL32, al2_ok);
            // spill to L3 → l2_spill++
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l2_spill) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_spill), x64.Operand.r(Reg.RDX) });
            // Inline L3 pool pop
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_pool_head) });
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
            try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "rt_oom", .{}));
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RAX, 0) });
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 8), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 12), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
            try emitRet(p);
            try setLabel(p, al2_ok);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RCX) });
            // l2_allocs++
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l2_allocs) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_allocs), x64.Operand.r(Reg.RDX) });
            // peak L2
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l2_ptr) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_l2_base) });
            try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_telem_l2_peak) });
            try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try emitShortJmp(p, .JBE_REL32, pk_0_2);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_peak), x64.Operand.r(Reg.RDX) });
            try setLabel(p, pk_0_2);
            try emitRet(p);
            try setLabel(p, al1_ok);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_ptr), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RCX) });
            // l1_allocs++
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l1_allocs) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_allocs), x64.Operand.r(Reg.RDX) });
            // peak L1
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l1_ptr) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_l1_base) });
            try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_telem_l1_peak) });
            try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try emitShortJmp(p, .JBE_REL32, pk_0_1);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_peak), x64.Operand.r(Reg.RDX) });
            try setLabel(p, pk_0_1);
        },
        .arena_l2_alloc => {
            const bl2_ok = try allocLabelId(p, "bl2_ok", .{});
            const pk_1_2 = try allocLabelId(p, "pk1_2", .{});
            // try L2
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_l2_ptr) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l2_end) });
            try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
            try emitShortJmp(p, .JBE_REL32, bl2_ok);
            // spill to L3 → l2_spill++
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l2_spill) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_spill), x64.Operand.r(Reg.RDX) });
            // Inline L3 pool pop
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_pool_head) });
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
            try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "rt_oom", .{}));
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RAX, 0) });
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 8), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 12), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
            try emitRet(p);
            try setLabel(p, bl2_ok);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RCX) });
            // l2_allocs++
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l2_allocs) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_allocs), x64.Operand.r(Reg.RDX) });
            // peak L2
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l2_ptr) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_l2_base) });
            try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_telem_l2_peak) });
            try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try emitShortJmp(p, .JBE_REL32, pk_1_2);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_peak), x64.Operand.r(Reg.RDX) });
            try setLabel(p, pk_1_2);
        },
        .arena_l3_alloc => {
            // Save size in RDX, then pop pool_head
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_pool_head) });
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
            try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "rt_oom", .{}));
            // pool_head = block->free_next
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RAX, 0) });
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.R8) });
            // Store original_size and bytes_used in header
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 8), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 12), x64.Operand.r(Reg.RDX) });
            // l3_allocs++
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs) });
            try emitInc(p, Reg.R8);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs), x64.Operand.r(Reg.R8) });
            // Return data pointer (block + 16)
            try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
        },
        .arena_l1_reset => {
            // reset all three arenas (L1 + L2 + L3) — spills are scoped to state handler
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l1_base) });
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_ptr), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l2_base) });
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l3_base) });
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l3_ptr), x64.Operand.r(Reg.RAX) });
        },
        .arena_l2_reset => {
            // reset L2 arena cursor to base
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l2_base) });
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RAX) });
        },
        .arena_l3_reset => {
            // O(1) reset: pool_head = l3_base
            // free_next chain is preserved because alloc never writes to block[0]
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l3_base) });
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.RAX) });
        },
        .handle_alloc => {
            const ha_fail = try allocLabelId(p, "ha_fail", .{});
            const ha_gen_ok = try allocLabelId(p, "ha_gen_ok", .{});
            const ha_done = try allocLabelId(p, "ha_done", .{});
            // RCX = ptr, RDX = size → RAX = Handle (slot | gen << 32)
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_ht_free_head) });
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0xFFFFFFFF) });
            try emitCondLongJmp(p, .JE_REL32, ha_fail);
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
            // free_head = free_next[slot]
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_free_next) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_ht_free_head), x64.Operand.r(Reg.R10) });
            // ptrs[slot] = RCX
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(3) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.RCX) });
            // sizes[slot] = RDX
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_sizes) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.RDX) });
            // generations[slot] = prev_gen + 1 (wrap 0→1)
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try emitInc(p, Reg.R10);
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
            try emitCondLongJmp(p, .JNE_REL32, ha_gen_ok);
            try emitInc(p, Reg.R10);
            try setLabel(p, ha_gen_ok);
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // Save gen in R8 for handle construction
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.R10) });
            // states[slot] = 1 (Used)
            try emitMovRegImm32(p, Reg.R10, 1);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // heats[slot] = 0
            try emitXorReg(p, Reg.R10);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_heats) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R14), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R14), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R14) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // tiers[slot] = 0 (L1)
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_tiers) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // Restore gen from R8, build handle: RAX = slot | gen << 32
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(32) });
            try x64.emit(&p.code, .OR_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R10) });
            try emitShortJmp(p, .JMP_REL32, ha_done);
            try setLabel(p, ha_fail);
            try emitXorReg(p, Reg.RAX);
            try setLabel(p, ha_done);
        },
        .handle_access => {
            const ha_fail = try allocLabelId(p, "ha_fail", .{});
            const ha_done = try allocLabelId(p, "ha_done", .{});
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
            try emitCondLongJmp(p, .JAE_REL32, ha_fail);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
            try emitCondLongJmp(p, .JNE_REL32, ha_fail);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
            try emitCondLongJmp(p, .JNE_REL32, ha_fail);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(3) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.R11, 0) });
            try emitShortJmp(p, .JMP_REL32, ha_done);
            try setLabel(p, ha_fail);
            try emitXorReg(p, Reg.RAX);
            try setLabel(p, ha_done);
        },
        .handle_release => {
            const hr_skip = try allocLabelId(p, "hr_skip", .{});
            const hr_gen_ok = try allocLabelId(p, "hr_gen_ok", .{});
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
            try emitCondLongJmp(p, .JAE_REL32, hr_skip);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
            try emitCondLongJmp(p, .JNE_REL32, hr_skip);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
            try emitCondLongJmp(p, .JNE_REL32, hr_skip);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try emitXorReg(p, Reg.R10);
            try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(3) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try emitXorReg(p, Reg.R10);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_sizes) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try emitXorReg(p, Reg.R10);
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_heats) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try emitXorReg(p, Reg.R10);
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // tiers[slot] = 0
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_tiers) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.RBP, p.off_ht_free_head) });
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_free_next) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_ht_free_head), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try emitInc(p, Reg.R10);
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
            try emitCondLongJmp(p, .JNE_REL32, hr_gen_ok);
            try emitInc(p, Reg.R10);
            try setLabel(p, hr_gen_ok);
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try setLabel(p, hr_skip);
        },
        .handle_validate => {
            const hv_ok = try allocLabelId(p, "hv_ok", .{});
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
            try emitCondLongJmp(p, .JAE_REL32, try allocLabelId(p, "rt_14", .{}));
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
            try emitCondLongJmp(p, .JNE_REL32, try allocLabelId(p, "rt_14", .{}));
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
            try emitCondLongJmp(p, .JNE_REL32, try allocLabelId(p, "rt_14", .{}));
            try setLabel(p, hv_ok);
        },
        .log_event => {
            // stub — no-op (to be implemented)
        },
        .handle_touch => {
            const ht_skip = try allocLabelId(p, "ht_skip", .{});
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
            try emitCondLongJmp(p, .JAE_REL32, ht_skip);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
            try emitCondLongJmp(p, .JNE_REL32, ht_skip);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
            try emitCondLongJmp(p, .JNE_REL32, ht_skip);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_heats) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(0xFFFFFFFF) });
            try emitCondLongJmp(p, .JE_REL32, ht_skip);
            try emitInc(p, Reg.R10);
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try setLabel(p, ht_skip);
        },
        .move_hotter => {
            const mh_skip = try allocLabelId(p, "mh_skip", .{});
            const mh_panic = try allocLabelId(p, "rt_14", .{});
            try emitTierMove(p, mh_skip, mh_panic, "mh", -1);
            try setLabel(p, mh_skip);
        },
        .move_colder => {
            const mc_skip = try allocLabelId(p, "mc_skip", .{});
            const mc_panic = try allocLabelId(p, "rt_14", .{});
            try emitTierMove(p, mc_skip, mc_panic, "mc", 1);
            try setLabel(p, mc_skip);
        },
        .tick => {
            const loop_label = try allocLabelId(p, "tick_loop", .{});
            const done_label = try allocLabelId(p, "tick_done", .{});
            const tick_next = try allocLabelId(p, "tick_next", .{});
            const tick_skip_mig = try allocLabelId(p, "tick_skip_mig", .{});
            const tick_try_demote = try allocLabelId(p, "tick_try_demote", .{});
const mh_label = try allocLabelId(p, "rt_{d}", .{@intFromEnum(rt.Intrinsic.move_hotter)});
const mc_label = try allocLabelId(p, "rt_{d}", .{@intFromEnum(rt.Intrinsic.move_colder)});
            try emitMovRegImm32(p, Reg.R12, 4);
            try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_epoch) });
            try emitInc(p, Reg.RAX);
            try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_epoch), x64.Operand.r(Reg.RAX) });
            try emitXorReg(p, Reg.RCX);
            try setLabel(p, loop_label);
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
            try emitCondLongJmp(p, .JAE_REL32, done_label);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
            try emitCondLongJmp(p, .JE_REL32, tick_next);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_heats) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.RBX), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.code, .SHIFT_RIGHT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // Migration: check budget, thresholds, tier
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.R12), x64.Operand.r(Reg.R12) });
            try emitCondLongJmp(p, .JE_REL32, tick_skip_mig);
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_tiers) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.R11, 0) });
            // Promote: heat > 100 && tier > 0
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(100) });
            try emitCondLongJmp(p, .JBE_REL32, tick_try_demote);
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.R9) });
            try emitCondLongJmp(p, .JE_REL32, tick_try_demote);
            // Move hotter: RCX=slot, RDX=generations[slot]
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R13), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R13) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.R11, 0) });
            try emitCallToLabel(p, mh_label);
            try emitDec(p, Reg.R12);
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.R13) });
            try emitShortJmp(p, .JMP_REL32, tick_next);
            try setLabel(p, tick_try_demote);
            // Demote: heat > 0 && heat < 30 && tier < 2
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(30) });
            try emitCondLongJmp(p, .JAE_REL32, tick_skip_mig);
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
            try emitCondLongJmp(p, .JE_REL32, tick_skip_mig);
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R9), x64.Operand.immU32(2) });
            try emitCondLongJmp(p, .JAE_REL32, tick_skip_mig);
            // Move colder: RCX=slot, RDX=generations[slot]
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R13), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R13) });
            try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.R11, 0) });
            try emitCallToLabel(p, mc_label);
            try emitDec(p, Reg.R12);
            try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.R13) });
            try setLabel(p, tick_skip_mig);
            try setLabel(p, tick_next);
            try emitInc(p, Reg.RCX);
            try emitShortJmp(p, .JMP_REL32, loop_label);
            try setLabel(p, done_label);
        },
        .panic => {
            // ExitProcess(1)
            try emitXorReg(p, Reg.RCX);
            try emitInc(p, Reg.RCX);
            try emitShadowCall(p, 3);
        },
    }
    try emitRet(p);
}

fn emitRuntimeSection(p: *PendingOutput) !void {
    inline for (comptime std.meta.tags(rt.Intrinsic)) |tag| {
        try emitOneIntrinsic(p, tag);
    }

    // oom helper (shared across alloc intrinsics)
    try setLabel(p, try allocLabelId(p, "rt_oom", .{}));
    try emitXorReg(p, Reg.RAX);
    try emitRet(p);

    // L3 compression/decompression helper subroutines
    try emitL3Helpers(p);
}

fn emitIntrinsicCall(p: *PendingOutput, intrinsic: rt.Intrinsic) !void {
    try emitCallToLabel(p, try allocLabelId(p, "rt_{d}", .{@intFromEnum(intrinsic)}));
}

fn emitRet(p: *PendingOutput) !void {
    try p.code.append(0xC3);
}

fn emitPushR64(p: *PendingOutput, reg: i16) !void {
    if (reg >= 8) try p.code.append(0x41);
    try p.code.append(@as(u8, @intCast(0x50 + (reg & 7))));
}

fn emitPopR64(p: *PendingOutput, reg: i16) !void {
    if (reg >= 8) try p.code.append(0x41);
    try p.code.append(@as(u8, @intCast(0x58 + (reg & 7))));
}

fn emitAffinityInit(p: *PendingOutput) !void {
    try emitMovRegImm32(p, Reg.RAX, 0x1A);
    try p.code.append(0x0F); try p.code.append(0xA2);
    try p.code.append(0xC1); try p.code.append(0xE8); try p.code.append(0x18);
    try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_core_type), x64.Operand.r(Reg.RAX) });
    try emitShadowCall(p, 8);
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
    const mask: i64 = if (p.has_hot_states) 15 else -16;
    try emitLoadImm(p, Reg.RDX, mask);
    try emitShadowCall(p, 7);
}

const SortedEntry = struct { idx: usize, hw: f64 };

fn emitStateEnterFuncs(p: *PendingOutput, program: ast.ProgramNode) !void {
    var sorted = std.ArrayList(SortedEntry).init(p.allocator);
    defer sorted.deinit();
    for (program.states.items, 0..) |s, i| try sorted.append(.{ .idx = i, .hw = s.hot_weight orelse 0.5 });
    std.mem.sort(SortedEntry, sorted.items, {}, struct {
        fn lessThan(_: void, a: SortedEntry, b: SortedEntry) bool {
            const ag: u32 = if (a.hw >= 0.8) 2 else if (a.hw <= 0.3) 0 else 1;
            const bg: u32 = if (b.hw >= 0.8) 2 else if (b.hw <= 0.3) 0 else 1;
            if (ag != bg) return ag > bg;
            return a.idx < b.idx;
        }
    }.lessThan);
    for (sorted.items) |item| {
        const state = program.states.items[item.idx];
        if ((state.hot_weight orelse 0) >= 0.8) {
            const av = state.cache_align orelse 64;
            if (av == 64) { try alignTo64(p); } else if (av >= 16) { while (p.code.items.len % @as(usize, @intCast(av)) != 0) try p.code.append(0x90); }
        }
        const start_off = p.code.items.len;
        try setLabel(p, p.en_id[item.idx]);
        // Re-init @Cache(L1) variables on state entry
        for (state.variables.items) |v| {
            if (v.cache_policy) |cp| {
                if (std.mem.eql(u8, cp, "L1")) {
                    try emitLoadImm(p, Reg.RAX, parseNumber(v.default_value orelse "0"));
                    const vo = getVarOffset(p, state.name, v.name);
                    if (vo != std.math.minInt(i32)) try emitStoreVarFromReg(p, vo, Reg.RAX, getVarSize(p, state.name, v.name));
                }
            }
        }
        if (state.enter_body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, state.name); }
        for (state.transitions.items) |t| {
            if (t.body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, state.name); }
        }
        var lv = std.ArrayList(*const ast.TransitionNode).init(p.allocator);
        for (state.transitions.items) |*t| try lv.append(t);
        std.mem.sort(*const ast.TransitionNode, lv.items, {}, struct {
            fn lessThan(_: void, a: *const ast.TransitionNode, b: *const ast.TransitionNode) bool {
                return (a.hot_weight orelse 0.5) > (b.hot_weight orelse 0.5);
            }
        }.lessThan);
        const pc = @min(lv.items.len, 3);
        for (0..pc) |ti| {
            const t = lv.items[ti];
            const ti_idx = p.state_index_map.get(t.target).?;
            const ts = program.states.items[ti_idx];
            const level: i32 = if (ts.cache_policy) |cp| blk: { if (std.mem.eql(u8, cp, "L2")) break :blk 2; if (std.mem.eql(u8, cp, "L3")) break :blk 3; break :blk 1; } else 1;
            if (p.state_vars.get(t.target)) |vars| { for (vars.items) |sv| try emitPrefetchData(p, sv.stack_offset, level); }
            if (level <= 1) try emitPrefetch(p, p.en_id[ti_idx]);
        }
        lv.deinit();
        try x64.emit(&p.code, .RET, &.{});
        const end_off = p.code.items.len;
        const scb_key = try std.fmt.allocPrint(p.allocator, "{d}", .{item.idx});
        try p.state_code_bounds.put(scb_key, .{ .start = start_off, .end = end_off });
    }
}

fn padForCacheAssociativity(p: *PendingOutput, program: ast.ProgramNode) !void {
    _ = program;
    var set_occ = std.AutoHashMap(u32, u32).init(p.allocator);
    defer set_occ.deinit();
    var it = p.state_code_bounds.iterator();
    while (it.next()) |entry| {
        const oi = std.fmt.parseInt(u32, entry.key_ptr.*, 10) catch continue;
        const offset: u32 = @intCast(entry.value_ptr.start);
        const orig_end: u32 = @intCast(entry.value_ptr.end);
        const set = offset % 4096;
        const cnt = set_occ.get(set) orelse 0;
        if (cnt >= 8) {
            var pad: usize = 4096 - (offset % 4096);
            if (pad == 4096) pad = 0;
            try emitNop(p, @intCast(pad));
            const orig_sz = orig_end - offset;
            const new_off: u32 = @intCast(p.code.items.len);
            try setLabelAt(p, p.en_id[oi], new_off);
            try p.state_code_bounds.put(entry.key_ptr.*, .{ .start = new_off, .end = new_off + orig_sz });
            try set_occ.put(0, 1);
        } else try set_occ.put(set, cnt + 1);
    }
}

fn analyzeTraces(program: ast.ProgramNode, state_index_map: std.StringHashMap(usize)) !std.ArrayList(Trace) {
    var traces = std.ArrayList(Trace).init(state_index_map.allocator);
    var si: usize = 0;
    while (si < program.states.items.len) {
        var chain_len: usize = 1;
        while (si + chain_len < program.states.items.len) {
            const prev = program.states.items[si + chain_len - 1];
            const prev_ti = if (prev.transitions.items.len == 1 and prev.transitions.items[0].is_always and (prev.transitions.items[0].event_name == null or prev.transitions.items[0].event_name.?.len == 0)) state_index_map.get(prev.transitions.items[0].target).? else program.states.items.len;
            if (prev_ti == si + chain_len) {
                chain_len += 1;
            } else break;
        }
        var total_hw: f64 = 0;
        for (si..si + chain_len) |i| {
            total_hw += program.states.items[i].hot_weight orelse 0.5;
        }
        try traces.append(.{ .start_state = si, .len = chain_len, .hot_weight = total_hw / @as(f64, @floatFromInt(chain_len)) });
        si += chain_len;
    }
    return traces;
}

fn emitEventLoop(p: *PendingOutput, program: ast.ProgramNode) !void {
    try setLabel(p, try allocLabelId(p, "evloop", .{}));
    try emitMovRegImm32(p, Reg.RAX, 4);
    try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_abudget), x64.Operand.r(Reg.RAX) });
    try emitIntrinsicCall(p, .tick);
    try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_hstdin) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try emitMovRegImm32(p, Reg.R8, 256);
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.RBP, p.off_chars_read) });
    try x64.emit(&p.code, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try emitXorReg(p, Reg.RAX);
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 32), x64.Operand.r(Reg.RAX) });
    try emitIatCall(p, 2);
    try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_chars_read) });
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try x64.emit(&p.code, .XOR_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_cursor), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_remaining), x64.Operand.r(Reg.RAX) });
    try alignTo16(p);
    try setLabel(p, try allocLabelId(p, "re_dispatch", .{}));
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_remaining) });
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "always_entry", .{}));
    const ex_idx = try addPoolString(p, "exit");
    try emitRipLea(p, Reg.RSI, ex_idx);
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_cursor) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RAX) });
    try setLabel(p, try allocLabelId(p, "exl", .{}));
    try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
    try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RBX), x64.Operand.mem(Reg.RSI, 0) });
    try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
    try emitShortJmp(p, .JNE_REL32, try allocLabelId(p, "exce", .{}));
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try emitInc(p, Reg.RDI); try emitInc(p, Reg.RSI);
    try emitShortJmp(p, .JMP_REL32, try allocLabelId(p, "exl", .{}));
    try setLabel(p, try allocLabelId(p, "exce", .{}));
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RBX) });
    try emitShortJmp(p, .JE_REL32, try allocLabelId(p, "ex_chk_term", .{}));
    try emitShortJmp(p, .JMP_REL32, try allocLabelId(p, "no_exit", .{}));
    try setLabel(p, try allocLabelId(p, "ex_skip_ws", .{}));
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
    try setLabel(p, try allocLabelId(p, "ex_chk_term", .{}));
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x20) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "ex_skip_ws", .{}));
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x09) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "ex_skip_ws", .{}));
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0A) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0D) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try emitShortJmp(p, .JMP_REL32, try allocLabelId(p, "no_exit", .{}));
    try setLabel(p, try allocLabelId(p, "always_entry", .{}));
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_abudget) });
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "evloop", .{}));
    try emitLongJmp(p, try allocLabelId(p, "always_dispatch", .{}));
    try setLabel(p, try allocLabelId(p, "always_dispatch", .{}));
    try setLabel(p, try allocLabelId(p, "no_exit", .{}));
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R12), x64.Operand.mem(Reg.RBP, p.off_cur_state) });
    // Jump table dispatch: bounds check + O(1) indirect jump via [table + state*4]
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R12), x64.Operand.immU32(@intCast(p.state_names.items.len)) });
    try emitCondLongJmp(p, .JAE_REL32, try allocLabelId(p, "re_dispatch", .{}));
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(255, 0) });
    try p.pending_fixups.append(.{ .offset = p.code.items.len - 4, .disp_size = 4, .label_id = try allocLabelId(p, "jmp_table", .{}) });
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.memIdx(Reg.R11, Reg.R12, 4, 0) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R11) });
    try p.code.append(0xFF); try p.code.append(0xE0);
    // Emit jump table (entries filled after fixups)
    try setLabel(p, try allocLabelId(p, "jmp_table", .{}));
    for (0..p.state_names.items.len) |_| try p.code.appendNTimes(0, 4);
    // Analyze traces (superblock chains) and emit in hot-first order
    var traces = try analyzeTraces(program, p.state_index_map);
    defer traces.deinit();
    std.mem.sort(Trace, traces.items, {}, struct {
        fn lessThan(_: void, a: Trace, b: Trace) bool {
            if (a.hot_weight != b.hot_weight) return a.hot_weight > b.hot_weight;
            return a.start_state < b.start_state;
        }
    }.lessThan);
    for (traces.items) |trace| {
        for (trace.start_state..trace.start_state + trace.len) |block_si| {
            const is_last = block_si == trace.start_state + trace.len - 1;
            const bs = program.states.items[block_si];
            try setLabel(p, p.dp_id[block_si]);
            // Profiling: increment state hit counter
            const hit_off = p.off_state_hits + @as(i32, @intCast(block_si)) * 8;
            try p.code.append(0x48); // REX.W
            try p.code.append(0xFF); // Opcode
            try p.code.append(0x85); // ModRM: mod=10(disp32), reg=0(INC), rm=101(RBP)
            try p.code.appendSlice(&@as([4]u8, @bitCast(hit_off)));
            if ((bs.hot_weight orelse 0.5) <= 0.3) try emitPrefetchColdData(p, &bs);
            try emitStateDispatch(p, &bs, block_si, program, if (trace.len > 1) !is_last else false);
            if (is_last) try emitLongJmp(p, try allocLabelId(p, "advance_cursor", .{}));
        }
    }
    try emitLongJmp(p, try allocLabelId(p, "advance_cursor", .{}));
    try alignTo16(p);
    try setLabel(p, try allocLabelId(p, "advance_cursor", .{}));
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_cursor) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_remaining) });
    try setLabel(p, try allocLabelId(p, "adv_scan", .{}));
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RCX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "evloop", .{}));
    try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitShortJmp(p, .JE_REL32, try allocLabelId(p, "adv_found", .{}));
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0A) });
    try emitShortJmp(p, .JE_REL32, try allocLabelId(p, "adv_found", .{}));
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0D) });
    try emitShortJmp(p, .JE_REL32, try allocLabelId(p, "adv_cr", .{}));
    try emitInc(p, Reg.RDI); try emitDec(p, Reg.RCX);
    try emitShortJmp(p, .JMP_REL32, try allocLabelId(p, "adv_scan", .{}));
    try setLabel(p, try allocLabelId(p, "adv_cr", .{}));
    try emitInc(p, Reg.RDI); try emitDec(p, Reg.RCX);
    try emitShortJmp(p, .JE_REL32, try allocLabelId(p, "adv_done", .{}));
    try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0A) });
    try emitShortJmp(p, .JNE_REL32, try allocLabelId(p, "adv_done", .{}));
    try emitInc(p, Reg.RDI); try emitDec(p, Reg.RCX);
    try emitShortJmp(p, .JMP_REL32, try allocLabelId(p, "adv_done", .{}));
    try setLabel(p, try allocLabelId(p, "adv_found", .{}));
    try emitInc(p, Reg.RDI); try emitDec(p, Reg.RCX);
    try setLabel(p, try allocLabelId(p, "adv_done", .{}));
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RDI) });
    try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_remaining) });
    try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_remaining), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_cursor), x64.Operand.r(Reg.RDI) });
    try emitLongJmp(p, try allocLabelId(p, "re_dispatch", .{}));
    try setLabel(p, try allocLabelId(p, "exit_process", .{}));
    // Telemetry dump: build "TELEM:XXXXXXXXXXXXXXXX...XXXXXXXXXXXXXXXX\n" in buf (256B, dead at exit)
    const th_sub = try allocLabelId(p, "th_sub", .{});
    const th_lp = try allocLabelId(p, "th_lp", .{});
    const th_hd = try allocLabelId(p, "th_hd", .{});
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.code, .MOV_R64_IMM64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(0x00003A4D454C4554) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RDI), x64.Operand.immU32(6) });
    const telem_offs = [_]i32{
        p.off_telem_l1_spill, p.off_telem_l2_spill,
        p.off_telem_l1_peak, p.off_telem_l2_peak, p.off_telem_l3_peak,
        p.off_telem_l1_allocs, p.off_telem_l2_allocs, p.off_telem_l3_allocs,
    };
    inline for (telem_offs, 0..) |off, i| {
        try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, off) });
        try emitCallToLabel(p, th_sub);
        if (i < telem_offs.len - 1) {
            try emitMovRegImm32(p, Reg.RAX, ' ');
            try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
            try emitInc(p, Reg.RDI);
        }
    }
    try emitMovRegImm32(p, Reg.RAX, 0x0A);
    try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    // WriteFile(stdout, buf, length)
    try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_hstdout) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDI) });
    try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.RBP, p.off_chars_written) });
    try x64.emit(&p.code, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try emitXorReg(p, Reg.RAX);
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 32), x64.Operand.r(Reg.RAX) });
    try emitIatCall(p, 1);
    try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    // State hit profile dump
    try alignTo16(p);
    try setLabel(p, try allocLabelId(p, "sth_start", .{}));
    // RSI = &state_hits[0], R12 = state count (loop counter)
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RSI), x64.Operand.mem(Reg.RBP, p.off_state_hits) });
    try emitMovRegImm32(p, Reg.R12, @intCast(program.states.items.len));
    try setLabel(p, try allocLabelId(p, "sth_loop", .{}));
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try emitMovRegImm32(p, Reg.RAX, 'S');
    try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try emitMovRegImm32(p, Reg.RAX, ' ');
    try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RSI, 0) });
    try emitCallToLabel(p, th_sub);
    try emitMovRegImm32(p, Reg.RAX, 0x0A);
    try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    // WriteFile(stdout, buf, length)
    try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_hstdout) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDI) });
    try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.RBP, p.off_chars_written) });
    try x64.emit(&p.code, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try emitXorReg(p, Reg.RAX);
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 32), x64.Operand.r(Reg.RAX) });
    try emitIatCall(p, 1);
    try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSI), x64.Operand.immU32(8) });
    try emitDec(p, Reg.R12);
    try emitCondLongJmp(p, .JNE_REL32, try allocLabelId(p, "sth_loop", .{}));
    try emitLongJmp(p, try allocLabelId(p, "exit_end", .{}));
    // Hex conversion subroutine (reached only via CALL)
    try setLabel(p, th_sub);
    try emitMovRegImm32(p, Reg.RCX, 16);
    try setLabel(p, th_lp);
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .SHIFT_RIGHT, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(60) });
    try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(0x30) });
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(0x39) });
    try emitShortJmp(p, .JBE_REL32, th_hd);
    try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(0x27) });
    try setLabel(p, th_hd);
    try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RDX) });
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(4) });
    try emitDec(p, Reg.RCX);
    try emitCondLongJmp(p, .JNE_REL32, th_lp);
    try emitRet(p);
    try setLabel(p, try allocLabelId(p, "exit_end", .{}));
    // ExitProcess
    try emitWin32Call(p, 3, 0);
    try emitLongJmp(p, try allocLabelId(p, "exit_process", .{}));
}

fn emitStateDispatch(p: *PendingOutput, state: *const ast.StateDefNode, si: usize, program: ast.ProgramNode, fuse: bool) !void {
    for (state.transitions.items, 0..) |t, ti_| {
        _ = ti_;
        if ((t.event_name != null and t.event_name.?.len > 0) or !t.is_always) continue;
        if (t.is_always and (t.event_name == null or t.event_name.?.len == 0)) {
            if (t.guard == null or t.guard.?.len == 0) {
                if (t.body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, state.name); }
                try changeToState(p, t.target, si, program, true, fuse);
                return;
            }
            try emitGuardSkip(p, t.guard.?, si, 0);
            if (t.body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, state.name); }
            try changeToState(p, t.target, si, program, true, fuse);
            try setLabel(p, try allocLabelId(p, "sk_{d}_{d}", .{si, 0}));
        }
    }
    var eg_keys = std.ArrayList([]const u8).init(p.allocator);
    var eg_lists = std.StringHashMap(std.ArrayList(*const ast.TransitionNode)).init(p.allocator);
    defer { eg_keys.deinit(); var git = eg_lists.iterator(); while (git.next()) |e| e.value_ptr.deinit(); eg_lists.deinit(); }
    for (state.transitions.items) |*t| {
        if (t.event_name == null or t.event_name.?.len == 0) continue;
        if (eg_lists.getPtr(t.event_name.?)) |list| { try list.append(t); }
        else { var nl = std.ArrayList(*const ast.TransitionNode).init(p.allocator); try nl.append(t); try eg_lists.put(t.event_name.?, nl); try eg_keys.append(t.event_name.?); }
    }
    var eg_idx: usize = 0;
    for (eg_keys.items) |en| {
        const tl = eg_lists.get(en) orelse continue;
        const str_idx = try addPoolString(p, en);
        try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
        try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_cursor) });
        try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RAX) });
        const done_label = try allocLabelId(p, "eg_done_{d}_{d}", .{si, eg_idx});
        const ws_label = try allocLabelId(p, "eg_ws_{d}_{d}", .{si, eg_idx});
        const match_label = try allocLabelId(p, "eg_mt_{d}_{d}", .{si, eg_idx});
        if (en.len <= 4 and en.len > 0) {
            try emitCompiledEventMatch(p, en, done_label, ws_label, match_label);
        } else {
            try emitRipLea(p, Reg.RSI, str_idx);
            const ll = try allocLabelId(p, "eg_lp_{d}_{d}", .{si, eg_idx});
            const ce = try allocLabelId(p, "eg_ce_{d}_{d}", .{si, eg_idx});
            const skip_label = try allocLabelId(p, "eg_skip_{d}_{d}", .{si, eg_idx});
            try setLabel(p, ll);
            try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RBX), x64.Operand.mem(Reg.RSI, 0) });
            try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
            try emitShortJmp(p, .JNE_REL32, ce);
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
            try emitShortJmp(p, .JE_REL32, match_label);
            try emitInc(p, Reg.RDI); try emitInc(p, Reg.RSI);
            try emitShortJmp(p, .JMP_REL32, ll);
            try setLabel(p, ce);
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RBX) });
            try emitCondLongJmp(p, .JE_REL32, skip_label);
            try emitLongJmp(p, done_label);
            try setLabel(p, ws_label);
            try emitInc(p, Reg.RDI);
            try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try setLabel(p, skip_label);
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x20) });
            try emitShortJmp(p, .JE_REL32, ws_label);
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x09) });
            try emitShortJmp(p, .JE_REL32, ws_label);
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
            try emitShortJmp(p, .JE_REL32, match_label);
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0A) });
            try emitShortJmp(p, .JE_REL32, match_label);
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0D) });
            try emitShortJmp(p, .JE_REL32, match_label);
            try emitLongJmp(p, done_label);
        }
        try setLabel(p, match_label);
        var specific = std.ArrayList(*const ast.TransitionNode).init(p.allocator);
        var neq = std.ArrayList(*const ast.TransitionNode).init(p.allocator);
        var guardless = std.ArrayList(*const ast.TransitionNode).init(p.allocator);
        for (tl.items) |tt| {
            if (tt.guard) |g| {
                if (std.mem.indexOf(u8, g, "!=") != null) {
                    try neq.append(tt);
                } else {
                    try specific.append(tt);
                }
            } else {
                try guardless.append(tt);
            }
        }
        var allTis = std.ArrayList(*const ast.TransitionNode).init(p.allocator);
        try allTis.appendSlice(specific.items);
        try allTis.appendSlice(guardless.items);
        try allTis.appendSlice(neq.items);
        // Find the original index for each transition
        for (allTis.items) |tt| {
            var orig_ti: usize = 0;
            for (state.transitions.items, 0..) |*st, sti| { if (@intFromPtr(st) == @intFromPtr(tt)) { orig_ti = sti; break; } }
            if (tt.guard) |g| { if (g.len > 0) { try emitGuardSkip(p, g, si, orig_ti); } }
            try emitPrefetchForTransitionCacheAware(p, tt);
            if (tt.body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, state.name); }
            try changeToState(p, tt.target, si, program, false, false);
            try setLabel(p, try allocLabelId(p, "sk_{d}_{d}", .{si, orig_ti}));
        }
        specific.deinit(); neq.deinit(); guardless.deinit(); allTis.deinit();
        try setLabel(p, try allocLabelId(p, "eg_done_{d}_{d}", .{si, eg_idx}));
        eg_idx += 1;
    }
}

fn emitGuardSkip(p: *PendingOutput, guard: []const u8, si: usize, ti: usize) !void {
    const skip = try allocLabelId(p, "sk_{d}_{d}", .{si, ti});
    const g = std.mem.trim(u8, guard, " \t");
    if (g.len == 0) return;
    const ops = [_][]const u8{ ">=", "<=", "==", "!=", ">", "<" };
    var lhs: []const u8 = ""; var op: []const u8 = ""; var rhs: []const u8 = "";
    for (ops) |o| {
        if (std.mem.indexOf(u8, g, o)) |idx| {
            if (idx > 0) { lhs = std.mem.trim(u8, g[0..idx], " \t"); op = o; rhs = std.mem.trim(u8, g[idx + o.len..], " \t"); break; }
        }
    }
    if (op.len == 0) return;
    if (!try tryLoadVarToReg(p, Reg.RAX, lhs, "")) {
        if (parseNumber(lhs) != 0 or (lhs.len > 0 and (std.ascii.isDigit(lhs[0]) or lhs[0] == '-'))) {
            try emitLoadImm(p, Reg.RAX, parseNumber(lhs));
        } else {
            try emitXorReg(p, Reg.RAX);
        }
    }
    if (!try tryLoadVarToReg(p, Reg.RBX, rhs, "")) {
        const rn = parseNumber(rhs);
        if (rn != 0 or (rhs.len > 0 and (std.ascii.isDigit(rhs[0]) or rhs[0] == '-'))) {
            try emitLoadImm(p, Reg.RBX, rn);
        } else {
            try x64.emit(&p.code, .XOR_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RBX) });
        }
    }
    try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
    if (std.mem.eql(u8, op, ">")) { try emitCondLongJmp(p, .JLE_REL32, skip); }
    else if (std.mem.eql(u8, op, "<")) { try emitCondLongJmp(p, .JGE_REL32, skip); }
    else if (std.mem.eql(u8, op, ">=")) { try emitCondLongJmp(p, .JL_REL32, skip); }
    else if (std.mem.eql(u8, op, "<=")) { try emitCondLongJmp(p, .JG_REL32, skip); }
    else if (std.mem.eql(u8, op, "==")) { try emitCondLongJmp(p, .JNE_REL32, skip); }
    else if (std.mem.eql(u8, op, "!=")) { try emitCondLongJmp(p, .JE_REL32, skip); }
}

fn emitCompiledEventMatch(p: *PendingOutput, en: []const u8, done_label: u32, ws_label: u32, match_label: u32) !void {
    const len = en.len;
    if (len == 0 or len > 4) return;
    switch (len) {
        1 => {
            try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(en[0]) });
            try emitCondLongJmp(p, .JNE_REL32, done_label);
        },
        2 => {
            const imm = @as(u16, en[0]) | (@as(u16, en[1]) << 8);
            try x64.emit(&p.code, .MOVZX_R64_MEM16, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(imm) });
            try emitCondLongJmp(p, .JNE_REL32, done_label);
        },
        3 => {
            const imm16 = @as(u16, en[0]) | (@as(u16, en[1]) << 8);
            try x64.emit(&p.code, .MOVZX_R64_MEM16, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(imm16) });
            try emitCondLongJmp(p, .JNE_REL32, done_label);
            try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 2) });
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(en[2]) });
            try emitCondLongJmp(p, .JNE_REL32, done_label);
        },
        4 => {
            const imm = @as(u32, en[0]) | (@as(u32, en[1]) << 8) | (@as(u32, en[2]) << 16) | (@as(u32, en[3]) << 24);
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(imm) });
            try emitCondLongJmp(p, .JNE_REL32, done_label);
        },
        else => unreachable,
    }
    try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, @intCast(len)) });
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x20) });
    try emitShortJmp(p, .JE_REL32, ws_label);
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x09) });
    try emitShortJmp(p, .JE_REL32, ws_label);
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitShortJmp(p, .JE_REL32, match_label);
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0A) });
    try emitShortJmp(p, .JE_REL32, match_label);
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0D) });
    try emitShortJmp(p, .JE_REL32, match_label);
    try emitLongJmp(p, done_label);
}

fn changeToState(p: *PendingOutput, target: []const u8, current_si: usize, program: ast.ProgramNode, jump_to_scheduler: bool, fuse: bool) !void {
    const ti = p.state_index_map.get(target).?;
    if (!fuse) try emitIntrinsicCall(p, rt.Intrinsic.arena_l1_reset);
    const cur_state = program.states.items[current_si];
    if (cur_state.exit_body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, cur_state.name); }
    for (cur_state.transitions.items) |act| {
        if (act.body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, cur_state.name); }
    }
    try emitMovRegImm32(p, Reg.RAX, @intCast(ti));
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_cur_state), x64.Operand.r(Reg.RAX) });
    try emitCallToLabel(p, p.en_id[ti]);
    if (jump_to_scheduler) {
        if (!fuse) {
            try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_abudget) });
            try x64.emit(&p.code, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(1) });
            try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_abudget), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
            try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "always_entry", .{}));
            try emitLongJmp(p, p.dp_id[ti]);
        }
    } else {
        try emitLongJmp(p, try allocLabelId(p, "advance_cursor", .{}));
    }
}

fn emitCacheBudgetChecks(p: *PendingOutput, program: ast.ProgramNode) !void {
    _ = program;
    const re_disp_start = getLabel(p, try allocLabelId(p, "re_dispatch", .{})) orelse 0;
    const ad_start = getLabel(p, try allocLabelId(p, "advance_cursor", .{})) orelse 0;
    const loop_end = if (ad_start > re_disp_start) ad_start else p.code.items.len;
    const loop_bytes = if (loop_end > re_disp_start) loop_end - re_disp_start else 0;
    var hot_enter: usize = 0;
    var it = p.state_code_bounds.iterator();
    while (it.next()) |entry| {
        hot_enter += entry.value_ptr.end - entry.value_ptr.start;
    }
    const total_hot = loop_bytes + hot_enter;
    if (total_hot > 24576) {
        const w = try std.fmt.allocPrint(p.allocator, "; L1i: hot {d}B > 75% of 32KB\x00", .{total_hot});
        try p.code.appendSlice(w);
        p.allocator.free(w);
    }
}

fn embedStringPool(p: *PendingOutput) !void {
    for (p.string_list.items, 0..) |s, i| {
        try setLabel(p, try allocLabelId(p, "str_{d}", .{i}));
        try p.code.appendSlice(s);
        try p.code.append(0);
    }
}

fn emitImportTable(p: *PendingOutput) !u32 {
    const base_off = @as(u32, @intCast(p.code.items.len));
    const nf = IMPORT_FNS.len;
    const desc_size: u32 = 2 * 20;
    const int_off = base_off + desc_size;
    const int_sz: u32 = @as(u32, @intCast((nf + 1) * 8));
    const dll_name_off = int_off + int_sz;
    const dll_name = "kernel32.dll\x00";
    const hint_base = dll_name_off + @as(u32, @intCast(dll_name.len));
    var hint_offs = std.ArrayList(u32).init(p.allocator);
    var hint_dats = std.ArrayList([]const u8).init(p.allocator);
    var cur = hint_base;
    for (IMPORT_FNS) |fn_name| {
        try hint_offs.append(cur);
        const d = try std.fmt.allocPrint(p.allocator, "{s}\x00", .{fn_name});
        try hint_dats.append(d);
        cur += 2 + @as(u32, @intCast(d.len));
    }
    const iat_off = cur;
    // IMAGE_IMPORT_DESCRIPTOR
    try p.code.appendSlice(&@as([4]u8, @bitCast(SectionRva + int_off))); // OriginalFirstThunk
    try p.code.appendNTimes(0, 4); // TimeDateStamp
    try p.code.appendNTimes(0, 4); // ForwarderChain
    try p.code.appendSlice(&@as([4]u8, @bitCast(SectionRva + dll_name_off))); // Name
    try p.code.appendSlice(&@as([4]u8, @bitCast(SectionRva + iat_off))); // FirstThunk
    try p.code.appendNTimes(0, 20);

    // INT
    for (hint_offs.items) |ho| try p.code.appendSlice(&@as([8]u8, @bitCast(@as(u64, SectionRva + ho))));
    try p.code.appendNTimes(0, 8);

    // DLL name
    try p.code.appendSlice(dll_name);

    // Hint/name entries
    for (hint_dats.items) |hd| { try p.code.append(0); try p.code.append(0); try p.code.appendSlice(hd); }

    // IAT
    for (hint_offs.items) |ho| try p.code.appendSlice(&@as([8]u8, @bitCast(@as(u64, SectionRva + ho))));
    try p.code.appendNTimes(0, 8);

    for (IMPORT_FNS, 0..) |_, i| {
        const iat_label_val = @as(usize, @intCast(iat_off + @as(u32, @intCast(i)) * 8));
        try setLabelAt(p, try allocLabelId(p, "iat_{d}", .{i}), iat_label_val);
    }
    hint_offs.deinit(); hint_dats.deinit();
    return base_off;
}

fn computeImportTableSize() u32 {
    const nf = IMPORT_FNS.len;
    const desc: u32 = 2 * 20;
    const int_sz: u32 = @as(u32, @intCast((nf + 1) * 8));
    var hint_sz: u32 = 0;
    for (IMPORT_FNS) |fn_name| hint_sz += 2 + @as(u32, @intCast(fn_name.len)) + 1;
    const iat_sz: u32 = @as(u32, @intCast((nf + 1) * 8));
    const dll_name_len: u32 = 13; // "kernel32.dll\0"
    return desc + int_sz + dll_name_len + hint_sz + iat_sz;
}

fn applyFixups(p: *PendingOutput) !void {
    for (p.pending_fixups.items) |fx| {
        const target = getLabel(p, fx.label_id) orelse continue;
        if (fx.offset >= p.code.items.len) continue;
        const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(fx.offset + fx.disp_size)));
        if (fx.disp_size == 1) {
            p.code.items[fx.offset] = @as(u8, @bitCast(@as(i8, @truncate(disp))));
        } else if (fx.disp_size == 4) {
            const db: [4]u8 = @bitCast(disp);
            for (db, 0..) |b, j| { if (fx.offset + j < p.code.items.len) p.code.items[fx.offset + j] = b; }
        }
    }
}

fn emitShortJmp(p: *PendingOutput, op: x64.OpCode, label_id: u32) !void {
    try x64.emit(&p.code, op, &.{x64.Operand.imm(0)});
    try p.pending_fixups.append(.{ .offset = p.code.items.len - 4, .disp_size = 4, .label_id = label_id });
}

fn emitLongJmp(p: *PendingOutput, label_id: u32) !void {
    try x64.emit(&p.code, .JMP_REL32, &.{x64.Operand.imm(0)});
    try p.pending_fixups.append(.{ .offset = p.code.items.len - 4, .disp_size = 4, .label_id = label_id });
}

fn emitCondLongJmp(p: *PendingOutput, op: x64.OpCode, label_id: u32) !void {
    try x64.emit(&p.code, op, &.{x64.Operand.imm(0)});
    try p.pending_fixups.append(.{ .offset = p.code.items.len - 4, .disp_size = 4, .label_id = label_id });
}

fn emitCallToLabel(p: *PendingOutput, label_id: u32) !void {
    try x64.emit(&p.code, .CALL_REL32, &.{x64.Operand.imm(0)});
    try p.pending_fixups.append(.{ .offset = p.code.items.len - 4, .disp_size = 4, .label_id = label_id });
}

fn emitRipLea(p: *PendingOutput, dst: i16, string_idx: u32) !void {
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(dst), x64.Operand.mem(255, 0) });
    const disp_off = p.code.items.len - 4;
    const label_id = try allocLabelId(p, "str_{d}", .{string_idx});
    try p.pending_fixups.append(.{ .offset = disp_off, .disp_size = 4, .label_id = label_id });
}

fn emitIatCall(p: *PendingOutput, import_idx: usize) !void {
    try p.code.append(0xFF); try p.code.append(0x15);
    const fixoff = p.code.items.len;
    try p.code.appendNTimes(0, 4);
    const label_id = try allocLabelId(p, "iat_{d}", .{import_idx});
    try p.pending_fixups.append(.{ .offset = fixoff, .disp_size = 4, .label_id = label_id });
}

fn emitWin32Call(p: *PendingOutput, import_idx: usize, arg: i32) !void {
    if (arg == 0) {
        try emitXorReg(p, Reg.RCX);
    } else {
        try x64.emit(&p.code, .MOV_R64_IMM64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.imm(arg) });
    }
    try emitShadowCall(p, import_idx);
}

fn emitShadowCall(p: *PendingOutput, import_idx: usize) !void {
    try x64.emit(&p.code, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try emitIatCall(p, import_idx);
    try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
}

fn emitXorReg(p: *PendingOutput, reg: i16) !void {
    if (reg >= 8) try p.code.append(0x45);
    try p.code.append(0x33);
    try p.code.append(@as(u8, @intCast(0xC0 + (reg & 7) * 9)));
}

fn emitInc(p: *PendingOutput, reg: i16) !void {
    try p.code.append(@as(u8, @intCast(0x48 + ((reg >> 3) & 1))));
    try p.code.append(0xFF);
    try p.code.append(@as(u8, @intCast(0xC0 + (reg & 7))));
}

fn emitDec(p: *PendingOutput, reg: i16) !void {
    try p.code.append(@as(u8, @intCast(0x48 + ((reg >> 3) & 1))));
    try p.code.append(0xFF);
    try p.code.append(@as(u8, @intCast(0xC8 + (reg & 7))));
}

fn emitMovRegImm32(p: *PendingOutput, reg: i16, imm: u32) !void {
    if (reg >= 8) try p.code.append(0x41);
    try p.code.append(@as(u8, @intCast(0xB8 + (reg & 7))));
    try p.code.appendSlice(&@as([4]u8, @bitCast(imm)));
}

fn emitLoadImm(p: *PendingOutput, reg: i16, val: i64) !void {
    if (val == 0) {
        try emitXorReg(p, reg);
    } else if (val > 0 and val <= std.math.maxInt(i32)) {
        try emitMovRegImm32(p, reg, @intCast(val));
    } else {
        try x64.emit(&p.code, .MOV_R64_IMM64, &.{ x64.Operand.r(reg), x64.Operand.imm(val) });
    }
}

fn emitNop(p: *PendingOutput, count: usize) !void {
    var remaining = count;
    while (remaining >= 9) { try p.code.appendSlice(&[_]u8{ 0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 }); remaining -= 9; }
    while (remaining >= 8) { try p.code.appendSlice(&[_]u8{ 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 }); remaining -= 8; }
    while (remaining >= 7) { try p.code.appendSlice(&[_]u8{ 0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00 }); remaining -= 7; }
    while (remaining >= 6) { try p.code.appendSlice(&[_]u8{ 0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00 }); remaining -= 6; }
    while (remaining >= 5) { try p.code.appendSlice(&[_]u8{ 0x0F, 0x1F, 0x44, 0x00, 0x00 }); remaining -= 5; }
    while (remaining >= 4) { try p.code.appendSlice(&[_]u8{ 0x0F, 0x1F, 0x40, 0x00 }); remaining -= 4; }
    while (remaining >= 3) { try p.code.appendSlice(&[_]u8{ 0x0F, 0x1F, 0x00 }); remaining -= 3; }
    while (remaining >= 2) { try p.code.appendSlice(&[_]u8{ 0x66, 0x90 }); remaining -= 2; }
    while (remaining >= 1) { try p.code.append(0x90); remaining -= 1; }
}

fn emitTierMove(p: *PendingOutput, skip: u32, panic: u32, comptime prefix: []const u8, delta: i8) !void {
    const l1 = try allocLabelId(p, "{s}_l1", .{prefix});
    const l2 = try allocLabelId(p, "{s}_l2", .{prefix});
    const done = try allocLabelId(p, "{s}_ad", .{prefix});
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
    try emitCondLongJmp(p, .JAE_REL32, skip);
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
    try emitCondLongJmp(p, .JNE_REL32, skip);
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
    try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
    try emitCondLongJmp(p, .JNE_REL32, skip);
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_tiers) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R15), x64.Operand.r(Reg.R10) });
    if (delta < 0) {
        try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
        try emitCondLongJmp(p, .JE_REL32, skip);
        try emitDec(p, Reg.R10);
    } else {
        try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
        try emitCondLongJmp(p, .JAE_REL32, skip);
        try emitInc(p, Reg.R10);
    }
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(3) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RSI), x64.Operand.mem(Reg.R11, 0) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_sizes) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.R11, 0) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R12), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R9), x64.Operand.immU32(0) });
    try emitCondLongJmp(p, .JE_REL32, l1);
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R9), x64.Operand.immU32(1) });
    try emitCondLongJmp(p, .JE_REL32, l2);
    try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_pool_head) });
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, panic);
    try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RAX, 0) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.R11) });
    try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 8), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 12), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RAX, 16) });
    try emitShortJmp(p, .JMP_REL32, done);
    try setLabel(p, l2);
    try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_l2_ptr) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_l2_end) });
    try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.R11) });
    try emitCondLongJmp(p, .JA_REL32, panic);
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RCX) });
    try emitShortJmp(p, .JMP_REL32, done);
    try setLabel(p, l1);
    try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_l1_ptr) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_l1_end) });
    try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.R11) });
    try emitCondLongJmp(p, .JA_REL32, panic);
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_ptr), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RCX) });
    const try_decomp = try allocLabelId(p, "{s}_td", .{prefix});
    const plain = try allocLabelId(p, "{s}_pl", .{prefix});
    const after_copy = try allocLabelId(p, "{s}_ac", .{prefix});
    try setLabel(p, done);
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.R12) });
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R9), x64.Operand.immU32(2) });
    try emitCondLongJmp(p, .JNE_REL32, try_decomp);
    try emitCallToLabel(p, try allocLabelId(p, "l3_compress", .{}));
    try emitShortJmp(p, .JMP_REL32, after_copy);
    try setLabel(p, try_decomp);
    try x64.emit(&p.code, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.R15), x64.Operand.immU32(2) });
    try emitCondLongJmp(p, .JNE_REL32, plain);
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.RSI, -4) });
    try x64.emit(&p.code, .SHIFT_RIGHT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(31) });
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
    try emitCondLongJmp(p, .JE_REL32, plain);
    try emitCallToLabel(p, try allocLabelId(p, "l3_decompress", .{}));
    try emitShortJmp(p, .JMP_REL32, after_copy);
    try setLabel(p, plain);
    try p.code.append(0xF3); try p.code.append(0xA4);
    try setLabel(p, after_copy);
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDI) });
    try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R12) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.code, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(3) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_tiers) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R9) });
}

fn emitL3Helpers(p: *PendingOutput) !void {
    const cl_loop = try allocLabelId(p, "cl_loop", .{});
    const cl_skip = try allocLabelId(p, "cl_skip", .{});
    const cl_done = try allocLabelId(p, "cl_done", .{});
    const cl_chk = try allocLabelId(p, "cl_chk", .{});
    const cl_store = try allocLabelId(p, "cl_store", .{});
    try setLabel(p, try allocLabelId(p, "l3_compress", .{}));
    try emitXorReg(p, Reg.R8);
    try emitXorReg(p, Reg.R9);
    try setLabel(p, cl_loop);
    try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RCX) });
    try emitCondLongJmp(p, .JAE_REL32, cl_done);
    try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.memIdx(Reg.RSI, Reg.R8, 1, 0) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.code, .XOR_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.memIdx(Reg.RDI, Reg.R8, 1, 0), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, cl_skip);
    try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.R8, 1) });
    try setLabel(p, cl_skip);
    try emitInc(p, Reg.R8);
    try emitShortJmp(p, .JMP_REL32, cl_loop);
    try setLabel(p, cl_done);
    try x64.emit(&p.code, .TEST_R64_R64, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.R9) });
    try emitCondLongJmp(p, .JNE_REL32, cl_chk);
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.RCX) });
    try setLabel(p, cl_chk);
    try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.RCX) });
    try emitCondLongJmp(p, .JE_REL32, cl_store);
    try emitLoadImm(p, Reg.R10, 0x80000000);
    try x64.emit(&p.code, .OR_R64_R64, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RDI, -4), x64.Operand.r(Reg.R9) });
    try setLabel(p, cl_store);
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RSI), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RCX) });
    try emitRet(p);

    const dl_loop = try allocLabelId(p, "dl_loop", .{});
    const dl_zf = try allocLabelId(p, "dl_zf", .{});
    const dl_zloop = try allocLabelId(p, "dl_zloop", .{});
    const dl_done = try allocLabelId(p, "dl_done", .{});
    try setLabel(p, try allocLabelId(p, "l3_decompress", .{}));
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.RSI, -4) });
    try emitLoadImm(p, Reg.RDX, 0x7FFFFFFF);
    try x64.emit(&p.code, .AND_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RSI, -8) });
    try emitXorReg(p, Reg.R8);
    try setLabel(p, dl_loop);
    try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.R10) });
    try emitCondLongJmp(p, .JAE_REL32, dl_zf);
    try x64.emit(&p.code, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.memIdx(Reg.RSI, Reg.R8, 1, 0) });
    try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.code, .XOR_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.memIdx(Reg.RDI, Reg.R8, 1, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.R8);
    try emitShortJmp(p, .JMP_REL32, dl_loop);
    try setLabel(p, dl_zf);
    try emitXorReg(p, Reg.RAX);
    try setLabel(p, dl_zloop);
    try x64.emit(&p.code, .CMP_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.R11) });
    try emitCondLongJmp(p, .JAE_REL32, dl_done);
    try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.memIdx(Reg.RDI, Reg.R8, 1, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.R8);
    try emitShortJmp(p, .JMP_REL32, dl_zloop);
    try setLabel(p, dl_done);
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RSI), x64.Operand.r(Reg.R11) });
    try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.R11) });
    try emitRet(p);
}

fn alignTo64(p: *PendingOutput) !void {
    const mod = p.code.items.len % 64;
    if (mod != 0) try emitNop(p, 64 - mod);
}

fn alignTo16(p: *PendingOutput) !void {
    const mod = p.code.items.len % 16;
    if (mod != 0) try emitNop(p, 16 - mod);
}

fn emitPrefetchData(p: *PendingOutput, stack_offset: i32, level: i32) !void {
    try p.code.append(0x0F); try p.code.append(0x18);
    const reg: u8 = if (level == 0) 0 else if (level == 1) 1 else if (level == 2) 2 else 3;
    if (stack_offset >= -128 and stack_offset <= 127) {
        try p.code.append(0x45 | (reg << 3));
        try p.code.append(@as(u8, @bitCast(@as(i8, @intCast(stack_offset)))));
    } else {
        try p.code.append(0x85 | (reg << 3));
        try p.code.appendSlice(&@as([4]u8, @bitCast(stack_offset)));
    }
}

fn emitPrefetch(p: *PendingOutput, label_id: u32) !void {
    try x64.emit(&p.code, .PREFETCHT0_RIPREL, &.{x64.Operand.imm(0)});
    try p.pending_fixups.append(.{ .offset = p.code.items.len - 4, .disp_size = 4, .label_id = label_id });
}

fn emitPrefetchColdData(p: *PendingOutput, state: *const ast.StateDefNode) !void {
    if ((state.hot_weight orelse 0.5) > 0.3) return;
    if (p.state_vars.get(state.name)) |vars| { for (vars.items) |sv| try emitPrefetchData(p, sv.stack_offset, 0); }
}

fn emitPrefetchForTransitionCacheAware(p: *PendingOutput, t: *const ast.TransitionNode) !void {
    const hw = t.hot_weight orelse 0.5;
    const level: i32 = if (hw >= 0.8) 1 else if (hw >= 0.4) 2 else 0;
    const ti = p.state_index_map.get(t.target).?;
    if (p.state_vars.get(t.target)) |vars| { for (vars.items) |sv| try emitPrefetchData(p, sv.stack_offset, level); }
    try emitPrefetch(p, p.en_id[ti]);
}

fn parseNumber(s: []const u8) i64 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return 0;
    if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X")) return std.fmt.parseInt(i64, t[2..], 16) catch 0;
    if (t.len > 0 and (std.ascii.isDigit(t[0]) or t[0] == '-' or t[0] == '+')) return std.fmt.parseInt(i64, t, 10) catch 0;
    return 0;
}

pub fn addPoolString(p: *PendingOutput, str: []const u8) !u32 {
    if (p.string_pool.get(str)) |idx| return @intCast(idx);
    const idx = p.string_list.items.len;
    try p.string_list.append(try p.allocator.dupe(u8, str));
    try p.string_pool.put(str, idx);
    return @intCast(idx);
}

fn emitAction(p: *PendingOutput, body: []const u8, current_state: []const u8) !void {
    if (body.len == 0) return;
    var it = std.mem.splitScalar(u8, body, ';');
    while (it.next()) |stmt| {
        const s = std.mem.trim(u8, stmt, " \t\r\n");
        if (s.len == 0) continue;
        try emitSingleAction(p, s, current_state);
    }
}

fn emitSingleAction(p: *PendingOutput, body: []const u8, current_state: []const u8) !void {
    if (body.len == 0) return;
    if (std.mem.startsWith(u8, body, "print(") and std.mem.endsWith(u8, body, ")")) {
        const content = std.mem.trim(u8, body["print(".len..body.len - 1], " \t\"");
        if (content.len == 0) return;
        const str_off = try addPoolString(p, content);
        try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_hstdout) });
        try emitRipLea(p, Reg.RDX, str_off);
        try x64.emit(&p.code, .MOV_R64_IMM64, &.{ x64.Operand.r(Reg.R8), x64.Operand.imm(@intCast(content.len)) });
        try x64.emit(&p.code, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.RBP, p.off_chars_written) });
        try x64.emit(&p.code, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
        try emitXorReg(p, Reg.RAX);
        try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 32), x64.Operand.r(Reg.RAX) });
        try emitIatCall(p, 1);
        try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
        return;
    }
    if (std.mem.startsWith(u8, body, "free(") and std.mem.endsWith(u8, body, ")")) {
        try emitShadowCall(p, 4);
        try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
        try emitXorReg(p, Reg.RDX);
        const ptr_name = std.mem.trim(u8, body["free(".len..body.len - 1], " \t");
        if (!try tryLoadVarToReg(p, Reg.R8, ptr_name, current_state)) try emitXorReg(p, Reg.R8);
        try emitShadowCall(p, 6);
        return;
    }
    if (std.mem.containsAtLeast(u8, body, 1, "+=")) {
        const idx = std.mem.indexOf(u8, body, "+=") orelse return;
        const var_name = std.mem.trim(u8, body[0..idx], " \t");
        const expr = std.mem.trim(u8, body[idx+2..], " \t");
        const vo = getVarOffset(p, current_state, var_name);
        if (vo != std.math.minInt(i32)) {
            const size = getVarSize(p, current_state, var_name);
            try emitLoadVarToReg(p, Reg.RAX, vo, size);
            try emitExprToRAXAdd(p, expr, current_state);
            try emitStoreVarFromReg(p, vo, Reg.RAX, size);
        }
        return;
    }
    if (std.mem.containsAtLeast(u8, body, 1, "-=")) {
        const idx = std.mem.indexOf(u8, body, "-=") orelse return;
        const var_name = std.mem.trim(u8, body[0..idx], " \t");
        const expr = std.mem.trim(u8, body[idx+2..], " \t");
        const vo = getVarOffset(p, current_state, var_name);
        if (vo != std.math.minInt(i32)) {
            const size = getVarSize(p, current_state, var_name);
            try emitLoadVarToReg(p, Reg.RAX, vo, size);
            try emitExprToRAXSub(p, expr, current_state);
            try emitStoreVarFromReg(p, vo, Reg.RAX, size);
        }
        return;
    }
    const eq = std.mem.indexOf(u8, body, "=");
    if (eq != null and eq.? > 0) {
        const var_name = std.mem.trim(u8, body[0..eq.?], " \t");
        const expr = std.mem.trim(u8, body[eq.?+1..], " \t");
        const vo = getVarOffset(p, current_state, var_name);
        if (vo != std.math.minInt(i32)) {
            try emitExprToRAX(p, expr, current_state);
            const size = getVarSize(p, current_state, var_name);
            try emitStoreVarFromReg(p, vo, Reg.RAX, size);
        }
        return;
    }
}

fn getVarOffset(p: *PendingOutput, state_name: []const u8, var_name: []const u8) i32 {
    for (p.ctx_vars.items, 0..) |cv, i| { if (std.mem.eql(u8, cv.name, var_name)) return p.off_ctx_var_start - @as(i32, @intCast(i)) * 8; }
    if (p.state_vars.get(state_name)) |sv_list| { for (sv_list.items) |sv| { if (std.mem.eql(u8, sv.name, var_name)) return sv.stack_offset; } }
    return std.math.minInt(i32);
}

fn getVarSize(p: *PendingOutput, state_name: []const u8, var_name: []const u8) u32 {
    for (p.ctx_vars.items) |cv| { if (std.mem.eql(u8, cv.name, var_name)) return 8; }
    if (p.state_vars.get(state_name)) |sv_list| { for (sv_list.items) |sv| { if (std.mem.eql(u8, sv.name, var_name)) return sv.size; } }
    return 8;
}

fn emitLoadVarToReg(p: *PendingOutput, reg: i16, offset: i32, size: u32) !void {
    switch (size) {
        1 => try x64.emit(&p.code, .MOVSX_R64_MEM8, &.{ x64.Operand.r(reg), x64.Operand.mem(Reg.RBP, offset) }),
        2 => try x64.emit(&p.code, .MOVSX_R64_MEM16, &.{ x64.Operand.r(reg), x64.Operand.mem(Reg.RBP, offset) }),
        4 => try x64.emit(&p.code, .MOV_R32_MEM, &.{ x64.Operand.r(reg), x64.Operand.mem(Reg.RBP, offset) }),
        else => try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(reg), x64.Operand.mem(Reg.RBP, offset) }),
    }
}

fn emitStoreVarFromReg(p: *PendingOutput, offset: i32, reg: i16, size: u32) !void {
    switch (size) {
        1 => try x64.emit(&p.code, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RBP, offset), x64.Operand.r(reg) }),
        2 => try x64.emit(&p.code, .MOV_MEM_R16, &.{ x64.Operand.mem(Reg.RBP, offset), x64.Operand.r(reg) }),
        4 => try x64.emit(&p.code, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, offset), x64.Operand.r(reg) }),
        else => try x64.emit(&p.code, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, offset), x64.Operand.r(reg) }),
    }
}

fn emitExprToRAX(p: *PendingOutput, expr: []const u8, current_state: []const u8) !void {
    const e = std.mem.trim(u8, expr, " \t");
    if (e.len == 0) { try emitXorReg(p, Reg.RAX); return; }
    if (std.mem.eql(u8, e, "true")) { try emitLoadImm(p, Reg.RAX, 1); return; }
    if (std.mem.eql(u8, e, "false")) { try emitXorReg(p, Reg.RAX); return; }
    const plus_idx = std.mem.lastIndexOfScalar(u8, e, '+');
    const minus_idx = std.mem.lastIndexOfScalar(u8, e, '-');
    if (plus_idx != null and plus_idx.? > 0) {
        const lhs = std.mem.trim(u8, e[0..plus_idx.?], " \t");
        const rhs = std.mem.trim(u8, e[plus_idx.?+1..], " \t");
        try emitExprAtomToRAX(p, lhs, current_state);
        if (try tryLoadVarToReg(p, Reg.RBX, rhs, current_state)) {
            try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
        } else {
            const rn = parseNumber(rhs);
            if (rn != 0) try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(rn) });
        }
        return;
    }
    if (minus_idx != null and minus_idx.? > 0) {
        const lhs = std.mem.trim(u8, e[0..minus_idx.?], " \t");
        const rhs = std.mem.trim(u8, e[minus_idx.?+1..], " \t");
        try emitExprAtomToRAX(p, lhs, current_state);
        if (try tryLoadVarToReg(p, Reg.RBX, rhs, current_state)) {
            try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
        } else {
            const rn = parseNumber(rhs);
            if (rn != 0) try x64.emit(&p.code, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(rn) });
        }
        return;
    }
    try emitExprAtomToRAX(p, e, current_state);
}

fn emitExprToRAXAdd(p: *PendingOutput, expr: []const u8, current_state: []const u8) !void {
    const e = std.mem.trim(u8, expr, " \t");
    if (try tryLoadVarToReg(p, Reg.RBX, e, current_state)) {
        try x64.emit(&p.code, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
    } else {
        const rn = parseNumber(e);
        try x64.emit(&p.code, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(@intCast(rn)) });
    }
}

fn emitExprToRAXSub(p: *PendingOutput, expr: []const u8, current_state: []const u8) !void {
    const e = std.mem.trim(u8, expr, " \t");
    if (try tryLoadVarToReg(p, Reg.RBX, e, current_state)) {
        try x64.emit(&p.code, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
    } else {
        const rn = parseNumber(e);
        try x64.emit(&p.code, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(@intCast(rn)) });
    }
}

fn emitExprAtomToRAX(p: *PendingOutput, atom: []const u8, current_state: []const u8) !void {
    const a = std.mem.trim(u8, atom, " \t");
    if (a.len == 0) { try emitXorReg(p, Reg.RAX); return; }
    if (std.mem.startsWith(u8, a, "malloc(") and std.mem.endsWith(u8, a, ")")) {
        const size_expr = std.mem.trim(u8, a["malloc(".len..a.len-1], " \t");
        const sz_val = parseNumber(size_expr);
        try emitShadowCall(p, 4);
        try x64.emit(&p.code, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
        try emitXorReg(p, Reg.RDX);
        try x64.emit(&p.code, .MOV_R64_IMM64, &.{ x64.Operand.r(Reg.R8), x64.Operand.imm(sz_val) });
        try emitShadowCall(p, 5);
        return;
    }
    if (std.mem.startsWith(u8, a, "*")) {
        const ptr_name = std.mem.trim(u8, a[1..], " \t");
        if (!try tryLoadVarToReg(p, Reg.RAX, ptr_name, current_state)) try emitXorReg(p, Reg.RAX);
        try x64.emit(&p.code, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RAX, 0) });
        return;
    }
    if (!try tryLoadVarToReg(p, Reg.RAX, a, current_state)) {
        const n = parseNumber(a);
        if (n != 0 or (a.len > 0 and (std.ascii.isDigit(a[0]) or a[0] == '-'))) {
            try emitLoadImm(p, Reg.RAX, n);
        } else {
            try emitXorReg(p, Reg.RAX);
        }
    }
}

fn tryLoadVarToReg(p: *PendingOutput, reg: i16, name: []const u8, state: []const u8) !bool {
    const vo = getVarOffset(p, state, name);
    if (vo != std.math.minInt(i32)) {
        const size = getVarSize(p, state, name);
        try emitLoadVarToReg(p, reg, vo, size);
        return true;
    }
    return false;
}









