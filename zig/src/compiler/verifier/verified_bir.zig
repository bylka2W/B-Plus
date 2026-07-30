const std = @import("std");
const bir = @import("../middle/bir/bir.zig");

pub const VerifiedBIR = struct {
    module: *bir.Module,
    allocator: std.mem.Allocator,

    pub fn getModule(self: *const VerifiedBIR) *bir.Module {
        return self.module;
    }

    pub fn deinit(self: *VerifiedBIR) void {
        self.module.deinit();
        self.allocator.destroy(self.module);
    }

    pub fn format(self: VerifiedBIR, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("VerifiedBIR({d} funcs)", .{self.module.functions.items.len});
    }
};
