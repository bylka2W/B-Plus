const std = @import("std");
const plan_ir = @import("../../ir/plan.zig");
const diag = @import("diagnostics.zig");
const ids = @import("../../../frontend/foundation/ids/ids.zig");

const PlanStateId = ids.PlanStateId;

pub fn checkReachability(graph: plan_ir.PlanGraph, diagnostics: *diag.DiagnosticList, allocator: std.mem.Allocator) void {
    if (graph.state_count == 0) return;

    var reachable = allocator.alloc(bool, graph.state_count) catch return;
    defer allocator.free(reachable);
    for (reachable) |*r| r.* = false;

    reachable[graph.initial_state.index] = true;

    var changed = true;
    while (changed) {
        changed = false;
        for (graph.transitions) |t| {
            if (reachable[t.from.index] and !reachable[t.to.index]) {
                reachable[t.to.index] = true;
                changed = true;
            }
        }
    }

    for (graph.states) |s| {
        if (s.flags.is_terminal) continue;
        if (!reachable[s.id.index]) {
            diagnostics.push(.unreachable_state, .warning, s.id, "PLAN101: state is unreachable from initial state");
        }
    }
}
