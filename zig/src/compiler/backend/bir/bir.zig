const std = @import("std");
const Allocator = std.mem.Allocator;
pub const types = @import("bir_types.zig");
pub const TypeId = types.TypeId;
const INVALID_TYPE = types.INVALID_TYPE;
const AddressSpace = types.AddressSpace;
const ScalarKind = types.ScalarKind;

// ─── Value / IR identifiers ───

pub const ValueId = u32;
pub const BlockId = u32;
pub const FunctionId = u32;
pub const INVALID_ID: u32 = std.math.maxInt(u32);
pub const NO_VALUE: ValueId = 0;

// ─── Operations ───

pub const Op = enum {
    // Terminator
    br,
    cond_br,
    ret,
    unreachable_op,

    // Memory
    alloca,
    load,
    store,
    ptr_offset,
    ptr_to_int,
    int_to_ptr,

    // Arithmetic
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    max,
    min,

    // Float
    fadd,
    fsub,
    fmul,
    fdiv,
    fmod,
    fneg,
    fma,
    sqrt,
    rsqrt,
    exp,
    log,
    sin,
    cos,
    floor,
    ceil,
    frac,
    abs,
    saturate,
    lerp,

    // Integer comparison
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    // Float comparison
    feq,
    fne,
    flt,
    fle,
    fgt,
    fge,

    // Logical
    or_op,
    and_op,
    xor_op,
    not,
    shl,
    shr,
    shra,

    // Conversion
    cast,
    bitcast,
    sext,
    zext,
    trunc,
    fptosi,
    sitofp,
    fpext,
    fptrunc,

    // Aggregate
    composite,
    extract,
    insert,
    shuffle,

    // Vector
    splat,
    extract_element,
    insert_element,
    vector_add,
    vector_sub,
    vector_mul,
    vector_div,
    vector_dot,
    vector_cross,
    vector_normalize,
    vector_length,
    vector_reflect,
    vector_refract,

    // Matrix
    matrix_mul,
    matrix_transpose,
    matrix_inverse,
    matrix_determinant,

    // Memory model
    fence,
    atomic_add,
    atomic_sub,
    atomic_min,
    atomic_max,
    atomic_and,
    atomic_or,
    atomic_xor,
    atomic_xchg,
    atomic_cmpxchg,

    // GPU
    thread_id,
    block_id,
    thread_count,
    block_count,
    barrier,
    groupshared_barrier,
    wave_get_lane_index,
    wave_is_first_lane,
    wave_read_lane_first,
    wave_active_all_equal,
    quad_read_across_x,
    quad_read_across_y,
    groupshared_alloc,

    // Texture
    texture_sample,
    texture_load,
    texture_store,
    texture_gather,
    texture_query_dimensions,
    texture_query_lod,

    // Other
    call,
    phi,
    @"const",
    resource,
    select,
    getelementptr,
    branch_on_bit,
};

// ─── Data payloads ───

pub const ConstData = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    undefined: void,
    zero: void,
};

pub const PhiIncoming = struct { value: ValueId, block: BlockId };

pub const MemoryOrder = enum {
    relaxed,
    acquire,
    release,
    acq_rel,
    seq_cst,
};

pub const AtomicOp = struct {
    ptr: ValueId,
    val: ValueId,
    order: MemoryOrder,
};

pub const CastKind = enum {
    f2i,
    i2f,
    f2f,
    i2i,
    bitcast,
    ptr2int,
    int2ptr,
    zeroext,
    signext,
    trunc,
};

pub const BarrierKind = enum {
    group,
    device,
    all,
};

pub const SampleInfo = struct {
    tex: ValueId,
    sampler: ValueId,
    coord: ValueId,
    lod: ?ValueId,
    offset: ?ValueId,
};

pub const GepInfo = struct {
    ptr: ValueId,
    indices: []ValueId,
    result_elem_type: TypeId,
};

pub const CallInfo = struct {
    callee: ValueId,
    args: []ValueId,
};

// ─── Instruction ───

