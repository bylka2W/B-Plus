const std = @import("std");
const value = @import("value.zig");
const types = @import("types.zig");
const instruction = @import("instruction.zig");
const block = @import("block.zig");
const func = @import("function.zig");
const ValueId = value.ValueId;
const BlockId = value.BlockId;
const FunctionId = value.FunctionId;
const NO_VALUE = value.NO_VALUE;
const INVALID_ID = value.INVALID_ID;
const Inst = instruction.Inst;
const BasicBlock = block.BasicBlock;
const Function = func.Function;
const FuncParam = func.FuncParam;
const CallingConvention = func.CallingConvention;
const ValueInfo = value.ValueInfo;
const TypeTable = types.TypeTable;
const TypeId = types.TypeId;
const AddressSpace = types.AddressSpace;
const ScalarKind = types.ScalarKind;

pub const MemRegion = struct {
    name: []const u8,
    ty: TypeId,
    space: AddressSpace,
    size_val: u32,
    alignment: u32,
};

pub const ResourceDecl = struct {
    name: []const u8,
    ty: TypeId,
    binding: u32,
    space: u32,
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    types: TypeTable,
    functions: std.ArrayList(Function),
    resources: std.ArrayList(ResourceDecl),
    memory_regions: std.ArrayList(MemRegion),
    entry_point: ?FunctionId,
    next_function_id: FunctionId,
    metadata: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Module {
        return .{
            .allocator = allocator,
            .types = TypeTable.init(allocator),
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
        var blk = BasicBlock{
            .label = try self.allocator.dupe(u8, label),
            .instrs = std.ArrayList(Inst).init(self.allocator),
            .next_value_id = 0,
            .preds = std.ArrayList(BlockId).init(self.allocator),
            .succs = std.ArrayList(BlockId).init(self.allocator),
            .phi_count = 0,
        };
        for (initial_instrs) |inst| {
            var owned = inst;
            if (owned.result == NO_VALUE) {
                owned.result = try fn_ptr.createValue();
            }
            const idx = blk.instrs.items.len;
            fn_ptr.getValueInfo(owned.result).def = .{
                .block = id,
                .idx = @as(u32, @intCast(idx)),
            };
            {
                var i: usize = 0;
                while (i < owned.operands.len) : (i += 1) {
                    const op_val = owned.operands[i];
                    if (op_val != NO_VALUE) {
                        try fn_ptr.getValueInfo(op_val).uses.append(owned.result);
                    }
                }
            }
            {
                var list = std.ArrayList(ValueId).init(self.allocator);
                defer list.deinit();
                try instruction.collectDataRefs(&owned.data, &list);
                for (list.items) |ref| {
                    if (ref != NO_VALUE) {
                        try fn_ptr.getValueInfo(ref).uses.append(owned.result);
                    }
                }
            }
            try blk.instrs.append(owned);
        }
        try fn_ptr.blocks.append(blk);
        return id;
    }

    pub fn addInst(self: *Module, func_id: FunctionId, block_id: BlockId, inst: Inst) !ValueId {
        const fn_ptr = self.getFunctionMut(func_id);
        const val = try fn_ptr.createValue();

        var owned = inst;
        owned.result = val;

        const idx = fn_ptr.blocks.items[block_id].instrs.items.len;
        fn_ptr.getValueInfo(val).def = .{
            .block = block_id,
            .idx = @as(u32, @intCast(idx)),
        };

        {
            var i: usize = 0;
            while (i < owned.operands.len) : (i += 1) {
                const op_val = owned.operands[i];
                if (op_val != NO_VALUE) {
                    try fn_ptr.getValueInfo(op_val).uses.append(val);
                }
            }
        }
        {
            var list = std.ArrayList(ValueId).init(self.allocator);
            defer list.deinit();
            try instruction.collectDataRefs(&owned.data, &list);
            for (list.items) |ref| {
                if (ref != NO_VALUE) {
                    try fn_ptr.getValueInfo(ref).uses.append(val);
                }
            }
        }

        try fn_ptr.blocks.items[block_id].instrs.append(owned);
        return val;
    }

    pub fn addPhi(self: *Module, func_id: FunctionId, block_id: BlockId, ty: TypeId, incoming: []instruction.PhiIncoming) !ValueId {
        const fn_ptr = self.getFunctionMut(func_id);
        const blk = &fn_ptr.blocks.items[block_id];
        const val = try fn_ptr.createValue();
        const insert_idx = blk.phi_count;

        fn_ptr.getValueInfo(val).def = .{
            .block = block_id,
            .idx = insert_idx,
        };

        {
            const phi_data = Inst.Data{ .phi_incoming = incoming };
            var ref_list = std.ArrayList(ValueId).init(self.allocator);
            defer ref_list.deinit();
            try instruction.collectDataRefs(&phi_data, &ref_list);
            for (ref_list.items) |ref| {
                if (ref != NO_VALUE) {
                    try fn_ptr.getValueInfo(ref).uses.append(val);
                }
            }
        }

        try blk.instrs.insert(insert_idx, .{
            .op = .phi,
            .ty = ty,
            .result = val,
            .operands = &.{},
            .data = .{ .phi_incoming = incoming },
        });
        blk.phi_count += 1;

        if (insert_idx < @as(u32, @intCast(blk.instrs.items.len - 1))) {
            var bi: u32 = insert_idx + 1;
            while (bi < @as(u32, @intCast(blk.instrs.items.len))) : (bi += 1) {
                const shifted = &blk.instrs.items[bi];
                if (shifted.result != NO_VALUE) {
                    fn_ptr.getValueInfo(shifted.result).def.idx = bi;
                }
            }
        }

        return val;
    }

    pub fn rebuildUses(self: *Module) void {
        for (self.functions.items) |*f| {
            for (f.value_info.items) |*vi| {
                vi.uses.clearRetainingCapacity();
            }
            for (f.blocks.items, 0..) |*blk, bi| {
                for (blk.instrs.items, 0..) |*inst, ii| {
                    if (inst.result != NO_VALUE) {
                        f.getValueInfo(inst.result).def = .{
                            .block = @as(BlockId, @intCast(bi)),
                            .idx = @as(u32, @intCast(ii)),
                        };
                    }
                    for (inst.operands) |op_val| {
                        if (op_val != NO_VALUE) {
                            f.getValueInfo(op_val).uses.append(inst.result) catch {};
                        }
                    }
                    func.registerDataUses(f, &inst.data, inst.result);
                }
            }
        }
    }

    pub fn removeInst(self: *Module, func_id: FunctionId, block_id: BlockId, idx: u32) void {
        const fn_ptr = self.getFunctionMut(func_id);
        const blk = fn_ptr.getBlock(block_id);
        const inst = &blk.instrs.items[idx];
        const removed_val = inst.result;

        for (inst.operands) |op_val| {
            if (op_val != NO_VALUE) {
                const vi = fn_ptr.getValueInfo(op_val);
                if (std.mem.indexOfScalar(ValueId, vi.uses.items, removed_val)) |use_idx| {
                    _ = vi.uses.swapRemove(use_idx);
                }
            }
        }
        func.unregisterDataUses(fn_ptr, &inst.data, removed_val);

        inst.deinit(self.allocator);
        _ = blk.instrs.orderedRemove(idx);
    }
};
