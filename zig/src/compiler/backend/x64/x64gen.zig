const std = @import("std");
const fs = std.fs;
const ast = @import("../../parser/ast.zig");
const x64 = @import("x64enc.zig");
const rt = @import("../../../runtime/runtime.zig");
const sym = @import("../../parser/symbol.zig");
const abi = @import("abi.zig");
const layout = @import("layout.zig");
const codebuffer = @import("codebuffer.zig");
const Allocator = std.mem.Allocator;

pub const X64Output = struct {
    code: []u8,
    import_dir_rva: u32,
    idat_size: u32,
    symbols: sym.SymbolTable,
    is_dll: bool,
    entry_point_rva: u32,
};

const Reg = struct {
    const RAX: i16 = 0; const RCX: i16 = 1; const RDX: i16 = 2; const RBX: i16 = 3;
    const RSP: i16 = 4; const RBP: i16 = 5; const RSI: i16 = 6; const RDI: i16 = 7;
    const R8: i16 = 8; const R9: i16 = 9; const R10: i16 = 10; const R11: i16 = 11;
    const R12: i16 = 12; const R13: i16 = 13; const R14: i16 = 14; const R15: i16 = 15;
};

const XMM = struct {
    const XMM0: i16 = 0; const XMM1: i16 = 1; const XMM2: i16 = 2; const XMM3: i16 = 3;
    const XMM4: i16 = 4; const XMM5: i16 = 5; const XMM6: i16 = 6; const XMM7: i16 = 7;
};

const ImportGroup = struct {
    dll: []const u8,
    fns: []const []const u8,
};

const IMPORT_GROUPS = [_]ImportGroup{
    .{ .dll = "kernel32.dll", .fns = &[_][]const u8{
        "GetStdHandle", "WriteFile", "ReadFile", "ExitProcess",
        "GetProcessHeap", "HeapAlloc", "HeapFree", "SetThreadAffinityMask",
        "GetCurrentThread", "GetNumaHighestNodeNumber", "GetNumaNodeProcessorMask",
        "VirtualAlloc", "VirtualFree", "CreateFileW", "GetFileSizeEx",
        "CreateFileMappingW", "MapViewOfFile", "UnmapViewOfFile", "CloseHandle",
        "LoadLibraryA", "LoadLibraryW", "GetProcAddress",
        "GetModuleHandleA", "GetModuleHandleW",
        "OpenProcess", "VirtualAllocEx", "WriteProcessMemory", "CreateRemoteThread", "WaitForSingleObject",
        "GetCurrentProcessId", "WinExec",
        "TlsAlloc", "TlsGetValue", "TlsSetValue", "TlsFree",
    } },
    .{ .dll = "msvcrt.dll", .fns = &[_][]const u8{
        "sinf", "cosf", "expf", "logf", "powf", "atanf", "tanf", "sqrtf",
        "sin", "cos", "exp", "log", "pow", "atan", "tan", "sqrt",
    } },
    .{ .dll = "user32.dll", .fns = &[_][]const u8{
        "MessageBoxW",
    } },
};

const IMPORT_FNS = [_][]const u8{
    "GetStdHandle", "WriteFile", "ReadFile", "ExitProcess",
    "GetProcessHeap", "HeapAlloc", "HeapFree", "SetThreadAffinityMask",
    "GetCurrentThread", "GetNumaHighestNodeNumber", "GetNumaNodeProcessorMask",
    "VirtualAlloc", "VirtualFree", "CreateFileW", "GetFileSizeEx",
    "CreateFileMappingW", "MapViewOfFile", "UnmapViewOfFile", "CloseHandle",
    "LoadLibraryA", "LoadLibraryW", "GetProcAddress",
    "GetModuleHandleA", "GetModuleHandleW",
    "OpenProcess", "VirtualAllocEx", "WriteProcessMemory", "CreateRemoteThread", "WaitForSingleObject",
    "GetCurrentProcessId", "WinExec",
    "TlsAlloc", "TlsGetValue", "TlsSetValue", "TlsFree",
    // CRT math functions (msvcrt.dll)
    "sinf", "cosf", "expf", "logf", "powf", "atanf", "tanf", "sqrtf",
    "sin", "cos", "exp", "log", "pow", "atan", "tan", "sqrt",
    // user32.dll
    "MessageBoxW",
};

const ComMethod = struct {
    name: []const u8,
    iface: []const u8,
    slot: u8,
};

const COM_METHODS = [_]ComMethod{
    // DXGI
    .{ .name = "Present",       .iface = "IDXGISwapChain",   .slot = 8  },
    .{ .name = "GetBuffer",     .iface = "IDXGISwapChain",   .slot = 9  },
    .{ .name = "ResizeBuffers", .iface = "IDXGISwapChain",   .slot = 10 },
    .{ .name = "ResizeTarget",  .iface = "IDXGISwapChain",   .slot = 11 },
    // IUnknown
    .{ .name = "QueryInterface", .iface = "IUnknown",        .slot = 0  },
    .{ .name = "AddRef",        .iface = "IUnknown",         .slot = 1  },
    .{ .name = "Release",       .iface = "IUnknown",         .slot = 2  },
    // D3D11
    .{ .name = "CreateBuffer",  .iface = "ID3D11Device",     .slot = 5  },
    .{ .name = "CreateTexture2D", .iface = "ID3D11Device",   .slot = 7  },
    .{ .name = "CreateRenderTargetView", .iface = "ID3D11Device", .slot = 15 },
    .{ .name = "VSSetShader",   .iface = "ID3D11DeviceContext", .slot = 17 },
    .{ .name = "PSSetShader",   .iface = "ID3D11DeviceContext", .slot = 20 },
    .{ .name = "DrawIndexed",   .iface = "ID3D11DeviceContext", .slot = 38 },
    .{ .name = "Draw",          .iface = "ID3D11DeviceContext", .slot = 39 },
    .{ .name = "Map",           .iface = "ID3D11DeviceContext", .slot = 43 },
    .{ .name = "Unmap",         .iface = "ID3D11DeviceContext", .slot = 44 },
    // D3D12 Device (slots 7+ = index after D3D12BaseVtbl: 3 IUnknown + 4 ID3D12Object)
    .{ .name = "CreateCommandQueue",       .iface = "ID3D12Device",          .slot = 8  },
    .{ .name = "CreateCommandAllocator",   .iface = "ID3D12Device",          .slot = 9  },
    .{ .name = "CreateComputePipelineState",.iface = "ID3D12Device",         .slot = 11 },
    .{ .name = "CreateCommandList",        .iface = "ID3D12Device",          .slot = 12 },
    .{ .name = "CreateDescriptorHeap",     .iface = "ID3D12Device",          .slot = 14 },
    .{ .name = "CreateRootSignature",      .iface = "ID3D12Device",          .slot = 16 },
    .{ .name = "GetDescriptorHandleIncrementSize", .iface = "ID3D12Device",  .slot = 15 },
    .{ .name = "CreateConstantBufferView",  .iface = "ID3D12Device",         .slot = 17 },
    .{ .name = "CreateShaderResourceView",  .iface = "ID3D12Device",         .slot = 18 },
    .{ .name = "CreateUnorderedAccessView", .iface = "ID3D12Device",         .slot = 19 },
    .{ .name = "CreateCommittedResource",  .iface = "ID3D12Device",          .slot = 27 },
    .{ .name = "CreateHeap",               .iface = "ID3D12Device",          .slot = 28 },
    .{ .name = "CreatePlacedResource",     .iface = "ID3D12Device",          .slot = 29 },
    .{ .name = "CreateFence",              .iface = "ID3D12Device",          .slot = 36 },
    .{ .name = "GetCopyableFootprints",    .iface = "ID3D12Device",          .slot = 38 },
    // D3D12 CommandQueue (slots 10+ = index after D3D12BaseVtbl + DeviceChild)
    .{ .name = "ExecuteCommandLists",      .iface = "ID3D12CommandQueue",    .slot = 10 },
    .{ .name = "Signal",                   .iface = "ID3D12CommandQueue",    .slot = 14 },
    .{ .name = "Wait",                     .iface = "ID3D12CommandQueue",    .slot = 15 },
    // D3D12 GraphicsCommandList (slots 8+ = index after D3D12BaseVtbl + DeviceChild + CmdList base)
    .{ .name = "Close",                    .iface = "ID3D12GraphicsCommandList", .slot = 9  },
    .{ .name = "Reset",                    .iface = "ID3D12GraphicsCommandList", .slot = 10 },
    .{ .name = "Dispatch",                 .iface = "ID3D12GraphicsCommandList", .slot = 14 },
    .{ .name = "CopyBufferRegion",         .iface = "ID3D12GraphicsCommandList", .slot = 15 },
    .{ .name = "CopyTextureRegion",        .iface = "ID3D12GraphicsCommandList", .slot = 16 },
    .{ .name = "CopyResource",             .iface = "ID3D12GraphicsCommandList", .slot = 17 },
    .{ .name = "SetPipelineState",         .iface = "ID3D12GraphicsCommandList", .slot = 25 },
    .{ .name = "ResourceBarrier",          .iface = "ID3D12GraphicsCommandList", .slot = 26 },
    .{ .name = "SetDescriptorHeaps",       .iface = "ID3D12GraphicsCommandList", .slot = 28 },
    .{ .name = "SetComputeRootSignature",  .iface = "ID3D12GraphicsCommandList", .slot = 29 },
    .{ .name = "SetComputeRootDescriptorTable", .iface = "ID3D12GraphicsCommandList", .slot = 31 },
    .{ .name = "SetComputeRoot32BitConstants",  .iface = "ID3D12GraphicsCommandList", .slot = 35 },
    .{ .name = "SetComputeRootConstantBufferView", .iface = "ID3D12GraphicsCommandList", .slot = 37 },
    .{ .name = "ClearUnorderedAccessViewFloat", .iface = "ID3D12GraphicsCommandList", .slot = 50 },
    // D3D12 Fence (slots 8+ = index after D3D12BaseVtbl + DeviceChild)
    .{ .name = "GetCompletedValue",        .iface = "ID3D12Fence",           .slot = 8  },
    .{ .name = "SetEventOnCompletion",     .iface = "ID3D12Fence",           .slot = 9  },
    // D3D12 Resource (slots 8+ = index after D3D12BaseVtbl + DeviceChild)
    .{ .name = "GetGPUVirtualAddress",     .iface = "ID3D12Resource",        .slot = 11 },
    // D3D12 DescriptorHeap (slots 9+ = index after D3D12BaseVtbl + DeviceChild)
    .{ .name = "GetCPUDescriptorHandleForHeapStart", .iface = "ID3D12DescriptorHeap", .slot = 9 },
    .{ .name = "GetGPUDescriptorHandleForHeapStart", .iface = "ID3D12DescriptorHeap", .slot = 10 },
};

const SectionRva: u32 = 0x1000;

const ContextVarInfo = struct { name: []const u8, type_name: []const u8, default_value: []const u8 };
const StateVarInfo = struct { name: []const u8, type_name: []const u8, default_value: []const u8, stack_offset: i32, size: u32, cache_policy: ?[]const u8, layout_offset: u32 };
const Fixup = codebuffer.Fixup;
const StateBounds = struct { start: usize, end: usize };

const RetValue = union(enum) {
    int: i16,
    float: i16,
    imm_int: i64,
};

pub const TraceMode = enum {
    off,
    writes,
    reads,
    full,
};

const Trace = struct {
    start_state: usize,
    len: usize,
    hot_weight: f64,
};

const PendingOutput = struct {
    cbuf: codebuffer.CodeBuffer,
    string_pool: std.StringHashMap(usize),
    string_list: std.ArrayList([]const u8),
    entry_point_rva: u32,
    wstring_pool: std.StringHashMap(usize),
    wstring_list: std.ArrayList([]const u16),
    state_names: std.ArrayList([]const u8),
    state_index_map: std.StringHashMap(usize),
    ctx_vars: std.ArrayList(ContextVarInfo),
    state_vars: std.StringHashMap(std.ArrayList(StateVarInfo)),
    state_layout_sizes: std.StringHashMap(u32),
    state_code_bounds: std.StringHashMap(StateBounds),
    stack_frame_size: u32,
    off_hstdin: i32, off_hstdout: i32,
    off_chars_read: i32, off_chars_written: i32,
    off_cur_state: i32, off_cursor: i32, off_remaining: i32, off_abudget: i32,
    off_buf: i32,
    off_exit_code: i32,
    off_ctx_var_start: i32, off_state_data_base: i32,
    entry_vars: std.StringHashMap(i32),
    entry_var_types: std.StringHashMap([]const u8),
    in_for_loop: bool,
    in_for_range: bool, for_range_var_name: []const u8,
    off_for_loop_x: i32, off_for_loop_y: i32, off_for_range_counter: i32,
    break_labels: std.ArrayList(u32),
    continue_labels: std.ArrayList(u32),
    defer_scopes: std.ArrayList(std.ArrayList([]const u8)),
    off_core_type: i32, off_numa_highest_node: i32, off_numa_node_mask: i32,
    off_l1_base: i32, off_l1_ptr: i32, off_l1_end: i32, off_l1_buf_start: i32,
    off_l2_base: i32, off_l2_ptr: i32, off_l2_end: i32, off_l2_buf_start: i32,
    off_l3_base: i32, off_l3_ptr: i32, off_l3_end: i32, off_l3_buf_start: i32,
    off_pool_head: i32,
    off_state_hits: i32,
    off_trans_hits: i32,
    off_epoch: i32,
    off_ht_tiers: i32,
    off_ht_states: i32,
    off_ht_total_heats: i32,
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
    total_transitions: u32,
    is_dll: bool,
    dp_id: []u32,
    en_id: []u32,
    inline_enter: []const bool,
    allocator: Allocator,
    xmm_used: [16]bool,
    symbols: sym.SymbolTable,
    struct_defs: std.StringHashMap(ast.StructDef),
    enum_defs: std.StringHashMap(i64), // key = "EnumName.Variant", value = variant index
    enum_keys: std.ArrayList([]const u8),
    func_defs: std.StringHashMap(ast.EntryDecl),
    in_function: bool,
    fn_epilogue_lbl: u32,
    expr_arena: std.ArrayList(Expr),
    value_uses: std.ArrayList(u32), // use count per value (parallel to expr_arena)
    value_cache: std.AutoHashMap(usize, i16),
    state_base_reg: i16,
    pending_ret: ?RetValue,
    trace_mode: TraceMode,
};


pub fn generate(allocator: Allocator, program: ast.ProgramNode) !X64Output {
    return generateEx(allocator, program, false, .off);
}

pub fn generateEx(allocator: Allocator, program: ast.ProgramNode, is_dll: bool, trace_mode: TraceMode) !X64Output {
    var p = PendingOutput{
        .cbuf = codebuffer.CodeBuffer.init(allocator),
        .string_pool = std.StringHashMap(usize).init(allocator),
        .string_list = std.ArrayList([]const u8).init(allocator),
        .wstring_pool = std.StringHashMap(usize).init(allocator),
        .wstring_list = std.ArrayList([]const u16).init(allocator),
        .state_names = std.ArrayList([]const u8).init(allocator),
        .state_index_map = std.StringHashMap(usize).init(allocator),
        .ctx_vars = std.ArrayList(ContextVarInfo).init(allocator),
        .entry_vars = std.StringHashMap(i32).init(allocator),
        .entry_var_types = std.StringHashMap([]const u8).init(allocator),
        .state_vars = std.StringHashMap(std.ArrayList(StateVarInfo)).init(allocator),
        .state_layout_sizes = std.StringHashMap(u32).init(allocator),
        .state_code_bounds = std.StringHashMap(StateBounds).init(allocator),
        .stack_frame_size = 0,
        .off_hstdin = -8, .off_hstdout = -16,
        .off_chars_read = -24, .off_chars_written = -32,
        .off_cur_state = -40, .off_cursor = -48, .off_remaining = -56, .off_abudget = 0,
        .off_buf = -64, .off_exit_code = 0,
        .off_ctx_var_start = -72, .off_state_data_base = -80,
        .off_core_type = -88, .off_numa_highest_node = -92, .off_numa_node_mask = -100,
        .off_l1_base = -108, .off_l1_ptr = -116, .off_l1_end = -124, .off_l1_buf_start = 0,
        .off_l2_base = 0, .off_l2_ptr = 0, .off_l2_end = 0, .off_l2_buf_start = 0,
        .off_l3_base = 0, .off_l3_ptr = 0, .off_l3_end = 0, .off_l3_buf_start = 0,
        .off_pool_head = -132,
        .off_state_hits = 0,
        .off_trans_hits = 0,
        .off_epoch = 0,
        .off_ht_tiers = 0,
        .off_ht_states = 0,
        .off_ht_total_heats = 0,
        .off_ht_heats = 0,
        .off_ht_ptrs = 0,
        .off_ht_generations = 0,
        .off_ht_sizes = 0,
        .off_ht_free_next = 0,
        .off_ht_free_head = 0,
        .in_for_loop = false,
        .in_for_range = false, .for_range_var_name = "",
        .off_for_loop_x = 0, .off_for_loop_y = 0, .off_for_range_counter = 0,
        .break_labels = std.ArrayList(u32).init(allocator),
        .continue_labels = std.ArrayList(u32).init(allocator),
        .defer_scopes = std.ArrayList(std.ArrayList([]const u8)).init(allocator),
        .off_telem_l1_spill = 0, .off_telem_l2_spill = 0,
        .off_telem_l1_peak = 0, .off_telem_l2_peak = 0, .off_telem_l3_peak = 0,
        .off_telem_l1_allocs = 0, .off_telem_l2_allocs = 0, .off_telem_l3_allocs = 0,
        .arena_l1_size = 0,
        .arena_l2_size = 0,
        .arena_l3_size = 0,
        .l3_block_size = 0,
        .l3_num_blocks = 0,
        .has_hot_states = false,
        .total_transitions = 0,
        .is_dll = is_dll,
        .dp_id = &.{},
        .en_id = &.{},
        .inline_enter = &.{},
        .allocator = allocator,
        .xmm_used = .{false} ** 16,
        .trace_mode = trace_mode,
        .entry_point_rva = 0,
        .state_base_reg = Reg.RBP,
        .pending_ret = null,
        .symbols = sym.SymbolTable.init(allocator),
        .struct_defs = program.struct_defs,
        .enum_defs = std.StringHashMap(i64).init(allocator),
        .enum_keys = std.ArrayList([]const u8).init(allocator),
        .func_defs = std.StringHashMap(ast.EntryDecl).init(allocator),
        .in_function = false,
        .fn_epilogue_lbl = 0,
        .expr_arena = std.ArrayList(Expr).init(allocator),
        .value_uses = std.ArrayList(u32).init(allocator),
        .value_cache = std.AutoHashMap(usize, i16).init(allocator),
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
    if (program.metal) |metal| {
        for (metal.variables.items) |v| try p.ctx_vars.append(.{
            .name = v.name, .type_name = v.type_name, .default_value = v.default_value orelse "0",
        });
    }
    p.state_base_reg = Reg.R14;
    computeArenaSizes(&p, program);
    for (program.states.items) |s| p.total_transitions += @intCast(s.transitions.items.len);
    try computeStackLayout(&p, program);
    try computeStateLayout(&p, program);
    for (program.enums.items) |ed| {
        for (ed.members.items, 0..) |member, i| {
            const key = try std.fmt.allocPrint(p.allocator, "{s}.{s}", .{ ed.name, member });
            try p.enum_keys.append(key);
            try p.enum_defs.put(key, @intCast(i));
        }
    }
    for (program.func_defs.items) |*fd| {
        try p.func_defs.put(fd.name, fd.*);
    }
    try emitPrologueAndInit(&p, program);
    try emitRuntimeSection(&p);
    // Analyze traces and compute inline_enter before emitting enter funcs
    var traces = try analyzeTraces(program, p.state_index_map);
    defer traces.deinit();
    std.mem.sort(Trace, traces.items, {}, struct {
        fn lessThan(_: void, a: Trace, b: Trace) bool {
            if (a.hot_weight != b.hot_weight) return a.hot_weight > b.hot_weight;
            return a.start_state < b.start_state;
        }
    }.lessThan);
    {
        var indegree = try allocator.alloc(usize, program.states.items.len);
        defer allocator.free(indegree);
        @memset(indegree, 0);
        for (program.states.items) |s| {
            for (s.transitions.items) |t| {
                if (p.state_index_map.get(t.target)) |ti| indegree[ti] += 1;
            }
        }
        var ie = try allocator.alloc(bool, program.states.items.len);
        for (0..ie.len) |i| ie[i] = false;
        for (traces.items) |trace| {
            if (trace.len <= 1) continue;
            for (trace.start_state + 1..trace.start_state + trace.len) |bsi| {
                if (indegree[bsi] == 1) ie[bsi] = true;
            }
        }
        for (ie, 0..) |ie_flag, i| {
            if (ie_flag) p.en_id[i] = p.dp_id[i];
        }
        p.inline_enter = ie;
    }
    try emitStateEnterFuncs(&p, program);
    try padForCacheAssociativity(&p, program);
    try emitEventLoop(&p, program, traces);
    try emitCacheBudgetChecks(&p, program);
    try embedStringPool(&p);
    try embedStateGlobals(&p);
    const import_dir_rva = try emitImportTable(&p);
    // Emit user-defined function bodies
    {
        var it = p.func_defs.iterator();
        while (it.next()) |entry| {
            const fd = entry.value_ptr.*;
            const fn_lbl = try allocLabelId(&p, "fn_{s}", .{fd.name});
            try setLabel(&p, fn_lbl);
            // Prologue
            try x64.emit(&p.cbuf.bytes, .PUSH_R64, &.{x64.Operand.r(Reg.RBP)});
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBP), x64.Operand.r(Reg.RSP) });
            try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(32) });
            // Store parameters from Win64 registers to stack
            const win64_param_regs = [_]i16{ 1, 2, 8, 9 };
            const saved_entry_vars = p.entry_vars;
            const saved_entry_var_types = p.entry_var_types;
            p.entry_vars = std.StringHashMap(i32).init(p.allocator);
            p.entry_var_types = std.StringHashMap([]const u8).init(p.allocator);
            defer {
                p.entry_vars.deinit();
                p.entry_var_types.deinit();
                p.entry_vars = saved_entry_vars;
                p.entry_var_types = saved_entry_var_types;
            }
            var param_off: i32 = -8;
            for (fd.params.items, 0..) |param, i| {
                if (i < 4) {
                    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, param_off), x64.Operand.r(win64_param_regs[i]) });
                }
                try p.entry_vars.put(param.name, param_off);
                if (!std.mem.eql(u8, param.type_name, "int") and !std.mem.eql(u8, param.type_name, "int32") and !std.mem.eql(u8, param.type_name, "i32")) {
                    try p.entry_var_types.put(param.name, param.type_name);
                }
                param_off -= 8;
            }
            // Save function state flags
            const saved_in_fn = p.in_function;
            const saved_epi_lbl = p.fn_epilogue_lbl;
            const fn_epi_lbl = try allocLabelId(&p, "fn_epi_{s}", .{fd.name});
            p.in_function = true;
            p.fn_epilogue_lbl = fn_epi_lbl;
            // Compile body
            const body_text = try std.mem.join(p.allocator, ";", fd.body_lines.items);
            defer p.allocator.free(body_text);
            try emitAction(&p, body_text, "");
            // Epilogue label
            try setLabel(&p, fn_epi_lbl);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RSP), x64.Operand.r(Reg.RBP) });
            try x64.emit(&p.cbuf.bytes, .POP_R64, &.{x64.Operand.r(Reg.RBP)});
            try x64.emit(&p.cbuf.bytes, .RET, &.{});
            // Restore state
            p.in_function = saved_in_fn;
            p.fn_epilogue_lbl = saved_epi_lbl;
        }
    }
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
                p.cbuf.bytes.items[entry_off + 0] = db[0];
                p.cbuf.bytes.items[entry_off + 1] = db[1];
                p.cbuf.bytes.items[entry_off + 2] = db[2];
                p.cbuf.bytes.items[entry_off + 3] = db[3];
            }
        }
    }
    const idat_size = computeImportTableSize();
    p.allocator.free(p.dp_id);
    p.allocator.free(p.en_id);
    p.allocator.free(p.inline_enter);
    p.func_defs.deinit();
    // Must extract cbuf.bytes before deinit cbuf, since toOwnedSlice takes ownership
    const code = try p.cbuf.bytes.toOwnedSlice();
    p.cbuf.deinit();
    {
        var sit = p.state_vars.iterator();
        while (sit.next()) |e| e.value_ptr.deinit();
        p.state_vars.deinit();
        p.state_layout_sizes.deinit();
    }
    {
        var it = p.state_code_bounds.iterator();
        while (it.next()) |entry| p.allocator.free(entry.key_ptr.*);
    }
    p.state_code_bounds.deinit();
    for (p.string_list.items) |s| p.allocator.free(s);
    p.string_list.deinit();
    p.string_pool.deinit();
    for (p.wstring_list.items) |ws| p.allocator.free(ws);
    p.wstring_list.deinit();
    p.wstring_pool.deinit();
    p.state_names.deinit();
    p.state_index_map.deinit();
    p.ctx_vars.deinit();
    p.entry_vars.deinit();
    p.expr_arena.deinit();
    p.value_uses.deinit();
    p.value_cache.deinit();
    for (p.enum_keys.items) |k| p.allocator.free(k);
    p.enum_keys.deinit();
    p.enum_defs.deinit();
    p.break_labels.deinit();
    p.continue_labels.deinit();
    p.defer_scopes.deinit();
    return X64Output{
        .code = code,
        .import_dir_rva = @intCast(import_dir_rva),
        .idat_size = idat_size,
        .symbols = p.symbols,
        .is_dll = p.is_dll,
        .entry_point_rva = p.entry_point_rva,
    };
}

fn allocLabelId(p: *PendingOutput, comptime fmt: []const u8, args: anytype) !u32 {
    return p.cbuf.allocLabel(fmt, args);
}

fn setLabel(p: *PendingOutput, id: u32) !void {
    try p.cbuf.setLabel(id);
}

fn setLabelAt(p: *PendingOutput, id: u32, off: usize) void {
    p.cbuf.setLabelAt(id, off);
}

fn getLabel(p: *const PendingOutput, id: u32) ?usize {
    return p.cbuf.getLabel(id);
}

fn getTypeSize(t: []const u8) u32 {
    if (std.mem.eql(u8, t, "int32") or std.mem.eql(u8, t, "i32") or std.mem.eql(u8, t, "u32") or std.mem.eql(u8, t, "int") or std.mem.eql(u8, t, "uint") or std.mem.eql(u8, t, "float")) return 4;
    if (std.mem.eql(u8, t, "int16") or std.mem.eql(u8, t, "i16") or std.mem.eql(u8, t, "u16") or std.mem.eql(u8, t, "short") or std.mem.eql(u8, t, "half") or std.mem.eql(u8, t, "vec2h")) return 2;
    if (std.mem.eql(u8, t, "int8") or std.mem.eql(u8, t, "i8") or std.mem.eql(u8, t, "u8") or std.mem.eql(u8, t, "byte") or std.mem.eql(u8, t, "bool")) return 1;
    if (std.mem.eql(u8, t, "vec2f") or std.mem.eql(u8, t, "vec2i")) return 8;
    if (std.mem.eql(u8, t, "vec4f") or std.mem.eql(u8, t, "vec4i") or std.mem.eql(u8, t, "vec4h")) return 16;
    if (std.mem.startsWith(u8, t, "image<")) return 8;
    return 8;
}

fn getStructFieldSize(p: *const PendingOutput, type_name: []const u8) u32 {
    if (p.struct_defs.get(type_name)) |sd| {
        var total: u32 = 0;
        for (sd.fields.items) |f| { total += getStructFieldSize(p, f.type_name); }
        return total;
    }
    return getTypeSize(type_name);
}

fn getStructFieldOffset(p: *const PendingOutput, struct_type: []const u8, field_name: []const u8) ?u32 {
    const sd = p.struct_defs.get(struct_type) orelse return null;
    var offset: u32 = 0;
    for (sd.fields.items) |f| {
        if (std.mem.eql(u8, f.name, field_name)) return offset;
        offset += getStructFieldSize(p, f.type_name);
    }
    return null;
}

fn getStructFieldType(p: *const PendingOutput, struct_type: []const u8, field_name: []const u8) []const u8 {
    const sd = p.struct_defs.get(struct_type) orelse return "int";
    for (sd.fields.items) |f| { if (std.mem.eql(u8, f.name, field_name)) return f.type_name; }
    return "int";
}

fn isStructType(p: *const PendingOutput, type_name: []const u8) bool {
    return p.struct_defs.contains(type_name);
}

fn isSimdType(t: []const u8) bool {
    return std.mem.eql(u8, t, "float") or std.mem.eql(u8, t, "f32") or std.mem.eql(u8, t, "vec2f") or std.mem.eql(u8, t, "vec4f") or std.mem.eql(u8, t, "half");
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
    var sf = layout.StackFrame.init(p.allocator);
    defer sf.deinit();

    try sf.addSlot(.hstdin, 8);
    try sf.addSlot(.hstdout, 8);
    try sf.addSlot(.chars_read, 8);
    try sf.addSlot(.chars_written, 8);
    try sf.addSlot(.cur_state, 8);
    try sf.addSlot(.cursor, 8);
    try sf.addSlot(.remaining, 8);
    try sf.addSlot(.abudget, 4);

    p.off_hstdin = sf.getOffset(.hstdin).?;
    p.off_hstdout = sf.getOffset(.hstdout).?;
    p.off_chars_read = sf.getOffset(.chars_read).?;
    p.off_chars_written = sf.getOffset(.chars_written).?;
    p.off_cur_state = sf.getOffset(.cur_state).?;
    p.off_cursor = sf.getOffset(.cursor).?;
    p.off_remaining = sf.getOffset(.remaining).?;
    p.off_abudget = sf.getOffset(.abudget).?;

    // Fixed slots (part 2)
    try sf.addSlot(.core_type, 4);
    try sf.addSlot(.numa_highest_node, 4);
    try sf.addSlot(.numa_node_mask, 8);
    try sf.addSlot(.pool_head, 8);
    try sf.addSlot(.l1_base, 8);
    try sf.addSlot(.l1_ptr, 8);
    try sf.addSlot(.l1_end, 8);
    try sf.addSlot(.l2_base, 8);
    try sf.addSlot(.l2_ptr, 8);
    try sf.addSlot(.l2_end, 8);
    try sf.addSlot(.l3_base, 8);
    try sf.addSlot(.l3_ptr, 8);
    try sf.addSlot(.l3_end, 8);

    // Telemetry counters
    try sf.addSlot(.telem_l1_spill, 8);
    try sf.addSlot(.telem_l2_spill, 8);
    try sf.addSlot(.telem_l1_peak, 8);
    try sf.addSlot(.telem_l2_peak, 8);
    try sf.addSlot(.telem_l3_peak, 8);
    try sf.addSlot(.telem_l1_allocs, 8);
    try sf.addSlot(.telem_l2_allocs, 8);
    try sf.addSlot(.telem_l3_allocs, 8);

    p.off_core_type = sf.getOffset(.core_type).?;
    p.off_numa_highest_node = sf.getOffset(.numa_highest_node).?;
    p.off_numa_node_mask = sf.getOffset(.numa_node_mask).?;
    p.off_pool_head = sf.getOffset(.pool_head).?;
    p.off_l1_base = sf.getOffset(.l1_base).?;
    p.off_l1_ptr = sf.getOffset(.l1_ptr).?;
    p.off_l1_end = sf.getOffset(.l1_end).?;
    p.off_l2_base = sf.getOffset(.l2_base).?;
    p.off_l2_ptr = sf.getOffset(.l2_ptr).?;
    p.off_l2_end = sf.getOffset(.l2_end).?;
    p.off_l3_base = sf.getOffset(.l3_base).?;
    p.off_l3_ptr = sf.getOffset(.l3_ptr).?;
    p.off_l3_end = sf.getOffset(.l3_end).?;
    p.off_telem_l1_spill = sf.getOffset(.telem_l1_spill).?;
    p.off_telem_l2_spill = sf.getOffset(.telem_l2_spill).?;
    p.off_telem_l1_peak = sf.getOffset(.telem_l1_peak).?;
    p.off_telem_l2_peak = sf.getOffset(.telem_l2_peak).?;
    p.off_telem_l3_peak = sf.getOffset(.telem_l3_peak).?;
    p.off_telem_l1_allocs = sf.getOffset(.telem_l1_allocs).?;
    p.off_telem_l2_allocs = sf.getOffset(.telem_l2_allocs).?;
    p.off_telem_l3_allocs = sf.getOffset(.telem_l3_allocs).?;

    var off = sf.currentOff();

    p.off_ctx_var_start = off;
    for (p.ctx_vars.items) |_| off -= 8;
    // Allocate stack slots for entry body variables
    for (program.entries.items) |entry| {
        for (entry.body_lines.items) |line| {
            const t = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, t, "var ")) {
                const rest = std.mem.trimLeft(u8, t["var ".len..], " \t\r\n");
                const eq_idx = std.mem.indexOfScalar(u8, rest, '=');
                if (eq_idx) |ei| {
                    const name = std.mem.trim(u8, rest[0..ei], " \t\r\n");
                    var expr = std.mem.trim(u8, rest[ei+1..], " \t\r\n");
                    if (expr.len > 0 and expr[expr.len-1] == ';') expr = expr[0..expr.len-1];
                    if (!p.entry_vars.contains(name)) {
                        if (expr.len > 2 and expr[expr.len-1] == '}' and expr[expr.len-2] == '{') {
                            const type_name = std.mem.trim(u8, expr[0..expr.len-2], " \t");
                            if (isStructType(p, type_name)) {
                                const sz = getStructFieldSize(p, type_name);
                                off -= @as(i32, @intCast(sz));
                                try p.entry_vars.put(name, off);
                                try p.entry_var_types.put(name, type_name);
                            } else {
                                off -= 8;
                                try p.entry_vars.put(name, off);
                            }
                        } else {
                            off -= 8;
                            try p.entry_vars.put(name, off);
                        }
                    }
                }
            }
        }
    }
    p.state_vars.clearRetainingCapacity();
    p.state_layout_sizes.clearRetainingCapacity();
    var shared = std.StringHashMap(i32).init(p.allocator);
    defer shared.deinit();
    for (program.states.items) |state| {
        const isL1 = if (state.cache_policy) |cp| std.mem.eql(u8, cp, "L1") else false;
        if (!isL1) continue;
        var sv = std.ArrayList(StateVarInfo).init(p.allocator);
        for (state.variables.items) |v| {
            const g = shared.get(v.name);
            const v_sz = if (isStructType(p, v.type_name)) getStructFieldSize(p, v.type_name) else getTypeSize(v.type_name);
            if (g) |eo| { try sv.append(.{ .name = v.name, .type_name = v.type_name, .default_value = v.default_value orelse "0", .stack_offset = eo, .size = v_sz, .cache_policy = v.cache_policy, .layout_offset = 0 }); }
            else { const a = getTypeAlign(v.type_name); off = @divFloor(off, @as(i32, @intCast(a))) * @as(i32, @intCast(a)) - @as(i32, @intCast(v_sz)); try shared.put(v.name, off); try sv.append(.{ .name = v.name, .type_name = v.type_name, .default_value = v.default_value orelse "0", .stack_offset = off, .size = v_sz, .cache_policy = v.cache_policy, .layout_offset = 0 }); }
        }
        try p.state_vars.put(state.name, sv);
    }
    for (program.states.items) |state| {
        const isL1 = if (state.cache_policy) |cp| std.mem.eql(u8, cp, "L1") else false;
        if (isL1) continue;
        var sv = std.ArrayList(StateVarInfo).init(p.allocator);
        for (state.variables.items) |v| {
            const g = shared.get(v.name);
            const v_sz = if (isStructType(p, v.type_name)) getStructFieldSize(p, v.type_name) else getTypeSize(v.type_name);
            if (g) |eo| { try sv.append(.{ .name = v.name, .type_name = v.type_name, .default_value = v.default_value orelse "0", .stack_offset = eo, .size = v_sz, .cache_policy = v.cache_policy, .layout_offset = 0 }); }
            else { off -= @as(i32, @intCast(v_sz)); try shared.put(v.name, off); try sv.append(.{ .name = v.name, .type_name = v.type_name, .default_value = v.default_value orelse "0", .stack_offset = off, .size = v_sz, .cache_policy = v.cache_policy, .layout_offset = 0 }); }
        }
        try p.state_vars.put(state.name, sv);
    }
    p.off_state_data_base = off;

    p.off_state_hits = off - @as(i32, @intCast(program.states.items.len * 8)); off -= @as(i32, @intCast(program.states.items.len * 8));
    p.off_trans_hits = off - @as(i32, @intCast(p.total_transitions * 8)); off -= @as(i32, @intCast(p.total_transitions * 8));
    p.off_exit_code = off; off -= 8;
    p.off_buf = off - 256; off -= 256;
    p.off_l1_buf_start = off - @as(i32, @intCast(p.arena_l1_size)); off -= @as(i32, @intCast(p.arena_l1_size));
    p.off_l2_buf_start = off - @as(i32, @intCast(p.arena_l2_size)); off -= @as(i32, @intCast(p.arena_l2_size));
    p.off_l3_buf_start = off - @as(i32, @intCast(p.arena_l3_size)); off -= @as(i32, @intCast(p.arena_l3_size));
    p.off_epoch = off; off -= 8;
    p.off_for_loop_x = off; off -= 4;
    p.off_for_loop_y = off; off -= 4;
    p.off_for_range_counter = off; off -= 8;
    p.off_ht_states = off - 64; off -= 64;
    p.off_ht_tiers = off - 64; off -= 64;
    p.off_ht_heats = off - 256; off -= 256;
    p.off_ht_total_heats = off - 256; off -= 256;
    p.off_ht_generations = off - 256; off -= 256;
    p.off_ht_sizes = off - 256; off -= 256;
    p.off_ht_free_next = off - 256; off -= 256;
    p.off_ht_ptrs = off - 512; off -= 512;
    p.off_ht_free_head = off - 8; off -= 8;
    const neg = -off;
    p.stack_frame_size = @as(u32, @intCast(neg + 15)) & ~@as(u32, 15);
    if (p.stack_frame_size < 32) p.stack_frame_size = 32;
    p.stack_frame_size |= 8;
}

