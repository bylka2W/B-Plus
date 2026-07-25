const std = @import("std");
const HirLowering = @import("../lower.zig").HirLowering;
const LowerError = @import("../lower.zig").LowerError;
const ItemId = @import("../lower.zig").ItemId;
const ast = @import("../../../ast.zig");
const hir_item = @import("../../item.zig");
const HirItemKind = hir_item.HirItem.HirItemKind;

pub fn lowerStateItem(self: *HirLowering, state: ast.StateDefNode) LowerError!ItemId {
    var fields = std.ArrayList(HirItemKind.StateVar).init(self.hir.allocator());
    for (state.variables.items) |_| {
        fields.append(.{
            .name = .INVALID,
            .ty = .INVALID,
            .default = null,
        }) catch return error.OutOfMemory;
    }

    var transitions = std.ArrayList(HirItemKind.Transition).init(self.hir.allocator());
    for (state.transitions.items) |t| {
        transitions.append(.{
            .event = null,
            .target = .INVALID,
            .guard = null,
            .priority = if (t.hot_weight) |hw| @intFromFloat(hw) else 0,
            .attrs = &.{},
        }) catch return error.OutOfMemory;
    }

    _ = state.enter_body;
    _ = state.exit_body;

    return self.hir.addItem(.{
        .span = .{ .file_id = 0, .start = 0, .end = 0 },
        .kind = .{ .state_item = .{
            .name = .INVALID,
            .def_id = .INVALID,
            .attrs = &.{},
            .fields = fields.toOwnedSlice() catch return error.OutOfMemory,
            .entry = null,
            .exit = null,
            .transitions = transitions.toOwnedSlice() catch return error.OutOfMemory,
            .parent = null,
            .visibility = .public,
        } },
    });
}
