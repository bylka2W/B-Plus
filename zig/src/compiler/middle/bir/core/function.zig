const std = @import("std");
const value = @import("value.zig");
const block = @import("block.zig");
const instruction = @import("instruction.zig");
const types = @import("types.zig");
const ValueId = value.ValueId;
const BlockId = value.BlockId;
const ValueInfo = value.ValueInfo;
const InstRef = value.InstRef;
const NO_VALUE = value.NO_VALUE;
const INVALID_ID = value.INVALID_ID;
const Inst = instruction.Inst;
const BasicBlock = block.BasicBlock;
const TypeId = types.TypeId;

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
    allocator: std.mem.Allocator,
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

    pub fn deinit(self: *Function, allocator: std.mem.Allocator) void {
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

    pub fn createValue(self: *Function) !ValueId {
        const id = @as(ValueId, @intCast(self.locals_count + 1));
        self.locals_count += 1;
        try self.value_info.append(.{
            .def = .{ .block = INVALID_ID, .idx = INVALID_ID },
            .uses = std.ArrayList(ValueId).init(self.allocator),
        });
        return id;
    }

    pub fn getBlock(self: *Function, id: BlockId) *BasicBlock {
        return &self.blocks.items[id];
    }

    pub fn getValueInfo(self: *Function, val: ValueId) *ValueInfo {
        std.debug.assert(val != NO_VALUE);
        std.debug.assert(val <= self.value_info.items.len);
        return &self.value_info.items[val - 1];
    }
};

pub fn registerDataUses(func: *Function, data: *const Inst.Data, result_val: ValueId) void {
    switch (data.*) {
        .phi_incoming => |incoming| for (incoming) |inc|
            if (inc.value != NO_VALUE) func.getValueInfo(inc.value).uses.append(result_val) catch {},
        .gep_info => |gi| {
            if (gi.ptr != NO_VALUE) func.getValueInfo(gi.ptr).uses.append(result_val) catch {};
            for (gi.indices) |idx| if (idx != NO_VALUE)
                func.getValueInfo(idx).uses.append(result_val) catch {};
        },
        .call_info => |ci| {
            if (ci.callee != NO_VALUE) func.getValueInfo(ci.callee).uses.append(result_val) catch {};
            for (ci.args) |arg| if (arg != NO_VALUE)
                func.getValueInfo(arg).uses.append(result_val) catch {};
        },
        .atomic_info => |ai| {
            if (ai.ptr != NO_VALUE) func.getValueInfo(ai.ptr).uses.append(result_val) catch {};
            if (ai.val != NO_VALUE) func.getValueInfo(ai.val).uses.append(result_val) catch {};
        },
        .sample_info => |si| {
            if (si.tex != NO_VALUE) func.getValueInfo(si.tex).uses.append(result_val) catch {};
            if (si.sampler != NO_VALUE) func.getValueInfo(si.sampler).uses.append(result_val) catch {};
            if (si.coord != NO_VALUE) func.getValueInfo(si.coord).uses.append(result_val) catch {};
            if (si.lod) |v| if (v != NO_VALUE) func.getValueInfo(v).uses.append(result_val) catch {};
            if (si.offset) |v| if (v != NO_VALUE) func.getValueInfo(v).uses.append(result_val) catch {};
        },
        .texture_store_info => |tsi| {
            if (tsi.tex != NO_VALUE) func.getValueInfo(tsi.tex).uses.append(result_val) catch {};
            if (tsi.coord_x != NO_VALUE) func.getValueInfo(tsi.coord_x).uses.append(result_val) catch {};
            if (tsi.coord_y != NO_VALUE) func.getValueInfo(tsi.coord_y).uses.append(result_val) catch {};
            if (tsi.val != NO_VALUE) func.getValueInfo(tsi.val).uses.append(result_val) catch {};
        },
        .named_call => |nc| for (nc.args) |arg|
            if (arg != NO_VALUE) func.getValueInfo(arg).uses.append(result_val) catch {},
        .cond_branch => |cb|
            if (cb.cond != NO_VALUE) func.getValueInfo(cb.cond).uses.append(result_val) catch {},
        .branch_on_bit => |bb|
            if (bb.bit != NO_VALUE) func.getValueInfo(bb.bit).uses.append(result_val) catch {},
        else => {},
    }
}

pub fn unregisterDataUses(func: *Function, data: *const Inst.Data, removed_val: ValueId) void {
    const U = struct {
        fn removeUse(f: *Function, val: ValueId, rv: ValueId) void {
            if (val == NO_VALUE) return;
            const vi = f.getValueInfo(val);
            if (std.mem.indexOfScalar(ValueId, vi.uses.items, rv)) |use_idx| {
                _ = vi.uses.swapRemove(use_idx);
            }
        }
    };
    switch (data.*) {
        .phi_incoming => |incoming| for (incoming) |inc|
            U.removeUse(func, inc.value, removed_val),
        .gep_info => |gi| {
            U.removeUse(func, gi.ptr, removed_val);
            for (gi.indices) |idx| U.removeUse(func, idx, removed_val);
        },
        .call_info => |ci| {
            U.removeUse(func, ci.callee, removed_val);
            for (ci.args) |arg| U.removeUse(func, arg, removed_val);
        },
        .atomic_info => |ai| {
            U.removeUse(func, ai.ptr, removed_val);
            U.removeUse(func, ai.val, removed_val);
        },
        .sample_info => |si| {
            U.removeUse(func, si.tex, removed_val);
            U.removeUse(func, si.sampler, removed_val);
            U.removeUse(func, si.coord, removed_val);
            if (si.lod) |v| U.removeUse(func, v, removed_val);
            if (si.offset) |v| U.removeUse(func, v, removed_val);
        },
        .texture_store_info => |tsi| {
            U.removeUse(func, tsi.tex, removed_val);
            U.removeUse(func, tsi.coord_x, removed_val);
            U.removeUse(func, tsi.coord_y, removed_val);
            U.removeUse(func, tsi.val, removed_val);
        },
        .named_call => |nc| for (nc.args) |arg| U.removeUse(func, arg, removed_val),
        .cond_branch => |cb| U.removeUse(func, cb.cond, removed_val),
        .branch_on_bit => |bb| U.removeUse(func, bb.bit, removed_val),
        else => {},
    }
}