fn computeStateLayout(p: *PendingOutput, program: ast.ProgramNode) !void {
    for (program.states.items) |state| {
        const sv_list = p.state_vars.get(state.name) orelse continue;
        for (sv_list.items) |*sv| {
            sv.layout_offset = @as(u32, @intCast(sv.stack_offset - p.off_state_data_base));
        }
        var max_end: u32 = 0;
        for (sv_list.items) |sv| {
            const end = sv.layout_offset + sv.size;
            if (end > max_end) max_end = end;
        }
        const max_align: u32 = 16;
        max_end = (max_end + max_align - 1) & ~(max_align - 1);
        try p.state_layout_sizes.put(state.name, max_end);
    }
}

fn emitPrologueAndInit(p: *PendingOutput, program: ast.ProgramNode) !void {
    if (p.is_dll) {
        // ============================================================
        // DllMain entry point
        // RCX = hinstDLL, RDX = fdwReason, R8 = lpvReserved
        // ============================================================
        const dll_main_attach = try allocLabelId(p, "dll_attach", .{});
        const dll_main_detach = try allocLabelId(p, "dll_detach", .{});
        try p.cbuf.bytes.append(0x55); // push rbp
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBP), x64.Operand.r(Reg.RSP) });
        try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(0x30) });
        try emitCmpEdxImm(p, 1); // DLL_PROCESS_ATTACH
        try emitJeRel32(p, dll_main_attach);
        try emitCmpEdxImm(p, 0); // DLL_PROCESS_DETACH
        try emitJeRel32(p, dll_main_detach);
        // DLL_THREAD_ATTACH or DLL_THREAD_DETACH: return TRUE
        try emitXorReg(p, Reg.RAX);
        try emitInc(p, Reg.RAX);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RSP), x64.Operand.r(Reg.RBP) });
        try p.cbuf.bytes.append(0x5D); // pop rbp
        try p.cbuf.bytes.append(0xC3); // ret
        // --- ATTACH ---
        try setLabel(p, dll_main_attach);
        for (program.states.items, 0..) |state, si| {
            const tls_idx_label = try allocLabelId(p, "tls_idx_{d}", .{si});
            const state_ptr_label = try allocLabelId(p, "state_ptr_{d}", .{si});
            // Allocate TLS index
            try emitIatCall(p, 28); // TlsAlloc
            try emitRipRelativeStore32(p, Reg.RAX, tls_idx_label);
            // Allocate heap state block
            try emitIatCall(p, 4); // GetProcessHeap → RAX
            // HeapAlloc(RAX, HEAP_ZERO_MEMORY(8), layout_size)
            try emitMovRegImm32(p, Reg.R8, p.state_layout_sizes.get(state.name) orelse 0);
            try emitMovRegImm32(p, Reg.RDX, 8); // HEAP_ZERO_MEMORY
            // RCX = heap handle from RAX
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try emitWin32Call(p, 5, &.{}); // HeapAlloc (rcx/rdx/r8 already set)
            // Store block pointer
            try emitRipRelativeStore64(p, Reg.RAX, state_ptr_label);
            // TlsSetValue(tls_idx, block_ptr)
            try emitRipRelativeLoad32(p, Reg.RCX, tls_idx_label);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
            try emitWin32Call(p, 30, &.{}); // TlsSetValue
        }
        try emitXorReg(p, Reg.RAX);
        try emitInc(p, Reg.RAX);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RSP), x64.Operand.r(Reg.RBP) });
        try p.cbuf.bytes.append(0x5D); // pop rbp
        try p.cbuf.bytes.append(0xC3); // ret
        // --- DETACH ---
        try setLabel(p, dll_main_detach);
        for (0..program.states.items.len) |si| {
            const tls_idx_label = try allocLabelId(p, "tls_idx_{d}", .{si});
            // TlsGetValue(tls_idx) → block pointer
            try emitRipRelativeLoad32(p, Reg.RCX, tls_idx_label);
            try emitWin32Call(p, 29, &.{}); // TlsGetValue
            // Save block pointer (R15 is non-volatile, preserved across calls below)
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R15), x64.Operand.r(Reg.RAX) });
            // GetProcessHeap
            try emitIatCall(p, 4); // → RAX = heap
            // HeapFree(heap, 0, block_ptr)
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try emitXorReg(p, Reg.RDX); // dwFlags = 0
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.R15) });
            try emitWin32Call(p, 6, &.{}); // HeapFree
            // TlsFree(tls_idx)
            try emitRipRelativeLoad32(p, Reg.RCX, tls_idx_label);
            try emitWin32Call(p, 31, &.{}); // TlsFree
        }
        try emitXorReg(p, Reg.RAX);
        try emitInc(p, Reg.RAX);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RSP), x64.Operand.r(Reg.RBP) });
        try p.cbuf.bytes.append(0x5D); // pop rbp
        try p.cbuf.bytes.append(0xC3); // ret
    }

    // Process forwarders
    for (program.forwarders.items) |fwd| {
        const forward_str = try std.fmt.allocPrint(p.allocator, "{s}.{s}", .{ fwd.target_dll, fwd.export_name });
        try p.symbols.addForward(fwd.export_name, forward_str);
        p.allocator.free(forward_str);
    }
    // Auto-generate bpc_get_state export for test introspection
    if (program.states.items.len > 0) {
        const state_name = program.states.items[0].name;
        const sv_list = p.state_vars.get(state_name) orelse return error.NoStateVars;

        // --- bpc_get_state: returns state base pointer ---
        {
            const name = "bpc_get_state";
            const label_id = try allocLabelId(p, "exp_{s}", .{name});
            try setLabel(p, label_id);
            try p.symbols.add(name, sym.SymbolKind.exp, @intCast(p.cbuf.bytes.items.len));
            try abi.emitFullPrologue(&p.cbuf.bytes);
            if (p.is_dll) {
                const state_idx: usize = 0;
                const tls_idx_label = try allocLabelId(p, "tls_idx_{d}", .{state_idx});
                try emitRipRelativeLoad32(p, Reg.RCX, tls_idx_label);
                try emitWin32Call(p, 29, &.{}); // TlsGetValue
                try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R14), x64.Operand.r(Reg.RAX) });
            } else {
                try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R14), x64.Operand.mem(Reg.RBP, p.off_state_data_base) });
            }
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R14) });
            try abi.emitFullEpilogue(&p.cbuf.bytes);
        }

        // --- Field metadata table ---
        // Each entry: 32-byte zero-padded field name + 4-byte type_tag + 4-byte reserved + 8-byte layout_offset = 48 bytes
        const field_table_label = try allocLabelId(p, "field_table", .{});
        try setLabel(p, field_table_label);
        const table_start_offset = p.cbuf.bytes.items.len;
        for (sv_list.items) |sv| {
            // Write field name (32 bytes, zero-padded)
            const name_bytes = sv.name;
            var buf: [32]u8 = [_]u8{0} ** 32;
            const copy_len = @min(name_bytes.len, 31);
            @memcpy(buf[0..copy_len], name_bytes[0..copy_len]);
            try p.cbuf.bytes.appendSlice(&buf);
            // Write type tag as 32-bit little-endian
            const type_tag: u32 = if (std.mem.eql(u8, sv.type_name, "image<f32>")) 2
            else if (std.mem.eql(u8, sv.type_name, "float")) 1
            else 0; // INT = 0, FLOAT = 1, IMAGE_F32 = 2
            const tag_bytes: [4]u8 = @bitCast(type_tag);
            try p.cbuf.bytes.appendSlice(&tag_bytes);
            // Reserved (4 bytes, zero)
            try p.cbuf.bytes.appendSlice(&([_]u8{0} ** 4));
            // Write layout_offset as 64-bit little-endian
            const off_bytes: [8]u8 = @bitCast(@as(i64, @intCast(sv.layout_offset)));
            try p.cbuf.bytes.appendSlice(&off_bytes);
        }
        // End marker: 48 zero bytes
        {
            const zeros: [48]u8 = [_]u8{0} ** 48;
            try p.cbuf.bytes.appendSlice(&zeros);
        }

        // --- bpc_enum_fields: returns absolute address of field table ---
        {
            const name = "bpc_enum_fields";
            const label_id = try allocLabelId(p, "exp_{s}", .{name});
            try setLabel(p, label_id);
            try p.symbols.add(name, sym.SymbolKind.exp, @intCast(p.cbuf.bytes.items.len));
            // LEA RAX, [RIP + field_table]
            const disp = @as(i32, @truncate(@as(i64, @intCast(table_start_offset)) - @as(i64, @intCast(p.cbuf.bytes.items.len + 7))));
            try p.cbuf.bytes.append(0x48); // REX.W
            try p.cbuf.bytes.append(0x8D); // LEA
            try p.cbuf.bytes.append(0x05); // ModRM: mod=00, reg=000(RAX), r/m=101(RIP-rel)
            const disp_bytes: [4]u8 = @bitCast(disp);
            try p.cbuf.bytes.appendSlice(&disp_bytes);
            try p.cbuf.bytes.append(0xC3); // RET
        }

        // --- bpc_get_trace_buf_slot: returns address of trace buffer pointer slot ---
        if (p.trace_mode != .off) {
            try emitBpcGetTraceBufSlot(p);
        }
    }
    if (p.is_dll) {
        return;
    }
    p.entry_point_rva = @intCast(p.cbuf.bytes.items.len);
    try p.cbuf.bytes.append(0x55);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBP), x64.Operand.r(Reg.RSP) });
    try emitPushR64(p, Reg.RBX); try emitPushR64(p, Reg.R12);
    try emitPushR64(p, Reg.R13); try emitPushR64(p, Reg.R14); try emitPushR64(p, Reg.R15);
    try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(p.stack_frame_size) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R14), x64.Operand.mem(Reg.RBP, p.off_state_data_base) });
    var off = p.off_ctx_var_start;
    for (p.ctx_vars.items) |v| {
        if (isSimdType(v.type_name)) {
            const val = parseNumber(v.default_value);
            if (val == 0) {
                try emitXorXmm(p, XMM.XMM0);
            } else {
                try emitLoadImm(p, Reg.RAX, val);
                try x64.emit(&p.cbuf.bytes, .SSE_CVTSI2SS, &.{ x64.Operand.xmm(XMM.XMM0), x64.Operand.r(Reg.RAX) });
            }
            try emitStoreXmmFromReg(p, off, XMM.XMM0, 4, Reg.RBP);
        } else {
            try emitLoadImm(p, Reg.RAX, parseNumber(v.default_value));
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, off), x64.Operand.r(Reg.RAX) });
        }
        off -= 8;
    }
    var it = p.state_vars.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.items) |sv| {
            if (sv.size > 8 or isSimdType(sv.type_name)) {
                const val = parseNumber(sv.default_value);
                if (val == 0) {
                    try emitXorXmm(p, XMM.XMM0);
                } else {
                    try emitLoadImm(p, Reg.RAX, val);
                    try x64.emit(&p.cbuf.bytes, .SSE_CVTSI2SS, &.{ x64.Operand.xmm(XMM.XMM0), x64.Operand.r(Reg.RAX) });
                    if (sv.size == 16) {
                        try x64.emit(&p.cbuf.bytes, .SSE_SHUFPS, &.{ x64.Operand.xmm(XMM.XMM0), x64.Operand.xmm(XMM.XMM0), x64.Operand.immU32(0) });
                    }
                }
                try emitStoreXmmFromReg(p, @as(i32, @intCast(sv.layout_offset)), XMM.XMM0, sv.size, p.state_base_reg);
            } else {
                try emitLoadImm(p, Reg.RAX, parseNumber(sv.default_value));
                try emitStoreVarFromReg(p, @as(i32, @intCast(sv.layout_offset)), Reg.RAX, sv.size, p.state_base_reg);
            }
        }
    }
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l1_buf_start) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_base), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_ptr), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(p.arena_l1_size) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_end), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l2_buf_start) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_base), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(p.arena_l2_size) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_end), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l3_buf_start) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l3_base), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l3_ptr), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(p.arena_l3_size) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l3_end), x64.Operand.r(Reg.RAX) });
    // L3 block pool init: link all blocks into free list
    // L3 block pool init: link all blocks into free list
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l3_buf_start) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.RAX) });
    if (p.l3_num_blocks > 1) {
        const pl_lp = try allocLabelId(p, "pl_lp", .{});
        try emitMovRegImm32(p, Reg.RCX, p.l3_num_blocks - 1);
        try emitMovRegImm32(p, Reg.RDX, p.l3_block_size);
        try setLabel(p, pl_lp);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDX) });
        try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RAX, 0), x64.Operand.r(Reg.R8) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R8) });
        try emitDec(p, Reg.RCX);
        try emitCondLongJmp(p, .JNE_REL32, pl_lp);
    }
    try emitXorReg(p, Reg.R8);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RAX, 0), x64.Operand.r(Reg.R8) });
    try emitXorReg(p, Reg.RAX);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_cur_state), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_epoch), x64.Operand.r(Reg.RAX) });
    // Zero telemetry counters (RAX = 0 from XOR above)
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_spill), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_spill), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_peak), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_peak), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_peak), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_allocs), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_allocs), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs), x64.Operand.r(Reg.RAX) });
    // Zero handle table metadata arrays (RAX=0 from earlier XOR)
    // Start at ptrs (lowest address), zero upward through free_next/sizes/gens/heats/states
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
    try emitMovRegImm32(p, Reg.RCX, 512 + 256 + 256 + 256 + 256 + 256 + 64 + 64); // ptrs + free_next + sizes + gens + total_heats + heats + tiers + states
    try p.cbuf.bytes.append(0xF3); try p.cbuf.bytes.append(0xAA); // REP STOSB
    // Init free list: free_next[slot] = slot + 1, last = -1
    try emitXorReg(p, Reg.RCX); // slot = 0
    const fl_loop = try allocLabelId(p, "fl_loop", .{});
    const fl_done = try allocLabelId(p, "fl_done", .{});
    const fl_last = try allocLabelId(p, "fl_last", .{});
    const fl_next = try allocLabelId(p, "fl_next", .{});
    try setLabel(p, fl_loop);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
    try emitCondLongJmp(p, .JAE_REL32, fl_done);
    // R11 = &free_next[0], R10 = slot, SHL R10, 2, ADD R11, R10 → &free_next[slot]
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_free_next) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
    // R10 = slot + 1
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.RCX, 1) });
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(64) });
    try emitCondLongJmp(p, .JAE_REL32, fl_last);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) }); // free_next[slot] = slot+1
    try emitShortJmp(p, .JMP_REL32, fl_next);
    try setLabel(p, fl_last);
    try emitMovRegImm32(p, Reg.R10, 0xFFFFFFFF);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) }); // free_next[63] = -1
    try setLabel(p, fl_next);
    try emitInc(p, Reg.RCX);
    try emitShortJmp(p, .JMP_REL32, fl_loop);
    try setLabel(p, fl_done);
    try emitXorReg(p, Reg.RAX); // free_head = 0
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_ht_free_head), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_exit_code), x64.Operand.r(Reg.RAX) }); // default exit code = 0

    if (!p.is_dll) {
        try emitWin32Call(p, 0, &.{abi.CallArg{ .imm = -10 }});
        try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_hstdin), x64.Operand.r(Reg.RAX) });
        try emitWin32Call(p, 0, &.{abi.CallArg{ .imm = -11 }});
        try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_hstdout), x64.Operand.r(Reg.RAX) });
        try emitAffinityInit(p);
    }
    if (!p.is_dll and program.entries.items.len > 0 and !program.entries.items[0].is_export) {
        const entry = &program.entries.items[0];
        if (entry.body_lines.items.len > 0) {
            var buf = std.ArrayList(u8).init(p.allocator);
            for (entry.body_lines.items, 0..) |line, i| {
                const t = std.mem.trim(u8, line, " \t");
                if (t.len == 0) continue;
                if (std.mem.startsWith(u8, t, "var ")) {
                    const rest = std.mem.trimLeft(u8, t["var ".len..], " \t\r\n");
                    const eq_idx = std.mem.indexOfScalar(u8, rest, '=');
                    if (eq_idx) |ei| {
                        const name = std.mem.trim(u8, rest[0..ei], " \t\r\n");
                        var expr = std.mem.trim(u8, rest[ei+1..], " \t\r\n");
                        if (expr.len > 0 and expr[expr.len-1] == ';') expr = expr[0..expr.len-1];
                        const vo = getVarOffset(p, "", name);
                        if (vo != std.math.minInt(i32)) {
                            if (std.mem.startsWith(u8, expr, "if ") or std.mem.startsWith(u8, expr, "if(")) {
                                try emitIfAsExprToRAX(p, expr, "");
                            } else {
                                try emitExprToRAX(p, expr, "");
                            }
                            try emitStoreVarFromReg(p, vo, Reg.RAX, 8, Reg.RBP);
                        }
                    }
                    continue;
                }
                if (std.mem.startsWith(u8, t, "state ")) continue;
                if (i > 0) try buf.append(';');
                try buf.appendSlice(t);
            }
            const state_ctx = if (program.states.items.len > 0) program.states.items[0].name else "";
            try pushDeferScope(p);
            try emitAction(p, buf.items, state_ctx);
            try popDeferScope(p);
            buf.deinit();
        }
    }

    if (program.states.items.len > 0) {
        try emitMovRegImm32(p, Reg.RAX, 1024);
        try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_abudget), x64.Operand.r(Reg.RAX) });
        try emitCallToLabel(p, p.en_id[0]); try emitLongJmp(p, try allocLabelId(p, "always_entry", .{}));
    } else {
        try emitLongJmp(p, try allocLabelId(p, "exit_process", .{}));
    }
    // ============================================================
    // Export stubs for all export entries (emitted after main code
    // so the PE/ELF entry point points to the main function, not
    // to an export stub).
    // ============================================================
    for (program.entries.items) |*entry| {
        if (entry.is_export) {
            const label_id = try allocLabelId(p, "exp_{s}", .{entry.name});
            try setLabel(p, label_id);
            try p.symbols.add(entry.name, sym.SymbolKind.exp, @intCast(p.cbuf.bytes.items.len));
            if (entry.body_lines.items.len > 0) {
                // Entry with body: full frame prologue, state load, init, compile body, epilogue
                try p.cbuf.bytes.append(0x55); // push rbp
                try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBP), x64.Operand.r(Reg.RSP) });
                try emitPushR64(p, Reg.RBX); try emitPushR64(p, Reg.R12);
                try emitPushR64(p, Reg.R13); try emitPushR64(p, Reg.R14); try emitPushR64(p, Reg.R15);
                try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(p.stack_frame_size) });
                // Load state block
                const state_ctx = if (program.states.items.len > 0) program.states.items[0].name else entry.name;
                if (p.is_dll) {
                    const state_idx = p.state_index_map.get(state_ctx) orelse 0;
                    const tls_idx_label = try allocLabelId(p, "tls_idx_{d}", .{state_idx});
                    try emitRipRelativeLoad32(p, Reg.RCX, tls_idx_label);
                    try emitWin32Call(p, 29, &.{}); // TlsGetValue → RAX = state block
                    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R14), x64.Operand.r(Reg.RAX) });
                } else {
                    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R14), x64.Operand.mem(Reg.RBP, p.off_state_data_base) });
                }
                // Load R15 with trace buffer pointer slot address (if tracing enabled)
                if (p.trace_mode != .off) {
                    try emitTraceBufPtrLoad(p);
                }
                // Init: zero all reserved slots, then init stdin/stdout handles
                try emitXorReg(p, Reg.RAX);
                // Zero telem counters
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_spill), x64.Operand.r(Reg.RAX) });
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_spill), x64.Operand.r(Reg.RAX) });
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_peak), x64.Operand.r(Reg.RAX) });
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_peak), x64.Operand.r(Reg.RAX) });
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_peak), x64.Operand.r(Reg.RAX) });
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_allocs), x64.Operand.r(Reg.RAX) });
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_allocs), x64.Operand.r(Reg.RAX) });
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs), x64.Operand.r(Reg.RAX) });
                // Init I/O handles (EXE only)
                if (!p.is_dll) {
                    try emitWin32Call(p, 0, &.{abi.CallArg{ .imm = -10 }});
                    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_hstdin), x64.Operand.r(Reg.RAX) });
                    try emitWin32Call(p, 0, &.{abi.CallArg{ .imm = -11 }});
                    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_hstdout), x64.Operand.r(Reg.RAX) });
                }
                // Compile body
                var buf = std.ArrayList(u8).init(p.allocator);
                for (entry.body_lines.items, 0..) |line, i| {
                    const t = std.mem.trim(u8, line, " \t");
                    std.debug.print("  line[{d}]: t=\"{s}\"\n", .{i, t});
                    if (t.len == 0) continue;
                    if (std.mem.startsWith(u8, t, "var ")) {
                        const rest = std.mem.trimLeft(u8, t["var ".len..], " \t\r\n");
                        const eq_idx = std.mem.indexOfScalar(u8, rest, '=');
                        if (eq_idx) |ei| {
                            const name = std.mem.trim(u8, rest[0..ei], " \t\r\n");
                            var expr = std.mem.trim(u8, rest[ei+1..], " \t\r\n");
                        if (expr.len > 0 and expr[expr.len-1] == ';') expr = expr[0..expr.len-1];
                        const vo = getVarOffset(p, state_ctx, name);
                        std.debug.print("  var: name=\"{s}\" expr=\"{s}\" vo={d}\n", .{name, expr, vo});
                        if (vo != std.math.minInt(i32)) {
                            if (expr.len > 2 and expr[expr.len-1] == '}' and expr[expr.len-2] == '{') {
                                const type_name = std.mem.trim(u8, expr[0..expr.len-2], " \t");
                                if (isStructType(p, type_name)) {
                                    const sz = getStructFieldSize(p, type_name);
                                    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, vo) });
                                    try emitXorReg(p, Reg.RAX);
                                    var qoff: u32 = 0;
                                    while (qoff < sz) {
                                        const chunk = if (sz - qoff >= 8) @as(u32, 8) else if (sz - qoff >= 4) @as(u32, 4) else if (sz - qoff >= 2) @as(u32, 2) else 1;
                                        switch (chunk) {
                                            8 => try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RDI, @as(i32, @intCast(qoff))), x64.Operand.r(Reg.RAX) }),
                                            4 => try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RDI, @as(i32, @intCast(qoff))), x64.Operand.r(Reg.RAX) }),
                                            2 => try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RDI, @as(i32, @intCast(qoff))), x64.Operand.r(Reg.RAX) }),
                                            else => try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RDI, @as(i32, @intCast(qoff))), x64.Operand.r(Reg.RAX) }),
                                        }
                                        qoff += chunk;
                                    }
                                    p.pending_ret = RetValue{ .int = Reg.RAX };
                                } else {
                                    try emitXorReg(p, Reg.RAX);
                                    try emitStoreVarFromReg(p, vo, Reg.RAX, 8, Reg.RBP);
                                }
                            } else {
                                if (std.mem.startsWith(u8, expr, "if ") or std.mem.startsWith(u8, expr, "if(")) {
                                try emitIfAsExprToRAX(p, expr, state_ctx);
                            } else {
                                try emitExprToRAX(p, expr, state_ctx);
                            }
                            try emitStoreVarFromReg(p, vo, Reg.RAX, 8, Reg.RBP);
                        }
                        }
                        continue;
                    }
                    if (std.mem.startsWith(u8, t, "state ")) continue;
                    if (i > 0) try buf.append(';');
                    try buf.appendSlice(t);
                    }
                }
                p.pending_ret = null;
                if (buf.items.len > 0) {
                    try pushDeferScope(p);
                    try emitAction(p, buf.items, state_ctx);
                    try popDeferScope(p);
                } else {
                    try emitXorReg(p, Reg.RAX);
                    try emitInc(p, Reg.RAX);
                    p.pending_ret = RetValue{ .int = Reg.RAX };
                }
                buf.deinit();
                if (p.pending_ret) |rv| {
                    try emitReturn(p, rv);
                }
                try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(p.stack_frame_size) });
                try emitPopR64(p, Reg.R15); try emitPopR64(p, Reg.R14);
                try emitPopR64(p, Reg.R13); try emitPopR64(p, Reg.R12);
                try emitPopR64(p, Reg.RBX);
                try p.cbuf.bytes.append(0x5D); // pop rbp
                try p.cbuf.bytes.append(0xC3); // ret
            } else {
                try abi.emitFullPrologue(&p.cbuf.bytes);
                try emitXorReg(p, Reg.RAX);
                try emitInc(p, Reg.RAX);
                try abi.emitFullEpilogue(&p.cbuf.bytes);
            }
        }
    }
}

