const std = @import("std");

pub const ValueId = u32;
pub const BlockId = u32;
pub const FunctionId = u32;
pub const INVALID_ID: u32 = std.math.maxInt(u32);
pub const NO_VALUE: ValueId = 0;

pub const InstRef = struct {
    block: BlockId,
    idx: u32,
};

pub const ValueInfo = struct {
    def: InstRef,
    uses: std.ArrayList(ValueId),

    pub fn deinit(self: *ValueInfo, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.uses.deinit();
    }
};
