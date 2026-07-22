const std = @import("std");
const mir = @import("../../mir/core/mir.zig");

/// Target-independent register allocation result.
pub const RegAllocResult = struct {
    regs: std.AutoHashMap(u32, mir.PhysReg),
    spills: std.AutoHashMap(u32, SpillSlot),
    allocator: std.mem.Allocator,
};

pub const SpillSlot = struct {
    offset: i32,
    size: u8,
};

/// Target interface: every backend (x64, ARM64, Wasm) implements this.
pub const Target = struct {
    name: []const u8,

    /// Lower a MIR instruction to target-specific instructions.
    lowerInst: *const fn (
        ctx: *TargetContext,
        inst: mir.MInst,
    ) anyerror!void,

    /// Allocate physical registers for a MIR function.
    allocateRegisters: *const fn (
        mfunc: *const mir.MFunction,
        allocator: std.mem.Allocator,
    ) anyerror!RegAllocResult,

    /// Emit machine code for a lowered MIR function.
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