fn emitOneIntrinsic(p: *PendingOutput, intrinsic: rt.Intrinsic) !void {
    const lbl = try p.cbuf.allocLabel("rt_{d}", .{@intFromEnum(intrinsic)});
    try setLabel(p, lbl);
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
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_l1_ptr) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l1_end) });
            try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
            try emitShortJmp(p, .JBE_REL32, al1_ok);
            // spill to L2 → l1_spill++
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l1_spill) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_spill), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_l2_ptr) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l2_end) });
            try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
            try emitShortJmp(p, .JBE_REL32, al2_ok);
            // spill to L3 → l2_spill++
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l2_spill) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_spill), x64.Operand.r(Reg.RDX) });
            // Inline L3 pool pop
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_pool_head) });
            try x64.emit(&p.cbuf.bytes, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
            try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "rt_oom", .{}));
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RAX, 0) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 8), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 12), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
            try emitRet(p);
            try setLabel(p, al2_ok);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RCX) });
            // l2_allocs++
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l2_allocs) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_allocs), x64.Operand.r(Reg.RDX) });
            // peak L2
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l2_ptr) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_l2_base) });
            try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_telem_l2_peak) });
            try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try emitShortJmp(p, .JBE_REL32, pk_0_2);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_peak), x64.Operand.r(Reg.RDX) });
            try setLabel(p, pk_0_2);
            try emitRet(p);
            try setLabel(p, al1_ok);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_ptr), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RCX) });
            // l1_allocs++
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l1_allocs) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_allocs), x64.Operand.r(Reg.RDX) });
            // peak L1
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l1_ptr) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_l1_base) });
            try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_telem_l1_peak) });
            try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try emitShortJmp(p, .JBE_REL32, pk_0_1);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l1_peak), x64.Operand.r(Reg.RDX) });
            try setLabel(p, pk_0_1);
        },
        .arena_l2_alloc => {
            const bl2_ok = try allocLabelId(p, "bl2_ok", .{});
            const pk_1_2 = try allocLabelId(p, "pk1_2", .{});
            // try L2
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_l2_ptr) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l2_end) });
            try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
            try emitShortJmp(p, .JBE_REL32, bl2_ok);
            // spill to L3 → l2_spill++
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l2_spill) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_spill), x64.Operand.r(Reg.RDX) });
            // Inline L3 pool pop
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_pool_head) });
            try x64.emit(&p.cbuf.bytes, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
            try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "rt_oom", .{}));
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RAX, 0) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 8), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 12), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
            try emitRet(p);
            try setLabel(p, bl2_ok);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RCX) });
            // l2_allocs++
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_telem_l2_allocs) });
            try emitInc(p, Reg.RDX);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_allocs), x64.Operand.r(Reg.RDX) });
            // peak L2
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_l2_ptr) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_l2_base) });
            try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_telem_l2_peak) });
            try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try emitShortJmp(p, .JBE_REL32, pk_1_2);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l2_peak), x64.Operand.r(Reg.RDX) });
            try setLabel(p, pk_1_2);
        },
        .arena_l3_alloc => {
            // Save size in RDX, then pop pool_head
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_pool_head) });
            try x64.emit(&p.cbuf.bytes, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
            try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "rt_oom", .{}));
            // pool_head = block->free_next
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RAX, 0) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.R8) });
            // Store original_size and bytes_used in header
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 8), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 12), x64.Operand.r(Reg.RDX) });
            // l3_allocs++
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R8), x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs) });
            try emitInc(p, Reg.R8);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_telem_l3_allocs), x64.Operand.r(Reg.R8) });
            // Return data pointer (block + 16)
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
        },
        .arena_l1_reset => {
            // reset all three arenas (L1 + L2 + L3) — spills are scoped to state handler
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l1_base) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_ptr), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l2_base) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l3_base) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l3_ptr), x64.Operand.r(Reg.RAX) });
        },
        .arena_l2_reset => {
            // reset L2 arena cursor to base
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l2_base) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RAX) });
        },
        .arena_l3_reset => {
            // O(1) reset: pool_head = l3_base
            // free_next chain is preserved because alloc never writes to block[0]
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_l3_base) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.RAX) });
        },
        .handle_alloc => {
            const ha_fail = try allocLabelId(p, "ha_fail", .{});
            const ha_gen_ok = try allocLabelId(p, "ha_gen_ok", .{});
            const ha_done = try allocLabelId(p, "ha_done", .{});
            // RCX = ptr, RDX = size → RAX = Handle (slot | gen << 32)
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_ht_free_head) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0xFFFFFFFF) });
            try emitCondLongJmp(p, .JE_REL32, ha_fail);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
            // free_head = free_next[slot]
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_free_next) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_ht_free_head), x64.Operand.r(Reg.R10) });
            // ptrs[slot] = RCX
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(3) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.RCX) });
            // sizes[slot] = RDX
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_sizes) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.RDX) });
            // generations[slot] = prev_gen + 1 (wrap 0→1)
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try emitInc(p, Reg.R10);
            try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
            try emitCondLongJmp(p, .JNE_REL32, ha_gen_ok);
            try emitInc(p, Reg.R10);
            try setLabel(p, ha_gen_ok);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // Save gen in R8 for handle construction
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.R10) });
            // states[slot] = 1 (Used)
            try emitMovRegImm32(p, Reg.R10, 1);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // heats[slot] = 0
            try emitXorReg(p, Reg.R10);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_heats) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R14), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R14), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R14) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // total_heats[slot] = 0
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_total_heats) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R14), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R14), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R14) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // tiers[slot] = 0 (L1)
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_tiers) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // Restore gen from R8, build handle: RAX = slot | gen << 32
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(32) });
            try x64.emit(&p.cbuf.bytes, .OR_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R10) });
            try emitShortJmp(p, .JMP_REL32, ha_done);
            try setLabel(p, ha_fail);
            try emitXorReg(p, Reg.RAX);
            try setLabel(p, ha_done);
        },
        .handle_access => {
            const ha_fail = try allocLabelId(p, "ha_fail", .{});
            const ha_done = try allocLabelId(p, "ha_done", .{});
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
            try emitCondLongJmp(p, .JAE_REL32, ha_fail);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
            try emitCondLongJmp(p, .JNE_REL32, ha_fail);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_R32, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
            try emitCondLongJmp(p, .JNE_REL32, ha_fail);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(3) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.R11, 0) });
            // Touch: heats[slot]++ (capped at maxInt(u32))
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_heats) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(0xFFFFFFFF) });
            try emitCondLongJmp(p, .JE_REL32, ha_done);
            try emitInc(p, Reg.R10);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // total_heats[slot]++ (persistent metric, never reset)
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_total_heats) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(0xFFFFFFFF) });
            try emitCondLongJmp(p, .JE_REL32, ha_done);
            try emitInc(p, Reg.R10);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try emitShortJmp(p, .JMP_REL32, ha_done);
            try setLabel(p, ha_fail);
            try emitXorReg(p, Reg.RAX);
            try setLabel(p, ha_done);
        },
        .handle_release => {
            const hr_skip = try allocLabelId(p, "hr_skip", .{});
            const hr_gen_ok = try allocLabelId(p, "hr_gen_ok", .{});
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
            try emitCondLongJmp(p, .JAE_REL32, hr_skip);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
            try emitCondLongJmp(p, .JNE_REL32, hr_skip);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_R32, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
            try emitCondLongJmp(p, .JNE_REL32, hr_skip);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try emitXorReg(p, Reg.R10);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(3) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try emitXorReg(p, Reg.R10);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_sizes) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try emitXorReg(p, Reg.R10);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_heats) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try emitXorReg(p, Reg.R10);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // tiers[slot] = 0
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_tiers) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.RBP, p.off_ht_free_head) });
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_free_next) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_ht_free_head), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try emitInc(p, Reg.R10);
            try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
            try emitCondLongJmp(p, .JNE_REL32, hr_gen_ok);
            try emitInc(p, Reg.R10);
            try setLabel(p, hr_gen_ok);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            try setLabel(p, hr_skip);
        },
        .handle_validate => {
            const hv_ok = try allocLabelId(p, "hv_ok", .{});
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
            try emitCondLongJmp(p, .JAE_REL32, try allocLabelId(p, "rt_14", .{}));
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
            try emitCondLongJmp(p, .JNE_REL32, try allocLabelId(p, "rt_14", .{}));
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_R32, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
            try emitCondLongJmp(p, .JNE_REL32, try allocLabelId(p, "rt_14", .{}));
            try setLabel(p, hv_ok);
        },
        .log_event => {
            const le_skip = try allocLabelId(p, "le_skip", .{});
            const le_trace = try allocLabelId(p, "trace_buf_ptr", .{});
            // LEA R10, [RIP + trace_buf_ptr] — address of the global slot
            try emitRipRelativeLea(p, Reg.R10, le_trace);
            // MOV R11, [R10] — load current write pointer
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.R10, 0) });
            // TEST R11, R11 — null check
            try x64.emit(&p.cbuf.bytes, .TEST_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R11) });
            try emitCondLongJmp(p, .JE_REL32, le_skip);
            // MOV byte [R11], CL — write kind
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.RCX) });
            // MOV dword [R11+4], EDX — write slot
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 4), x64.Operand.r(Reg.RDX) });
            // MOV dword [R11+8], R8D — write gen
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 8), x64.Operand.r(Reg.R8) });
            // MOV dword [R11+12], R9D — write arg
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 12), x64.Operand.r(Reg.R9) });
            // ADD R11, 16 — advance pointer
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.R11), x64.Operand.immU32(16) });
            // MOV [R10], R11 — store back advanced pointer
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.R10, 0), x64.Operand.r(Reg.R11) });
            try setLabel(p, le_skip);
        },
        .handle_touch => {
            const ht_skip = try allocLabelId(p, "ht_skip", .{});
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
            try emitCondLongJmp(p, .JAE_REL32, ht_skip);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
            try emitCondLongJmp(p, .JNE_REL32, ht_skip);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_R32, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
            try emitCondLongJmp(p, .JNE_REL32, ht_skip);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_heats) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(0xFFFFFFFF) });
            try emitCondLongJmp(p, .JE_REL32, ht_skip);
            try emitInc(p, Reg.R10);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // total_heats[slot]++
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_total_heats) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(0xFFFFFFFF) });
            try emitCondLongJmp(p, .JE_REL32, ht_skip);
            try emitInc(p, Reg.R10);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
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
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_epoch) });
            try emitInc(p, Reg.RAX);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_epoch), x64.Operand.r(Reg.RAX) });
            try emitXorReg(p, Reg.RCX);
            try setLabel(p, loop_label);
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
            try emitCondLongJmp(p, .JAE_REL32, done_label);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
            try emitCondLongJmp(p, .JE_REL32, tick_next);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_heats) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.RBX), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_RIGHT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
            // Migration: check budget, thresholds, tier
            try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.R12), x64.Operand.r(Reg.R12) });
            try emitCondLongJmp(p, .JE_REL32, tick_skip_mig);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_tiers) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.R11, 0) });
            // Promote: heat > 100 && tier > 0
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(100) });
            try emitCondLongJmp(p, .JBE_REL32, tick_try_demote);
            try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.R9) });
            try emitCondLongJmp(p, .JE_REL32, tick_try_demote);
            // Move hotter: RCX=slot, RDX=generations[slot]
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R13), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R13) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.R11, 0) });
            try emitCallToLabel(p, mh_label);
            try emitDec(p, Reg.R12);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.R13) });
            try emitShortJmp(p, .JMP_REL32, tick_next);
            try setLabel(p, tick_try_demote);
            // Demote: heat > 0 && heat < 30 && tier < 2
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(30) });
            try emitCondLongJmp(p, .JAE_REL32, tick_skip_mig);
            try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
            try emitCondLongJmp(p, .JE_REL32, tick_skip_mig);
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R9), x64.Operand.immU32(2) });
            try emitCondLongJmp(p, .JAE_REL32, tick_skip_mig);
            // Move colder: RCX=slot, RDX=generations[slot]
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R13), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R13) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.R11, 0) });
            try emitCallToLabel(p, mc_label);
            try emitDec(p, Reg.R12);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.R13) });
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
            try abi.emitCallArgs(&p.cbuf.bytes, &.{});
            try emitIatCall(p, 3);
            try abi.emitCallCleanup(&p.cbuf.bytes);
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
    try p.cbuf.bytes.append(0xC3);
}

fn emitPushR64(p: *PendingOutput, reg: i16) !void {
    if (reg >= 8) try p.cbuf.bytes.append(0x41);
    try p.cbuf.bytes.append(@as(u8, @intCast(0x50 + (reg & 7))));
}

fn emitPopR64(p: *PendingOutput, reg: i16) !void {
    if (reg >= 8) try p.cbuf.bytes.append(0x41);
    try p.cbuf.bytes.append(@as(u8, @intCast(0x58 + (reg & 7))));
}

fn emitAffinityInit(p: *PendingOutput) !void {
    try emitMovRegImm32(p, Reg.RAX, 0x1A);
    try p.cbuf.bytes.append(0x0F); try p.cbuf.bytes.append(0xA2);
    try p.cbuf.bytes.append(0xC1); try p.cbuf.bytes.append(0xE8); try p.cbuf.bytes.append(0x18);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_core_type), x64.Operand.r(Reg.RAX) });
    try abi.emitCallArgs(&p.cbuf.bytes, &.{});
    try emitIatCall(p, 8);
    try abi.emitCallCleanup(&p.cbuf.bytes);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
    const mask: i64 = if (p.has_hot_states) 15 else -16;
    try emitLoadImm(p, Reg.RDX, mask);
    try abi.emitCallArgs(&p.cbuf.bytes, &.{});
    try emitIatCall(p, 7);
    try abi.emitCallCleanup(&p.cbuf.bytes);
}

const SortedEntry = struct { idx: usize, hw: f64 };

fn emitStateEnterBodyContent(p: *PendingOutput, state: *const ast.StateDefNode, si: usize) !void {
    _ = si;
    for (state.variables.items) |v| {
        if (v.cache_policy) |cp| {
            if (std.mem.eql(u8, cp, "L1")) {
                try emitLoadImm(p, Reg.RAX, parseNumber(v.default_value orelse "0"));
                const vo = getVarOffset(p, state.name, v.name);
                if (vo != std.math.minInt(i32)) {
                    const vsz = getVarSize(p, state.name, v.name);
                    if (vsz > 8 or isSimdType(v.type_name)) {
                        const val = parseNumber(v.default_value orelse "0");
                        if (val == 0) {
                            try emitXorXmm(p, XMM.XMM0);
                        } else {
                            try emitLoadImm(p, Reg.RAX, val);
                            try x64.emit(&p.cbuf.bytes, .SSE_CVTSI2SS, &.{ x64.Operand.xmm(XMM.XMM0), x64.Operand.r(Reg.RAX) });
                            if (vsz == 16) {
                                try x64.emit(&p.cbuf.bytes, .SSE_SHUFPS, &.{ x64.Operand.xmm(XMM.XMM0), x64.Operand.xmm(XMM.XMM0), x64.Operand.immU32(0) });
                            }
                        }
                        try emitStoreXmmFromReg(p, vo, XMM.XMM0, vsz, getVarBaseReg(p, state.name, v.name));
                    } else {
                        try emitStoreVarFromReg(p, vo, Reg.RAX, vsz, getVarBaseReg(p, state.name, v.name));
                    }
                }
            }
        }
    }
    if (state.enter_body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, state.name); }
    for (state.transitions.items) |t| {
        if (t.body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, state.name); }
    }
}

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
            if (av == 64) { try alignTo64(p); } else if (av >= 16) { while (p.cbuf.bytes.items.len % @as(usize, @intCast(av)) != 0) try p.cbuf.bytes.append(0x90); }
        }
        if (p.inline_enter.len > item.idx and p.inline_enter[item.idx]) continue;
        const start_off = p.cbuf.bytes.items.len;
        try setLabel(p, p.en_id[item.idx]);
        try emitStateEnterBodyContent(p, &state, item.idx);
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
            const ti_idx = p.state_index_map.get(t.target) orelse return error.UndefinedStateTarget;
            const ts = program.states.items[ti_idx];
            const level: i32 = if (ts.cache_policy) |cp| blk: { if (std.mem.eql(u8, cp, "L2")) break :blk 2; if (std.mem.eql(u8, cp, "L3")) break :blk 3; break :blk 1; } else 1;
            if (p.state_vars.get(t.target)) |vars| { for (vars.items) |sv| try emitPrefetchData(p, @as(i32, @intCast(sv.layout_offset)), level, p.state_base_reg); }
            if (level <= 1) try emitPrefetch(p, p.en_id[ti_idx]);
        }
        lv.deinit();
        try x64.emit(&p.cbuf.bytes, .RET, &.{});
        const end_off = p.cbuf.bytes.items.len;
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
            const new_off: u32 = @intCast(p.cbuf.bytes.items.len);
            setLabelAt(p, p.en_id[oi], new_off);
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
            const has_always = prev.transitions.items.len == 1 and prev.transitions.items[0].is_always and (prev.transitions.items[0].event_name == null or prev.transitions.items[0].event_name.?.len == 0);
            if (!has_always) break;
            const prev_ti = state_index_map.get(prev.transitions.items[0].target) orelse return error.UndefinedStateTarget;
            if (prev_ti != si + chain_len) break;
            const trans_hw = prev.transitions.items[0].hot_weight orelse prev.hot_weight orelse 0.5;
            if (trans_hw < 0.4) break;
            chain_len += 1;
        }
        var total_hw: f64 = 0;
        var total_trans_hw: f64 = 0;
        for (si..si + chain_len) |i| {
            total_hw += program.states.items[i].hot_weight orelse 0.5;
            if (i + 1 < si + chain_len) {
                const t_hw = program.states.items[i].transitions.items[0].hot_weight orelse program.states.items[i].hot_weight orelse 0.5;
                total_trans_hw += t_hw;
            }
        }
        const avg_state_hw = total_hw / @as(f64, @floatFromInt(chain_len));
        const avg_trans_hw = if (chain_len > 1) total_trans_hw / @as(f64, @floatFromInt(chain_len - 1)) else 0.5;
        try traces.append(.{ .start_state = si, .len = chain_len, .hot_weight = avg_state_hw * 0.6 + avg_trans_hw * 0.4 });
        si += chain_len;
    }
    return traces;
}

fn emitEventLoop(p: *PendingOutput, program: ast.ProgramNode, traces: std.ArrayList(Trace)) !void {
    try setLabel(p, try allocLabelId(p, "evloop", .{}));
    try emitMovRegImm32(p, Reg.RAX, 4);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_abudget), x64.Operand.r(Reg.RAX) });
    try emitIntrinsicCall(p, .tick);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_hstdin) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try emitMovRegImm32(p, Reg.R8, 256);
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.RBP, p.off_chars_read) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try emitXorReg(p, Reg.RAX);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 32), x64.Operand.r(Reg.RAX) });
    try emitIatCall(p, 2);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_chars_read) });
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try emitXorReg(p, Reg.RCX);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_cursor), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_remaining), x64.Operand.r(Reg.RAX) });
    try alignTo16(p);
    try setLabel(p, try allocLabelId(p, "re_dispatch", .{}));
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_remaining) });
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "always_entry", .{}));
    const ex_idx = try addPoolString(p, "exit");
    try emitRipLea(p, Reg.RSI, ex_idx);
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_cursor) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RAX) });
    try setLabel(p, try allocLabelId(p, "exl", .{}));
    try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
    try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RBX), x64.Operand.mem(Reg.RSI, 0) });
    try x64.emit(&p.cbuf.bytes, .CMP_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
    try emitShortJmp(p, .JNE_REL32, try allocLabelId(p, "exce", .{}));
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try emitInc(p, Reg.RDI); try emitInc(p, Reg.RSI);
    try emitShortJmp(p, .JMP_REL32, try allocLabelId(p, "exl", .{}));
    try setLabel(p, try allocLabelId(p, "exce", .{}));
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RBX) });
    try emitShortJmp(p, .JE_REL32, try allocLabelId(p, "ex_chk_term", .{}));
    try emitShortJmp(p, .JMP_REL32, try allocLabelId(p, "no_exit", .{}));
    try setLabel(p, try allocLabelId(p, "ex_skip_ws", .{}));
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
    try setLabel(p, try allocLabelId(p, "ex_chk_term", .{}));
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x20) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "ex_skip_ws", .{}));
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x09) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "ex_skip_ws", .{}));
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0A) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0D) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "exit_process", .{}));
    try emitShortJmp(p, .JMP_REL32, try allocLabelId(p, "no_exit", .{}));
    try setLabel(p, try allocLabelId(p, "always_entry", .{}));
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_abudget) });
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JNE_REL32, try allocLabelId(p, "always_dispatch", .{}));
    // Budget exhausted: reset to 4 and enter event loop (may read stdin, or exit if EOF)
    try emitMovRegImm32(p, Reg.RAX, 4);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_abudget), x64.Operand.r(Reg.RAX) });
    try emitLongJmp(p, try allocLabelId(p, "evloop", .{}));
    try setLabel(p, try allocLabelId(p, "always_dispatch", .{}));
    // Check budget: if exhausted, enter event loop
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_abudget) });
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JLE_REL32, try allocLabelId(p, "always_entry", .{}));
    try setLabel(p, try allocLabelId(p, "no_exit", .{}));
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R12), x64.Operand.mem(Reg.RBP, p.off_cur_state) });
    // Jump table dispatch: bounds check + O(1) indirect jump via [table + state*4]
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R12), x64.Operand.immU32(@intCast(p.state_names.items.len)) });
    try emitCondLongJmp(p, .JAE_REL32, try allocLabelId(p, "re_dispatch", .{}));
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(255, 0) });
    try p.cbuf.fixups.append(.{ .offset = p.cbuf.bytes.items.len - 4, .disp_size = 4, .label_id = try allocLabelId(p, "jmp_table", .{}) });
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.memIdx(Reg.R11, Reg.R12, 4, 0) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R11) });
    try p.cbuf.bytes.append(0xFF); try p.cbuf.bytes.append(0xE0);
    // Emit jump table (entries filled after fixups)
    try setLabel(p, try allocLabelId(p, "jmp_table", .{}));
    for (0..p.state_names.items.len) |_| try p.cbuf.bytes.appendNTimes(0, 4);
    for (traces.items) |trace| {
        for (trace.start_state..trace.start_state + trace.len) |block_si| {
            const is_last = block_si == trace.start_state + trace.len - 1;
            const bs = program.states.items[block_si];
            try setLabel(p, p.dp_id[block_si]);
            // Profiling: increment state hit counter
            const hit_off = p.off_state_hits + @as(i32, @intCast(block_si)) * 8;
            try p.cbuf.bytes.append(0x48); // REX.W
            try p.cbuf.bytes.append(0xFF); // Opcode
            try p.cbuf.bytes.append(0x85); // ModRM: mod=10(disp32), reg=0(INC), rm=101(RBP)
            try p.cbuf.bytes.appendSlice(&@as([4]u8, @bitCast(hit_off)));
            if ((bs.hot_weight orelse 0.5) <= 0.3) try emitPrefetchColdData(p, &bs);
            const fuse = if (trace.len > 1) !is_last else false;
            const next_inline = if (!is_last and block_si + 1 < p.inline_enter.len) p.inline_enter[block_si + 1] else false;
            try emitStateDispatch(p, &bs, block_si, program, fuse, next_inline);
            if (is_last) try emitLongJmp(p, try allocLabelId(p, "advance_cursor", .{}));
        }
    }
    try emitLongJmp(p, try allocLabelId(p, "advance_cursor", .{}));
    try alignTo16(p);
    try setLabel(p, try allocLabelId(p, "advance_cursor", .{}));
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_cursor) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_R32_R32, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_remaining) });
    try setLabel(p, try allocLabelId(p, "adv_scan", .{}));
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RCX) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "evloop", .{}));
    try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitShortJmp(p, .JE_REL32, try allocLabelId(p, "adv_found", .{}));
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0A) });
    try emitShortJmp(p, .JE_REL32, try allocLabelId(p, "adv_found", .{}));
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0D) });
    try emitShortJmp(p, .JE_REL32, try allocLabelId(p, "adv_cr", .{}));
    try emitInc(p, Reg.RDI); try emitDec(p, Reg.RCX);
    try emitShortJmp(p, .JMP_REL32, try allocLabelId(p, "adv_scan", .{}));
    try setLabel(p, try allocLabelId(p, "adv_cr", .{}));
    try emitInc(p, Reg.RDI); try emitDec(p, Reg.RCX);
    try emitShortJmp(p, .JE_REL32, try allocLabelId(p, "adv_done", .{}));
    try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0A) });
    try emitShortJmp(p, .JNE_REL32, try allocLabelId(p, "adv_done", .{}));
    try emitInc(p, Reg.RDI); try emitDec(p, Reg.RCX);
    try emitShortJmp(p, .JMP_REL32, try allocLabelId(p, "adv_done", .{}));
    try setLabel(p, try allocLabelId(p, "adv_found", .{}));
    try emitInc(p, Reg.RDI); try emitDec(p, Reg.RCX);
    try setLabel(p, try allocLabelId(p, "adv_done", .{}));
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.cbuf.bytes, .SUB_R32_R32, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RDI) });
    try x64.emit(&p.cbuf.bytes, .SUB_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_remaining) });
    try x64.emit(&p.cbuf.bytes, .SUB_R32_R32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_remaining), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_cursor), x64.Operand.r(Reg.RDI) });
    try emitLongJmp(p, try allocLabelId(p, "re_dispatch", .{}));
    try setLabel(p, try allocLabelId(p, "exit_process", .{}));
    // Telemetry dump: build "TELEM:XXXXXXXXXXXXXXXX...XXXXXXXXXXXXXXXX\n" in buf (256B, dead at exit)
    const th_sub = try allocLabelId(p, "th_sub", .{});
    const th_lp = try allocLabelId(p, "th_lp", .{});
    const th_hd = try allocLabelId(p, "th_hd", .{});
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_IMM64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(0x00003A4D454C4554) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RDI), x64.Operand.immU32(6) });
    const telem_offs = [_]i32{
        p.off_telem_l1_spill, p.off_telem_l2_spill,
        p.off_telem_l1_peak, p.off_telem_l2_peak, p.off_telem_l3_peak,
        p.off_telem_l1_allocs, p.off_telem_l2_allocs, p.off_telem_l3_allocs,
    };
    inline for (telem_offs, 0..) |off, i| {
        try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, off) });
        try emitCallToLabel(p, th_sub);
        if (i < telem_offs.len - 1) {
            try emitMovRegImm32(p, Reg.RAX, ' ');
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
            try emitInc(p, Reg.RDI);
        }
    }
    try emitMovRegImm32(p, Reg.RAX, 0x0A);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    // WriteFile(stdout, buf, length)
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_hstdout) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDI) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.RBP, p.off_chars_written) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try emitXorReg(p, Reg.RAX);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 32), x64.Operand.r(Reg.RAX) });
    try emitIatCall(p, 1);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    // State hit profile dump
    try alignTo16(p);
    try setLabel(p, try allocLabelId(p, "sth_start", .{}));
    // RSI = &state_hits[0], R12 = state count (loop counter)
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RSI), x64.Operand.mem(Reg.RBP, p.off_state_hits) });
    try emitMovRegImm32(p, Reg.R12, @intCast(program.states.items.len));
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R12), x64.Operand.immU32(0) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "sth_done", .{}));
    try setLabel(p, try allocLabelId(p, "sth_loop", .{}));
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try emitMovRegImm32(p, Reg.RAX, 'S');
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try emitMovRegImm32(p, Reg.RAX, ' ');
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RSI, 0) });
    try emitCallToLabel(p, th_sub);
    try emitMovRegImm32(p, Reg.RAX, 0x0A);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    // WriteFile(stdout, buf, length)
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_hstdout) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDI) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.RBP, p.off_chars_written) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try emitXorReg(p, Reg.RAX);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 32), x64.Operand.r(Reg.RAX) });
    try emitIatCall(p, 1);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSI), x64.Operand.immU32(8) });
    try emitDec(p, Reg.R12);
    try emitCondLongJmp(p, .JNE_REL32, try allocLabelId(p, "sth_loop", .{}));
    try setLabel(p, try allocLabelId(p, "sth_done", .{}));
    // Transition counter dump
    try setLabel(p, try allocLabelId(p, "thr_start", .{}));
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RSI), x64.Operand.mem(Reg.RBP, p.off_trans_hits) });
    try emitMovRegImm32(p, Reg.R12, p.total_transitions);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R12), x64.Operand.immU32(0) });
    try emitCondLongJmp(p, .JE_REL32, try allocLabelId(p, "thr_done", .{}));
    try setLabel(p, try allocLabelId(p, "thr_loop", .{}));
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try emitMovRegImm32(p, Reg.RAX, 'T');
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try emitMovRegImm32(p, Reg.RAX, ' ');
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RSI, 0) });
    try emitCallToLabel(p, th_sub);
    try emitMovRegImm32(p, Reg.RAX, 0x0A);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_hstdout) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDI) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.RBP, p.off_chars_written) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try emitXorReg(p, Reg.RAX);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 32), x64.Operand.r(Reg.RAX) });
    try emitIatCall(p, 1);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSI), x64.Operand.immU32(8) });
    try emitDec(p, Reg.R12);
    try emitCondLongJmp(p, .JNE_REL32, try allocLabelId(p, "thr_loop", .{}));
    try setLabel(p, try allocLabelId(p, "thr_done", .{}));
    // Heat dump: "H XXXXXXXX\n" for each slot (Used only)
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RSI), x64.Operand.mem(Reg.RBP, p.off_ht_heats) });
    try emitMovRegImm32(p, Reg.R12, 64);
    try setLabel(p, try allocLabelId(p, "hdp_loop", .{}));
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try emitMovRegImm32(p, Reg.RAX, 'H');
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try emitMovRegImm32(p, Reg.RAX, ' ');
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RSI, 0) });
    try emitCallToLabel(p, th_sub);
    try emitMovRegImm32(p, Reg.RAX, 0x0A);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_hstdout) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDI) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.RBP, p.off_chars_written) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try emitXorReg(p, Reg.RAX);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 32), x64.Operand.r(Reg.RAX) });
    try emitIatCall(p, 1);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSI), x64.Operand.immU32(4) });
    try emitDec(p, Reg.R12);
    try emitCondLongJmp(p, .JNE_REL32, try allocLabelId(p, "hdp_loop", .{}));
    // Total heat dump: "TH XXXXXXXX\n" for each slot
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RSI), x64.Operand.mem(Reg.RBP, p.off_ht_total_heats) });
    try emitMovRegImm32(p, Reg.R12, 64);
    try setLabel(p, try allocLabelId(p, "thdp_loop", .{}));
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try emitMovRegImm32(p, Reg.RAX, 'T');
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try emitMovRegImm32(p, Reg.RAX, 'H');
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try emitMovRegImm32(p, Reg.RAX, ' ');
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RSI, 0) });
    try emitCallToLabel(p, th_sub);
    try emitMovRegImm32(p, Reg.RAX, 0x0A);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_hstdout) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.RBP, p.off_buf) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDI) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.RBP, p.off_chars_written) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try emitXorReg(p, Reg.RAX);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 32), x64.Operand.r(Reg.RAX) });
    try emitIatCall(p, 1);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSI), x64.Operand.immU32(4) });
    try emitDec(p, Reg.R12);
    try emitCondLongJmp(p, .JNE_REL32, try allocLabelId(p, "thdp_loop", .{}));
    try emitLongJmp(p, try allocLabelId(p, "exit_end", .{}));
    // Hex conversion subroutine (reached only via CALL)
    try setLabel(p, th_sub);
    try emitMovRegImm32(p, Reg.RCX, 16);
    try setLabel(p, th_lp);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .SHIFT_RIGHT, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(60) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(0x30) });
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(0x39) });
    try emitShortJmp(p, .JBE_REL32, th_hd);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(0x27) });
    try setLabel(p, th_hd);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.RDI, 0), x64.Operand.r(Reg.RDX) });
    try emitInc(p, Reg.RDI);
    try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(4) });
    try emitDec(p, Reg.RCX);
    try emitCondLongJmp(p, .JNE_REL32, th_lp);
    try emitRet(p);
    try setLabel(p, try allocLabelId(p, "exit_end", .{}));
    // ExitProcess with saved return value
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_exit_code) });
    try emitWin32Call(p, 3, &.{});
    try emitLongJmp(p, try allocLabelId(p, "exit_process", .{}));
}

fn emitStateDispatch(p: *PendingOutput, state: *const ast.StateDefNode, si: usize, program: ast.ProgramNode, fuse: bool, inline_enter: bool) !void {
    var state_trans_start: u32 = 0;
    for (0..si) |i| state_trans_start += @intCast(program.states.items[i].transitions.items.len);
    for (state.transitions.items, 0..) |t, ti_| {
        if ((t.event_name != null and t.event_name.?.len > 0) or !t.is_always) continue;
        if (t.is_always and (t.event_name == null or t.event_name.?.len == 0)) {
            if (t.guard == null or t.guard.?.len == 0) {
                if (t.body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, state.name); }
                const trans_hit_off = p.off_trans_hits + @as(i32, @intCast((state_trans_start + @as(u32, @intCast(ti_))) * 8));
                try p.cbuf.bytes.appendSlice(&.{ 0x48, 0xFF, 0x85 });
                try p.cbuf.bytes.appendSlice(&@as([4]u8, @bitCast(trans_hit_off)));
                try changeToState(p, t.target, si, program, true, fuse, inline_enter);
                return;
            }
            try emitGuardSkip(p, t.guard.?, si, 0);
            if (t.body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, state.name); }
            const trans_hit_off = p.off_trans_hits + @as(i32, @intCast((state_trans_start + @as(u32, @intCast(ti_))) * 8));
            try p.cbuf.bytes.appendSlice(&.{ 0x48, 0xFF, 0x85 });
            try p.cbuf.bytes.appendSlice(&@as([4]u8, @bitCast(trans_hit_off)));
            try changeToState(p, t.target, si, program, true, fuse, inline_enter);
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
        try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RBP, p.off_buf) });
        try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_cursor) });
        try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RAX) });
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
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RBX), x64.Operand.mem(Reg.RSI, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
            try emitShortJmp(p, .JNE_REL32, ce);
            try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
            try emitShortJmp(p, .JE_REL32, match_label);
            try emitInc(p, Reg.RDI); try emitInc(p, Reg.RSI);
            try emitShortJmp(p, .JMP_REL32, ll);
            try setLabel(p, ce);
            try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RBX) });
            try emitCondLongJmp(p, .JE_REL32, skip_label);
            try emitLongJmp(p, done_label);
            try setLabel(p, ws_label);
            try emitInc(p, Reg.RDI);
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try setLabel(p, skip_label);
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x20) });
            try emitShortJmp(p, .JE_REL32, ws_label);
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x09) });
            try emitShortJmp(p, .JE_REL32, ws_label);
            try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
            try emitShortJmp(p, .JE_REL32, match_label);
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0A) });
            try emitShortJmp(p, .JE_REL32, match_label);
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0D) });
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
            const trans_hit_off = p.off_trans_hits + @as(i32, @intCast((state_trans_start + @as(u32, @intCast(orig_ti))) * 8));
            try p.cbuf.bytes.appendSlice(&.{ 0x48, 0xFF, 0x85 });
            try p.cbuf.bytes.appendSlice(&@as([4]u8, @bitCast(trans_hit_off)));
            try changeToState(p, tt.target, si, program, false, false, false);
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
            try emitXorReg(p, Reg.RBX);
        }
    }
    try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
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
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(en[0]) });
            try emitCondLongJmp(p, .JNE_REL32, done_label);
        },
        2 => {
            const imm = @as(u16, en[0]) | (@as(u16, en[1]) << 8);
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM16, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(imm) });
            try emitCondLongJmp(p, .JNE_REL32, done_label);
        },
        3 => {
            const imm16 = @as(u16, en[0]) | (@as(u16, en[1]) << 8);
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM16, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(imm16) });
            try emitCondLongJmp(p, .JNE_REL32, done_label);
            try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 2) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(en[2]) });
            try emitCondLongJmp(p, .JNE_REL32, done_label);
        },
        4 => {
            const imm = @as(u32, en[0]) | (@as(u32, en[1]) << 8) | (@as(u32, en[2]) << 16) | (@as(u32, en[3]) << 24);
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, 0) });
            try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(imm) });
            try emitCondLongJmp(p, .JNE_REL32, done_label);
        },
        else => unreachable,
    }
    try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RDI, @intCast(len)) });
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x20) });
    try emitShortJmp(p, .JE_REL32, ws_label);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x09) });
    try emitShortJmp(p, .JE_REL32, ws_label);
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitShortJmp(p, .JE_REL32, match_label);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0A) });
    try emitShortJmp(p, .JE_REL32, match_label);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(0x0D) });
    try emitShortJmp(p, .JE_REL32, match_label);
    try emitLongJmp(p, done_label);
}

fn changeToState(p: *PendingOutput, target: []const u8, current_si: usize, program: ast.ProgramNode, jump_to_scheduler: bool, fuse: bool, inline_enter: bool) !void {
    const ti = p.state_index_map.get(target) orelse return error.UndefinedStateTarget;
    if (!fuse) try emitIntrinsicCall(p, rt.Intrinsic.arena_l1_reset);
    const cur_state = program.states.items[current_si];
    if (cur_state.exit_body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, cur_state.name); }
    for (cur_state.transitions.items) |act| {
        if (act.body) |body| { const tb = std.mem.trim(u8, body, " \t\r\n"); if (tb.len > 0) try emitAction(p, tb, cur_state.name); }
    }
    try emitMovRegImm32(p, Reg.RAX, @intCast(ti));
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_cur_state), x64.Operand.r(Reg.RAX) });
    if (inline_enter) {
        try emitStateEnterBodyContent(p, &program.states.items[ti], ti);
    } else {
        try emitCallToLabel(p, p.en_id[ti]);
    }
    if (jump_to_scheduler) {
        if (!fuse) {
            try emitLongJmp(p, try allocLabelId(p, "always_dispatch", .{}));
        }
    } else {
        try emitLongJmp(p, try allocLabelId(p, "advance_cursor", .{}));
    }
}

fn emitCacheBudgetChecks(p: *PendingOutput, program: ast.ProgramNode) !void {
    _ = program;
    const re_disp_start = getLabel(p, try allocLabelId(p, "re_dispatch", .{})) orelse 0;
    const ad_start = getLabel(p, try allocLabelId(p, "advance_cursor", .{})) orelse 0;
    const loop_end = if (ad_start > re_disp_start) ad_start else p.cbuf.bytes.items.len;
    const loop_bytes = if (loop_end > re_disp_start) loop_end - re_disp_start else 0;
    var hot_enter: usize = 0;
    var it = p.state_code_bounds.iterator();
    while (it.next()) |entry| {
        hot_enter += entry.value_ptr.end - entry.value_ptr.start;
    }
    const total_hot = loop_bytes + hot_enter;
    if (total_hot > 24576) {
        const w = try std.fmt.allocPrint(p.allocator, "; L1i: hot {d}B > 75% of 32KB\x00", .{total_hot});
        try p.cbuf.bytes.appendSlice(w);
        p.allocator.free(w);
    }
}

