const std = @import("std");

const opcode = @import("opcode.zig");
const operand = @import("operand.zig");
const value = @import("value.zig");

pub const MInst = opcode.MInst;
pub const MOperand = operand.MOperand;
pub const DataType = value.DataType;
pub const VRegClass = value.VRegClass;
pub const VRegInfo = value.VRegInfo;

pub const MBlock = struct {
    label: []const u8,
    instrs: std.ArrayList(MInst),
};

pub const MFunction = struct {
    name: []const u8,
    params: []const MOperand,
    blocks: std.ArrayList(MBlock),
    allocator: std.mem.Allocator,
    vreg_info: std.AutoHashMap(u32, VRegInfo),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) MFunction {
        return .{
            .name = allocator.dupe(u8, name) catch "?",
            .params = &.{},
            .blocks = std.ArrayList(MBlock).init(allocator),
            .allocator = allocator,
            .vreg_info = std.AutoHashMap(u32, VRegInfo).init(allocator),
        };
    }

    pub fn setParams(self: *MFunction, params: []const MOperand) void {
        self.params = params;
    }

    pub fn deinit(self: *MFunction) void {
        self.allocator.free(self.name);
        self.allocator.free(self.params);
        for (self.blocks.items) |*b| {
            self.allocator.free(b.label);
            for (b.instrs.items) |*inst| {
                switch (inst.*) {
                    .call => self.allocator.free(inst.call.name),
                    .phi => |p| self.allocator.free(p.incoming),
                    else => {},
                }
            }
            b.instrs.deinit();
        }
        self.blocks.deinit();
        self.vreg_info.deinit();
    }

    pub fn putVReg(self: *MFunction, vreg: u32, ty: DataType) !void {
        try self.vreg_info.put(vreg, VRegInfo.init(ty));
    }

    pub fn getVRegClass(self: *const MFunction, vreg: u32) ?VRegClass {
        if (self.vreg_info.get(vreg)) |info| return info.class;
        return null;
    }

    pub fn getVRegType(self: *const MFunction, vreg: u32) ?DataType {
        if (self.vreg_info.get(vreg)) |info| return info.ty;
        return null;
    }
};

pub const MModule = struct {
    functions: std.ArrayList(MFunction),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MModule {
        return .{
            .functions = std.ArrayList(MFunction).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MModule) void {
        for (self.functions.items) |*f| f.deinit();
        self.functions.deinit();
    }

    pub fn addFunction(self: *MModule, name: []const u8) !*MFunction {
        const func = MFunction.init(self.allocator, name);
        try self.functions.append(func);
        return &self.functions.items[self.functions.items.len - 1];
    }
};
