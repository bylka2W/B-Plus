const std = @import("std");
const mir = @import("../backend/mir/mir.zig");

pub const VerifiedMIR = struct {
    module: *mir.MModule,
    allocator: std.mem.Allocator,

    pub fn getModule(self: *const VerifiedMIR) *mir.MModule {
        return self.module;
    }

    pub fn deinit(self: *VerifiedMIR) void {
        self.module.deinit();
        self.allocator.destroy(self.module);
    }

    pub fn format(self: VerifiedMIR, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("VerifiedMIR({d} funcs)", .{self.module.functions.items.len});
    }
};