fn embedStringPool(p: *PendingOutput) !void {
    for (p.string_list.items, 0..) |s, i| {
        try setLabel(p, try allocLabelId(p, "str_{d}", .{i}));
        try p.cbuf.bytes.appendSlice(s);
        try p.cbuf.bytes.append(0);
    }
    for (p.wstring_list.items, 0..) |ws, i| {
        try setLabel(p, try allocLabelId(p, "wstr_{d}", .{i}));
        try p.cbuf.bytes.appendSlice(std.mem.sliceAsBytes(ws));
    }
}

fn embedStateGlobals(p: *PendingOutput) !void {
    for (0..p.state_names.items.len) |si| {
        try setLabel(p, try allocLabelId(p, "tls_idx_{d}", .{si}));
        try p.cbuf.bytes.appendNTimes(0, 4); // dword TLS index
        try setLabel(p, try allocLabelId(p, "state_ptr_{d}", .{si}));
        try p.cbuf.bytes.appendNTimes(0, 8); // qword state block pointer
    }
    // Trace buffer pointer slot (written by runner via bpc_set_trace_buffer)
    try setLabel(p, try allocLabelId(p, "trace_buf_ptr", .{}));
    try p.cbuf.bytes.appendNTimes(0, 8); // qword: current write position in trace buffer
}

fn emitImportTable(p: *PendingOutput) !u32 {
    const base_off = @as(u32, @intCast(p.cbuf.bytes.items.len));
    const ng = IMPORT_GROUPS.len;
    const desc_total: u32 = @as(u32, @intCast((ng + 1) * 20));
    const int_off = base_off + desc_total;
    var group_ints = std.ArrayList(u32).init(p.allocator);
    var group_names = std.ArrayList(u32).init(p.allocator);
    var group_iats = std.ArrayList(u32).init(p.allocator);
    var cur_int = int_off;
    var cur_name: u32 = undefined;
    var cur_hint: u32 = undefined;
    var cur_iat: u32 = undefined;
    // pass 1: allocate INTs
    for (IMPORT_GROUPS) |g| {
        try group_ints.append(cur_int);
        cur_int += @as(u32, @intCast((g.fns.len + 1) * 8));
    }
    cur_name = cur_int;
    // pass 2: allocate DLL names
    for (IMPORT_GROUPS) |g| {
        try group_names.append(cur_name);
        cur_name += @as(u32, @intCast(g.dll.len)) + 1;
    }
    cur_hint = cur_name;
    // pass 3: allocate hint/name entries per group
    var group_hint_bases = std.ArrayList(u32).init(p.allocator);
    var hint_offs = std.ArrayList(u32).init(p.allocator);
    var hint_dats = std.ArrayList([]const u8).init(p.allocator);
    for (IMPORT_GROUPS) |g| {
        try group_hint_bases.append(cur_hint);
        for (g.fns) |fn_name| {
            try hint_offs.append(cur_hint);
            const d = try std.fmt.allocPrint(p.allocator, "{s}\x00", .{fn_name});
            try hint_dats.append(d);
            cur_hint += 2 + @as(u32, @intCast(d.len));
        }
    }
    cur_iat = cur_hint;
    // pass 4: IAT starts after all hint data
    for (IMPORT_GROUPS) |g| {
        try group_iats.append(cur_iat);
        cur_iat += @as(u32, @intCast((g.fns.len + 1) * 8));
    }

    // Emit import descriptors
    for (IMPORT_GROUPS, 0..) |_, gi| {
        try p.cbuf.bytes.appendSlice(&@as([4]u8, @bitCast(SectionRva + group_ints.items[gi]))); // OriginalFirstThunk
        try p.cbuf.bytes.appendNTimes(0, 4); // TimeDateStamp
        try p.cbuf.bytes.appendNTimes(0, 4); // ForwarderChain
        try p.cbuf.bytes.appendSlice(&@as([4]u8, @bitCast(SectionRva + group_names.items[gi]))); // Name
        try p.cbuf.bytes.appendSlice(&@as([4]u8, @bitCast(SectionRva + group_iats.items[gi]))); // FirstThunk
    }
    try p.cbuf.bytes.appendNTimes(0, 20); // zero terminator

    // Emit per-group INT arrays
    var fn_idx: u32 = 0;
    for (IMPORT_GROUPS) |g| {
        for (0..g.fns.len) |_| {
            try p.cbuf.bytes.appendSlice(&@as([8]u8, @bitCast(@as(u64, SectionRva + hint_offs.items[fn_idx]))));
            fn_idx += 1;
        }
        try p.cbuf.bytes.appendNTimes(0, 8); // null terminator
    }

    // Emit DLL names
    for (IMPORT_GROUPS) |g| {
        try p.cbuf.bytes.appendSlice(g.dll);
        try p.cbuf.bytes.append(0);
    }

    // Emit hint/name entries
    for (hint_dats.items) |hd| {
        try p.cbuf.bytes.append(0); try p.cbuf.bytes.append(0); // hint
        try p.cbuf.bytes.appendSlice(hd);
    }

    // Emit IAT arrays
    fn_idx = 0;
    for (IMPORT_GROUPS) |g| {
        for (0..g.fns.len) |_| {
            try p.cbuf.bytes.appendSlice(&@as([8]u8, @bitCast(@as(u64, SectionRva + hint_offs.items[fn_idx]))));
            fn_idx += 1;
        }
        try p.cbuf.bytes.appendNTimes(0, 8); // null terminator
    }

    // Set iat_N labels for each function (flat IAT indices)
    fn_idx = 0;
    for (IMPORT_GROUPS, 0..) |g, gi| {
        var i: u32 = 0;
        while (i < g.fns.len) : (i += 1) {
            const iat_label_val = group_iats.items[gi] + i * 8;
            setLabelAt(p, try allocLabelId(p, "iat_{d}", .{fn_idx}), iat_label_val);
            fn_idx += 1;
        }
    }

    // cleanup
    for (hint_dats.items) |s| p.allocator.free(s);
    hint_offs.deinit(); hint_dats.deinit();
    group_ints.deinit(); group_names.deinit(); group_iats.deinit(); group_hint_bases.deinit();
    return base_off;
}

fn computeImportTableSize() u32 {
    const ng = IMPORT_GROUPS.len;
    const desc_total: u32 = @as(u32, @intCast((ng + 1) * 20));
    var total: u32 = desc_total;
    for (IMPORT_GROUPS) |g| {
        total += @as(u32, @intCast((g.fns.len + 1) * 8)); // INT
        total += @as(u32, @intCast(g.dll.len)) + 1; // DLL name
        for (g.fns) |fn_name| {
            total += 2 + @as(u32, @intCast(fn_name.len)) + 1; // hint/name
        }
        total += @as(u32, @intCast((g.fns.len + 1) * 8)); // IAT
    }
    return total;
}

fn applyFixups(p: *PendingOutput) !void {
    for (p.cbuf.fixups.items) |fx| {
        const target = getLabel(p, fx.label_id) orelse continue;
        if (fx.offset >= p.cbuf.bytes.items.len) continue;
        const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(fx.offset + fx.disp_size)));
        if (fx.disp_size == 1) {
            p.cbuf.bytes.items[fx.offset] = @as(u8, @bitCast(@as(i8, @truncate(disp))));
        } else if (fx.disp_size == 4) {
            const u = @as(u32, @bitCast(disp));
            p.cbuf.bytes.items[fx.offset + 0] = @as(u8, @truncate(u));
            p.cbuf.bytes.items[fx.offset + 1] = @as(u8, @truncate(u >> 8));
            p.cbuf.bytes.items[fx.offset + 2] = @as(u8, @truncate(u >> 16));
            p.cbuf.bytes.items[fx.offset + 3] = @as(u8, @truncate(u >> 24));
        }
    }
}

fn emitShortJmp(p: *PendingOutput, op: x64.OpCode, label_id: u32) !void {
    try x64.emit(&p.cbuf.bytes, op, &.{x64.Operand.imm(0)});
    try p.cbuf.fixups.append(.{ .offset = p.cbuf.bytes.items.len - 4, .disp_size = 4, .label_id = label_id });
}

fn emitLongJmp(p: *PendingOutput, label_id: u32) !void {
    try x64.emit(&p.cbuf.bytes, .JMP_REL32, &.{x64.Operand.imm(0)});
    try p.cbuf.fixups.append(.{ .offset = p.cbuf.bytes.items.len - 4, .disp_size = 4, .label_id = label_id });
}

fn emitCondLongJmp(p: *PendingOutput, op: x64.OpCode, label_id: u32) !void {
    try x64.emit(&p.cbuf.bytes, op, &.{x64.Operand.imm(0)});
    try p.cbuf.fixups.append(.{ .offset = p.cbuf.bytes.items.len - 4, .disp_size = 4, .label_id = label_id });
}

fn emitCallToLabel(p: *PendingOutput, label_id: u32) !void {
    try x64.emit(&p.cbuf.bytes, .CALL_REL32, &.{x64.Operand.imm(0)});
    try p.cbuf.fixups.append(.{ .offset = p.cbuf.bytes.items.len - 4, .disp_size = 4, .label_id = label_id });
}

fn emitRipLea(p: *PendingOutput, dst: i16, string_idx: u32) !void {
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(dst), x64.Operand.mem(255, 0) });
    const disp_off = p.cbuf.bytes.items.len - 4;
    const label_id = try allocLabelId(p, "str_{d}", .{string_idx});
    try p.cbuf.fixups.append(.{ .offset = disp_off, .disp_size = 4, .label_id = label_id });
}

fn emitRipLeaWide(p: *PendingOutput, dst: i16, wstring_idx: u32) !void {
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(dst), x64.Operand.mem(255, 0) });
    const disp_off = p.cbuf.bytes.items.len - 4;
    const label_id = try allocLabelId(p, "wstr_{d}", .{wstring_idx});
    try p.cbuf.fixups.append(.{ .offset = disp_off, .disp_size = 4, .label_id = label_id });
}

fn emitIatCall(p: *PendingOutput, import_idx: usize) !void {
    try p.cbuf.bytes.append(0xFF); try p.cbuf.bytes.append(0x15);
    const fixoff = p.cbuf.bytes.items.len;
    try p.cbuf.bytes.appendNTimes(0, 4);
    const label_id = try allocLabelId(p, "iat_{d}", .{import_idx});
    try p.cbuf.fixups.append(.{ .offset = fixoff, .disp_size = 4, .label_id = label_id });
}

fn emitRipLeaIat(p: *PendingOutput, dst: i16, import_idx: usize) !void {
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM_RIP, &.{ x64.Operand.r(dst), x64.Operand.mem(255, 0) });
    const disp_off = p.cbuf.bytes.items.len - 4;
    const label_id = try allocLabelId(p, "iat_{d}", .{import_idx});
    try p.cbuf.fixups.append(.{ .offset = disp_off, .disp_size = 4, .label_id = label_id });
}

fn emitCallIndirect(p: *PendingOutput, args_str: []const u8, current_state: []const u8) anyerror!void {
    var args = std.ArrayList([]const u8).init(p.allocator);
    defer args.deinit();
    {
        var depth: u32 = 0;
        var start: usize = 0;
        for (args_str, 0..) |c, i| {
            switch (c) {
                '(' => depth += 1,
                ')' => { if (depth > 0) depth -= 1; },
                ',' => {
                    if (depth == 0) {
                        const arg = std.mem.trim(u8, args_str[start..i], " \t");
                        if (arg.len > 0) try args.append(arg);
                        start = i + 1;
                    }
                },
                else => {},
            }
        }
        const last = std.mem.trim(u8, args_str[start..], " \t");
        if (last.len > 0) try args.append(last);
    }
    if (args.items.len == 0) return;

    const fn_expr = args.items[0];
    const call_args = args.items[1..];
    const num_args = call_args.len;

    // Stack needed: shadow space (0x20) + stack args beyond 4
    const extra_stack: i32 = if (num_args > 4) @as(i32, @intCast((num_args - 4) * 8)) else 0;
    const total_alloc: i32 = 0x20 + extra_stack;
    try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(@as(u32, @intCast(total_alloc))) });

    // Save fn ptr to temp at bottom of allocated space
    try emitExprToRAX(p, fn_expr, current_state);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 0), x64.Operand.r(Reg.RAX) });

    // Set up first 4 args in registers
    const regs = [_]i16{ Reg.RCX, Reg.RDX, Reg.R8, Reg.R9 };
    const max_reg_args = @min(num_args, 4);
    for (0..max_reg_args) |i| {
        try emitExprToRAX(p, call_args[i], current_state);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(regs[i]), x64.Operand.r(Reg.RAX) });
    }

    // Place remaining args on the stack (above shadow space)
    if (num_args > 4) {
        for (4..num_args) |i| {
            const stack_off: i32 = 0x20 + @as(i32, @intCast(i - 4)) * 8;
            try emitExprToRAX(p, call_args[i], current_state);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, stack_off), x64.Operand.r(Reg.RAX) });
        }
    }

    // Load fn ptr from temp and call
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RSP, 0) });
    try x64.emit(&p.cbuf.bytes, .CALL_R64, &.{x64.Operand.r(Reg.RAX)});

    // Restore stack
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(@as(u32, @intCast(total_alloc))) });
}

fn emitArgToRAX(p: *PendingOutput, arg: []const u8, current_state: []const u8) anyerror!void {
    if (std.mem.startsWith(u8, arg, "call_indirect(") and std.mem.endsWith(u8, arg, ")")) {
        const inner = arg["call_indirect(".len..arg.len - 1];
        try emitCallIndirect(p, inner, current_state);
    } else {
        try emitExprToRAX(p, arg, current_state);
    }
}

fn emitComCall(p: *PendingOutput, obj_expr: []const u8, method_name: []const u8, args_str: []const u8, current_state: []const u8) !void {
    // Look up method slot
    var slot: u8 = 0;
    var found = false;
    for (COM_METHODS) |m| {
        if (std.mem.eql(u8, m.name, method_name)) {
            slot = m.slot;
            found = true;
            break;
        }
    }
    if (!found) return;

    // Parse args
    var args = std.ArrayList([]const u8).init(p.allocator);
    defer args.deinit();
    {
        var depth: u32 = 0;
        var start: usize = 0;
        const s = args_str;
        for (s, 0..) |c, i| {
            switch (c) {
                '(' => depth += 1,
                ')' => { if (depth > 0) depth -= 1; },
                ',' => {
                    if (depth == 0) {
                        const arg = std.mem.trim(u8, s[start..i], " \t");
                        if (arg.len > 0) try args.append(arg);
                        start = i + 1;
                    }
                },
                else => {},
            }
        }
        const last = std.mem.trim(u8, s[start..], " \t");
        if (last.len > 0) try args.append(last);
    }

    // RCX = this, RDX/R8/R9 for next 3 args, then stack
    const num_args = args.items.len;
    const extra_stack: i32 = if (num_args > 3) @as(i32, @intCast((num_args - 3) * 8)) else 0;
    const total_alloc: i32 = 0x20 + extra_stack;
    try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(@as(u32, @intCast(total_alloc))) });

    // Evaluate obj ptr into RCX (this)
    try emitExprToRAX(p, obj_expr, current_state);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });

    // Load vtable ptr, then method ptr
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RCX, 0) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RAX, @as(i32, @intCast(slot)) * 8) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 0), x64.Operand.r(Reg.RAX) });

    // Evaluate args into RDX, R8, R9 (skipping RCX which holds this)
    const regs = [_]i16{ Reg.RDX, Reg.R8, Reg.R9 };
    const max_reg_args = @min(num_args, 3);
    for (0..max_reg_args) |i| {
        try emitExprToRAX(p, args.items[i], current_state);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(regs[i]), x64.Operand.r(Reg.RAX) });
    }

    // Place remaining args on the stack (above shadow space)
    if (num_args > 3) {
        for (3..num_args) |i| {
            const stack_off: i32 = 0x20 + @as(i32, @intCast(i - 3)) * 8;
            try emitExprToRAX(p, args.items[i], current_state);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, stack_off), x64.Operand.r(Reg.RAX) });
        }
    }

    // Restore method ptr and call
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RSP, 0) });
    try x64.emit(&p.cbuf.bytes, .CALL_R64, &.{x64.Operand.r(Reg.RAX)});

    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(@as(u32, @intCast(total_alloc))) });
}

fn isComCallExpr(body: []const u8) bool {
    const sep = std.mem.indexOfScalar(u8, body, '.') orelse std.mem.indexOf(u8, body, "->");
    const paren_open = std.mem.indexOfScalar(u8, body, '(');
    if (sep) |si| {
        if (paren_open) |po| {
            if (si > 0 and po > si + 1) {
                const paren_close = std.mem.lastIndexOfScalar(u8, body, ')');
                if (paren_close == body.len - 1) return true;
            }
        }
    }
    return false;
}

fn parseComCall(body: []const u8) !struct { obj: []const u8, method: []const u8, args: []const u8 } {
    const arrow = std.mem.indexOf(u8, body, "->");
    const dot_idx = if (arrow) |_| arrow.? else std.mem.indexOfScalar(u8, body, '.') orelse return error.InvalidComCall;
    const sep_len: usize = if (arrow != null) 2 else 1;
    const paren_open = std.mem.indexOfScalar(u8, body, '(') orelse return error.InvalidComCall;
    const paren_close = std.mem.lastIndexOfScalar(u8, body, ')') orelse return error.InvalidComCall;
    return .{
        .obj = std.mem.trim(u8, body[0..dot_idx], " \t"),
        .method = std.mem.trim(u8, body[dot_idx + sep_len .. paren_open], " \t"),
        .args = std.mem.trim(u8, body[paren_open + 1 .. paren_close], " \t"),
    };
}

fn emitRipRelativeStore64(p: *PendingOutput, reg: i16, label_id: u32) !void {
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(255, 0), x64.Operand.r(reg) });
    const disp_off = p.cbuf.bytes.items.len - 4;
    try p.cbuf.fixups.append(.{ .offset = disp_off, .disp_size = 4, .label_id = label_id });
}

fn emitRipRelativeStore32(p: *PendingOutput, reg: i16, label_id: u32) !void {
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(255, 0), x64.Operand.r(reg) });
    const disp_off = p.cbuf.bytes.items.len - 4;
    try p.cbuf.fixups.append(.{ .offset = disp_off, .disp_size = 4, .label_id = label_id });
}

fn emitRipRelativeLoad64(p: *PendingOutput, reg: i16, label_id: u32) !void {
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(reg), x64.Operand.mem(255, 0) });
    const disp_off = p.cbuf.bytes.items.len - 4;
    try p.cbuf.fixups.append(.{ .offset = disp_off, .disp_size = 4, .label_id = label_id });
}

fn emitRipRelativeLoad32(p: *PendingOutput, reg: i16, label_id: u32) !void {
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(reg), x64.Operand.mem(255, 0) });
    const disp_off = p.cbuf.bytes.items.len - 4;
    try p.cbuf.fixups.append(.{ .offset = disp_off, .disp_size = 4, .label_id = label_id });
}

fn emitCmpEdxImm(p: *PendingOutput, imm: u8) !void {
    try p.cbuf.bytes.append(0x83);
    try p.cbuf.bytes.append(0xFA);
    try p.cbuf.bytes.append(imm);
}

fn emitJeRel32(p: *PendingOutput, label_id: u32) !void {
    try p.cbuf.bytes.append(0x0F);
    try p.cbuf.bytes.append(0x84);
    const fixoff = p.cbuf.bytes.items.len;
    try p.cbuf.bytes.appendNTimes(0, 4);
    try p.cbuf.fixups.append(.{ .offset = fixoff, .disp_size = 4, .label_id = label_id });
}

fn emitJneRel32(p: *PendingOutput, label_id: u32) !void {
    try p.cbuf.bytes.append(0x0F);
    try p.cbuf.bytes.append(0x85);
    const fixoff = p.cbuf.bytes.items.len;
    try p.cbuf.bytes.appendNTimes(0, 4);
    try p.cbuf.fixups.append(.{ .offset = fixoff, .disp_size = 4, .label_id = label_id });
}

fn emitJmpRel32(p: *PendingOutput, label_id: u32) !void {
    try p.cbuf.bytes.append(0xE9);
    const fixoff = p.cbuf.bytes.items.len;
    try p.cbuf.bytes.appendNTimes(0, 4);
    try p.cbuf.fixups.append(.{ .offset = fixoff, .disp_size = 4, .label_id = label_id });
}

fn emitWin32Call(p: *PendingOutput, import_idx: usize, args: []const abi.CallArg) !void {
    try abi.emitCallArgs(&p.cbuf.bytes, args);
    try emitIatCall(p, import_idx);
    try abi.emitCallCleanup(&p.cbuf.bytes);
}

fn emitXorReg(p: *PendingOutput, reg: i16) !void {
    if (reg >= 8) try p.cbuf.bytes.append(0x45);
    try p.cbuf.bytes.append(0x33);
    try p.cbuf.bytes.append(@as(u8, @intCast(0xC0 + (reg & 7) * 9)));
}

fn emitInc(p: *PendingOutput, reg: i16) !void {
    try p.cbuf.bytes.append(@as(u8, @intCast(0x48 + ((reg >> 3) & 1))));
    try p.cbuf.bytes.append(0xFF);
    try p.cbuf.bytes.append(@as(u8, @intCast(0xC0 + (reg & 7))));
}

fn emitDec(p: *PendingOutput, reg: i16) !void {
    try p.cbuf.bytes.append(@as(u8, @intCast(0x48 + ((reg >> 3) & 1))));
    try p.cbuf.bytes.append(0xFF);
    try p.cbuf.bytes.append(@as(u8, @intCast(0xC8 + (reg & 7))));
}

fn emitMovRegImm32(p: *PendingOutput, reg: i16, imm: u32) !void {
    try x64.emit(&p.cbuf.bytes, .MOV_R64_IMM64, &.{ x64.Operand.r(reg), x64.Operand.imm(@as(i64, @intCast(imm))) });
}

fn emitLoadImm(p: *PendingOutput, reg: i16, val: i64) !void {
    if (val == 0) {
        try emitXorReg(p, reg);
    } else if (val > 0 and val <= std.math.maxInt(i32)) {
        try emitMovRegImm32(p, reg, @intCast(val));
    } else {
        try x64.emit(&p.cbuf.bytes, .MOV_R64_IMM64, &.{ x64.Operand.r(reg), x64.Operand.imm(val) });
    }
}

fn emitNop(p: *PendingOutput, count: usize) !void {
    var remaining = count;
    while (remaining >= 9) { try p.cbuf.bytes.appendSlice(&[_]u8{ 0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 }); remaining -= 9; }
    while (remaining >= 8) { try p.cbuf.bytes.appendSlice(&[_]u8{ 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 }); remaining -= 8; }
    while (remaining >= 7) { try p.cbuf.bytes.appendSlice(&[_]u8{ 0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00 }); remaining -= 7; }
    while (remaining >= 6) { try p.cbuf.bytes.appendSlice(&[_]u8{ 0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00 }); remaining -= 6; }
    while (remaining >= 5) { try p.cbuf.bytes.appendSlice(&[_]u8{ 0x0F, 0x1F, 0x44, 0x00, 0x00 }); remaining -= 5; }
    while (remaining >= 4) { try p.cbuf.bytes.appendSlice(&[_]u8{ 0x0F, 0x1F, 0x40, 0x00 }); remaining -= 4; }
    while (remaining >= 3) { try p.cbuf.bytes.appendSlice(&[_]u8{ 0x0F, 0x1F, 0x00 }); remaining -= 3; }
    while (remaining >= 2) { try p.cbuf.bytes.appendSlice(&[_]u8{ 0x66, 0x90 }); remaining -= 2; }
    while (remaining >= 1) { try p.cbuf.bytes.append(0x90); remaining -= 1; }
}

fn emitTierMove(p: *PendingOutput, skip: u32, panic: u32, comptime prefix: []const u8, delta: i8) !void {
    const l1 = try allocLabelId(p, "{s}_l1", .{prefix});
    const l2 = try allocLabelId(p, "{s}_l2", .{prefix});
    const done = try allocLabelId(p, "{s}_ad", .{prefix});
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RCX), x64.Operand.immU32(64) });
    try emitCondLongJmp(p, .JAE_REL32, skip);
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_states) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(1) });
    try emitCondLongJmp(p, .JNE_REL32, skip);
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_generations) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
    try x64.emit(&p.cbuf.bytes, .CMP_R32_R32, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
    try emitCondLongJmp(p, .JNE_REL32, skip);
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_tiers) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.R11, 0) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R15), x64.Operand.r(Reg.R10) });
    if (delta < 0) {
        try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
        try emitCondLongJmp(p, .JE_REL32, skip);
        try emitDec(p, Reg.R10);
    } else {
        try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
        try emitCondLongJmp(p, .JAE_REL32, skip);
        try emitInc(p, Reg.R10);
    }
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(3) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RSI), x64.Operand.mem(Reg.R11, 0) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_sizes) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(2) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RDX), x64.Operand.mem(Reg.R11, 0) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R12), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R9), x64.Operand.immU32(0) });
    try emitCondLongJmp(p, .JE_REL32, l1);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R9), x64.Operand.immU32(1) });
    try emitCondLongJmp(p, .JE_REL32, l2);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_pool_head) });
    try x64.emit(&p.cbuf.bytes, .TEST_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, panic);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RAX, 0) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_pool_head), x64.Operand.r(Reg.R11) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 8), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RAX, 12), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RDI), x64.Operand.mem(Reg.RAX, 16) });
    try emitShortJmp(p, .JMP_REL32, done);
    try setLabel(p, l2);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_l2_ptr) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_l2_end) });
    try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.R11) });
    try emitCondLongJmp(p, .JA_REL32, panic);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l2_ptr), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RCX) });
    try emitShortJmp(p, .JMP_REL32, done);
    try setLabel(p, l1);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_l1_ptr) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_l1_end) });
    try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.R11) });
    try emitCondLongJmp(p, .JA_REL32, panic);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_l1_ptr), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RCX) });
    const try_decomp = try allocLabelId(p, "{s}_td", .{prefix});
    const plain = try allocLabelId(p, "{s}_pl", .{prefix});
    const after_copy = try allocLabelId(p, "{s}_ac", .{prefix});
    try setLabel(p, done);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.R12) });
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R9), x64.Operand.immU32(2) });
    try emitCondLongJmp(p, .JNE_REL32, try_decomp);
    try emitCallToLabel(p, try allocLabelId(p, "l3_compress", .{}));
    try emitShortJmp(p, .JMP_REL32, after_copy);
    try setLabel(p, try_decomp);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.R15), x64.Operand.immU32(2) });
    try emitCondLongJmp(p, .JNE_REL32, plain);
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.RSI, -4) });
    try x64.emit(&p.cbuf.bytes, .SHIFT_RIGHT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(31) });
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R10) });
    try emitCondLongJmp(p, .JE_REL32, plain);
    try emitCallToLabel(p, try allocLabelId(p, "l3_decompress", .{}));
    try emitShortJmp(p, .JMP_REL32, after_copy);
    try setLabel(p, plain);
    try p.cbuf.bytes.append(0xF3); try p.cbuf.bytes.append(0xA4);
    try setLabel(p, after_copy);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDI) });
    try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.R12) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_ptrs) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(3) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RBP, p.off_ht_tiers) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(Reg.R11, 0), x64.Operand.r(Reg.R9) });
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
    try x64.emit(&p.cbuf.bytes, .CMP_R32_R32, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.RCX) });
    try emitCondLongJmp(p, .JAE_REL32, cl_done);
    try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.memIdx(Reg.RSI, Reg.R8, 1, 0) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.cbuf.bytes, .XOR_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.memIdx(Reg.RDI, Reg.R8, 1, 0), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RAX) });
    try emitCondLongJmp(p, .JE_REL32, cl_skip);
    try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.R8, 1) });
    try setLabel(p, cl_skip);
    try emitInc(p, Reg.R8);
    try emitShortJmp(p, .JMP_REL32, cl_loop);
    try setLabel(p, cl_done);
    try x64.emit(&p.cbuf.bytes, .TEST_R32_R32, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.R9) });
    try emitCondLongJmp(p, .JNE_REL32, cl_chk);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.RCX) });
    try setLabel(p, cl_chk);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_R32, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.RCX) });
    try emitCondLongJmp(p, .JE_REL32, cl_store);
    try emitLoadImm(p, Reg.R10, 0x80000000);
    try x64.emit(&p.cbuf.bytes, .OR_R64_R64, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.R10) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RDI, -4), x64.Operand.r(Reg.R9) });
    try setLabel(p, cl_store);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RSI), x64.Operand.r(Reg.RCX) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.RCX) });
    try emitRet(p);

    const dl_loop = try allocLabelId(p, "dl_loop", .{});
    const dl_zf = try allocLabelId(p, "dl_zf", .{});
    const dl_zloop = try allocLabelId(p, "dl_zloop", .{});
    const dl_done = try allocLabelId(p, "dl_done", .{});
    try setLabel(p, try allocLabelId(p, "l3_decompress", .{}));
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.RSI, -4) });
    try emitLoadImm(p, Reg.RDX, 0x7FFFFFFF);
    try x64.emit(&p.cbuf.bytes, .AND_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.RSI, -8) });
    try emitXorReg(p, Reg.R8);
    try setLabel(p, dl_loop);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_R32, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.R10) });
    try emitCondLongJmp(p, .JAE_REL32, dl_zf);
    try x64.emit(&p.cbuf.bytes, .MOVZX_R64_MEM8, &.{ x64.Operand.r(Reg.RAX), x64.Operand.memIdx(Reg.RSI, Reg.R8, 1, 0) });
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
    try x64.emit(&p.cbuf.bytes, .XOR_R32_R32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RDX) });
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.memIdx(Reg.RDI, Reg.R8, 1, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.R8);
    try emitShortJmp(p, .JMP_REL32, dl_loop);
    try setLabel(p, dl_zf);
    try emitXorReg(p, Reg.RAX);
    try setLabel(p, dl_zloop);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_R32, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.R11) });
    try emitCondLongJmp(p, .JAE_REL32, dl_done);
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.memIdx(Reg.RDI, Reg.R8, 1, 0), x64.Operand.r(Reg.RAX) });
    try emitInc(p, Reg.R8);
    try emitShortJmp(p, .JMP_REL32, dl_zloop);
    try setLabel(p, dl_done);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RSI), x64.Operand.r(Reg.R11) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDI), x64.Operand.r(Reg.R11) });
    try emitRet(p);
}

fn alignTo64(p: *PendingOutput) !void {
    const mod = p.cbuf.bytes.items.len % 64;
    if (mod != 0) try emitNop(p, 64 - mod);
}

fn alignTo16(p: *PendingOutput) !void {
    const mod = p.cbuf.bytes.items.len % 16;
    if (mod != 0) try emitNop(p, 16 - mod);
}

fn emitPrefetchData(p: *PendingOutput, offset: i32, level: i32, base_reg: i16) !void {
    try p.cbuf.bytes.append(0x0F); try p.cbuf.bytes.append(0x18);
    var reg: u8 = 3;
    if (level == 0) { reg = 0; } else if (level == 1) { reg = 1; } else if (level == 2) { reg = 2; }
    if (base_reg >= 8) {
        try p.cbuf.bytes.append(0x41);
    }
    const rm_low = @as(u8, @intCast(base_reg & 0x7));
    if (offset >= -128 and offset <= 127) {
        try p.cbuf.bytes.append(0x40 | (reg << 3) | rm_low);
        try p.cbuf.bytes.append(@as(u8, @bitCast(@as(i8, @intCast(offset)))));
    } else {
        try p.cbuf.bytes.append(0x80 | (reg << 3) | rm_low);
        try p.cbuf.bytes.appendSlice(&@as([4]u8, @bitCast(offset)));
    }
}

fn emitPrefetch(p: *PendingOutput, label_id: u32) !void {
    try x64.emit(&p.cbuf.bytes, .PREFETCHT0_RIPREL, &.{x64.Operand.imm(0)});
    try p.cbuf.fixups.append(.{ .offset = p.cbuf.bytes.items.len - 4, .disp_size = 4, .label_id = label_id });
}

fn emitPrefetchColdData(p: *PendingOutput, state: *const ast.StateDefNode) !void {
    if ((state.hot_weight orelse 0.5) > 0.3) return;
    if (p.state_vars.get(state.name)) |vars| { for (vars.items) |sv| try emitPrefetchData(p, @as(i32, @intCast(sv.layout_offset)), 0, p.state_base_reg); }
}

