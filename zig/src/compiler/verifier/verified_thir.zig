const std = @import("std");
const thir = @import("../middle/thir/thir.zig");

pub const VerifiedTHIR = struct {
    module: *thir.ThirModule,

    pub fn getModule(self: *const VerifiedTHIR) *thir.ThirModule {
        return self.module;
    }

    pub fn deinit(self: *VerifiedTHIR) void {
        self.module.deinit();
    }

    pub fn format(self: VerifiedTHIR, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("VerifiedTHIR({d} funcs)", .{self.module.functions.items.len});
    }
};
