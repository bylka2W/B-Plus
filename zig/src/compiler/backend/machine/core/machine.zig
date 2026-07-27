const std = @import("std");
const block = @import("block.zig");
const MBlock = block.MBlock;
const value = @import("value.zig");
const operand = @import("operand.zig");
const RegClass = value.RegClass;
const DataType = value.DataType;

pub const VRegInfo = struct {
    ty: DataType,
    class: RegClass,

    pub fn init(ty: DataType) VRegInfo {
        return .{ .ty = ty, .class = RegClass.forType(ty) };
    }
};

pub const MFunction = struct {
    name: []const u8,
    blocks: std.ArrayList(MBlock),
    vreg_info: std.AutoHashMap(u32, VRegInfo),
    params: []const operand.MOperand,
    allocator: std.mem.Allocator,

    pub fn putVReg(self: *MFunction, id: u32, ty: DataType) void {
        self.vreg_info.put(id, VRegInfo.init(ty)) catch {};
    }

    pub fn getVRegClass(self: *const MFunction, id: u32) RegClass {
        if (self.vreg_info.get(id)) |info| return info.class;
        return .gpr;
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
        for (self.functions.items) |*f| {
            for (f.blocks.items) |*b| b.deinit();
            f.blocks.deinit();
            f.vreg_info.deinit();
            if (f.params.len > 0) self.allocator.free(f.params);
        }
        self.functions.deinit();
    }
};
