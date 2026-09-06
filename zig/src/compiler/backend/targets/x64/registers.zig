const mir = @import("../../mir/core/mir.zig");


pub const X64Reg = enum(i16) {
    rax = 0, rcx = 1, rdx = 2, rbx = 3,
    rsp = 4, rbp = 5, rsi = 6, rdi = 7,
    r8 = 8, r9 = 9, r10 = 10, r11 = 11,
    r12 = 12, r13 = 13, r14 = 14, r15 = 15,
    xmm0 = 0, xmm1 = 1, xmm2 = 2, xmm3 = 3,
    xmm4 = 4, xmm5 = 5, xmm6 = 6, xmm7 = 7,
    xmm8 = 8, xmm9 = 9, xmm10 = 10, xmm11 = 11,
    xmm12 = 12, xmm13 = 13, xmm14 = 14, xmm15 = 15,


    pub fn toPhys(self: X64Reg) mir.PhysReg {
        return @intFromEnum(self);
    }

 
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
