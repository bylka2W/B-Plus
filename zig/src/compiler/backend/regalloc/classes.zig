const std = @import("std");

// ===== Register Classes =====

pub const RegClass = enum {
    gpr64,
    xmm,
    flags,

    pub fn info(self: RegClass) RegClassInfo {
        return switch (self) {
            .gpr64 => .{
                .available = &available_gpr64,
                .callee_saved = &callee_saved_gpr64,
            },
            .xmm => .{
                .available = &available_xmm,
                .callee_saved = &callee_saved_xmm_win64,
            },
            .flags => .{ .available = &.{}, .callee_saved = &.{} },
        };
    }

    pub fn k(self: RegClass) u32 {
        return @intCast(self.info().available.len);
    }
};

pub const RegClassInfo = struct {
    available: []const i16,
    callee_saved: []const i16,
};

pub const available_gpr64 = [_]i16{ 0, 1, 2, 3, 6, 7, 8, 9, 12, 13, 14, 15 };
pub const callee_saved_gpr64 = [_]i16{ 3, 6, 7, 12, 13, 14, 15 };
pub const available_xmm = [_]i16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
pub const callee_saved_xmm_win64 = [_]i16{ 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

// ===== Scratch registers (reserved, never allocated) =====

pub const SCRATCH_REG: i16 = 11;
pub const SCRATCH_REG_2: i16 = 10;