fn emitPrefetchForTransitionCacheAware(p: *PendingOutput, t: *const ast.TransitionNode) !void {
    const hw = t.hot_weight orelse 0.5;
    const level: i32 = if (hw >= 0.8) 1 else if (hw >= 0.4) 2 else 0;
    const ti = p.state_index_map.get(t.target) orelse return error.UndefinedStateTarget;
    if (p.state_vars.get(t.target)) |vars| { for (vars.items) |sv| try emitPrefetchData(p, @as(i32, @intCast(sv.layout_offset)), level, p.state_base_reg); }
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

fn utf8ToUtf16Le(allocator: std.mem.Allocator, utf8: []const u8) ![]u16 {
    std.debug.print("  utf8ToUtf16Le: len={d}\n", .{utf8.len});
    var result = std.ArrayList(u16).init(allocator);
    errdefer result.deinit();
    var i: usize = 0;
    while (i < utf8.len) {
        const seq_len = try std.unicode.utf8ByteSequenceLength(utf8[i]);
        const cp = try std.unicode.utf8Decode(utf8[i..i+seq_len]);
        i += seq_len;
        if (cp >= 0x10000) {
            const cp2 = cp - 0x10000;
            try result.append(@as(u16, @intCast(0xD800 | (cp2 >> 10))));
            try result.append(@as(u16, @intCast(0xDC00 | (cp2 & 0x3FF))));
        } else {
            try result.append(@as(u16, @intCast(cp)));
        }
    }
    try result.append(0);
    return result.toOwnedSlice();
}

fn addPoolWString(p: *PendingOutput, str: []const u8) !u32 {
    const get_result = p.wstring_pool.get(str);
    if (get_result) |idx| return @intCast(idx);
    const wstr = try utf8ToUtf16Le(p.allocator, str);
    const idx = p.wstring_list.items.len;
    try p.wstring_list.append(wstr);
    try p.wstring_pool.put(str, idx);
    return @intCast(idx);
}

fn findMatching(src: []const u8, start: usize, open: u8, close: u8) usize {
    var depth: u32 = 1;
    var i = start + 1;
    while (i < src.len and depth > 0) : (i += 1) {
        if (src[i] == open) depth += 1;
        if (src[i] == close) depth -= 1;
    }
    return i - 1;
}

fn pushDeferScope(p: *PendingOutput) !void {
    try p.defer_scopes.append(std.ArrayList([]const u8).init(p.allocator));
}

fn popDeferScope(p: *PendingOutput) !void {
    if (p.defer_scopes.items.len == 0) return;
    var scope = p.defer_scopes.pop().?;
    var i: usize = scope.items.len;
    while (i > 0) {
        i -= 1;
        try emitAction(p, scope.items[i], "");
    }
    scope.deinit();
}

fn emitAllDeferScopes(p: *PendingOutput) !void {
    var si: usize = 0;
    while (si < p.defer_scopes.items.len) {
        const scope = &p.defer_scopes.items[si];
        var j: usize = scope.items.len;
        while (j > 0) {
            j -= 1;
            try emitAction(p, scope.items[j], "");
        }
        si += 1;
    }
}

fn emitIfElse(p: *PendingOutput, cond: []const u8, then_body: []const u8, else_body: []const u8, current_state: []const u8) !void {
    const else_lbl = try allocLabelId(p, "if_else_{d}", .{p.cbuf.label_names.items.len});
    const merge_lbl = try allocLabelId(p, "if_merge_{d}", .{p.cbuf.label_names.items.len});

    try emitCondCheckToLabel(p, cond, else_lbl, current_state);
    try pushDeferScope(p);
    try emitAction(p, then_body, current_state);
    try popDeferScope(p);
    try emitLongJmp(p, merge_lbl);
    try setLabel(p, else_lbl);
    if (else_body.len > 0) {
        try pushDeferScope(p);
        try emitAction(p, else_body, current_state);
        try popDeferScope(p);
    }
    try setLabel(p, merge_lbl);
}

fn emitCmpR64ImmOrVar(p: *PendingOutput, rhs: []const u8, current_state: []const u8) !void {
    if (try tryLoadVarToReg(p, Reg.RBX, rhs, current_state)) {
        try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
    } else if (p.enum_defs.get(rhs)) |val| {
        try x64.emit(&p.cbuf.bytes, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(val) });
    } else {
        const val = parseNumber(rhs);
        try x64.emit(&p.cbuf.bytes, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(val) });
    }
}

fn emitForLoop(p: *PendingOutput, w: u32, h: u32, body: []const u8, current_state: []const u8) !void {
    const header_lbl = try allocLabelId(p, "for_hdr_{d}", .{p.cbuf.label_names.items.len});
    const end_lbl = try allocLabelId(p, "for_end_{d}", .{p.cbuf.label_names.items.len});

    try emitLoadImm(p, Reg.RAX, 0);
    try emitStoreVarFromReg(p, p.off_for_loop_x, Reg.RAX, 4, Reg.RBP);
    try emitStoreVarFromReg(p, p.off_for_loop_y, Reg.RAX, 4, Reg.RBP);

    try setLabel(p, header_lbl);
    try emitLoadVarToReg(p, Reg.RAX, p.off_for_loop_y, 4, Reg.RBP);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(h) });
    try emitCondLongJmp(p, .JGE_REL32, end_lbl);

    try p.break_labels.append(end_lbl);
    try p.continue_labels.append(header_lbl);
    try pushDeferScope(p);

    {
        const saved = p.in_for_loop;
        p.in_for_loop = true;
        try emitAction(p, body, current_state);
        p.in_for_loop = saved;
    }

    try popDeferScope(p);
    _ = p.break_labels.pop();
    _ = p.continue_labels.pop();

    try emitLoadVarToReg(p, Reg.RAX, p.off_for_loop_x, 4, Reg.RBP);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(1) });
    try emitStoreVarFromReg(p, p.off_for_loop_x, Reg.RAX, 4, Reg.RBP);
    try x64.emit(&p.cbuf.bytes, .CMP_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(w) });
    try emitCondLongJmp(p, .JL_REL32, header_lbl);

    try emitLoadImm(p, Reg.RAX, 0);
    try emitStoreVarFromReg(p, p.off_for_loop_x, Reg.RAX, 4, Reg.RBP);
    try emitLoadVarToReg(p, Reg.RAX, p.off_for_loop_y, 4, Reg.RBP);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(1) });
    try emitStoreVarFromReg(p, p.off_for_loop_y, Reg.RAX, 4, Reg.RBP);
    try emitLongJmp(p, header_lbl);
    try setLabel(p, end_lbl);
}

fn emitMatch(p: *PendingOutput, expr: []const u8, body: []const u8, current_state: []const u8) !void {
    const merge_lbl = try allocLabelId(p, "match_merge_{d}", .{p.cbuf.label_names.items.len});

    try emitExprToRAX(p, expr, current_state);
    try x64.emit(&p.cbuf.bytes, .PUSH_R64, &.{ x64.Operand.r(Reg.RAX) });

    var arm_labels = std.ArrayList(u32).init(p.allocator);
    defer arm_labels.deinit();

    var arms = std.ArrayList(MatchArm).init(p.allocator);
    defer arms.deinit();
    try parseMatchArms(body, &arms);

    for (arms.items, 0..) |arm, idx| {
        if (idx > 0) try setLabel(p, arm_labels.items[idx - 1]);
        if (arm.pattern.len == 1 and arm.pattern[0] == '_') {
            // wildcard arm: no comparison needed
        } else {
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RSP, 0) });
            const pval = resolveMatchPattern(p, arm.pattern);
            try x64.emit(&p.cbuf.bytes, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(@intCast(pval)) });
            if (idx < arms.items.len - 1) {
                const next_arm_lbl = try allocLabelId(p, "match_arm_{d}", .{p.cbuf.label_names.items.len});
                try arm_labels.append(next_arm_lbl);
                try emitCondLongJmp(p, .JNE_REL32, next_arm_lbl);
            } else {
                try emitCondLongJmp(p, .JNE_REL32, merge_lbl);
            }
        }
        try pushDeferScope(p);
        try emitAction(p, arm.body, current_state);
        try popDeferScope(p);
        try emitLongJmp(p, merge_lbl);
    }

    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(8) });
    try setLabel(p, merge_lbl);
}

fn resolveMatchPattern(p: *PendingOutput, pattern: []const u8) i64 {
    if (std.mem.indexOfScalar(u8, pattern, '.')) |_| {
        const trimmed = std.mem.trim(u8, pattern, " \t");
        if (p.enum_defs.get(trimmed)) |val| return val;
    }
    return parseNumber(pattern);
}

const MatchArm = struct {
    pattern: []const u8,
    body: []const u8,
};

fn parseMatchArms(body: []const u8, arms: *std.ArrayList(MatchArm)) !void {
    var start: usize = 0;
    var i: usize = 0;
    var depth: u32 = 0;
    while (i < body.len) : (i += 1) {
        switch (body[i]) {
            '{' => depth += 1,
            '}' => { if (depth > 0) depth -= 1; },
            ';' => {
                if (depth == 0) {
                    const arm_text = std.mem.trim(u8, body[start..i], " \t\r\n");
                    if (arm_text.len > 0) try addMatchArm(arm_text, arms);
                    start = i + 1;
                }
            },
            else => {},
        }
    }
    const last = std.mem.trim(u8, body[start..], " \t\r\n");
    if (last.len > 0) try addMatchArm(last, arms);
}

fn addMatchArm(arm_text: []const u8, arms: *std.ArrayList(MatchArm)) !void {
    const arrow = std.mem.indexOf(u8, arm_text, "=>") orelse return;
    const pattern = std.mem.trim(u8, arm_text[0..arrow], " \t\r\n");
    const after_arrow = std.mem.trimLeft(u8, arm_text[arrow + 2 ..], " \t\r\n");
    var body: []const u8 = undefined;
    if (after_arrow.len > 0 and after_arrow[0] == '{') {
        const body_end = findMatching(after_arrow, 0, '{', '}');
        body = after_arrow[1..body_end];
    } else {
        body = after_arrow;
    }
    try arms.append(.{ .pattern = pattern, .body = body });
}

fn emitForRangeLoop(p: *PendingOutput, var_name: []const u8, start_str: []const u8, end_str: []const u8, body: []const u8, current_state: []const u8) !void {
    const header_lbl = try allocLabelId(p, "for_hdr_{d}", .{p.cbuf.label_names.items.len});
    const end_lbl = try allocLabelId(p, "for_end_{d}", .{p.cbuf.label_names.items.len});

    try emitExprToRAX(p, start_str, current_state);
    try emitStoreVarFromReg(p, p.off_for_range_counter, Reg.RAX, 8, Reg.RBP);

    try setLabel(p, header_lbl);
    try emitLoadVarToReg(p, Reg.RAX, p.off_for_range_counter, 8, Reg.RBP);
    try emitCmpR64ImmOrVar(p, end_str, current_state);
    try emitCondLongJmp(p, .JGE_REL32, end_lbl);

    try p.break_labels.append(end_lbl);
    try p.continue_labels.append(header_lbl);
    try pushDeferScope(p);

    {
        const saved_name = p.for_range_var_name;
        const saved_flag = p.in_for_range;
        p.for_range_var_name = var_name;
        p.in_for_range = true;
        try emitAction(p, body, current_state);
        p.for_range_var_name = saved_name;
        p.in_for_range = saved_flag;
    }

    try popDeferScope(p);
    _ = p.break_labels.pop();
    _ = p.continue_labels.pop();

    try emitLoadVarToReg(p, Reg.RAX, p.off_for_range_counter, 8, Reg.RBP);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(1) });
    try emitStoreVarFromReg(p, p.off_for_range_counter, Reg.RAX, 8, Reg.RBP);
    try emitLongJmp(p, header_lbl);

    try setLabel(p, end_lbl);
}

fn emitWhileLoop(p: *PendingOutput, cond: []const u8, body: []const u8, current_state: []const u8) !void {
    const header_lbl = try allocLabelId(p, "while_hdr_{d}", .{p.cbuf.label_names.items.len});
    const end_lbl = try allocLabelId(p, "while_end_{d}", .{p.cbuf.label_names.items.len});

    try setLabel(p, header_lbl);

    try p.break_labels.append(end_lbl);
    try p.continue_labels.append(header_lbl);
    try pushDeferScope(p);

    try emitCondCheckToLabel(p, cond, end_lbl, current_state);
    try emitAction(p, body, current_state);
    try popDeferScope(p);
    _ = p.break_labels.pop();
    _ = p.continue_labels.pop();

    try emitLongJmp(p, header_lbl);
    try setLabel(p, end_lbl);
}

fn emitReturn(p: *PendingOutput, rv: RetValue) !void {
    switch (rv) {
        .float => |x| {
            if (x != XMM.XMM0) {
                try x64.emit(&p.cbuf.bytes, .SSE_MOVAPS_LD, &.{ x64.Operand.xmm(XMM.XMM0), x64.Operand.xmm(x) });
            }
            try x64.emit(&p.cbuf.bytes, .SSE_MOVD_ST, &.{ x64.Operand.r(Reg.RAX), x64.Operand.xmm(XMM.XMM0) });
        },
        .int => |reg| {
            if (reg != Reg.RAX) {
                try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(reg) });
            }
        },
        .imm_int => |val| {
            try x64.emit(&p.cbuf.bytes, .MOV_R64_IMM64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(val) });
        },
    }
}

fn emitAction(p: *PendingOutput, body: []const u8, current_state: []const u8) anyerror!void {
    if (body.len == 0) return;
    var start: usize = 0;
    var i: usize = 0;
    var depth: u32 = 0;
    while (i < body.len) : (i += 1) {
        switch (body[i]) {
            '{' => depth += 1,
            '}' => {
                if (depth > 0) depth -= 1;
            },
            ';' => {
                if (depth == 0) {
                    const s = std.mem.trim(u8, body[start..i], " \t\r\n");
                    if (s.len > 0) try emitSingleAction(p, s, current_state);
                    start = i + 1;
                }
            },
            else => {},
        }
    }
    const s = std.mem.trim(u8, body[start..], " \t\r\n");
    if (s.len > 0) try emitSingleAction(p, s, current_state);
}

fn emitSingleAction(p: *PendingOutput, body: []const u8, current_state: []const u8) anyerror!void {
    if (body.len == 0) return;
    const trimmed_body = std.mem.trimLeft(u8, body, " \t\r\n");

    // break
    if (std.mem.eql(u8, trimmed_body, "break")) {
        if (p.break_labels.items.len == 0) return error.BreakOutsideLoop;
        try emitLongJmp(p, p.break_labels.getLast());
        return;
    }
    // continue
    if (std.mem.eql(u8, trimmed_body, "continue")) {
        if (p.continue_labels.items.len == 0) return error.ContinueOutsideLoop;
        try emitLongJmp(p, p.continue_labels.getLast());
        return;
    }

    // defer { body }
    if (std.mem.startsWith(u8, trimmed_body, "defer") and (trimmed_body.len == 5 or trimmed_body[5] == ' ' or trimmed_body[5] == '{')) {
        const after_defer = std.mem.trimLeft(u8, trimmed_body[5..], " \t\r\n");
        if (after_defer.len > 0 and after_defer[0] == '{') {
            const body_end = findMatching(after_defer, 0, '{', '}');
            const defer_body = after_defer[1..body_end];
            if (p.defer_scopes.items.len > 0) {
                try p.defer_scopes.items[p.defer_scopes.items.len - 1].append(defer_body);
            }
        }
        return;
    }

    if (trimmed_body.len >= 2 and std.mem.eql(u8, trimmed_body[0..2], "if")) {
        const after_if = std.mem.trimLeft(u8, trimmed_body[2..], " \t\r\n");
        if (after_if.len > 0 and after_if[0] == '(') {
            const cond_close = findMatching(after_if, 0, '(', ')');
            const cond = std.mem.trim(u8, after_if[1..cond_close], " \t\r\n");
            const after_paren = std.mem.trimLeft(u8, after_if[cond_close + 1 ..], " \t\r\n");
            if (after_paren.len > 0 and after_paren[0] == '{') {
                const then_end = findMatching(after_paren, 0, '{', '}');
                const then_body = after_paren[1..then_end];
    var else_body: []const u8 = "";
    const after_then = std.mem.trimLeft(u8, after_paren[then_end + 1 ..], " \t\r\n");
    if (std.mem.startsWith(u8, after_then, "else{")) {
                    const else_end = findMatching(after_then, 4, '{', '}');
                    else_body = after_then[5..else_end];
                } else if (std.mem.startsWith(u8, after_then, "else {")) {
                    const else_end = findMatching(after_then, 5, '{', '}');
                    else_body = after_then[6..else_end];
                }
                try emitIfElse(p, cond, then_body, else_body, current_state);
            } else if (after_paren.len > 0) {
                const then_body = after_paren;
                try emitIfElse(p, cond, then_body, "", current_state);
            }
            return;
        }
    }
    if (trimmed_body.len >= 5 and std.mem.eql(u8, trimmed_body[0..5], "match")) {
        const after_match = std.mem.trimLeft(u8, trimmed_body[5..], " \t\r\n");
        if (after_match.len > 0 and after_match[0] == '(') {
            const paren_close = findMatching(after_match, 0, '(', ')');
            const match_expr = std.mem.trim(u8, after_match[1..paren_close], " \t\r\n");
            const after_paren = std.mem.trimLeft(u8, after_match[paren_close + 1 ..], " \t\r\n");
            if (after_paren.len > 0 and after_paren[0] == '{') {
                const body_end = findMatching(after_paren, 0, '{', '}');
                const match_body = after_paren[1..body_end];
                try emitMatch(p, match_expr, match_body, current_state);
            }
            return;
        }
    }
    if (trimmed_body.len >= 3 and std.mem.eql(u8, trimmed_body[0..3], "for")) {
        const after_for = std.mem.trimLeft(u8, trimmed_body[3..], " \t\r\n");
        if (after_for.len > 0 and after_for[0] == '(') {
            const close_paren = findMatching(after_for, 0, '(', ')');
            const args_str = std.mem.trim(u8, after_for[1..close_paren], " \t\r\n");
            const after_paren = std.mem.trimLeft(u8, after_for[close_paren + 1 ..], " \t\r\n");
            // Detect for-range: for(var : start..end)
            const colon_idx = std.mem.indexOfScalar(u8, args_str, ':');
            if (colon_idx != null) {
                const var_name = std.mem.trim(u8, args_str[0..colon_idx.?], " \t\r\n");
                const range_str = std.mem.trim(u8, args_str[colon_idx.? + 1 ..], " \t\r\n");
                const dotdot_idx = std.mem.indexOf(u8, range_str, "..");
                if (dotdot_idx == null) return;
                const start_str = std.mem.trim(u8, range_str[0..dotdot_idx.?], " \t\r\n");
                const end_str = std.mem.trim(u8, range_str[dotdot_idx.? + 2 ..], " \t\r\n");
                if (after_paren.len > 0 and after_paren[0] == '{') {
                    const body_end = findMatching(after_paren, 0, '{', '}');
                    const for_body = after_paren[1..body_end];
                    try emitForRangeLoop(p, var_name, start_str, end_str, for_body, current_state);
                }
            } else {
                // 2D pixel loop: for(x, y, w, h)
                var it = std.mem.splitScalar(u8, args_str, ',');
                _ = std.mem.trim(u8, it.next() orelse "x", " \t\r\n");
                _ = std.mem.trim(u8, it.next() orelse "y", " \t\r\n");
                var w: u32 = 1;
                var h: u32 = 1;
                const rest = std.mem.trimLeft(u8, it.rest(), " \t\r\n");
                if (rest.len > 0) {
                    var it2 = std.mem.splitScalar(u8, rest, ',');
                    w = std.fmt.parseInt(u32, std.mem.trim(u8, it2.next() orelse "1", " \t\r\n"), 10) catch 1;
                    h = std.fmt.parseInt(u32, std.mem.trim(u8, it2.next() orelse "1", " \t\r\n"), 10) catch 1;
                }
                if (after_paren.len > 0 and after_paren[0] == '{') {
                    const body_end = findMatching(after_paren, 0, '{', '}');
                    const for_body = after_paren[1..body_end];
                    try emitForLoop(p, w, h, for_body, current_state);
                }
            }
            return;
        }
    }
    // if (cond) { ... } else { ... } as statement
    if (trimmed_body.len >= 2 and std.mem.eql(u8, trimmed_body[0..2], "if")) {
        const after_if = std.mem.trimLeft(u8, trimmed_body[2..], " \t\r\n");
        if (after_if.len > 0 and after_if[0] == '(') {
            const cond_close = findMatching(after_if, 0, '(', ')');
            const cond = std.mem.trim(u8, after_if[1..cond_close], " \t\r\n");
            const after_cond = std.mem.trimLeft(u8, after_if[cond_close + 1 ..], " \t\r\n");
            if (after_cond.len > 0 and after_cond[0] == '{') {
                const then_end = findMatching(after_cond, 0, '{', '}');
                const then_body = after_cond[1..then_end];
                const after_then = std.mem.trimLeft(u8, after_cond[then_end + 1 ..], " \t\r\n");
                var else_body: ?[]const u8 = null;
                if (std.mem.startsWith(u8, after_then, "else{")) {
                    const else_end = findMatching(after_then, 4, '{', '}');
                    else_body = after_then[5..else_end];
                } else if (std.mem.startsWith(u8, after_then, "else {")) {
                    const else_end = findMatching(after_then, 5, '{', '}');
                    else_body = after_then[6..else_end];
                }
                if (else_body) |eb| {
                    const else_lbl = try allocLabelId(p, "if_else_{d}", .{p.cbuf.label_names.items.len});
                    const merge_lbl = try allocLabelId(p, "if_merge_{d}", .{p.cbuf.label_names.items.len});
                    try emitCondCheckToLabel(p, cond, else_lbl, current_state);
                    try emitAction(p, then_body, current_state);
                    try emitLongJmp(p, merge_lbl);
                    try setLabel(p, else_lbl);
                    try emitAction(p, eb, current_state);
                    try setLabel(p, merge_lbl);
                } else {
                    const merge_lbl = try allocLabelId(p, "if_skip_{d}", .{p.cbuf.label_names.items.len});
                    try emitCondCheckToLabel(p, cond, merge_lbl, current_state);
                    try emitAction(p, then_body, current_state);
                    try setLabel(p, merge_lbl);
                }
            }
        }
        return;
    }

    if (trimmed_body.len >= 5 and std.mem.eql(u8, trimmed_body[0..5], "while")) {
        const after_while = std.mem.trimLeft(u8, trimmed_body[5..], " \t\r\n");
        if (after_while.len > 0 and after_while[0] == '(') {
            const cond_close = findMatching(after_while, 0, '(', ')');
            const cond = std.mem.trim(u8, after_while[1..cond_close], " \t\r\n");
            const after_paren = std.mem.trimLeft(u8, after_while[cond_close + 1 ..], " \t\r\n");
            if (after_paren.len > 0 and after_paren[0] == '{') {
                const body_end = findMatching(after_paren, 0, '{', '}');
                const while_body = after_paren[1..body_end];
                try emitWhileLoop(p, cond, while_body, current_state);
            }
            return;
        }
    }
    if (std.mem.startsWith(u8, body, "create_image(") and std.mem.endsWith(u8, body, ")")) {
        const inner = body["create_image(".len..body.len - 1];
        const first_comma = std.mem.indexOfScalar(u8, inner, ',') orelse return;
        const name = std.mem.trim(u8, inner[0..first_comma], " \t");
        const rest = std.mem.trim(u8, inner[first_comma + 1 ..], " \t");
        const second_comma = std.mem.indexOfScalar(u8, rest, ',') orelse return;
        const w_str = std.mem.trim(u8, rest[0..second_comma], " \t");
        const h_str = std.mem.trim(u8, rest[second_comma + 1 ..], " \t");
        const vo = getVarOffset(p, current_state, name);
        if (vo == std.math.minInt(i32)) return;
        try emitExprToRAX(p, w_str, current_state);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R9), x64.Operand.r(Reg.RAX) });
        try emitExprToRAX(p, h_str, current_state);
        try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R9) });
        try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(2) });
        try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R12), x64.Operand.r(Reg.RAX) });
        try abi.emitCallArgs(&p.cbuf.bytes, &.{});
        try emitIatCall(p, 4);
        try abi.emitCallCleanup(&p.cbuf.bytes);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
        try emitXorReg(p, Reg.RDX);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R8), x64.Operand.r(Reg.R12) });
        try abi.emitCallArgs(&p.cbuf.bytes, &.{});
        try emitIatCall(p, 5);
        try abi.emitCallCleanup(&p.cbuf.bytes);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R12), x64.Operand.r(Reg.RAX) });
        try emitExprToRAX(p, w_str, current_state);
        try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R12, 0), x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R12, 4), x64.Operand.r(Reg.RAX) });
        try emitExprToRAX(p, h_str, current_state);
        try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.R12, 8), x64.Operand.r(Reg.RAX) });
        try emitStoreVarFromReg(p, vo, Reg.R12, 8, getVarBaseReg(p, current_state, name));
        return;
    }
    if (std.mem.startsWith(u8, body, "print(") and std.mem.endsWith(u8, body, ")")) {
        const content = std.mem.trim(u8, body["print(".len..body.len - 1], " \t\"");
        if (content.len == 0) return;
        const str_off = try addPoolString(p, content);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RBP, p.off_hstdout) });
        try emitRipLea(p, Reg.RDX, str_off);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_IMM64, &.{ x64.Operand.r(Reg.R8), x64.Operand.imm(@intCast(content.len)) });
        try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.R9), x64.Operand.mem(Reg.RBP, p.off_chars_written) });
        try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
        try emitXorReg(p, Reg.RAX);
        try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, 32), x64.Operand.r(Reg.RAX) });
        try emitIatCall(p, 1);
        try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(40) });
        return;
    }
    if (std.mem.startsWith(u8, body, "@handle_release(") and std.mem.endsWith(u8, body, ")")) {
        const handle_expr = std.mem.trim(u8, body["@handle_release(".len..body.len - 1], " \t");
        try emitExprToRAX(p, handle_expr, current_state);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.cbuf.bytes, .SHIFT_RIGHT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(32) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R10) });
        try emitIntrinsicCall(p, .handle_release);
        return;
    }
    if (std.mem.startsWith(u8, body, "free(") and std.mem.endsWith(u8, body, ")")) {
        try abi.emitCallArgs(&p.cbuf.bytes, &.{});
        try emitIatCall(p, 4);
        try abi.emitCallCleanup(&p.cbuf.bytes);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
        try emitXorReg(p, Reg.RDX);
        const ptr_name = std.mem.trim(u8, body["free(".len..body.len - 1], " \t");
        if (!try tryLoadVarToReg(p, Reg.R8, ptr_name, current_state)) try emitXorReg(p, Reg.R8);
        try abi.emitCallArgs(&p.cbuf.bytes, &.{});
        try emitIatCall(p, 6);
        try abi.emitCallCleanup(&p.cbuf.bytes);
        return;
    }
    if (std.mem.containsAtLeast(u8, body, 1, "+=")) {
        const idx = std.mem.indexOf(u8, body, "+=") orelse return;
        const var_name = std.mem.trim(u8, body[0..idx], " \t");
        const expr = std.mem.trim(u8, body[idx+2..], " \t");
        const vo = getVarOffset(p, current_state, var_name);
        if (vo != std.math.minInt(i32)) {
            const size = getVarSize(p, current_state, var_name);
            if (isFloatVar(p, current_state, var_name)) {
                const rhs_reg = try emitExprToXmm(p, expr, current_state, size);
                try emitLoadXmmToReg(p, XMM.XMM0, vo, size, getVarBaseReg(p, current_state, var_name));
                try emitSseArith(p, XMM.XMM0, rhs_reg, .SSE_ADDPS, .SSE_ADDSS, size);
                freeXmm(p, rhs_reg);
                try emitStoreXmmFromReg(p, vo, XMM.XMM0, size, getVarBaseReg(p, current_state, var_name));
                p.pending_ret = RetValue{ .float = XMM.XMM0 };
            } else {
                try emitLoadVarToReg(p, Reg.RAX, vo, size, getVarBaseReg(p, current_state, var_name));
                try emitExprToRAXAdd(p, expr, current_state);
                try emitStoreVarFromReg(p, vo, Reg.RAX, size, getVarBaseReg(p, current_state, var_name));
                p.pending_ret = RetValue{ .int = Reg.RAX };
            }
            return;
        }
    }
    if (std.mem.containsAtLeast(u8, body, 1, "-=")) {
        const idx = std.mem.indexOf(u8, body, "-=") orelse return;
        const var_name = std.mem.trim(u8, body[0..idx], " \t");
        const expr = std.mem.trim(u8, body[idx+2..], " \t");
        const vo = getVarOffset(p, current_state, var_name);
        if (vo != std.math.minInt(i32)) {
            const size = getVarSize(p, current_state, var_name);
            if (isFloatVar(p, current_state, var_name)) {
                const rhs_reg = try emitExprToXmm(p, expr, current_state, size);
                try emitLoadXmmToReg(p, XMM.XMM0, vo, size, getVarBaseReg(p, current_state, var_name));
                try emitSseArith(p, XMM.XMM0, rhs_reg, .SSE_SUBPS, .SSE_SUBSS, size);
                freeXmm(p, rhs_reg);
                try emitStoreXmmFromReg(p, vo, XMM.XMM0, size, getVarBaseReg(p, current_state, var_name));
                p.pending_ret = RetValue{ .float = XMM.XMM0 };
            } else {
                try emitLoadVarToReg(p, Reg.RAX, vo, size, getVarBaseReg(p, current_state, var_name));
                try emitExprToRAXSub(p, expr, current_state);
                try emitStoreVarFromReg(p, vo, Reg.RAX, size, getVarBaseReg(p, current_state, var_name));
                p.pending_ret = RetValue{ .int = Reg.RAX };
            }
        }
        return;
    }
    // call_indirect(fn_ptr, arg1, arg2, ...)
    if (std.mem.startsWith(u8, body, "call_indirect(") and std.mem.endsWith(u8, body, ")")) {
        const inner = body["call_indirect(".len..body.len - 1];
        try emitCallIndirect(p, inner, current_state);
        return;
    }
    // ptr_store(dest, value) — store value into pointer dest
    if (std.mem.startsWith(u8, trimmed_body, "ptr_store(") and trimmed_body[trimmed_body.len-1] == ')') {
        const inner = std.mem.trim(u8, trimmed_body["ptr_store(".len..trimmed_body.len-1], " \t");
        var depth: u32 = 0;
        var comma_idx: ?usize = null;
        for (inner, 0..) |c, j| {
            switch (c) {
                '(' => depth += 1,
                ')' => { if (depth > 0) depth -= 1; },
                ',' => { if (depth == 0) { comma_idx = j; break; } },
                else => {},
            }
        }
        if (comma_idx) |ci| {
            const dest_expr = std.mem.trim(u8, inner[0..ci], " \t");
            const value_expr = std.mem.trim(u8, inner[ci+1..], " \t");
            try emitExprToRAX(p, dest_expr, current_state);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try emitExprToRAX(p, value_expr, current_state);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
        }
        return;
    }
    // obj.Method(arg1, ...) or obj->Method(arg1, ...) — COM vtbl call
    {
        const paren_open = std.mem.indexOfScalar(u8, body, '(');
        if (paren_open != null) {
            const po = paren_open.?;
            const arrow = std.mem.indexOf(u8, body, "->");
            const dot_idx = std.mem.indexOfScalar(u8, body, '.');
            const sep = if (arrow) |a| blk: {
                if (a > 0 and po > a + 1) break :blk a;
                break :blk null;
            } else dot_idx;
            if (sep) |si| {
                if (si > 0 and po > si + 1) {
                    const paren_close = std.mem.lastIndexOfScalar(u8, body, ')');
                    if (paren_close == body.len - 1) {
                        const sep_len: usize = if (arrow != null) 2 else 1;
                        const obj_expr = std.mem.trim(u8, body[0..si], " \t");
                        const method_name = std.mem.trim(u8, body[si+sep_len..po], " \t");
                        const args = std.mem.trim(u8, body[po+1..paren_close.?], " \t");
                        try emitComCall(p, obj_expr, method_name, args, current_state);
                        return;
                    }
                }
            }
        }
    }
    if (try tryEmitWin32Call(p, body, current_state)) return;
    // State name as bare identifier: transition to that state
    {
        const name = std.mem.trim(u8, body, " \t\r\n;");
        if (p.state_index_map.get(name)) |state_idx| {
            if (state_idx < p.en_id.len and state_idx < p.dp_id.len) {
                // Emit exit body and transition actions for current state
                _ = for (p.state_names.items, 0..) |sn, i| {
                    if (std.mem.eql(u8, sn, current_state)) break i;
                } else std.math.maxInt(usize);
                // Set cur_state, decrement migration budget, return to dispatch
                try emitMovRegImm32(p, Reg.RAX, @intCast(state_idx));
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_cur_state), x64.Operand.r(Reg.RAX) });
                try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RBP, p.off_abudget) });
                try x64.emit(&p.cbuf.bytes, .SUB_R32_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(1) });
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(Reg.RBP, p.off_abudget), x64.Operand.r(Reg.RAX) });
                return;
            }
        }
    }
    // return expr (inside function body)
    if (std.mem.startsWith(u8, trimmed_body, "return ")) {
        const expr = std.mem.trimLeft(u8, trimmed_body["return ".len..], " \t\r\n;");
        if (expr.len > 0) {
            try emitExprToRAX(p, expr, current_state);
        }
        try emitLongJmp(p, p.fn_epilogue_lbl);
        return;
    }
    // return -> expr
    if (std.mem.startsWith(u8, trimmed_body, "return ")) {
        const after_return = std.mem.trimLeft(u8, trimmed_body["return ".len..], " \t\r\n");
        if (std.mem.startsWith(u8, after_return, "-> ")) {
            const expr = std.mem.trimLeft(u8, after_return["-> ".len..], " \t\r\n");
            if (try tryEmitWin32Call(p, expr, current_state)) {
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_exit_code), x64.Operand.r(Reg.RAX) });
                p.pending_ret = RetValue{ .int = Reg.RAX };
                return;
            }
            if (std.mem.startsWith(u8, expr, "call_indirect(") and std.mem.endsWith(u8, expr, ")")) {
                const inner = expr["call_indirect(".len..expr.len - 1];
                try emitCallIndirect(p, inner, current_state);
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_exit_code), x64.Operand.r(Reg.RAX) });
                p.pending_ret = RetValue{ .int = Reg.RAX };
                return;
            }
            if (isComCallExpr(expr)) {
                const parsed = try parseComCall(expr);
                try emitComCall(p, parsed.obj, parsed.method, parsed.args, current_state);
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_exit_code), x64.Operand.r(Reg.RAX) });
                p.pending_ret = RetValue{ .int = Reg.RAX };
                return;
            }
            if (isFloatExpr(p, current_state, expr)) {
                const reg = try emitExprToXmm(p, expr, current_state, 4);
                try x64.emit(&p.cbuf.bytes, .SSE_MOVD_ST, &.{ x64.Operand.r(Reg.RAX), x64.Operand.xmm(reg) });
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_exit_code), x64.Operand.r(Reg.RAX) });
                p.pending_ret = RetValue{ .float = reg };
                freeXmm(p, reg);
                return;
            }
            try emitExprToRAX(p, expr, current_state);
            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RBP, p.off_exit_code), x64.Operand.r(Reg.RAX) });
            p.pending_ret = RetValue{ .int = Reg.RAX };
            return;
        }
    }
    // { block }
    if (trimmed_body.len > 0 and trimmed_body[0] == '{') {
        const close = findMatching(trimmed_body, 0, '{', '}');
        const inner = trimmed_body[1..close];
        try pushDeferScope(p);
        try emitAction(p, inner, current_state);
        try popDeferScope(p);
        return;
    }
    const eq = std.mem.indexOf(u8, body, "=");
    if (eq != null and eq.? > 0) {
        var var_name = std.mem.trim(u8, body[0..eq.?], " \t");
        if (std.mem.startsWith(u8, var_name, "var ")) {
            var_name = std.mem.trimLeft(u8, var_name["var ".len..], " \t\r\n");
        }
        const expr = std.mem.trim(u8, body[eq.?+1..], " \t");

        if (std.mem.startsWith(u8, expr, "if ") or std.mem.startsWith(u8, expr, "if(")) {
            try emitIfAsExprToRAX(p, expr, current_state);
            const vo = getVarOffset(p, current_state, var_name);
            if (vo != std.math.minInt(i32)) {
                try emitStoreVarFromReg(p, vo, Reg.RAX, 8, getVarBaseReg(p, current_state, var_name));
                p.pending_ret = RetValue{ .int = Reg.RAX };
            }
            return;
        }

        const brk = std.mem.indexOf(u8, var_name, "[");
        if (brk != null and std.mem.indexOf(u8, var_name, ",") != null and std.mem.indexOf(u8, var_name, "]") != null) {
            const rest = var_name[brk.?+1..];
            const comma_idx = std.mem.indexOf(u8, rest, ",") orelse return;
            const close_idx = std.mem.indexOf(u8, rest, "]") orelse return;
            const img_name = std.mem.trim(u8, var_name[0..brk.?], " \t");
            const x_expr = std.mem.trim(u8, rest[0..comma_idx], " \t");
            const y_expr = std.mem.trim(u8, rest[comma_idx+1..close_idx], " \t");
            const elem_size: u32 = 4;
            const reg = try emitExprToXmm(p, expr, current_state, elem_size);
            try emitImagePixelStoreReg(p, img_name, x_expr, y_expr, current_state, elem_size, reg);
            p.pending_ret = RetValue{ .float = reg };
            freeXmm(p, reg);
            return;
        }
        // Array index assignment: arr[idx] = expr
        const bracket_pos = std.mem.indexOfScalar(u8, var_name, '[');
        if (bracket_pos != null and bracket_pos.? > 0) {
            const close_bracket = std.mem.indexOfScalar(u8, var_name, ']');
            if (close_bracket != null) {
                const base_name = std.mem.trim(u8, var_name[0..bracket_pos.?], " \t");
                const index_expr = std.mem.trim(u8, var_name[bracket_pos.?+1..close_bracket.?], " \t");
                // Compute base address
                try emitExprAtomToRAX(p, base_name, current_state);
                try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
                // Compute address: base + index*8
                try emitExprToRAX(p, index_expr, current_state);
                try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.memIdx(Reg.RBX, Reg.RAX, 3, 0) });
                // Evaluate RHS and store to [RCX]
                if (try tryEmitWin32Call(p, expr, current_state)) {
                    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                    p.pending_ret = RetValue{ .int = Reg.RAX };
                } else if (isComCallExpr(expr)) {
                    const parsed = try parseComCall(expr);
                    try emitComCall(p, parsed.obj, parsed.method, parsed.args, current_state);
                    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                    p.pending_ret = RetValue{ .int = Reg.RAX };
                } else if (isFloatExpr(p, current_state, expr)) {
                    const reg = try emitExprToXmm(p, expr, current_state, 4);
                    try x64.emit(&p.cbuf.bytes, .SSE_MOVD_ST, &.{ x64.Operand.r(Reg.RAX), x64.Operand.xmm(reg) });
                    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                    p.pending_ret = RetValue{ .float = reg };
                    freeXmm(p, reg);
                } else {
                    try emitExprToRAX(p, expr, current_state);
                    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                    p.pending_ret = RetValue{ .int = Reg.RAX };
                }
                return;
            }
        }
        // *ptr = expr — dereference pointer and store
        if (std.mem.startsWith(u8, var_name, "*")) {
            const ptr_name = std.mem.trim(u8, var_name[1..], " \t");
            try emitExprToRAX(p, ptr_name, current_state);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            if (try tryEmitWin32Call(p, expr, current_state)) {
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                p.pending_ret = RetValue{ .int = Reg.RAX };
            } else if (isComCallExpr(expr)) {
                const parsed = try parseComCall(expr);
                try emitComCall(p, parsed.obj, parsed.method, parsed.args, current_state);
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                p.pending_ret = RetValue{ .int = Reg.RAX };
            } else if (isFloatExpr(p, current_state, expr)) {
                const reg = try emitExprToXmm(p, expr, current_state, 4);
                try x64.emit(&p.cbuf.bytes, .SSE_MOVD_ST, &.{ x64.Operand.r(Reg.RAX), x64.Operand.xmm(reg) });
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                p.pending_ret = RetValue{ .float = reg };
                freeXmm(p, reg);
            } else {
                try emitExprToRAX(p, expr, current_state);
                try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                p.pending_ret = RetValue{ .int = Reg.RAX };
            }
            return;
        }
        // Struct field assignment: var.field = expr
        if (std.mem.indexOfScalar(u8, var_name, '.')) |dot| {
            const struct_var = std.mem.trim(u8, var_name[0..dot], " \t");
            const field_name = std.mem.trim(u8, var_name[dot+1..], " \t");
            const struct_vo = getVarOffset(p, current_state, struct_var);
            if (struct_vo != std.math.minInt(i32)) {
                const struct_type = getVarTypeName(p, current_state, struct_var);
                if (isStructType(p, struct_type)) {
                    if (getStructFieldOffset(p, struct_type, field_name)) |field_off| {
                        const base_reg = getVarBaseReg(p, current_state, struct_var);
                        const field_addr = struct_vo + @as(i32, @intCast(field_off));
                        const field_type = getStructFieldType(p, struct_type, field_name);
                        const field_size = if (isStructType(p, field_type)) getStructFieldSize(p, field_type) else getTypeSize(field_type);
                        // Evaluate RHS and store to field
                        if (try tryEmitWin32Call(p, expr, current_state)) {
                            try emitStoreVarFromReg(p, field_addr, Reg.RAX, field_size, base_reg);
                            p.pending_ret = RetValue{ .int = Reg.RAX };
                        } else if (std.mem.startsWith(u8, expr, "call_indirect(") and std.mem.endsWith(u8, expr, ")")) {
                            const inner = expr["call_indirect(".len..expr.len - 1];
                            try emitCallIndirect(p, inner, current_state);
                            try emitStoreVarFromReg(p, field_addr, Reg.RAX, field_size, base_reg);
                            p.pending_ret = RetValue{ .int = Reg.RAX };
                        } else if (isComCallExpr(expr)) {
                            const parsed = try parseComCall(expr);
                            try emitComCall(p, parsed.obj, parsed.method, parsed.args, current_state);
                            try emitStoreVarFromReg(p, field_addr, Reg.RAX, field_size, base_reg);
                            p.pending_ret = RetValue{ .int = Reg.RAX };
                        } else if (isFloatExpr(p, current_state, expr)) {
                            const reg = try emitExprToXmm(p, expr, current_state, 4);
                            try emitStoreXmmFromReg(p, field_addr, reg, field_size, base_reg);
                            p.pending_ret = RetValue{ .float = reg };
                            freeXmm(p, reg);
                        } else {
                            try emitExprToRAX(p, expr, current_state);
                            try emitStoreVarFromReg(p, field_addr, Reg.RAX, field_size, base_reg);
                            p.pending_ret = RetValue{ .int = Reg.RAX };
                        }
                        return;
                    }
                }
            }
        }
        const vo = getVarOffset(p, current_state, var_name);
        if (vo != std.math.minInt(i32)) {
            const size = getVarSize(p, current_state, var_name);
            if (isFloatVar(p, current_state, var_name)) {
                // Try win32/math call first (handles sinf/cosf/etc)
                if (try tryEmitWin32Call(p, expr, current_state)) {
                    try emitStoreVarFromReg(p, vo, Reg.RAX, size, getVarBaseReg(p, current_state, var_name));
                    p.pending_ret = RetValue{ .int = Reg.RAX };
                } else {
                    const reg = try emitExprToXmm(p, expr, current_state, size);
                    try emitStoreXmmFromReg(p, vo, reg, size, getVarBaseReg(p, current_state, var_name));
                    p.pending_ret = RetValue{ .float = reg };
                    freeXmm(p, reg);
                }
            } else if (try tryEmitWin32Call(p, expr, current_state)) {
                try emitStoreVarFromReg(p, vo, Reg.RAX, size, getVarBaseReg(p, current_state, var_name));
                p.pending_ret = RetValue{ .int = Reg.RAX };
            } else if (std.mem.startsWith(u8, expr, "call_indirect(") and std.mem.endsWith(u8, expr, ")")) {
                const inner = expr["call_indirect(".len..expr.len - 1];
                try emitCallIndirect(p, inner, current_state);
                try emitStoreVarFromReg(p, vo, Reg.RAX, size, getVarBaseReg(p, current_state, var_name));
                p.pending_ret = RetValue{ .int = Reg.RAX };
            } else if (isComCallExpr(expr)) {
                const parsed = try parseComCall(expr);
                try emitComCall(p, parsed.obj, parsed.method, parsed.args, current_state);
                try emitStoreVarFromReg(p, vo, Reg.RAX, size, getVarBaseReg(p, current_state, var_name));
                p.pending_ret = RetValue{ .int = Reg.RAX };
            } else if (isFloatExpr(p, current_state, expr)) {
                const reg = try emitExprToXmm(p, expr, current_state, 4);
                try x64.emit(&p.cbuf.bytes, .SSE_CVTTSS2SI, &.{ x64.Operand.r(Reg.RAX), x64.Operand.xmm(reg) });
                freeXmm(p, reg);
                try emitStoreVarFromReg(p, vo, Reg.RAX, size, getVarBaseReg(p, current_state, var_name));
                p.pending_ret = RetValue{ .int = Reg.RAX };
            } else if (isComCallExpr(expr)) {
                const parsed = try parseComCall(expr);
                try emitComCall(p, parsed.obj, parsed.method, parsed.args, current_state);
                try emitStoreVarFromReg(p, vo, Reg.RAX, size, getVarBaseReg(p, current_state, var_name));
                p.pending_ret = RetValue{ .int = Reg.RAX };
            } else {
                try emitExprToRAX(p, expr, current_state);
                try emitStoreVarFromReg(p, vo, Reg.RAX, size, getVarBaseReg(p, current_state, var_name));
                p.pending_ret = RetValue{ .int = Reg.RAX };
            }
            return;
        }
        // *ptr = value (store to pointer)
        if (var_name.len > 0 and var_name[0] == '*') {
            const ptr_var = std.mem.trim(u8, var_name[1..], " \t");
            if (try tryEmitWin32Call(p, expr, current_state)) {
                if (try tryLoadVarToReg(p, Reg.RCX, ptr_var, current_state)) {
                    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                }
                p.pending_ret = RetValue{ .int = Reg.RAX };
            } else if (isFloatExpr(p, current_state, expr)) {
                const reg = try emitExprToXmm(p, expr, current_state, 4);
                if (try tryLoadVarToReg(p, Reg.RCX, ptr_var, current_state)) {
                    try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_ST, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.xmm(reg) });
                }
                p.pending_ret = RetValue{ .float = reg };
                freeXmm(p, reg);
            } else if (std.mem.startsWith(u8, expr, "call_indirect(") and std.mem.endsWith(u8, expr, ")")) {
                const inner = expr["call_indirect(".len..expr.len - 1];
                try emitCallIndirect(p, inner, current_state);
                if (try tryLoadVarToReg(p, Reg.RCX, ptr_var, current_state)) {
                    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                }
                p.pending_ret = RetValue{ .int = Reg.RAX };
            } else if (isComCallExpr(expr)) {
                const parsed = try parseComCall(expr);
                try emitComCall(p, parsed.obj, parsed.method, parsed.args, current_state);
                if (try tryLoadVarToReg(p, Reg.RCX, ptr_var, current_state)) {
                    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                }
                p.pending_ret = RetValue{ .int = Reg.RAX };
            } else {
                try emitExprToRAX(p, expr, current_state);
                if (try tryLoadVarToReg(p, Reg.RCX, ptr_var, current_state)) {
                    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RCX, 0), x64.Operand.r(Reg.RAX) });
                }
                p.pending_ret = RetValue{ .int = Reg.RAX };
            }
            return;
        }
        return;
    }
}

