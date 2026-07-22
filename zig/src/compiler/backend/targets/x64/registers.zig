const mir = @import("../../mir/core/mir.zig");

/// x64 architectural register enum.
/// Values match x64 encoding (0 = RAX, 1 = RCX, ...).
pub const X64Reg = enum(i16) {
    rax = 0, rcx = 1, rdx = 2, rbx = 3,
    rsp = 4, rbp = 5, rsi = 6, rdi = 7,
    r8 = 8, r9 = 9, r10 = 10, r11 = 11,
    r12 = 12, r13 = 13, r14 = 14, r15 = 15,
    xmm0 = 16, xmm1 = 17, xmm2 = 18, xmm3 = 19,
    xmm4 = 20, xmm5 = 21, xmm6 = 22, xmm7 = 23,
    xmm8 = 24, xmm9 = 25, xmm10 = 26, xmm11 = 27,
    xmm12 = 28, xmm13 = 29, xmm14 = 30, xmm15 = 31,

    /// Convert to generic PhysReg.
    pub fn toPhys(self: X64Reg) mir.PhysReg {
        return @intFromEnum(self);
    }

    /// Convert from generic PhysReg (panics if invalid).
    pub fn fromPhys(pr: mir.PhysReg) X64Reg {
        return @enumFromInt(pr);
    }

    pub fn isGPR(self: X64Reg) bool {
        return @intFromEnum(self) < 16;
    }

    pub fn isXMM(self: X64Reg) bool {
        return @intFromEnum(self) >= 16;
    }
};
