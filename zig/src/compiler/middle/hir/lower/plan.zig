const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../../frontend/ast.zig");
const hir = @import("../node.zig");
const types = @import("../types.zig");
const TypeId = types.TypeId;
const common = @import("common.zig");

pub const LowerError = error{ ParseError, TypeNotFound, OutOfMemory };

pub fn lowerState(allocator: Allocator, state: ast.StateDefNode, _: common.SemaContext) !hir.HirState {
    var variables = std.ArrayList(hir.HirState.StateVar).init(allocator);
    for (state.variables.items) |v| {
        const default_val = if (v.default_value) |dv|
            common.parseExpr(allocator, dv)
        else
            null;

        try variables.append(.{
            .name = try allocator.dupe(u8, v.name),
            .ty = TypeId.fromName(v.type_name),
            .default = default_val,
        });
    }

    var transitions = std.ArrayList(hir.HirState.Transition).init(allocator);
    for (state.transitions.items) |t| {
        try transitions.append(.{
            .event = if (t.event_name) |en| try allocator.dupe(u8, en) else null,
            .target = try allocator.dupe(u8, t.target),
            .guard = if (t.guard) |g| common.parseExpr(allocator, g) else null,
            .weight = t.hot_weight,
        });
    }

    const enter_body = if (state.enter_body) |body|
        try common.parseBodyForState(allocator, body)
    else
        null;

    return .{
        .name = try allocator.dupe(u8, state.name),
        .variables = variables,
        .enter_body = enter_body,
        .exit_body = null,
        .transitions = transitions,
    };
}