pub const Inst = struct {
    op: Op,
    ty: TypeId,
    result: ValueId,
    operands: []ValueId,
    data: Data,

    pub const Data = union(enum) {
        none: void,
        const_data: ConstData,
        string: []const u8,
        block_target: BlockId,
        cond_branch: struct { cond: ValueId, then_block: BlockId, else_block: BlockId },
        phi_incoming: []PhiIncoming,
        cast_info: struct { kind: CastKind, from: TypeId, to: TypeId },
        atomic_info: AtomicOp,
        sample_info: SampleInfo,
        barrier_kind: BarrierKind,
        gep_info: GepInfo,
        call_info: CallInfo,
        named_call: struct { name: []const u8, args: []ValueId },
        extract_info: struct { index: u32 },
        texture_store_info: struct { tex: ValueId, coord_x: ValueId, coord_y: ValueId, val: ValueId },
        vector_shuffle: struct { a: ValueId, b: ValueId, mask: []u32 },
        group_info: struct { dim: u32 },
        fence_info: MemoryOrder,
        groupshared_size: u32,
    };

    pub fn deinit(self: *Inst, allocator: Allocator) void {
        if (self.operands.len > 0) allocator.free(self.operands);
        switch (self.data) {
            .phi_incoming => |v| allocator.free(v),
            .gep_info => |v| allocator.free(v.indices),
            .call_info => |v| allocator.free(v.args),
            .named_call => |v| {
                allocator.free(v.name);
                allocator.free(v.args);
            },
            .vector_shuffle => |v| allocator.free(v.mask),
            .string => |v| if (v.len > 0) allocator.free(v),
            else => {},
        }
    }
};

// ─── SSA Value tracking ───

pub const InstRef = struct {
    block: BlockId,
    idx: u32,
};

pub const ValueInfo = struct {
    def: InstRef,
    uses: std.ArrayList(ValueId),

    pub fn deinit(self: *ValueInfo, allocator: Allocator) void {
        _ = allocator;
        self.uses.deinit();
    }
};

// ─── Basic block ───

pub const LoopInfo = struct {
    header: BlockId,
    preheader: BlockId,
    latch: BlockId,
    exits: []BlockId,
    depth: u32,
    induction_vars: []ValueId,
};

pub const BasicBlock = struct {
    label: []const u8,
    instrs: std.ArrayList(Inst),
    next_value_id: ValueId,
    loop: ?LoopInfo,

    pub fn deinit(self: *BasicBlock, allocator: Allocator) void {
        for (self.instrs.items) |*inst| inst.deinit(allocator);
        self.instrs.deinit();
        if (self.label.len > 0) allocator.free(self.label);
        if (self.loop) |li| {
            allocator.free(li.exits);
            allocator.free(li.induction_vars);
        }
    }
};

// ─── Function ───

pub const FuncParam = struct {
    name: []const u8,
    ty: TypeId,
};

pub const CallingConvention = enum {
    compute,
    graphics,
    entry,
    internal,
};

pub const Function = struct {
    allocator: Allocator,
    name: []const u8,
    params: []FuncParam,
    param_values: []ValueId,
    return_type: TypeId,
    blocks: std.ArrayList(BasicBlock),
    next_block_id: BlockId,
    calling_convention: CallingConvention,
    numthreads: struct { x: u32, y: u32, z: u32 },
    locals_count: u32,
    value_info: std.ArrayList(ValueInfo),
    attributes: std.StringHashMap(void),

    pub fn deinit(self: *Function, allocator: Allocator) void {
        for (self.blocks.items) |*b| b.deinit(allocator);
        self.blocks.deinit();
        for (self.value_info.items) |*vi| vi.deinit(allocator);
        self.value_info.deinit();
        for (self.params) |p| {
            allocator.free(p.name);
        }
        allocator.free(self.params);
        allocator.free(self.param_values);
        allocator.free(self.name);
        self.attributes.deinit();
    }

    pub fn createValue(self: *Function) ValueId {
        const id = @as(ValueId, @intCast(self.locals_count + 1));
        self.locals_count += 1;
        self.value_info.append(.{
            .def = .{ .block = INVALID_ID, .idx = INVALID_ID },
            .uses = std.ArrayList(ValueId).init(self.allocator),
        }) catch {};
        return id;
    }

    pub fn getBlock(self: *Function, id: BlockId) *BasicBlock {
        return &self.blocks.items[id];
    }

    pub fn getValueInfo(self: *Function, val: ValueId) *ValueInfo {
        return &self.value_info.items[val - 1];
    }
};

// ─── Memory regions ───

pub const MemRegion = struct {
    name: []const u8,
    ty: TypeId,
    space: AddressSpace,
    size_val: u32,
    alignment: u32,
};

// ─── Resource declaration (GPU binding) ───

pub const ResourceDecl = struct {
    name: []const u8,
    ty: TypeId,
    binding: u32,
    space: u32,
};

// ─── Module ───

