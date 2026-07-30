const std = @import("std");
const bir = @import("../middle/bir/bir.zig");
const ast = @import("../frontend/ast.zig");

pub const init_checker = @import("init_checker.zig");
pub const state_checker = @import("state_checker.zig");

pub const SafetyResult = struct {
    allocator: std.mem.Allocator,
    init_diagnostics: std.ArrayList(init_checker.InitDiagnostic),
    state_diagnostics: std.ArrayList(state_checker.StateDiagnostic),

    pub fn hasErrors(self: *const SafetyResult) bool {
        return self.init_diagnostics.items.len > 0 or self.state_diagnostics.items.len > 0;
    }

    pub fn deinit(self: *SafetyResult) void {
        for (self.init_diagnostics.items) |d| {
            self.allocator.free(d.func_name);
            self.allocator.free(d.block_name);
            self.allocator.free(d.slot_name);
            self.allocator.free(d.message);
        }
        self.init_diagnostics.deinit();
        for (self.state_diagnostics.items) |d| {
            self.allocator.free(d.state_name);
            self.allocator.free(d.message);
        }
        self.state_diagnostics.deinit();
    }
};

pub fn runSafetyChecks(allocator: std.mem.Allocator, program: *const ast.ProgramNode, bir_module: *bir.Module) !SafetyResult {
    var init_diags = std.ArrayList(init_checker.InitDiagnostic).init(allocator);
    var state_diags = std.ArrayList(state_checker.StateDiagnostic).init(allocator);

    {
        var checker = init_checker.InitChecker.init(allocator);
        checker.checkModule(bir_module) catch |err| {
            return err;
        };
        init_diags = checker.diagnostics;
    }

    {
        var checker = state_checker.StateChecker.init(allocator);
        checker.checkPlan(program) catch |err| {
            return err;
        };
        state_diags = checker.diagnostics;
    }

    return SafetyResult{
        .allocator = allocator,
        .init_diagnostics = init_diags,
        .state_diagnostics = state_diags,
    };
}

pub fn reportSafetyErrors(writer: anytype, result: *const SafetyResult) !void {
    for (result.init_diagnostics.items) |d| {
        try writer.print("error[UninitializedVariable]: {s}\n", .{d.message});
        try writer.print("  --> {s}:{s}\n", .{ d.func_name, d.block_name });
    }
    for (result.state_diagnostics.items) |d| {
        const tag = @tagName(d.kind);
        try writer.print("error[{s}]: {s}\n", .{ tag, d.message });
    }
}