fn isMathFn(name: []const u8) bool {
    return std.mem.eql(u8, name, "sinf") or std.mem.eql(u8, name, "cosf") or
        std.mem.eql(u8, name, "expf") or std.mem.eql(u8, name, "logf") or
        std.mem.eql(u8, name, "powf") or std.mem.eql(u8, name, "atanf") or
        std.mem.eql(u8, name, "tanf") or std.mem.eql(u8, name, "sqrtf") or
        std.mem.eql(u8, name, "sin") or std.mem.eql(u8, name, "cos") or
        std.mem.eql(u8, name, "exp") or std.mem.eql(u8, name, "log") or
        std.mem.eql(u8, name, "pow") or std.mem.eql(u8, name, "atan") or
        std.mem.eql(u8, name, "tan") or std.mem.eql(u8, name, "sqrt");
}

fn emitMathCall(p: *PendingOutput, name: []const u8, args_str: []const u8, import_idx: usize, current_state: []const u8) !void {
    // Float-arg calling convention: args in XMM0, XMM1, ..., result in XMM0
    const simd_size: u32 = if (name[name.len - 1] == 'f') 4 else 8; // sinf=float(4), sin=double(8)
    var xmm_args: [4]i16 = [_]i16{-1} ** 4;
    var num_xmm: usize = 0;
    if (args_str.len > 0) {
        var it = std.mem.splitScalar(u8, args_str, ',');
        while (it.next()) |raw_arg| {
            if (num_xmm >= 4) break;
            const arg = std.mem.trim(u8, raw_arg, " \t");
            if (arg.len == 0) continue;
            const reg = try emitExprToXmm(p, arg, current_state, simd_size);
            xmm_args[num_xmm] = reg;
            num_xmm += 1;
        }
    }
    // Move args to XMM0, XMM1, etc
    if (num_xmm >= 1 and xmm_args[0] != 0) {
        try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(0), x64.Operand.xmm(xmm_args[0]) });
    }
    if (num_xmm >= 2 and xmm_args[1] != 1) {
        try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(1), x64.Operand.xmm(xmm_args[1]) });
    }
    // Free temp regs
    for (0..num_xmm) |i| {
        if (xmm_args[i] >= 0) freeXmm(p, xmm_args[i]);
    }
    try abi.emitCallArgs(&p.cbuf.bytes, &.{});
    try emitIatCall(p, import_idx);
    try abi.emitCallCleanup(&p.cbuf.bytes);
    // Move result from XMM0 to RAX
    try x64.emit(&p.cbuf.bytes, .SSE_MOVD_ST, &.{ x64.Operand.r(Reg.RAX), x64.Operand.xmm(0) });
}

fn splitArgsDepthAware(input: []const u8, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).init(allocator);
    var start: usize = 0;
    var depth: i32 = 0;
    for (input, 0..) |c, i| {
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
        if (c == ',' and depth == 0) {
            try result.append(input[start..i]);
            start = i + 1;
        }
    }
    if (start < input.len) try result.append(input[start..]);
    return result;
}

fn lastIndexOfScalarDepth0(comptime T: type, input: []const T, needle: T) ?usize {
    var depth: i32 = 0;
    var i: usize = input.len;
    while (i > 0) {
        i -= 1;
        if (input[i] == ')') depth += 1;
        if (input[i] == '(') depth -= 1;
        if (depth == 0 and input[i] == needle) return i;
    }
    return null;
}

fn findLastSubstrDepth0(input: []const u8, substr: []const u8) ?usize {
    if (substr.len == 0 or input.len < substr.len) return null;
    var depth: u32 = 0;
    var i: usize = input.len;
    while (i > 0) {
        i -= 1;
        if (input[i] == ')') {
            depth += 1;
        } else if (input[i] == '(') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and i + substr.len <= input.len) {
            if (std.mem.eql(u8, input[i..i + substr.len], substr)) {
                return i;
            }
        }
    }
    return null;
}

fn stripOuterParens(input: []const u8) []const u8 {
    var s = std.mem.trim(u8, input, " \t\r\n");
    while (s.len >= 2 and s[0] == '(') {
        const close = findMatching(s, 0, '(', ')');
        if (close == s.len - 1) {
            s = std.mem.trim(u8, s[1..s.len-1], " \t\r\n");
        } else {
            break;
        }
    }
    return s;
}

fn emitCondCheckToLabel(p: *PendingOutput, cond: []const u8, false_lbl: u32, current_state: []const u8) !void {
    const c = stripOuterParens(cond);

    const or_idx = findLastSubstrDepth0(c, "||");
    if (or_idx != null and or_idx.? > 0) {
        const lhs = std.mem.trim(u8, c[0..or_idx.?], " \t");
        const rhs = std.mem.trim(u8, c[or_idx.?+2..], " \t");
        const check_rhs_lbl = try allocLabelId(p, "or_chk_{d}", .{p.cbuf.label_names.items.len});
        const true_skip_lbl = try allocLabelId(p, "or_skip_{d}", .{p.cbuf.label_names.items.len});
        try emitCondCheckToLabel(p, lhs, check_rhs_lbl, current_state);
        try emitLongJmp(p, true_skip_lbl);
        try setLabel(p, check_rhs_lbl);
        try emitCondCheckToLabel(p, rhs, false_lbl, current_state);
        try setLabel(p, true_skip_lbl);
        return;
    }

    const and_idx = findLastSubstrDepth0(c, "&&");
    if (and_idx != null and and_idx.? > 0) {
        const lhs = std.mem.trim(u8, c[0..and_idx.?], " \t");
        const rhs = std.mem.trim(u8, c[and_idx.?+2..], " \t");
        try emitCondCheckToLabel(p, lhs, false_lbl, current_state);
        try emitCondCheckToLabel(p, rhs, false_lbl, current_state);
        return;
    }

    const eq_idx = std.mem.indexOf(u8, c, "==");
    const ne_idx = std.mem.indexOf(u8, c, "!=");
    const ge_idx = std.mem.indexOf(u8, c, ">=");
    const le_idx = std.mem.indexOf(u8, c, "<=");
    const gt_idx = if (ge_idx == null) std.mem.indexOf(u8, c, ">") else null;
    const lt_idx = if (le_idx == null) std.mem.indexOf(u8, c, "<") else null;

    if (eq_idx) |idx| {
        const lhs = std.mem.trim(u8, c[0..idx], " \t");
        const rhs = std.mem.trim(u8, c[idx+2..], " \t");
        try emitExprToRAX(p, lhs, current_state);
        try emitCmpR64ImmOrVar(p, rhs, current_state);
        try emitCondLongJmp(p, .JNE_REL32, false_lbl);
    } else if (ne_idx) |idx| {
        const lhs = std.mem.trim(u8, c[0..idx], " \t");
        const rhs = std.mem.trim(u8, c[idx+2..], " \t");
        try emitExprToRAX(p, lhs, current_state);
        try emitCmpR64ImmOrVar(p, rhs, current_state);
        try emitCondLongJmp(p, .JE_REL32, false_lbl);
    } else if (ge_idx) |idx| {
        const lhs = std.mem.trim(u8, c[0..idx], " \t");
        const rhs = std.mem.trim(u8, c[idx+2..], " \t");
        try emitExprToRAX(p, lhs, current_state);
        try emitCmpR64ImmOrVar(p, rhs, current_state);
        try emitCondLongJmp(p, .JL_REL32, false_lbl);
    } else if (le_idx) |idx| {
        const lhs = std.mem.trim(u8, c[0..idx], " \t");
        const rhs = std.mem.trim(u8, c[idx+2..], " \t");
        try emitExprToRAX(p, lhs, current_state);
        try emitCmpR64ImmOrVar(p, rhs, current_state);
        try emitCondLongJmp(p, .JG_REL32, false_lbl);
    } else if (gt_idx) |idx| {
        const lhs = std.mem.trim(u8, c[0..idx], " \t");
        const rhs = std.mem.trim(u8, c[idx+1..], " \t");
        try emitExprToRAX(p, lhs, current_state);
        try emitCmpR64ImmOrVar(p, rhs, current_state);
        try emitCondLongJmp(p, .JLE_REL32, false_lbl);
    } else if (lt_idx) |idx| {
        const lhs = std.mem.trim(u8, c[0..idx], " \t");
        const rhs = std.mem.trim(u8, c[idx+1..], " \t");
        try emitExprToRAX(p, lhs, current_state);
        try emitCmpR64ImmOrVar(p, rhs, current_state);
        try emitCondLongJmp(p, .JGE_REL32, false_lbl);
    } else {
        try emitExprToRAX(p, c, current_state);
        try x64.emit(&p.cbuf.bytes, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(0) });
        try emitCondLongJmp(p, .JE_REL32, false_lbl);
    }
}

fn tryEmitWin32Call(p: *PendingOutput, body: []const u8, current_state: []const u8) !bool {
    const paren_open = std.mem.indexOfScalar(u8, body, '(');
    if (paren_open) |po| {
        const paren_close = std.mem.lastIndexOfScalar(u8, body, ')');
        if (paren_close) |pc| {
            if (pc == body.len - 1 and po > 0) {
                const fn_name = std.mem.trim(u8, body[0..po], " \t");
                for (IMPORT_FNS, 0..) |import_name, import_idx| {
                    if (std.mem.eql(u8, fn_name, import_name)) {
                        const args_str = std.mem.trim(u8, body[po+1..pc], " \t");
                         if (isMathFn(fn_name)) {
                            try emitMathCall(p, fn_name, args_str, @intCast(import_idx), current_state);
                            return true;
                        }
                        const is_wide = fn_name.len > 0 and fn_name[fn_name.len - 1] == 'W';
                        const target_regs = [_]i16{ 1, 2, 8, 9 }; // RCX, RDX, R8, R9
                        // Parse all args into fixed buffers
                        var imm_buf: [12]i64 = undefined;
                        var str_buf: [12]u32 = undefined;
                        var var_buf: [12][]const u8 = undefined;
                        var typ_buf: [12]u8 = undefined; // 0=imm, 1=str, 2=var
                        var num_total: usize = 0;
                        if (args_str.len > 0) {
                            var arg_list = try splitArgsDepthAware(args_str, p.allocator);
                            defer arg_list.deinit();
                            for (arg_list.items) |raw_arg| {
                                if (num_total >= 12) break;
                                const arg = std.mem.trim(u8, raw_arg, " \t");
                                if (arg.len == 0) continue;
                                if (arg[0] == '"' and arg[arg.len - 1] == '"') {
                                    typ_buf[num_total] = 1;
                                    str_buf[num_total] = if (is_wide)
                                        try addPoolWString(p, arg[1..arg.len - 1])
                                    else
                                        try addPoolString(p, arg[1..arg.len - 1]);
                                } else {
                                    const n = parseNumber(arg);
                                    if (n != 0 or (arg.len > 0 and (std.ascii.isDigit(arg[0]) or arg[0] == '-' or arg[0] == '+'))) {
                                        typ_buf[num_total] = 0;
                                        imm_buf[num_total] = n;
                                    } else {
                                        typ_buf[num_total] = 2;
                                        var_buf[num_total] = arg;
                                    }
                                }
                                num_total += 1;
                            }
                        }
                        // Register args (first 4)
                        for (0..@min(num_total, 4)) |i| {
                            switch (typ_buf[i]) {
                                0 => try emitLoadImm(p, target_regs[i], imm_buf[i]),
                                1 => {
                                    std.debug.print("  emitStrArg i={d} is_wide={} str_idx={d}\n", .{i, is_wide, str_buf[i]});
                                    if (is_wide) try emitRipLeaWide(p, target_regs[i], str_buf[i]) else try emitRipLea(p, target_regs[i], str_buf[i]);
                                },
                                2 => {
                                    if (!try tryLoadVarToReg(p, target_regs[i], var_buf[i], current_state)) {
                                        try emitExprToRAX(p, var_buf[i], current_state);
                                        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(target_regs[i]), x64.Operand.r(Reg.RAX) });
                                    }
                                },
                                else => {},
                            }
                        }
                        try abi.emitCallArgs(&p.cbuf.bytes, &.{});
                        // Stack args (beyond 4) at [RSP + 0x20 + (i-4)*8]
                        if (num_total > 4) {
                            for (4..num_total) |i| {
                                const stack_off: i32 = 0x20 + @as(i32, @intCast(i - 4)) * 8;
                                switch (typ_buf[i]) {
                                    0 => {
                                        try emitLoadImm(p, Reg.RAX, imm_buf[i]);
                                        try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, stack_off), x64.Operand.r(Reg.RAX) });
                                    },
                                    1 => {
                                        if (is_wide) try emitRipLeaWide(p, Reg.RAX, str_buf[i]) else try emitRipLea(p, Reg.RAX, str_buf[i]);
                                        try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, stack_off), x64.Operand.r(Reg.RAX) });
                                    },
                                    2 => {
                                        if (try tryLoadVarToReg(p, Reg.RAX, var_buf[i], current_state)) {
                                            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, stack_off), x64.Operand.r(Reg.RAX) });
                                        } else {
                                            try emitExprToRAX(p, var_buf[i], current_state);
                                            try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.RSP, stack_off), x64.Operand.r(Reg.RAX) });
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                        try emitIatCall(p, @intCast(import_idx));
                        try abi.emitCallCleanup(&p.cbuf.bytes);
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

fn getVarOffset(p: *PendingOutput, state_name: []const u8, var_name: []const u8) i32 {
    if (p.in_for_range) {
        if (std.mem.eql(u8, var_name, p.for_range_var_name)) return p.off_for_range_counter;
    }
    if (p.in_for_loop) {
        if (std.mem.eql(u8, var_name, "x")) return p.off_for_loop_x;
        if (std.mem.eql(u8, var_name, "y")) return p.off_for_loop_y;
    }
    for (p.ctx_vars.items, 0..) |cv, i| { if (std.mem.eql(u8, cv.name, var_name)) return p.off_ctx_var_start - @as(i32, @intCast(i)) * 8; }
    if (p.entry_vars.get(var_name)) |off| return off;
    if (p.state_vars.get(state_name)) |sv_list| { for (sv_list.items) |sv| { if (std.mem.eql(u8, sv.name, var_name)) return @as(i32, @intCast(sv.layout_offset)); } }
    return std.math.minInt(i32);
}

fn isStateVar(p: *PendingOutput, state_name: []const u8, var_name: []const u8) bool {
    if (p.in_for_range) {
        if (std.mem.eql(u8, var_name, p.for_range_var_name)) return false;
    }
    if (p.in_for_loop) {
        if (std.mem.eql(u8, var_name, "x") or std.mem.eql(u8, var_name, "y")) return false;
    }
    for (p.ctx_vars.items) |cv| { if (std.mem.eql(u8, cv.name, var_name)) return false; }
    if (p.entry_vars.contains(var_name)) return false;
    if (p.state_vars.get(state_name)) |sv_list| { for (sv_list.items) |sv| { if (std.mem.eql(u8, sv.name, var_name)) return true; } }
    return false;
}

fn getVarBaseReg(p: *PendingOutput, state_name: []const u8, var_name: []const u8) i16 {
    if (isStateVar(p, state_name, var_name)) return p.state_base_reg;
    return Reg.RBP;
}

fn getVarSize(p: *PendingOutput, state_name: []const u8, var_name: []const u8) u32 {
    if (p.in_for_range) {
        if (std.mem.eql(u8, var_name, p.for_range_var_name)) return 8;
    }
    if (p.in_for_loop) {
        if (std.mem.eql(u8, var_name, "x")) return 4;
        if (std.mem.eql(u8, var_name, "y")) return 4;
    }
    for (p.ctx_vars.items) |cv| { if (std.mem.eql(u8, cv.name, var_name)) return 8; }
    if (p.entry_vars.contains(var_name)) return 8;
    if (p.state_vars.get(state_name)) |sv_list| { for (sv_list.items) |sv| { if (std.mem.eql(u8, sv.name, var_name)) return sv.size; } }
    return 8;
}

fn emitLoadVarToReg(p: *PendingOutput, reg: i16, offset: i32, size: u32, base_reg: i16) !void {
    switch (size) {
        1 => try x64.emit(&p.cbuf.bytes, .MOVSX_R64_MEM8, &.{ x64.Operand.r(reg), x64.Operand.mem(base_reg, offset) }),
        2 => try x64.emit(&p.cbuf.bytes, .MOVSX_R64_MEM16, &.{ x64.Operand.r(reg), x64.Operand.mem(base_reg, offset) }),
        4 => try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(reg), x64.Operand.mem(base_reg, offset) }),
        else => try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(reg), x64.Operand.mem(base_reg, offset) }),
    }
    // Trace read of state field
    if (p.trace_mode == .reads or p.trace_mode == .full) {
        if (base_reg == p.state_base_reg) {
            try emitTraceRead(p, @as(u8, @intCast(size)), offset, reg);
        }
    }
}

fn emitStoreVarFromReg(p: *PendingOutput, offset: i32, reg: i16, size: u32, base_reg: i16) !void {
    switch (size) {
        1 => try x64.emit(&p.cbuf.bytes, .MOV_MEM_R8, &.{ x64.Operand.mem(base_reg, offset), x64.Operand.r(reg) }),
        2 => try x64.emit(&p.cbuf.bytes, .MOV_MEM_R16, &.{ x64.Operand.mem(base_reg, offset), x64.Operand.r(reg) }),
        4 => try x64.emit(&p.cbuf.bytes, .MOV_MEM_R32, &.{ x64.Operand.mem(base_reg, offset), x64.Operand.r(reg) }),
        else => try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(base_reg, offset), x64.Operand.r(reg) }),
    }
    // Trace write of state field
    if (p.trace_mode == .writes or p.trace_mode == .full) {
        if (base_reg == p.state_base_reg) {
            try emitTraceWrite(p, @as(u8, @intCast(size)), offset, reg);
        }
    }
}

fn emitLoadXmmToReg(p: *PendingOutput, xmm: i16, offset: i32, size: u32, base_reg: i16) !void {
    const mem = x64.Operand.mem(base_reg, offset);
    switch (size) {
        4 => try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(xmm), mem }),
        8 => try x64.emit(&p.cbuf.bytes, .SSE_MOVSD_LD, &.{ x64.Operand.xmm(xmm), mem }),
        16 => try x64.emit(&p.cbuf.bytes, .SSE_MOVUPS_LD, &.{ x64.Operand.xmm(xmm), mem }),
        else => try x64.emit(&p.cbuf.bytes, .SSE_MOVUPS_LD, &.{ x64.Operand.xmm(xmm), mem }),
    }
    // Trace read of SIMD state field
    if (p.trace_mode == .reads or p.trace_mode == .full) {
        if (base_reg == p.state_base_reg) {
            // Move XMM value to GPR for tracing
            const tmp_reg = Reg.RCX;
            if (size <= 4) {
                try x64.emit(&p.cbuf.bytes, .SSE_MOVD_ST, &.{ x64.Operand.r(tmp_reg), x64.Operand.xmm(xmm) });
            } else {
                try x64.emit(&p.cbuf.bytes, .SSE_MOVQ_ST, &.{ x64.Operand.r(tmp_reg), x64.Operand.xmm(xmm) });
            }
            try emitTraceRead(p, @as(u8, @intCast(size)), offset, tmp_reg);
        }
    }
}

fn emitStoreXmmFromReg(p: *PendingOutput, offset: i32, xmm: i16, size: u32, base_reg: i16) !void {
    const mem = x64.Operand.mem(base_reg, offset);
    // For trace, capture value before store (XMM still holds it)
    const should_trace = (p.trace_mode == .writes or p.trace_mode == .full) and base_reg == p.state_base_reg;
    if (should_trace) {
        // Move XMM value to GPR for tracing before the store
        const tmp_reg = Reg.RCX;
        if (size <= 4) {
            try x64.emit(&p.cbuf.bytes, .SSE_MOVD_ST, &.{ x64.Operand.r(tmp_reg), x64.Operand.xmm(xmm) });
        } else {
            try x64.emit(&p.cbuf.bytes, .SSE_MOVQ_ST, &.{ x64.Operand.r(tmp_reg), x64.Operand.xmm(xmm) });
        }
    }
    switch (size) {
        4 => try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_ST, &.{ mem, x64.Operand.xmm(xmm) }),
        8 => try x64.emit(&p.cbuf.bytes, .SSE_MOVSD_ST, &.{ mem, x64.Operand.xmm(xmm) }),
        16 => try x64.emit(&p.cbuf.bytes, .SSE_MOVUPS_ST, &.{ mem, x64.Operand.xmm(xmm) }),
        else => try x64.emit(&p.cbuf.bytes, .SSE_MOVUPS_ST, &.{ mem, x64.Operand.xmm(xmm) }),
    }
    if (should_trace) {
        try emitTraceWrite(p, @as(u8, @intCast(size)), offset, Reg.RCX);
    }
}

// --- Trace Event Instrumentation ---
// TraceEvent layout (16 bytes):
//   [0] u8  opcode  (0=read, 1=write)
//   [1] u8  size    (access size: 1/2/4/8)
//   [2] u16 reserved
//   [4] u32 field_offset (state field layout_offset)
//   [8] u64 value (raw bits)
//
// R15 = address of trace_buf_ptr global slot (loaded in export prologue)
// [R15] = current write position in trace buffer (advances with each event)

