const std = @import("std");
const mir = @import("../../mir/core/mir.zig");

pub const RegAllocResult = struct 
{
    regs: std.AutoHashMap(u32, mir.PhysReg),
    spills: std.AutoHashMap(u32, SpillSlot),
    allocator: std.mem.Allocator,
};

pub const SpillSlot = struct 
{
    offset: i32,
    size: u8,
};

pub const Target = struct 
{
    name: []const u8,

    ///переводит инструкцию MIR в инструкции конкретной платформы
    lowerInst: *const fn (
        ctx: *TargetContext,
        inst: mir.MInst,
    ) anyerror!void,

    
    allocateRegisters: *const fn (
        mfunc: *const mir.MFunction,
        allocator: std.mem.Allocator,
    ) anyerror!RegAllocResult,


    emit: *const fn (
        ctx: *TargetContext,
        mfunc: *const mir.MFunction,
        ra: *const RegAllocResult,
    ) anyerror!void,
};

pub const TargetContext = struct {
    code: *std.ArrayList(u8),
    target: *const Target,
};
