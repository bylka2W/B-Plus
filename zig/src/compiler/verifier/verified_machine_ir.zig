const std = @import("std");
const machine = @import("../backend/machine/machine.zig");

pub const VerifiedMachineIR = struct {
    module: *machine.MModule,
    allocator: std.mem.Allocator,

    pub fn getModule(self: *const VerifiedMachineIR) *machine.MModule {
        return self.module;
    }

    pub fn deinit(self: *VerifiedMachineIR) void {
        self.module.deinit();
        self.allocator.destroy(self.module);
    }

    pub fn format(self: VerifiedMachineIR, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("VerifiedMachineIR({d} funcs)", .{self.module.functions.items.len});
    }
};