fn emitTraceEvent(p: *PendingOutput, opcode: u8, size: u8, field_offset: i32, value_reg: i16) !void {
    // Use R11 as buffer temp (R11 is volatile, unused by callers like emitImagePixelStoreReg)
    // mov r11, [r15]         ; r11 = current buffer write position
    try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.R11), x64.Operand.mem(Reg.R15, 0) });
    // mov byte [r11], opcode
    try p.cbuf.bytes.append(0x41); try p.cbuf.bytes.append(0xC6); try p.cbuf.bytes.append(0x03); try p.cbuf.bytes.append(opcode);
    // mov byte [r11+1], size
    try p.cbuf.bytes.append(0x41); try p.cbuf.bytes.append(0xC6); try p.cbuf.bytes.append(0x43); try p.cbuf.bytes.append(0x01); try p.cbuf.bytes.append(size);
    // mov dword [r11+4], field_offset
    try p.cbuf.bytes.append(0x41); try p.cbuf.bytes.append(0xC7); // MOV r/m32, imm32 with REX.B
    try p.cbuf.bytes.append(0x43); // ModRM: mod=01, reg=000, r/m=011(R11), disp8
    try p.cbuf.bytes.append(0x04); // disp8 = 4
    const off_bytes: [4]u8 = @bitCast(@as(i32, @intCast(field_offset)));
    try p.cbuf.bytes.appendSlice(&off_bytes);
    // mov [r11+8], value_reg  (64-bit store)
    const rex_b: u8 = 0x01; // REX.B for R11 r/m
    const rex_r: u8 = if (value_reg >= 8) 0x04 else 0; // REX.R for ModRM.reg (source in 0x89 encoding)
    try p.cbuf.bytes.append(0x48 | rex_b | rex_r);
    try p.cbuf.bytes.append(0x89); // MOV r/m64, r64
    // ModRM: mod=01 (disp8), reg=value_reg&7, r/m=011(R11), disp8=8
    try p.cbuf.bytes.append(0x43 | (@as(u8, @intCast(value_reg & 7)) << 3));
    try p.cbuf.bytes.append(0x08); // disp8 = 8
    // add r11, 16
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.R11), x64.Operand.immU32(16) });
    // mov [r15], r11          ; store back advanced position
    try x64.emit(&p.cbuf.bytes, .MOV_MEM_R64, &.{ x64.Operand.mem(Reg.R15, 0), x64.Operand.r(Reg.R11) });
}

fn emitTraceRead(p: *PendingOutput, size: u8, field_offset: i32, value_reg: i16) !void {
    try emitTraceEvent(p, 0, size, field_offset, value_reg);
}

fn emitTraceWrite(p: *PendingOutput, size: u8, field_offset: i32, value_reg: i16) !void {
    try emitTraceEvent(p, 1, size, field_offset, value_reg);
}

// Load R15 with address of trace_buf_ptr global slot (called in export prologue)
fn emitTraceBufPtrLoad(p: *PendingOutput) !void {
    const label_id = try allocLabelId(p, "trace_buf_ptr", .{});
    // LEA R15, [RIP + trace_buf_ptr]
    const rex: u8 = 0x48 | 0x04; // REX.W + REX.R (R15 in ModRM.reg)
    try p.cbuf.bytes.append(rex);
    try p.cbuf.bytes.append(0x8D); // LEA
    try p.cbuf.bytes.append(0x3D); // ModRM: mod=00, reg=111(R15), r/m=101(RIP-rel)
    try p.cbuf.fixups.append(.{ .offset = @intCast(p.cbuf.bytes.items.len), .disp_size = 4, .label_id = label_id });
    try p.cbuf.bytes.appendNTimes(0, 4);
}

fn emitRipRelativeLea(p: *PendingOutput, reg: i16, label_id: u32) !void {
    const rex: u8 = 0x48 | (if (reg >= 8) @as(u8, 0x04) else 0); // REX.W + REX.R for extended reg
    try p.cbuf.bytes.append(rex);
    try p.cbuf.bytes.append(0x8D); // LEA
    // ModRM: mod=00, reg=reg&7, r/m=101 (RIP-relative)
    try p.cbuf.bytes.append(0x05 | (@as(u8, @intCast(reg & 7)) << 3));
    try p.cbuf.fixups.append(.{ .offset = @intCast(p.cbuf.bytes.items.len), .disp_size = 4, .label_id = label_id });
    try p.cbuf.bytes.appendNTimes(0, 4);
}

// --- Expose trace buffer slot address to runner ---
fn emitBpcGetTraceBufSlot(p: *PendingOutput) !void {
    const name = "bpc_get_trace_buf_slot";
    try setLabel(p, try allocLabelId(p, "exp_{s}", .{name}));
    try p.symbols.add(name, sym.SymbolKind.exp, @intCast(p.cbuf.bytes.items.len));
    try abi.emitFullPrologue(&p.cbuf.bytes);
    // LEA RAX, [RIP + trace_buf_ptr]
    const label_id = try allocLabelId(p, "trace_buf_ptr", .{});
    try emitRipRelativeLea(p, Reg.RAX, label_id);
    try abi.emitFullEpilogue(&p.cbuf.bytes);
}

fn emitIfAsExprToRAX(p: *PendingOutput, expr: []const u8, current_state: []const u8) !void {
    const e = std.mem.trimLeft(u8, expr, " \t\r\n");
    const after_if = std.mem.trimLeft(u8, e[2..], " \t\r\n");
    if (after_if.len == 0 or after_if[0] != '(') {
        try emitXorReg(p, Reg.RAX);
        return;
    }
    const cond_close = findMatching(after_if, 0, '(', ')');
    const cond = std.mem.trim(u8, after_if[1..cond_close], " \t\r\n");
    const after_paren = std.mem.trimLeft(u8, after_if[cond_close + 1 ..], " \t\r\n");
    if (after_paren.len == 0 or after_paren[0] != '{') {
        try emitXorReg(p, Reg.RAX);
        return;
    }
    const then_end = findMatching(after_paren, 0, '{', '}');
    const then_body = after_paren[1..then_end];
    var else_body: []const u8 = "";
    const after_then = std.mem.trimLeft(u8, after_paren[then_end + 1 ..], " \t\r\n");
    if (std.mem.startsWith(u8, after_then, "else{")) {
        const else_end = findMatching(after_then, 4, '{', '}');
        else_body = after_then[5..else_end];
    } else if (std.mem.startsWith(u8, after_then, "else {")) {
        const else_end = findMatching(after_then, 5, '{', '}');
        else_body = after_then[6..else_end];
    }

    const else_lbl = try allocLabelId(p, "if_expr_else_{d}", .{p.cbuf.label_names.items.len});
    const merge_lbl = try allocLabelId(p, "if_expr_merge_{d}", .{p.cbuf.label_names.items.len});

    try emitCondCheckToLabel(p, cond, else_lbl, current_state);
    try emitExprToRAX(p, then_body, current_state);
    try emitLongJmp(p, merge_lbl);
    try setLabel(p, else_lbl);
    if (else_body.len > 0) {
        try emitExprToRAX(p, else_body, current_state);
    } else {
        try emitXorReg(p, Reg.RAX);
    }
    try setLabel(p, merge_lbl);
}

fn emitExprToRAX(p: *PendingOutput, expr: []const u8, current_state: []const u8) anyerror!void {
    const e = std.mem.trim(u8, expr, " \t");
    if (e.len == 0) { try emitXorReg(p, Reg.RAX); return; }
    if (std.mem.eql(u8, e, "true")) { try emitLoadImm(p, Reg.RAX, 1); return; }
    if (std.mem.eql(u8, e, "false")) { try emitXorReg(p, Reg.RAX); return; }

    // || (lowest precedence among operators)
    const or_idx_e = findLastSubstrDepth0(e, "||");
    if (or_idx_e != null and or_idx_e.? > 0) {
        const lhs = std.mem.trim(u8, e[0..or_idx_e.?], " \t");
        const rhs = std.mem.trim(u8, e[or_idx_e.?+2..], " \t");
        const end_lbl = try allocLabelId(p, "or_end_{d}", .{p.cbuf.label_names.items.len});
        const true_lbl = try allocLabelId(p, "or_true_{d}", .{p.cbuf.label_names.items.len});
        try emitExprToRAX(p, lhs, current_state);
        try x64.emit(&p.cbuf.bytes, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(0) });
        try emitCondLongJmp(p, .JNE_REL32, true_lbl);
        try emitExprToRAX(p, rhs, current_state);
        try x64.emit(&p.cbuf.bytes, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(0) });
        try emitCondLongJmp(p, .JNE_REL32, true_lbl);
        try emitXorReg(p, Reg.RAX);
        try emitLongJmp(p, end_lbl);
        try setLabel(p, true_lbl);
        try emitLoadImm(p, Reg.RAX, 1);
        try setLabel(p, end_lbl);
        return;
    }

    // &&
    const and_idx_e = findLastSubstrDepth0(e, "&&");
    if (and_idx_e != null and and_idx_e.? > 0) {
        const lhs = std.mem.trim(u8, e[0..and_idx_e.?], " \t");
        const rhs = std.mem.trim(u8, e[and_idx_e.?+2..], " \t");
        const end_lbl = try allocLabelId(p, "and_end_{d}", .{p.cbuf.label_names.items.len});
        const false_lbl = try allocLabelId(p, "and_false_{d}", .{p.cbuf.label_names.items.len});
        try emitExprToRAX(p, lhs, current_state);
        try x64.emit(&p.cbuf.bytes, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(0) });
        try emitCondLongJmp(p, .JE_REL32, false_lbl);
        try emitExprToRAX(p, rhs, current_state);
        try x64.emit(&p.cbuf.bytes, .CMP_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.imm(0) });
        try emitCondLongJmp(p, .JE_REL32, false_lbl);
        try emitLoadImm(p, Reg.RAX, 1);
        try emitLongJmp(p, end_lbl);
        try setLabel(p, false_lbl);
        try emitXorReg(p, Reg.RAX);
        try setLabel(p, end_lbl);
        return;
    }

    // << (shift left, higher precedence than | &)
    const shl_idx_e = findLastSubstrDepth0(e, "<<");
    if (shl_idx_e != null and shl_idx_e.? > 0) {
        const lhs = std.mem.trim(u8, e[0..shl_idx_e.?], " \t");
        const rhs = std.mem.trim(u8, e[shl_idx_e.?+2..], " \t");
        try emitExprToRAX(p, lhs, current_state);
        try x64.emit(&p.cbuf.bytes, .PUSH_R64, &.{ x64.Operand.r(Reg.RBX) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
        try emitExprToRAX(p, rhs, current_state);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
        try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT_CL, &.{ x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.cbuf.bytes, .POP_R64, &.{ x64.Operand.r(Reg.RBX) });
        return;
    }

    // >> (shift right, higher precedence than | &)
    const shr_idx_e = findLastSubstrDepth0(e, ">>");
    if (shr_idx_e != null and shr_idx_e.? > 0) {
        const lhs = std.mem.trim(u8, e[0..shr_idx_e.?], " \t");
        const rhs = std.mem.trim(u8, e[shr_idx_e.?+2..], " \t");
        try emitExprToRAX(p, lhs, current_state);
        try x64.emit(&p.cbuf.bytes, .PUSH_R64, &.{ x64.Operand.r(Reg.RBX) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
        try emitExprToRAX(p, rhs, current_state);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
        try x64.emit(&p.cbuf.bytes, .SHIFT_RIGHT_CL, &.{ x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.cbuf.bytes, .POP_R64, &.{ x64.Operand.r(Reg.RBX) });
        return;
    }

    // | (bitwise OR, between <<>> and comparisons)
    const bitor_idx = findLastSubstrDepth0(e, "|");
    if (bitor_idx != null and bitor_idx.? > 0) {
        // Make sure it's not || (already checked above)
        if (bitor_idx.? + 1 >= e.len or e[bitor_idx.? + 1] != '|') {
            const lhs = std.mem.trim(u8, e[0..bitor_idx.?], " \t");
            const rhs = std.mem.trim(u8, e[bitor_idx.?+1..], " \t");
            try emitExprToRAX(p, lhs, current_state);
            try x64.emit(&p.cbuf.bytes, .PUSH_R64, &.{ x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
            try emitExprToRAX(p, rhs, current_state);
            try x64.emit(&p.cbuf.bytes, .OR_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .POP_R64, &.{ x64.Operand.r(Reg.RBX) });
            return;
        }
    }

    // & (bitwise AND, between | and comparisons)
    const bitand_idx = findLastSubstrDepth0(e, "&");
    if (bitand_idx != null and bitand_idx.? > 0) {
        // Make sure it's not && (already checked above)
        if (bitand_idx.? + 1 >= e.len or e[bitand_idx.? + 1] != '&') {
            const lhs = std.mem.trim(u8, e[0..bitand_idx.?], " \t");
            const rhs = std.mem.trim(u8, e[bitand_idx.?+1..], " \t");
            try emitExprToRAX(p, lhs, current_state);
            try x64.emit(&p.cbuf.bytes, .PUSH_R64, &.{ x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
            try emitExprToRAX(p, rhs, current_state);
            try x64.emit(&p.cbuf.bytes, .AND_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
            try x64.emit(&p.cbuf.bytes, .POP_R64, &.{ x64.Operand.r(Reg.RBX) });
            return;
        }
    }

    // Comparisons as values (higher precedence than &&/||/|/&, lower than arithmetic)
    {
        var cmp_pos: ?usize = null;
        var cmp_len: usize = 0;
        const ceq_idx = findLastSubstrDepth0(e, "==");
        const cne_idx = findLastSubstrDepth0(e, "!=");
        const cge_idx = findLastSubstrDepth0(e, ">=");
        const cle_idx = findLastSubstrDepth0(e, "<=");
        const cgt_idx = findLastSubstrDepth0(e, ">");
        const clt_idx = findLastSubstrDepth0(e, "<");
        if (ceq_idx) |p0| { if (cmp_pos == null or p0 > cmp_pos.?) { cmp_pos = p0; cmp_len = 2; } }
        if (cne_idx) |p0| { if (cmp_pos == null or p0 > cmp_pos.?) { cmp_pos = p0; cmp_len = 2; } }
        if (cge_idx) |p0| { if (cmp_pos == null or p0 > cmp_pos.?) { cmp_pos = p0; cmp_len = 2; } }
        if (cle_idx) |p0| { if (cmp_pos == null or p0 > cmp_pos.?) { cmp_pos = p0; cmp_len = 2; } }
        if (cgt_idx) |p0| {
            if (cge_idx == null or p0 != cge_idx.?) {
                if (cmp_pos == null or p0 > cmp_pos.?) { cmp_pos = p0; cmp_len = 1; }
            }
        }
        if (clt_idx) |p0| {
            if (cle_idx == null or p0 != cle_idx.?) {
                if (cmp_pos == null or p0 > cmp_pos.?) { cmp_pos = p0; cmp_len = 1; }
            }
        }
        if (cmp_pos) |idx| {
            if (idx > 0) {
                const lhs = std.mem.trim(u8, e[0..idx], " \t");
                const rhs = std.mem.trim(u8, e[idx+cmp_len..], " \t");
                const true_lbl = try allocLabelId(p, "cmp_true_{d}", .{p.cbuf.label_names.items.len});
                const end_lbl = try allocLabelId(p, "cmp_end_{d}", .{p.cbuf.label_names.items.len});
                const op = e[idx..idx+cmp_len];
                try emitExprToRAX(p, lhs, current_state);
                try emitCmpR64ImmOrVar(p, rhs, current_state);
                const jcc: x64.OpCode = if (std.mem.eql(u8, op, "==")) .JE_REL32
                else if (std.mem.eql(u8, op, "!=")) .JNE_REL32
                else if (std.mem.eql(u8, op, ">=")) .JGE_REL32
                else if (std.mem.eql(u8, op, "<=")) .JLE_REL32
                else if (std.mem.eql(u8, op, ">")) .JG_REL32
                else .JL_REL32;
                try emitCondLongJmp(p, jcc, true_lbl);
                try emitXorReg(p, Reg.RAX);
                try emitLongJmp(p, end_lbl);
                try setLabel(p, true_lbl);
                try emitLoadImm(p, Reg.RAX, 1);
                try setLabel(p, end_lbl);
                return;
            }
        }
    }

    const div_idx = lastIndexOfScalarDepth0(u8, e, '/');
    const plus_idx = lastIndexOfScalarDepth0(u8, e, '+');
    const minus_idx = lastIndexOfScalarDepth0(u8, e, '-');
    if (div_idx != null and div_idx.? > 0) {
        const lhs = std.mem.trim(u8, e[0..div_idx.?], " \t");
        const rhs = std.mem.trim(u8, e[div_idx.?+1..], " \t");
        try emitExprToRAX(p, lhs, current_state);
        try x64.emit(&p.cbuf.bytes, .CQO, &.{});
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RDX) });
        if (try tryLoadVarToReg(p, Reg.R8, rhs, current_state)) {
        } else {
            const rn = parseNumber(rhs);
            try emitLoadImm(p, Reg.R8, rn);
        }
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RCX) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RBX) });
        try x64.emit(&p.cbuf.bytes, .IDIV_R64, &.{ x64.Operand.r(Reg.R8) });
        return;
    }
    if (plus_idx != null and plus_idx.? > 0) {
        const lhs = std.mem.trim(u8, e[0..plus_idx.?], " \t");
        const rhs = std.mem.trim(u8, e[plus_idx.?+1..], " \t");
        try emitExprToRAX(p, lhs, current_state);
        try x64.emit(&p.cbuf.bytes, .PUSH_R64, &.{ x64.Operand.r(Reg.RBX) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
        try emitExprToRAX(p, rhs, current_state);
        try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
        try x64.emit(&p.cbuf.bytes, .POP_R64, &.{ x64.Operand.r(Reg.RBX) });
        return;
    }
    if (minus_idx != null and minus_idx.? > 0) {
        const lhs = std.mem.trim(u8, e[0..minus_idx.?], " \t");
        const rhs = std.mem.trim(u8, e[minus_idx.?+1..], " \t");
        try emitExprToRAX(p, rhs, current_state);
        try x64.emit(&p.cbuf.bytes, .PUSH_R64, &.{ x64.Operand.r(Reg.RBX) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
        try emitExprToRAX(p, lhs, current_state);
        try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
        try x64.emit(&p.cbuf.bytes, .POP_R64, &.{ x64.Operand.r(Reg.RBX) });
        return;
    }
    // Multiplication (must come before function-call detection to handle n * fact(n-1))
    const mul_idx = lastIndexOfScalarDepth0(u8, e, '*');
    if (mul_idx != null and mul_idx.? > 0) {
        const lhs = std.mem.trim(u8, e[0..mul_idx.?], " \t");
        const rhs = std.mem.trim(u8, e[mul_idx.?+1..], " \t");
        try emitExprToRAX(p, lhs, current_state);
        try x64.emit(&p.cbuf.bytes, .PUSH_R64, &.{ x64.Operand.r(Reg.RBX) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
        try emitExprToRAX(p, rhs, current_state);
        try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
        try x64.emit(&p.cbuf.bytes, .POP_R64, &.{ x64.Operand.r(Reg.RBX) });
        return;
    }
    // User-defined function call: name(args)
    if (std.mem.indexOfScalar(u8, e, '(')) |paren| {
        if (paren > 0) {
            const fn_name = std.mem.trim(u8, e[0..paren], " \t");
            const found = p.func_defs.get(fn_name);
            if (found) |_| {
                const close_paren = std.mem.lastIndexOfScalar(u8, e, ')') orelse return;
                const args_str = std.mem.trim(u8, e[paren+1..close_paren], " \t");
                const win64_args = [_]i16{ 1, 2, 8, 9 };
                var num_args: usize = 0;
                if (args_str.len > 0) {
                    var arg_list = try splitArgsDepthAware(args_str, p.allocator);
                    defer arg_list.deinit();
                    for (arg_list.items) |raw_arg| {
                        if (num_args >= 4) break;
                        const arg = std.mem.trim(u8, raw_arg, " \t");
                        if (arg.len == 0) continue;
                        try emitExprToRAX(p, arg, current_state);
                        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(win64_args[num_args]), x64.Operand.r(Reg.RAX) });
                        num_args += 1;
                    }
                }
                try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(32) });
                try emitCallToLabel(p, try allocLabelId(p, "fn_{s}", .{fn_name}));
                try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RSP), x64.Operand.immU32(32) });
                return;
            }
        }
    }
    try emitExprAtomToRAX(p, e, current_state);
}

fn emitExprToRAXAdd(p: *PendingOutput, expr: []const u8, current_state: []const u8) anyerror!void {
    const e = std.mem.trim(u8, expr, " \t");
    if (try tryLoadVarToReg(p, Reg.RBX, e, current_state)) {
        try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
    } else {
        const rn = parseNumber(e);
        try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(@intCast(rn)) });
    }
}

fn emitExprToRAXSub(p: *PendingOutput, expr: []const u8, current_state: []const u8) anyerror!void {
    const e = std.mem.trim(u8, expr, " \t");
    if (try tryLoadVarToReg(p, Reg.RBX, e, current_state)) {
        try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RBX) });
    } else {
        const rn = parseNumber(e);
        try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(@intCast(rn)) });
    }
}

fn emitExprAtomToRAX(p: *PendingOutput, atom: []const u8, current_state: []const u8) anyerror!void {
    const a = std.mem.trim(u8, atom, " \t");
    if (a.len == 0) { try emitXorReg(p, Reg.RAX); return; }
    if (std.mem.startsWith(u8, a, "@handle_alloc(") and std.mem.endsWith(u8, a, ")")) {
        const size_expr = std.mem.trim(u8, a["@handle_alloc(".len..a.len-1], " \t");
        try emitExprToRAX(p, size_expr, current_state);
        try emitPushR64(p, Reg.RAX);
        try emitIntrinsicCall(p, .arena_l1_alloc);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
        try emitPopR64(p, Reg.RDX);
        try emitIntrinsicCall(p, .handle_alloc);
        return;
    }
    if (std.mem.startsWith(u8, a, "@handle_access(") and std.mem.endsWith(u8, a, ")")) {
        const handle_expr = std.mem.trim(u8, a["@handle_access(".len..a.len-1], " \t");
        try emitExprToRAX(p, handle_expr, current_state);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R10), x64.Operand.r(Reg.RAX) });
        try x64.emit(&p.cbuf.bytes, .SHIFT_RIGHT, &.{ x64.Operand.r(Reg.R10), x64.Operand.immU32(32) });
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R10) });
        try emitIntrinsicCall(p, .handle_access);
        return;
    }
    if (std.mem.startsWith(u8, a, "@entry_addr(") and std.mem.endsWith(u8, a, ")")) {
        var entry_name = std.mem.trim(u8, a["@entry_addr(".len..a.len-1], " \t");
        if (entry_name.len >= 2 and entry_name[0] == '"' and entry_name[entry_name.len-1] == '"') {
            entry_name = entry_name[1..entry_name.len-1];
        }
        const label_id = try allocLabelId(p, "exp_{s}", .{entry_name});
        try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(255, 0) });
        const disp_off = p.cbuf.bytes.items.len - 4;
        std.debug.print("@entry_addr: entry_name={s} label_id={} disp_off={}\n", .{entry_name, label_id, disp_off});
        try p.cbuf.fixups.append(.{ .offset = disp_off, .disp_size = 4, .label_id = label_id });
        return;
    }
    if (std.mem.startsWith(u8, a, "malloc(") and std.mem.endsWith(u8, a, ")")) {
        const size_expr = std.mem.trim(u8, a["malloc(".len..a.len-1], " \t");
        const sz_val = parseNumber(size_expr);
        try abi.emitCallArgs(&p.cbuf.bytes, &.{});
        try emitIatCall(p, 4);
        try abi.emitCallCleanup(&p.cbuf.bytes);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
        try emitXorReg(p, Reg.RDX);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_IMM64, &.{ x64.Operand.r(Reg.R8), x64.Operand.imm(sz_val) });
        try abi.emitCallArgs(&p.cbuf.bytes, &.{});
        try emitIatCall(p, 5);
        try abi.emitCallCleanup(&p.cbuf.bytes);
        return;
    }
    if (std.mem.startsWith(u8, a, "ptr_load(") and std.mem.endsWith(u8, a, ")")) {
        const inner = std.mem.trim(u8, a["ptr_load(".len..a.len-1], " \t");
        try emitExprToRAX(p, inner, current_state);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RAX, 0) });
        return;
    }
    if (std.mem.startsWith(u8, a, "addr(") and std.mem.endsWith(u8, a, ")")) {
        const var_name = std.mem.trim(u8, a["addr(".len..a.len-1], " \t");
        const vo = getVarOffset(p, current_state, var_name);
        if (vo != std.math.minInt(i32)) {
            const base_reg = getVarBaseReg(p, current_state, var_name);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(base_reg, vo) });
        } else {
            try emitXorReg(p, Reg.RAX);
        }
        return;
    }
    if (a.len > 1 and a[0] == '&') {
        const var_name = std.mem.trim(u8, a[1..], " \t");
        const vo = getVarOffset(p, current_state, var_name);
        if (vo != std.math.minInt(i32)) {
            const base_reg = getVarBaseReg(p, current_state, var_name);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(base_reg, vo) });
        } else {
            try emitXorReg(p, Reg.RAX);
        }
        return;
    }
    if (std.mem.startsWith(u8, a, "*")) {
        const ptr_name = std.mem.trim(u8, a[1..], " \t");
        if (!try tryLoadVarToReg(p, Reg.RAX, ptr_name, current_state)) try emitXorReg(p, Reg.RAX);
        try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RAX, 0) });
        return;
    }
    // reinterpret_cast<T>(expr) → strip cast, eval inner expr
    if (std.mem.startsWith(u8, a, "reinterpret_cast<")) {
        const gt = std.mem.indexOfScalar(u8, a, '>') orelse {
            try emitXorReg(p, Reg.RAX);
            return;
        };
        const after_gt = std.mem.trimLeft(u8, a[gt+1..], " \t");
        if (after_gt.len > 0 and after_gt[0] == '(') {
            const close_paren = std.mem.lastIndexOfScalar(u8, after_gt, ')') orelse {
                try emitXorReg(p, Reg.RAX);
                return;
            };
            const inner = std.mem.trim(u8, after_gt[1..close_paren], " \t");
            try emitExprToRAX(p, inner, current_state);
            return;
        }
    }
    // Array index: base[index]
    if (std.mem.indexOfScalar(u8, a, '[')) |bracket| {
        if (bracket > 0) {
            const close_bracket = std.mem.indexOfScalar(u8, a, ']') orelse {
                try emitXorReg(p, Reg.RAX);
                return;
            };
            const base_name = std.mem.trim(u8, a[0..bracket], " \t");
            const index_expr = std.mem.trim(u8, a[bracket+1..close_bracket], " \t");
            // Compute base address
            try emitExprAtomToRAX(p, base_name, current_state);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
            // Compute address: base + index*8
            try emitExprToRAX(p, index_expr, current_state);
            try x64.emit(&p.cbuf.bytes, .LEA_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.memIdx(Reg.RBX, Reg.RAX, 3, 0) });
            // Load from computed address
            try x64.emit(&p.cbuf.bytes, .MOV_R64_MEM, &.{ x64.Operand.r(Reg.RAX), x64.Operand.mem(Reg.RAX, 0) });
            return;
        }
    }
    // Enum variant access: EnumName.Variant
    if (std.mem.indexOfScalar(u8, a, '.')) |_| {
        if (p.enum_defs.get(a)) |val| {
            try emitLoadImm(p, Reg.RAX, val);
            return;
        }
    }
    // Struct field access: var.fieldname
    if (std.mem.indexOfScalar(u8, a, '.')) |dot| {
        const struct_var = a[0..dot];
        const field_name = a[dot+1..];
        const struct_vo = getVarOffset(p, current_state, struct_var);
        if (struct_vo != std.math.minInt(i32)) {
            const struct_type = getVarTypeName(p, current_state, struct_var);
            if (isStructType(p, struct_type)) {
                if (getStructFieldOffset(p, struct_type, field_name)) |field_off| {
                    const base_reg = getVarBaseReg(p, current_state, struct_var);
                    const field_addr = struct_vo + @as(i32, @intCast(field_off));
                    const field_type = getStructFieldType(p, struct_type, field_name);
                    const field_size = if (isStructType(p, field_type)) getStructFieldSize(p, field_type) else getTypeSize(field_type);
                    try emitLoadVarToReg(p, Reg.RAX, field_addr, field_size, base_reg);
                    return;
                }
            }
        }
    }
    if (!try tryLoadVarToReg(p, Reg.RAX, a, current_state)) {
        const n = parseNumber(a);
        if (n != 0 or (a.len > 0 and (std.ascii.isDigit(a[0]) or a[0] == '-'))) {
            try emitLoadImm(p, Reg.RAX, n);
        } else {
            // Try import table (Win32 API function as expression)
            var found_import = false;
            for (IMPORT_FNS, 0..) |import_name, import_idx| {
                if (std.mem.eql(u8, a, import_name)) {
                    try emitRipLeaIat(p, Reg.RAX, import_idx);
                    found_import = true;
                    break;
                }
            }
            if (!found_import) try emitXorReg(p, Reg.RAX);
        }
    }
}

fn tryLoadVarToReg(p: *PendingOutput, reg: i16, name: []const u8, state: []const u8) !bool {
    const vo = getVarOffset(p, state, name);
    if (vo != std.math.minInt(i32)) {
        const size = getVarSize(p, state, name);
        try emitLoadVarToReg(p, reg, vo, size, getVarBaseReg(p, state, name));
        return true;
    }
    return false;
}

fn isFloatVar(p: *PendingOutput, state: []const u8, name: []const u8) bool {
    const vo = getVarOffset(p, state, name);
    if (vo == std.math.minInt(i32)) return false;
    const t = getVarTypeName(p, state, name);
    return isSimdType(t);
}

fn isFloatExpr(p: *PendingOutput, state: []const u8, expr: []const u8) bool {
    for (expr, 0..) |c, i| {
        if (c == '.' and i > 0 and i < expr.len - 1 and std.ascii.isDigit(expr[i-1]) and std.ascii.isDigit(expr[i+1])) {
            return true;
        }
    }
    const brk = std.mem.indexOfScalar(u8, expr, '[');
    if (brk) |b| {
        const img_name = std.mem.trim(u8, expr[0..b], " \t");
        const t = getVarTypeName(p, state, img_name);
        if (std.mem.eql(u8, t, "image<f32>")) return true;
    }
    var it = std.mem.tokenizeAny(u8, expr, " \t+-*/()");
    while (it.next()) |token| {
        if (token.len > 0 and isFloatVar(p, state, token)) return true;
    }
    return false;
}

fn getVarTypeName(p: *PendingOutput, state_name: []const u8, var_name: []const u8) []const u8 {
    for (p.ctx_vars.items) |cv| { if (std.mem.eql(u8, cv.name, var_name)) return cv.type_name; }
    if (p.state_vars.get(state_name)) |sv_list| { for (sv_list.items) |sv| { if (std.mem.eql(u8, sv.name, var_name)) return sv.type_name; } }
    if (p.entry_var_types.get(var_name)) |tn| return tn;
    return "int64";
}

const Expr = union(enum) {
    Const: f32,
    Var: []const u8,
    Add: struct { lhs: usize, rhs: usize },
    Sub: struct { lhs: usize, rhs: usize },
    Mul: struct { lhs: usize, rhs: usize },
    VecSplat: usize,
    VecSwizzle: struct { src: usize, mask: u8 },
    ImageLoad: struct { img: []const u8, x: usize, y: usize, elem_size: u32 },
    Dot: struct { lhs: usize, rhs: usize },
    Div: struct { lhs: usize, rhs: usize },
    Min: struct { lhs: usize, rhs: usize },
    Max: struct { lhs: usize, rhs: usize },
    Sample: struct { img: []const u8, u: usize, v: usize },
    Floor: usize,
    Sqrt: usize,
    Rsqrt: usize,
    Deref: []const u8,
};

fn pushExpr(p: *PendingOutput, expr: Expr) anyerror!usize {
    const idx = p.expr_arena.items.len;
    try p.expr_arena.append(expr);
    try p.value_uses.append(0);
    switch (expr) {
        .Add => |info| {
            p.value_uses.items[info.lhs] += 1;
            p.value_uses.items[info.rhs] += 1;
        },
        .Sub => |info| {
            p.value_uses.items[info.lhs] += 1;
            p.value_uses.items[info.rhs] += 1;
        },
        .Mul => |info| {
            p.value_uses.items[info.lhs] += 1;
            p.value_uses.items[info.rhs] += 1;
        },
        .Div => |info| {
            p.value_uses.items[info.lhs] += 1;
            p.value_uses.items[info.rhs] += 1;
        },
        .Min => |info| {
            p.value_uses.items[info.lhs] += 1;
            p.value_uses.items[info.rhs] += 1;
        },
        .Max => |info| {
            p.value_uses.items[info.lhs] += 1;
            p.value_uses.items[info.rhs] += 1;
        },
        .Sample => |s| {
            p.value_uses.items[s.u] += 1;
            p.value_uses.items[s.v] += 1;
        },
        .Floor => |inner| p.value_uses.items[inner] += 1,
        .Sqrt => |inner| p.value_uses.items[inner] += 1,
        .Rsqrt => |inner| p.value_uses.items[inner] += 1,
        .Dot => |d| {
            p.value_uses.items[d.lhs] += 1;
            p.value_uses.items[d.rhs] += 1;
        },
        else => {},
    }
    return idx;
}

fn skipSpaces(src: []const u8, pos: *usize) void {
    while (pos.* < src.len and (src[pos.*] == ' ' or src[pos.*] == '\t')) pos.* += 1;
}