pub const Module = struct {
    allocator: Allocator,
    types: types.TypeTable,
    functions: std.ArrayList(Function),
    resources: std.ArrayList(ResourceDecl),
    memory_regions: std.ArrayList(MemRegion),
    entry_point: ?FunctionId,
    next_function_id: FunctionId,
    metadata: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) Module {
        return .{
            .allocator = allocator,
            .types = types.TypeTable.init(allocator),
            .functions = std.ArrayList(Function).init(allocator),
            .resources = std.ArrayList(ResourceDecl).init(allocator),
            .memory_regions = std.ArrayList(MemRegion).init(allocator),
            .entry_point = null,
            .next_function_id = 0,
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Module) void {
        for (self.functions.items) |*f| f.deinit(self.allocator);
        self.functions.deinit();
        for (self.resources.items) |r| {
            self.allocator.free(r.name);
        }
        self.resources.deinit();
        for (self.memory_regions.items) |mr| {
            self.allocator.free(mr.name);
        }
        self.memory_regions.deinit();
        self.types.deinit();
        {
            var it = self.metadata.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.metadata.deinit();
        }
    }

    pub fn addFunction(self: *Module, name: []const u8, ret_ty: TypeId, cc: CallingConvention) !FunctionId {
        const id = self.next_function_id;
        self.next_function_id += 1;
        try self.functions.append(.{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, name),
            .params = &.{},
            .param_values = &.{},
            .return_type = ret_ty,
            .blocks = std.ArrayList(BasicBlock).init(self.allocator),
            .next_block_id = 0,
            .calling_convention = cc,
            .numthreads = .{ .x = 1, .y = 1, .z = 1 },
            .locals_count = 0,
            .value_info = std.ArrayList(ValueInfo).init(self.allocator),
            .attributes = std.StringHashMap(void).init(self.allocator),
        });
        return id;
    }

    pub fn getFunction(self: *const Module, id: FunctionId) *const Function {
        return &self.functions.items[id];
    }

    pub fn getFunctionMut(self: *Module, id: FunctionId) *Function {
        return &self.functions.items[id];
    }

    pub fn addBlock(self: *Module, func_id: FunctionId, label: []const u8) !BlockId {
        return self.addBlockWithInstrs(func_id, label, &.{});
    }

    pub fn addBlockWithInstrs(self: *Module, func_id: FunctionId, label: []const u8, initial_instrs: []const Inst) !BlockId {
        const fn_ptr = self.getFunctionMut(func_id);
        const id = fn_ptr.next_block_id;
        fn_ptr.next_block_id += 1;
        var block = BasicBlock{
            .label = try self.allocator.dupe(u8, label),
            .instrs = std.ArrayList(Inst).init(self.allocator),
            .next_value_id = 0,
            .loop = null,
        };
        for (initial_instrs) |inst| {
            var owned = inst;
            if (owned.result == NO_VALUE) {
                owned.result = fn_ptr.createValue();
            }
            const idx = block.instrs.items.len;
            fn_ptr.getValueInfo(owned.result).def = .{
                .block = id,
                .idx = @as(u32, @intCast(idx)),
            };
            for (owned.operands) |op_val| {
                if (op_val != NO_VALUE) {
                    try fn_ptr.getValueInfo(op_val).uses.append(owned.result);
                }
            }
            try block.instrs.append(owned);
        }
        try fn_ptr.blocks.append(block);
        return id;
    }

    pub fn addInst(self: *Module, func_id: FunctionId, block_id: BlockId, inst: Inst) !ValueId {
        const fn_ptr = self.getFunctionMut(func_id);
        const val = fn_ptr.createValue();

        var owned = inst;
        owned.result = val;

        const idx = fn_ptr.blocks.items[block_id].instrs.items.len;
        fn_ptr.getValueInfo(val).def = .{
            .block = block_id,
            .idx = @as(u32, @intCast(idx)),
        };

        for (owned.operands) |op_val| {
            if (op_val != NO_VALUE) {
                try fn_ptr.getValueInfo(op_val).uses.append(val);
            }
        }

        try fn_ptr.blocks.items[block_id].instrs.append(owned);
        return val;
    }

    pub fn addPhi(self: *Module, func_id: FunctionId, block_id: BlockId, ty: TypeId, incoming: []PhiIncoming) !ValueId {
        const fn_ptr = self.getFunctionMut(func_id);
        const val = fn_ptr.createValue();

        var insert_idx: u32 = 0;
        for (fn_ptr.blocks.items[block_id].instrs.items) |inst| {
            if (inst.op == .phi) {
                insert_idx += 1;
            } else {
                break;
            }
        }

        fn_ptr.getValueInfo(val).def = .{
            .block = block_id,
            .idx = insert_idx,
        };

        for (incoming) |inc| {
            if (inc.value != NO_VALUE) {
                try fn_ptr.getValueInfo(inc.value).uses.append(val);
            }
        }

        try fn_ptr.blocks.items[block_id].instrs.insert(insert_idx, .{
            .op = .phi,
            .ty = ty,
            .result = val,
            .operands = &.{},
            .data = .{ .phi_incoming = incoming },
        });

        if (insert_idx < @as(u32, @intCast(fn_ptr.blocks.items[block_id].instrs.items.len - 1))) {
            var bi: u32 = insert_idx + 1;
            while (bi < @as(u32, @intCast(fn_ptr.blocks.items[block_id].instrs.items.len))) : (bi += 1) {
                const shifted = &fn_ptr.blocks.items[block_id].instrs.items[bi];
                if (shifted.result != NO_VALUE) {
                    fn_ptr.getValueInfo(shifted.result).def.idx = bi;
                }
            }
        }

        return val;
    }

    pub fn rebuildUses(self: *Module) void {
        for (self.functions.items) |*func| {
            for (func.value_info.items) |*vi| {
                vi.uses.clearRetainingCapacity();
            }
            for (func.blocks.items, 0..) |*block, bi| {
                for (block.instrs.items, 0..) |*inst, ii| {
                    if (inst.result != NO_VALUE) {
                        func.getValueInfo(inst.result).def = .{
                            .block = @as(BlockId, @intCast(bi)),
                            .idx = @as(u32, @intCast(ii)),
                        };
                    }
                    for (inst.operands) |op_val| {
                        if (op_val != NO_VALUE) {
                            func.getValueInfo(op_val).uses.append(inst.result) catch {};
                        }
                    }
                    switch (inst.data) {
                        .texture_store_info => |tsi| {
                            if (tsi.tex != NO_VALUE) func.getValueInfo(tsi.tex).uses.append(inst.result) catch {};
                            if (tsi.coord_x != NO_VALUE) func.getValueInfo(tsi.coord_x).uses.append(inst.result) catch {};
                            if (tsi.coord_y != NO_VALUE) func.getValueInfo(tsi.coord_y).uses.append(inst.result) catch {};
                            if (tsi.val != NO_VALUE) func.getValueInfo(tsi.val).uses.append(inst.result) catch {};
                        },
                        .named_call => |nc| {
                            for (nc.args) |arg| {
                                if (arg != NO_VALUE) {
                                    func.getValueInfo(arg).uses.append(inst.result) catch {};
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    }

    pub fn removeInst(self: *Module, func_id: FunctionId, block_id: BlockId, idx: u32) void {
        const fn_ptr = self.getFunctionMut(func_id);
        const block = fn_ptr.getBlock(block_id);
        const inst = &block.instrs.items[idx];
        const removed_val = inst.result;

        for (inst.operands) |op_val| {
            if (op_val != NO_VALUE) {
                const vi = fn_ptr.getValueInfo(op_val);
                if (std.mem.indexOfScalar(ValueId, vi.uses.items, removed_val)) |use_idx| {
                    _ = vi.uses.swapRemove(use_idx);
                }
            }
        }

        switch (inst.data) {
            .texture_store_info => |tsi| {
                const fields = [_]ValueId{ tsi.tex, tsi.coord_x, tsi.coord_y, tsi.val };
                for (fields) |v| {
                    if (v != NO_VALUE) {
                        const vi = fn_ptr.getValueInfo(v);
                        if (std.mem.indexOfScalar(ValueId, vi.uses.items, removed_val)) |use_idx| {
                            _ = vi.uses.swapRemove(use_idx);
                        }
                    }
                }
            },
            .named_call => |nc| {
                for (nc.args) |arg| {
                    if (arg != NO_VALUE) {
                        const vi = fn_ptr.getValueInfo(arg);
                        if (std.mem.indexOfScalar(ValueId, vi.uses.items, removed_val)) |use_idx| {
                            _ = vi.uses.swapRemove(use_idx);
                        }
                    }
                }
            },
            else => {},
        }

        inst.deinit(self.allocator);
        _ = block.instrs.orderedRemove(idx);
    }
};

// ─── Pass infrastructure ───

pub const PassType = enum {
    analysis,
    transform,
};

pub const Pass = struct {
    name: []const u8,
    pass_type: PassType,
    run: *const fn (module: *Module, allocator: Allocator) anyerror!void,
};

pub const PassManager = struct {
    passes: std.ArrayList(Pass),
    allocator: Allocator,

    pub fn init(allocator: Allocator) PassManager {
        return .{
            .passes = std.ArrayList(Pass).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PassManager) void {
        self.passes.deinit();
    }

    pub fn addPass(self: *PassManager, pass: Pass) !void {
        try self.passes.append(pass);
    }

    pub fn run(self: *const PassManager, module: *Module) !void {
        for (self.passes.items) |pass| {
            try pass.run(module, self.allocator);
        }
    }
};
