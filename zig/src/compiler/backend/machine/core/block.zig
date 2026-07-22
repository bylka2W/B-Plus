const std = @import("std");
const instruction = @import("instruction.zig");
const MInst = instruction.MInst;

pub const MBlock = struct {
    name: []const u8,
    instrs: std.ArrayList(MInst),

    pub fn deinit(self: *MBlock) void {
        self.instrs.deinit();
    }
};