fn parseAtom(p: *PendingOutput, src: []const u8, pos: *usize) anyerror!usize {
    skipSpaces(src, pos);
    if (pos.* >= src.len) return pushExpr(p, .{ .Const = 0 });

    if (src[pos.*] == '(') {
        pos.* += 1;
        const idx = try parseAddSub(p, src, pos);
        skipSpaces(src, pos);
        if (pos.* < src.len and src[pos.*] == ')') pos.* += 1;
        return idx;
    }

    if (pos.* < src.len and ((src[pos.*] == '-' and pos.* + 1 < src.len and std.ascii.isDigit(src[pos.* + 1])) or std.ascii.isDigit(src[pos.*]) or src[pos.*] == '.')) {
        const start = pos.*;
        if (src[pos.*] == '-') pos.* += 1;
        while (pos.* < src.len and (std.ascii.isDigit(src[pos.*]) or src[pos.*] == '.')) pos.* += 1;
        const val = std.fmt.parseFloat(f32, src[start..pos.*]) catch 0;
        return pushExpr(p, .{ .Const = val });
    }

    if (src[pos.*] == '*') {
        pos.* += 1;
        skipSpaces(src, pos);
        const start = pos.*;
        while (pos.* < src.len and (std.ascii.isAlphanumeric(src[pos.*]) or src[pos.*] == '_')) pos.* += 1;
        const ptr_var = src[start..pos.*];
        return pushExpr(p, .{ .Deref = ptr_var });
    }

    if (std.ascii.isAlphabetic(src[pos.*]) or src[pos.*] == '_') {
        const start = pos.*;
        while (pos.* < src.len and (std.ascii.isAlphanumeric(src[pos.*]) or src[pos.*] == '_' or src[pos.*] == '<' or src[pos.*] == '>')) pos.* += 1;
        const name = src[start..pos.*];
        skipSpaces(src, pos);
        if (pos.* < src.len and src[pos.*] == '(') {
            pos.* += 1;
            if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
                const a = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const b = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ')') pos.* += 1;
                if (std.mem.eql(u8, name, "min")) return pushExpr(p, .{ .Min = .{ .lhs = a, .rhs = b } });
                return pushExpr(p, .{ .Max = .{ .lhs = a, .rhs = b } });
            }
            if (std.mem.eql(u8, name, "rcp")) {
                const a = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ')') pos.* += 1;
                const one = try pushExpr(p, .{ .Const = 1.0 });
                return pushExpr(p, .{ .Div = .{ .lhs = one, .rhs = a } });
            }
            if (std.mem.eql(u8, name, "lerp")) {
                const a = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const b = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const t = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ')') pos.* += 1;
                // a + t * (b - a)
                const b_minus_a = try pushExpr(p, .{ .Sub = .{ .lhs = b, .rhs = a } });
                const t_times = try pushExpr(p, .{ .Mul = .{ .lhs = t, .rhs = b_minus_a } });
                return pushExpr(p, .{ .Add = .{ .lhs = a, .rhs = t_times } });
            }
            if (std.mem.eql(u8, name, "med3")) {
                const a = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const b = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const c = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ')') pos.* += 1;
                // max(min(a,b), min(max(a,b), c))
                const min_ab = try pushExpr(p, .{ .Min = .{ .lhs = a, .rhs = b } });
                const max_ab = try pushExpr(p, .{ .Max = .{ .lhs = a, .rhs = b } });
                const min_maxab_c = try pushExpr(p, .{ .Min = .{ .lhs = max_ab, .rhs = c } });
                return pushExpr(p, .{ .Max = .{ .lhs = min_ab, .rhs = min_maxab_c } });
            }
            if (std.mem.eql(u8, name, "floor") or std.mem.eql(u8, name, "sqrt") or std.mem.eql(u8, name, "rsqrt") or std.mem.eql(u8, name, "abs") or std.mem.eql(u8, name, "frac") or std.mem.eql(u8, name, "saturate")) {
                const a = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ')') pos.* += 1;
                if (std.mem.eql(u8, name, "floor")) return pushExpr(p, .{ .Floor = a });
                if (std.mem.eql(u8, name, "sqrt")) return pushExpr(p, .{ .Sqrt = a });
                if (std.mem.eql(u8, name, "rsqrt")) return pushExpr(p, .{ .Rsqrt = a });
                if (std.mem.eql(u8, name, "abs")) {
                    // abs(x) -> max(x, 0.0 - x)
                    const zero = try pushExpr(p, .{ .Const = 0 });
                    const neg = try pushExpr(p, .{ .Sub = .{ .lhs = zero, .rhs = a } });
                    return try pushExpr(p, .{ .Max = .{ .lhs = a, .rhs = neg } });
                }
                if (std.mem.eql(u8, name, "frac")) {
                    // frac(x) -> x - floor(x)
                    const floored = try pushExpr(p, .{ .Floor = a });
                    return try pushExpr(p, .{ .Sub = .{ .lhs = a, .rhs = floored } });
                }
                // saturate(x) -> min(1.0, max(0.0, x))
                const zero = try pushExpr(p, .{ .Const = 0 });
                const one = try pushExpr(p, .{ .Const = 1.0 });
                const maxed = try pushExpr(p, .{ .Max = .{ .lhs = zero, .rhs = a } });
                return try pushExpr(p, .{ .Min = .{ .lhs = one, .rhs = maxed } });
            }
            if (std.mem.eql(u8, name, "dot")) {
                const a = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const b = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ')') pos.* += 1;
                return pushExpr(p, .{ .Dot = .{ .lhs = a, .rhs = b } });
            }
            if (std.mem.eql(u8, name, "sample_v4")) {
                skipSpaces(src, pos);
                const img_start = pos.*;
                while (pos.* < src.len and (std.ascii.isAlphanumeric(src[pos.*]) or src[pos.*] == '_')) pos.* += 1;
                const img_name = src[img_start..pos.*];
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const u_idx = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const v_idx = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ')') pos.* += 1;
                return pushExpr(p, .{ .ImageLoad = .{ .img = img_name, .x = u_idx, .y = v_idx, .elem_size = 4 } });
            }
            if (std.mem.eql(u8, name, "sample_offset_v4")) {
                skipSpaces(src, pos);
                const img_start = pos.*;
                while (pos.* < src.len and (std.ascii.isAlphanumeric(src[pos.*]) or src[pos.*] == '_')) pos.* += 1;
                const img_name = src[img_start..pos.*];
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const u_idx = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const v_idx = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const du_idx = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const dv_idx = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ')') pos.* += 1;
                const u_plus_du = try pushExpr(p, .{ .Add = .{ .lhs = u_idx, .rhs = du_idx } });
                const v_plus_dv = try pushExpr(p, .{ .Add = .{ .lhs = v_idx, .rhs = dv_idx } });
                return pushExpr(p, .{ .ImageLoad = .{ .img = img_name, .x = u_plus_du, .y = v_plus_dv, .elem_size = 4 } });
            }
            if (std.mem.eql(u8, name, "sample")) {
                skipSpaces(src, pos);
                const img_start = pos.*;
                while (pos.* < src.len and (std.ascii.isAlphanumeric(src[pos.*]) or src[pos.*] == '_')) pos.* += 1;
                const img_name = src[img_start..pos.*];
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const u_idx = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
                const v_idx = try parseAddSub(p, src, pos);
                skipSpaces(src, pos);
                if (pos.* < src.len and src[pos.*] == ')') pos.* += 1;
                return pushExpr(p, .{ .Sample = .{ .img = img_name, .u = u_idx, .v = v_idx } });
            }
            const inner = try parseAddSub(p, src, pos);
            skipSpaces(src, pos);
            if (pos.* < src.len and src[pos.*] == ')') pos.* += 1;
            return pushExpr(p, .{ .VecSplat = inner });
        }
        if (pos.* < src.len and src[pos.*] == '[') {
            pos.* += 1;
            const x_idx = try parseAddSub(p, src, pos);
            skipSpaces(src, pos);
            if (pos.* < src.len and src[pos.*] == ',') pos.* += 1;
            const y_idx = try parseAddSub(p, src, pos);
            skipSpaces(src, pos);
            if (pos.* < src.len and src[pos.*] == ']') pos.* += 1;
            return pushExpr(p, .{ .ImageLoad = .{ .img = name, .x = x_idx, .y = y_idx, .elem_size = 4 } });
        }
        const var_idx = try pushExpr(p, .{ .Var = name });
        skipSpaces(src, pos);
        if (pos.* < src.len and src[pos.*] == '.') {
            pos.* += 1;
            var mask: u8 = 0;
            const swiz_start = pos.*;
            while (pos.* < src.len and (src[pos.*] == 'x' or src[pos.*] == 'y' or src[pos.*] == 'z' or src[pos.*] == 'w')) pos.* += 1;
            const swiz = src[swiz_start..pos.*];
            for (swiz, 0..) |ch, i| {
                const lane: u8 = if (ch == 'x') @as(u8, 0) else if (ch == 'y') @as(u8, 1) else if (ch == 'z') @as(u8, 2) else @as(u8, 3);
                mask |= lane << @as(u3, @intCast(i * 2));
            }
            if (swiz.len > 0) return pushExpr(p, .{ .VecSwizzle = .{ .src = var_idx, .mask = mask } });
        }
        return var_idx;
    }

    pos.* += 1;
    return pushExpr(p, .{ .Const = 0 });
}

fn parseMulDiv(p: *PendingOutput, src: []const u8, pos: *usize) anyerror!usize {
    var lhs = try parseAtom(p, src, pos);
    while (true) {
        skipSpaces(src, pos);
        if (pos.* >= src.len) break;
        if (src[pos.*] == '*') {
            pos.* += 1;
            const rhs = try parseAtom(p, src, pos);
            lhs = try pushExpr(p, .{ .Mul = .{ .lhs = lhs, .rhs = rhs } });
        } else if (src[pos.*] == '/') {
            pos.* += 1;
            const rhs = try parseAtom(p, src, pos);
            lhs = try pushExpr(p, .{ .Div = .{ .lhs = lhs, .rhs = rhs } });
        } else {
            break;
        }
    }
    return lhs;
}

fn parseAddSub(p: *PendingOutput, src: []const u8, pos: *usize) anyerror!usize {
    var lhs = try parseMulDiv(p, src, pos);
    while (true) {
        skipSpaces(src, pos);
        if (pos.* >= src.len) break;
        if (src[pos.*] == '+') {
            pos.* += 1;
            const rhs = try parseMulDiv(p, src, pos);
            lhs = try pushExpr(p, .{ .Add = .{ .lhs = lhs, .rhs = rhs } });
        } else if (src[pos.*] == '-') {
            pos.* += 1;
            const rhs = try parseMulDiv(p, src, pos);
            lhs = try pushExpr(p, .{ .Sub = .{ .lhs = lhs, .rhs = rhs } });
        } else {
            break;
        }
    }
    return lhs;
}

fn consumeValue(p: *PendingOutput, value_id: usize) void {
    if (p.value_uses.items[value_id] > 0) {
        p.value_uses.items[value_id] -= 1;
    }
}

fn releaseValue(p: *PendingOutput, value_id: usize, reg: i16) void {
    const count = &p.value_uses.items[value_id];
    if (count.* > 0) count.* -= 1;
    if (count.* == 0) freeXmm(p, reg);
}

fn emitValue(p: *PendingOutput, value_id: usize, state: []const u8, simd_size: u32) anyerror!i16 {
    if (p.value_cache.get(value_id)) |r| return r;
    const r = try emitValueImpl(p, value_id, state, simd_size);
    try p.value_cache.put(value_id, r);
    return r;
}

fn emitValueImpl(p: *PendingOutput, value_id: usize, state: []const u8, simd_size: u32) anyerror!i16 {
    const expr = p.expr_arena.items[value_id];
    switch (expr) {
        .Const => |val| {
            const r = allocXmm(p);
            if (val == 0) {
                try emitXorXmm(p, r);
            } else {
                const bits = @as(u32, @bitCast(@as(f32, @floatCast(val))));
                try emitMovRegImm32(p, Reg.RAX, bits);
                try x64.emit(&p.cbuf.bytes, .SSE_MOVD_LD, &.{ x64.Operand.xmm(r), x64.Operand.r(Reg.RAX) });
                if (simd_size == 16) {
                    try x64.emit(&p.cbuf.bytes, .SSE_SHUFPS, &.{ x64.Operand.xmm(r), x64.Operand.xmm(r), x64.Operand.immU32(0) });
                }
            }
            return r;
        },
        .Var => |name| {
            const vo = getVarOffset(p, state, name);
            if (vo != std.math.minInt(i32)) {
                const r = allocXmm(p);
                if (p.in_for_loop and (std.mem.eql(u8, name, "x") or std.mem.eql(u8, name, "y"))) {
                    try emitLoadVarToReg(p, Reg.RAX, vo, 4, Reg.RBP);
                    try x64.emit(&p.cbuf.bytes, .SSE_CVTSI2SS, &.{ x64.Operand.xmm(r), x64.Operand.r(Reg.RAX) });
                } else if (!isSimdType(getVarTypeName(p, state, name))) {
                    try emitLoadVarToReg(p, Reg.RAX, vo, 4, getVarBaseReg(p, state, name));
                    if (std.mem.eql(u8, getVarTypeName(p, state, name), "float")) {
                        try x64.emit(&p.cbuf.bytes, .SSE_MOVD_LD, &.{ x64.Operand.xmm(r), x64.Operand.r(Reg.RAX) });
                    } else {
                        try x64.emit(&p.cbuf.bytes, .SSE_CVTSI2SS, &.{ x64.Operand.xmm(r), x64.Operand.r(Reg.RAX) });
                    }
                } else {
                    try emitLoadXmmToReg(p, r, vo, simd_size, getVarBaseReg(p, state, name));
                }
                return r;
            }
            const r = allocXmm(p);
            try emitXorXmm(p, r);
            return r;
        },
        .Deref => |ptr_var| {
            const ptr_vo = getVarOffset(p, state, ptr_var);
            if (ptr_vo == std.math.minInt(i32)) {
                const r = allocXmm(p);
                try emitXorXmm(p, r);
                return r;
            }
            try emitLoadVarToReg(p, Reg.RAX, ptr_vo, 8, getVarBaseReg(p, state, ptr_var));
            const r = allocXmm(p);
            try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(r), x64.Operand.mem(Reg.RAX, 0) });
            return r;
        },
        .Add => |info| {
            const lhs_reg = try emitValue(p, info.lhs, state, simd_size);
            const rhs_reg = try emitValue(p, info.rhs, state, simd_size);
            try emitSseArith(p, lhs_reg, rhs_reg, .SSE_ADDPS, .SSE_ADDSS, simd_size);
            consumeValue(p, info.lhs);
            releaseValue(p, info.rhs, rhs_reg);
            return lhs_reg;
        },
        .Sub => |info| {
            const lhs_reg = try emitValue(p, info.lhs, state, simd_size);
            const rhs_reg = try emitValue(p, info.rhs, state, simd_size);
            try emitSseArith(p, lhs_reg, rhs_reg, .SSE_SUBPS, .SSE_SUBSS, simd_size);
            consumeValue(p, info.lhs);
            releaseValue(p, info.rhs, rhs_reg);
            return lhs_reg;
        },
        .Mul => |info| {
            const lhs_reg = try emitValue(p, info.lhs, state, simd_size);
            const rhs_reg = try emitValue(p, info.rhs, state, simd_size);
            try emitSseArith(p, lhs_reg, rhs_reg, .SSE_MULPS, .SSE_MULSS, simd_size);
            consumeValue(p, info.lhs);
            releaseValue(p, info.rhs, rhs_reg);
            return lhs_reg;
        },
        .Div => |info| {
            const lhs_reg = try emitValue(p, info.lhs, state, simd_size);
            const rhs_reg = try emitValue(p, info.rhs, state, simd_size);
            try emitSseArith(p, lhs_reg, rhs_reg, .SSE_DIVPS, .SSE_DIVSS, simd_size);
            consumeValue(p, info.lhs);
            releaseValue(p, info.rhs, rhs_reg);
            return lhs_reg;
        },
        .Min => |info| {
            const lhs_reg = try emitValue(p, info.lhs, state, simd_size);
            const rhs_reg = try emitValue(p, info.rhs, state, simd_size);
            try emitSseArith(p, lhs_reg, rhs_reg, .SSE_MINPS, .SSE_MINSS, simd_size);
            consumeValue(p, info.lhs);
            releaseValue(p, info.rhs, rhs_reg);
            return lhs_reg;
        },
        .Max => |info| {
            const lhs_reg = try emitValue(p, info.lhs, state, simd_size);
            const rhs_reg = try emitValue(p, info.rhs, state, simd_size);
            try emitSseArith(p, lhs_reg, rhs_reg, .SSE_MAXPS, .SSE_MAXSS, simd_size);
            consumeValue(p, info.lhs);
            releaseValue(p, info.rhs, rhs_reg);
            return lhs_reg;
        },
        .Floor => |inner| {
            const inner_reg = try emitValue(p, inner, state, simd_size);
            const mode: u32 = 1; // 1 = round down (floor)
            try x64.emit(&p.cbuf.bytes, .SSE_ROUNDSS, &.{ x64.Operand.xmm(inner_reg), x64.Operand.xmm(inner_reg), x64.Operand.immU32(mode) });
            consumeValue(p, inner);
            return inner_reg;
        },
        .Sqrt => |inner| {
            const inner_reg = try emitValue(p, inner, state, simd_size);
            try x64.emit(&p.cbuf.bytes, .SSE_SQRTSS, &.{ x64.Operand.xmm(inner_reg), x64.Operand.xmm(inner_reg) });
            consumeValue(p, inner);
            return inner_reg;
        },
        .Rsqrt => |inner| {
            const inner_reg = try emitValue(p, inner, state, simd_size);
            try x64.emit(&p.cbuf.bytes, .SSE_RSQRTSS, &.{ x64.Operand.xmm(inner_reg), x64.Operand.xmm(inner_reg) });
            consumeValue(p, inner);
            return inner_reg;
        },
        .Dot => |d| {
            const lhs_reg = try emitValue(p, d.lhs, state, 16);
            const rhs_reg = try emitValue(p, d.rhs, state, 16);
            try x64.emit(&p.cbuf.bytes, .SSE_MULPS, &.{ x64.Operand.xmm(lhs_reg), x64.Operand.xmm(rhs_reg) });
            try x64.emit(&p.cbuf.bytes, .SSE_HADDPS, &.{ x64.Operand.xmm(lhs_reg), x64.Operand.xmm(lhs_reg) });
            try x64.emit(&p.cbuf.bytes, .SSE_HADDPS, &.{ x64.Operand.xmm(lhs_reg), x64.Operand.xmm(lhs_reg) });
            consumeValue(p, d.lhs);
            releaseValue(p, d.rhs, rhs_reg);
            return lhs_reg;
        },
        .VecSplat => |inner| {
            const inner_reg = try emitValue(p, inner, state, 4);
            if (simd_size >= 16) {
                try x64.emit(&p.cbuf.bytes, .SSE_SHUFPS, &.{ x64.Operand.xmm(inner_reg), x64.Operand.xmm(inner_reg), x64.Operand.immU32(0) });
            }
            consumeValue(p, inner);
            return inner_reg;
        },
        .VecSwizzle => |vs| {
            const src_reg = try emitValue(p, vs.src, state, simd_size);
            if (simd_size >= 16) {
                try x64.emit(&p.cbuf.bytes, .SSE_SHUFPS, &.{ x64.Operand.xmm(src_reg), x64.Operand.xmm(src_reg), x64.Operand.immU32(vs.mask) });
            }
            consumeValue(p, vs.src);
            return src_reg;
        },
        .ImageLoad => |il| {
            const img_vo = getVarOffset(p, state, il.img);
            if (img_vo == std.math.minInt(i32)) {
                const r = allocXmm(p);
                try emitXorXmm(p, r);
                return r;
            }
            try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, state, il.img));
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RAX, 0) });
            try emitIntToRdx(p, il.y, state);
            try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RCX) });
            try emitIntToRax(p, il.x, state);
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
            switch (il.elem_size) {
                4 => try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(2) }),
                16 => try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(4) }),
                else => {
                    try emitLoadImm(p, Reg.R8, il.elem_size);
                    try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
                },
            }
            try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, state, il.img));
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RDX) });
            const r = allocXmm(p);
            const mem = x64.Operand.mem(Reg.RAX, 0);
            switch (simd_size) {
                4 => try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(r), mem }),
                8 => try x64.emit(&p.cbuf.bytes, .SSE_MOVSD_LD, &.{ x64.Operand.xmm(r), mem }),
                16 => try x64.emit(&p.cbuf.bytes, .SSE_MOVUPS_LD, &.{ x64.Operand.xmm(r), mem }),
                else => try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(r), mem }),
            }
            return r;
        },
        .Sample => |s| {
            const img_vo = getVarOffset(p, state, s.img);
            if (img_vo == std.math.minInt(i32)) {
                const r = allocXmm(p);
                try emitXorXmm(p, r);
                return r;
            }
            const u_reg = try emitValue(p, s.u, state, 4);
            const v_reg = try emitValue(p, s.v, state, 4);
            const fx = allocXmm(p);
            const fy = allocXmm(p);
            const p00 = allocXmm(p);
            const p10 = allocXmm(p);
            const p01 = allocXmm(p);
            const p11 = allocXmm(p);
            try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, state, s.img));
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RAX, 0) });
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.R10), x64.Operand.mem(Reg.RAX, 4) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R12), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R13), x64.Operand.r(Reg.R10) });
            try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.R12), x64.Operand.immU32(1) });
            try x64.emit(&p.cbuf.bytes, .SUB_R64_IMM32, &.{ x64.Operand.r(Reg.R13), x64.Operand.immU32(1) });
            try x64.emit(&p.cbuf.bytes, .SSE_CVTSI2SS, &.{ x64.Operand.xmm(p00), x64.Operand.r(Reg.R12) });
            try x64.emit(&p.cbuf.bytes, .SSE_MINSS, &.{ x64.Operand.xmm(u_reg), x64.Operand.xmm(p00) });
            try emitXorXmm(p, p00);
            try x64.emit(&p.cbuf.bytes, .SSE_MAXSS, &.{ x64.Operand.xmm(u_reg), x64.Operand.xmm(p00) });
            try x64.emit(&p.cbuf.bytes, .SSE_CVTSI2SS, &.{ x64.Operand.xmm(p00), x64.Operand.r(Reg.R13) });
            try x64.emit(&p.cbuf.bytes, .SSE_MINSS, &.{ x64.Operand.xmm(v_reg), x64.Operand.xmm(p00) });
            try emitXorXmm(p, p00);
            try x64.emit(&p.cbuf.bytes, .SSE_MAXSS, &.{ x64.Operand.xmm(v_reg), x64.Operand.xmm(p00) });
            try x64.emit(&p.cbuf.bytes, .SSE_CVTTSS2SI, &.{ x64.Operand.r(Reg.R8), x64.Operand.xmm(u_reg) });
            try x64.emit(&p.cbuf.bytes, .SSE_CVTTSS2SI, &.{ x64.Operand.r(Reg.R9), x64.Operand.xmm(v_reg) });
            try x64.emit(&p.cbuf.bytes, .SSE_CVTSI2SS, &.{ x64.Operand.xmm(p00), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(fx), x64.Operand.xmm(u_reg) });
            try x64.emit(&p.cbuf.bytes, .SSE_SUBSS, &.{ x64.Operand.xmm(fx), x64.Operand.xmm(p00) });
            try x64.emit(&p.cbuf.bytes, .SSE_CVTSI2SS, &.{ x64.Operand.xmm(p00), x64.Operand.r(Reg.R9) });
            try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(fy), x64.Operand.xmm(v_reg) });
            try x64.emit(&p.cbuf.bytes, .SSE_SUBSS, &.{ x64.Operand.xmm(fy), x64.Operand.xmm(p00) });
            consumeValue(p, s.u);
            consumeValue(p, s.v);
            releaseValue(p, s.u, u_reg);
            releaseValue(p, s.v, v_reg);
            try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, state, s.img));
            try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RAX, 0) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R9) });
            try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R11), x64.Operand.immU32(2) });
            try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, state, s.img));
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R11) });
            try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(p00), x64.Operand.mem(Reg.RAX, 0) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R9) });
            try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(1) });
            try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R12) });
            {
                const lbl = try allocLabelId(p, "clamp_x1_{d}", .{p.cbuf.label_names.items.len});
                try emitCondLongJmp(p, .JLE_REL32, lbl);
                try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R12) });
                try setLabel(p, lbl);
            }
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R11), x64.Operand.immU32(2) });
            try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, state, s.img));
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R11) });
            try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(p10), x64.Operand.mem(Reg.RAX, 0) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R9) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.R11), x64.Operand.immU32(1) });
            try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R13) });
            {
                const lbl = try allocLabelId(p, "clamp_y1_{d}", .{p.cbuf.label_names.items.len});
                try emitCondLongJmp(p, .JLE_REL32, lbl);
                try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R13) });
                try setLabel(p, lbl);
            }
            try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R11), x64.Operand.immU32(2) });
            try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, state, s.img));
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R11) });
            try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(p01), x64.Operand.mem(Reg.RAX, 0) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R9) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.R11), x64.Operand.immU32(1) });
            try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R13) });
            {
                const lbl = try allocLabelId(p, "clamp_yp11_{d}", .{p.cbuf.label_names.items.len});
                try emitCondLongJmp(p, .JLE_REL32, lbl);
                try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.R13) });
                try setLabel(p, lbl);
            }
            try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RDX), x64.Operand.immU32(1) });
            try x64.emit(&p.cbuf.bytes, .CMP_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R12) });
            {
                const lbl = try allocLabelId(p, "clamp_xp11_{d}", .{p.cbuf.label_names.items.len});
                try emitCondLongJmp(p, .JLE_REL32, lbl);
                try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R12) });
                try setLabel(p, lbl);
            }
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.R11), x64.Operand.r(Reg.RDX) });
            try x64.emit(&p.cbuf.bytes, .SHIFT_LEFT, &.{ x64.Operand.r(Reg.R11), x64.Operand.immU32(2) });
            try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, state, s.img));
            try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.R11) });
            try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(p11), x64.Operand.mem(Reg.RAX, 0) });
            const top = allocXmm(p);
            try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(top), x64.Operand.xmm(p10) });
            try x64.emit(&p.cbuf.bytes, .SSE_SUBSS, &.{ x64.Operand.xmm(top), x64.Operand.xmm(p00) });
            try x64.emit(&p.cbuf.bytes, .SSE_MULSS, &.{ x64.Operand.xmm(top), x64.Operand.xmm(fx) });
            try x64.emit(&p.cbuf.bytes, .SSE_ADDSS, &.{ x64.Operand.xmm(top), x64.Operand.xmm(p00) });
            try x64.emit(&p.cbuf.bytes, .SSE_SUBSS, &.{ x64.Operand.xmm(p11), x64.Operand.xmm(p01) });
            try x64.emit(&p.cbuf.bytes, .SSE_MULSS, &.{ x64.Operand.xmm(p11), x64.Operand.xmm(fx) });
            try x64.emit(&p.cbuf.bytes, .SSE_ADDSS, &.{ x64.Operand.xmm(p11), x64.Operand.xmm(p01) });
            try x64.emit(&p.cbuf.bytes, .SSE_SUBSS, &.{ x64.Operand.xmm(p11), x64.Operand.xmm(top) });
            try x64.emit(&p.cbuf.bytes, .SSE_MULSS, &.{ x64.Operand.xmm(p11), x64.Operand.xmm(fy) });
            try x64.emit(&p.cbuf.bytes, .SSE_ADDSS, &.{ x64.Operand.xmm(p11), x64.Operand.xmm(top) });
            freeXmm(p, fx);
            freeXmm(p, fy);
            freeXmm(p, p00);
            freeXmm(p, p01);
            freeXmm(p, p10);
            freeXmm(p, top);
            return p11;
        },
    }
}

fn emitIntToRax(p: *PendingOutput, expr_idx: usize, state: []const u8) !void {
    const expr = p.expr_arena.items[expr_idx];
    switch (expr) {
        .Const => |val| try emitLoadImm(p, Reg.RAX, @as(i32, @intFromFloat(val))),
        .Var => |name| {
            const vo = getVarOffset(p, state, name);
            if (vo != std.math.minInt(i32)) {
                try emitLoadVarToReg(p, Reg.RAX, vo, 4, getVarBaseReg(p, state, name));
            } else {
                try emitLoadImm(p, Reg.RAX, 0);
            }
        },
        .Add => |info| {
            try emitIntToRax(p, info.lhs, state);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try emitIntToRax(p, info.rhs, state);
            try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RCX) });
        },
        .Sub => |info| {
            try emitIntToRax(p, info.lhs, state);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try emitIntToRax(p, info.rhs, state);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .SUB_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RDX) });
        },
        .Mul => |info| {
            try emitIntToRax(p, info.lhs, state);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try emitIntToRax(p, info.rhs, state);
            try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RCX) });
        },
        .Div => |info| {
            try emitIntToRax(p, info.lhs, state);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RCX), x64.Operand.r(Reg.RAX) });
            try emitIntToRax(p, info.rhs, state);
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RBX), x64.Operand.r(Reg.RAX) });
            try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RCX) });
            try x64.emit(&p.cbuf.bytes, .CQO, &.{});
            try x64.emit(&p.cbuf.bytes, .IDIV_R64, &.{ x64.Operand.r(Reg.RBX) });
        },
        else => try emitLoadImm(p, Reg.RAX, 0),
    }
}

fn emitIntToRdx(p: *PendingOutput, expr_idx: usize, state: []const u8) !void {
    try emitIntToRax(p, expr_idx, state);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
}

fn emitExprToXmm(p: *PendingOutput, expr: []const u8, current_state: []const u8, simd_size: u32) anyerror!i16 {
    p.value_cache.clearRetainingCapacity();
    var pos: usize = 0;
    const root = try parseAddSub(p, expr, &pos);
    return try emitValue(p, root, current_state, simd_size);
}

fn emitImagePixelLoad(p: *PendingOutput, img: []const u8, x: []const u8, y: []const u8, cs: []const u8, elem_size: u32) !i16 {
    const img_vo = getVarOffset(p, cs, img);
    if (img_vo == std.math.minInt(i32)) {
        const r = allocXmm(p);
        try emitXorXmm(p, r);
        return r;
    }
    try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, cs, img));
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RAX, 0) });
    try emitExprToRAX(p, y, cs);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RCX) });
    try emitExprToRAX(p, x, cs);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
    if (elem_size > 1) {
        try emitLoadImm(p, Reg.R8, elem_size);
        try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
    }
    try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, cs, img));
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RDX) });
    const r = allocXmm(p);
    const mem = x64.Operand.mem(Reg.RAX, 0);
    switch (elem_size) {
        4 => try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(r), mem }),
        8 => try x64.emit(&p.cbuf.bytes, .SSE_MOVSD_LD, &.{ x64.Operand.xmm(r), mem }),
        16 => try x64.emit(&p.cbuf.bytes, .SSE_MOVUPS_LD, &.{ x64.Operand.xmm(r), mem }),
        else => try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_LD, &.{ x64.Operand.xmm(r), mem }),
    }
    return r;
}

fn emitImagePixelStoreReg(p: *PendingOutput, img: []const u8, x: []const u8, y: []const u8, cs: []const u8, elem_size: u32, xmm_reg: i16) !void {
    const img_vo = getVarOffset(p, cs, img);
    if (img_vo == std.math.minInt(i32)) return;
    try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, cs, img));
    try x64.emit(&p.cbuf.bytes, .MOV_R32_MEM, &.{ x64.Operand.r(Reg.RCX), x64.Operand.mem(Reg.RAX, 0) });
    try emitExprToRAX(p, y, cs);
    try x64.emit(&p.cbuf.bytes, .MOV_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
    try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RCX) });
    try emitExprToRAX(p, x, cs);
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.RAX) });
    if (elem_size > 1) {
        try emitLoadImm(p, Reg.R8, elem_size);
        try x64.emit(&p.cbuf.bytes, .IMUL_R64_R64, &.{ x64.Operand.r(Reg.RDX), x64.Operand.r(Reg.R8) });
    }
    try emitLoadVarToReg(p, Reg.RAX, img_vo, 8, getVarBaseReg(p, cs, img));
    try x64.emit(&p.cbuf.bytes, .ADD_R64_IMM32, &.{ x64.Operand.r(Reg.RAX), x64.Operand.immU32(16) });
    try x64.emit(&p.cbuf.bytes, .ADD_R64_R64, &.{ x64.Operand.r(Reg.RAX), x64.Operand.r(Reg.RDX) });
    const mem = x64.Operand.mem(Reg.RAX, 0);
    switch (elem_size) {
        4 => try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_ST, &.{ mem, x64.Operand.xmm(xmm_reg) }),
        8 => try x64.emit(&p.cbuf.bytes, .SSE_MOVSD_ST, &.{ mem, x64.Operand.xmm(xmm_reg) }),
        16 => try x64.emit(&p.cbuf.bytes, .SSE_MOVUPS_ST, &.{ mem, x64.Operand.xmm(xmm_reg) }),
        else => try x64.emit(&p.cbuf.bytes, .SSE_MOVSS_ST, &.{ mem, x64.Operand.xmm(xmm_reg) }),
    }
}

fn allocXmm(p: *PendingOutput) i16 {
    for (0..16) |i| {
        if (!p.xmm_used[i]) {
            p.xmm_used[i] = true;
            return @intCast(i);
        }
    }
    return -1;
}

fn freeXmm(p: *PendingOutput, reg: i16) void {
    if (reg >= 0 and reg < 16) p.xmm_used[@intCast(reg)] = false;
}

fn emitXorXmm(p: *PendingOutput, xmm: i16) !void {
    try x64.emit(&p.cbuf.bytes, .SSE_XORPS, &.{ x64.Operand.xmm(xmm), x64.Operand.xmm(xmm) });
}

fn emitSseArith(p: *PendingOutput, dest: i16, src: i16, packed_op: x64.OpCode, scalar_op: x64.OpCode, simd_size: u32) !void {
    const op = if (simd_size == 4) scalar_op else packed_op;
    try x64.emit(&p.cbuf.bytes, op, &.{ x64.Operand.xmm(dest), x64.Operand.xmm(src) });
}









