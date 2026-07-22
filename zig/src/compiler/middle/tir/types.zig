const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TypeId = u32;
pub const INVALID_TYPE: TypeId = std.math.maxInt(TypeId);
pub const ValueId = u32;
pub const BlockId = u32;
pub const FuncId = u32;
pub const NO_VALUE: ValueId = std.math.maxInt(ValueId);

pub const ScalarKind = enum {
    i1,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
};

pub const AddressSpace = enum {
    generic,
    global,
    shared,
    @"const",
    local,
};

pub const TypeKind = union(enum) {
    void,
    scalar: ScalarKind,
    pointer: struct { elem: TypeId, space: AddressSpace },
    array: struct { elem: TypeId, len: u32 },
    struct_type: struct { name: []const u8, fields: []TypeId, offsets: []u32 },
    function: struct { params: []TypeId, ret: TypeId },
    custom_opaque: []const u8,
};

pub const TypeEntry = struct {
    kind: TypeKind,
};

pub const TypeTable = struct {
    allocator: Allocator,
    types: std.ArrayList(TypeEntry),

    pub fn init(allocator: Allocator) TypeTable {
        return .{
            .allocator = allocator,
            .types = std.ArrayList(TypeEntry).init(allocator),
        };
    }

    pub fn deinit(self: *TypeTable) void {
        for (self.types.items) |t| {
            switch (t.kind) {
                .struct_type => |s| {
                    self.allocator.free(s.name);
                    self.allocator.free(s.fields);
                    self.allocator.free(s.offsets);
                },
                .function => |f| {
                    self.allocator.free(f.params);
                },
                .custom_opaque => |n| self.allocator.free(n),
                else => {},
            }
        }
        self.types.deinit();
    }

    pub fn add(self: *TypeTable, kind: TypeKind) !TypeId {
        const id: TypeId = @intCast(self.types.items.len);
        try self.types.append(.{ .kind = kind });
        return id;
    }

    pub fn voidType(self: *TypeTable) !TypeId {
        return self.add(.void);
    }

    pub fn scalarType(self: *TypeTable, kind: ScalarKind) !TypeId {
        return self.add(.{ .scalar = kind });
    }

    pub fn pointerType(self: *TypeTable, elem: TypeId, space: AddressSpace) !TypeId {
        return self.add(.{ .pointer = .{ .elem = elem, .space = space } });
    }

    pub fn get(self: *TypeTable, id: TypeId) ?TypeEntry {
        if (id < self.types.items.len) return self.types.items[id];
        return null;
    }
};

pub const Op = enum {
    br,
    cond_br,
    ret,

    alloca,
    load,
    store,

    const_int,
    const_float,
    const_bool,

    add,
    sub,
    mul,
    div,
    mod,
    neg,

    fadd,
    fsub,
    fmul,
    fdiv,

    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    feq,
    fne,
    flt,
    fle,
    fgt,
    fge,

    and_op,
    or_op,
    not,
    xor_op,

    call,

    alloca_array,
    ptr_offset,

    cast,
    bitcast,
    sext,
    zext,
    trunc,
    fptosi,
    sitofp,
    fpext,

    phi,
};

pub const ConstData = union(enum) {
    int: i64,
    float: f64,
    bool_val: bool,
    none: void,
};

pub const Instruction = struct {
    op: Op,
    ty: TypeId,
    result: ValueId,
    operands: []const ValueId,
    data: Data,

    pub const Data = union(enum) {
        none: void,
        const_data: ConstData,
        named_call: struct { name: []const u8, args: []const ValueId },
        block_target: BlockId,
        cond_branch: struct { cond: ValueId, then_block: BlockId, else_block: BlockId },
        phi_entry: struct { incoming_val: ValueId, incoming_block: BlockId },
    };
};

pub const BasicBlock = struct {
    label: []const u8,
    instrs: std.ArrayList(Instruction),

    pub fn deinit(self: *BasicBlock, allocator: Allocator) void {
        for (self.instrs.items) |inst| {
            if (inst.operands.len > 0) allocator.free(inst.operands);
            switch (inst.data) {
                .named_call => |nc| {
                    allocator.free(nc.name);
                    if (nc.args.len > 0) allocator.free(nc.args);
                },
                else => {},
            }
        }
        self.instrs.deinit();
    }
};

pub const FuncParam = struct {
    name: []const u8,
    ty: TypeId,
};

pub const Function = struct {
    name: []const u8,
    ret_type: TypeId,
    params: []const FuncParam,
    param_values: []const ValueId,
    blocks: std.ArrayList(BasicBlock),
    values: std.ArrayList(ValueInfo),

    pub const ValueInfo = struct {
        ty: TypeId,
    };

    pub const Linkage = enum { @"export", internal, entry };

    linkage: Linkage,
    next_value: ValueId,
    next_block: BlockId,

    pub fn deinit(self: *Function, allocator: Allocator) void {
        for (self.blocks.items) |*b| b.deinit(allocator);
        self.blocks.deinit();
        self.values.deinit();
        allocator.free(self.name);
        if (self.params.len > 0) allocator.free(self.params);
        if (self.param_values.len > 0) allocator.free(self.param_values);
    }

    pub fn createValue(self: *Function, ty: TypeId) !ValueId {
        const id = self.next_value;
        self.next_value += 1;
        try self.values.append(.{ .ty = ty });
        return id;
    }

    pub fn addBlock(self: *Function, label: []const u8) !BlockId {
        const id = self.next_block;
        self.next_block += 1;
        try self.blocks.append(.{
            .label = label,
            .instrs = std.ArrayList(Instruction).init(self.values.allocator),
        });
        return id;
    }
};

pub const Module = struct {
    allocator: Allocator,
    types: TypeTable,
    functions: std.ArrayList(Function),
    next_func: FuncId,

    pub fn init(allocator: Allocator) Module {
        return .{
            .allocator = allocator,
            .types = TypeTable.init(allocator),
            .functions = std.ArrayList(Function).init(allocator),
            .next_func = 0,
        };
    }

    pub fn deinit(self: *Module) void {
        for (self.functions.items) |*f| f.deinit(self.allocator);
        self.functions.deinit();
        self.types.deinit();
    }

    pub fn addFunction(self: *Module, name: []const u8, ret_type: TypeId, linkage: Function.Linkage) !FuncId {
        const id = self.next_func;
        self.next_func += 1;
        try self.functions.append(.{
            .name = try self.allocator.dupe(u8, name),
            .ret_type = ret_type,
            .params = &.{},
            .param_values = &.{},
            .blocks = std.ArrayList(BasicBlock).init(self.allocator),
            .values = std.ArrayList(Function.ValueInfo).init(self.allocator),
            .linkage = linkage,
            .next_value = 0,
            .next_block = 0,
        });
        return id;
    }

    pub fn getFunction(self: *Module, id: FuncId) *Function {
        return &self.functions.items[id];
    }

    pub fn getFunctionMut(self: *Module, id: FuncId) *Function {
        return &self.functions.items[id];
    }
};
