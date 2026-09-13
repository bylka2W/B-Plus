pub var debug_ir: bool = false;

pub fn initFromEnv() void {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "BPC_DEBUG_IR")) |val| {
        defer std.heap.page_allocator.free(val);
        debug_ir = val.len > 0;
    } else |_| {}
}

const std = @import("std");
