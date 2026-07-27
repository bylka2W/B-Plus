const std = @import("std");
const plan_ir = @import("../../ir/plan.zig");
const diag = @import("diagnostics.zig");

pub fn checkIds(graph: plan_ir.PlanGraph, diagnostics: *diag.DiagnosticList) void {
    for (graph.transitions) |t| {
        if (t.from.index >= graph.state_count) {
            diagnostics.push(.invalid_state_id, .@"error", t.from, "PLAN010: transition references invalid source state");
        }
        if (t.to.index >= graph.state_count) {
            diagnostics.push(.invalid_state_id, .@"error", t.to, "PLAN011: transition references invalid target state");
        }
        if (t.event) |ev| {
            if (ev.index >= graph.event_count) {
                diagnostics.push(.invalid_event_id, .@"error", null, "PLAN012: transition references invalid event");
            }
        }
    }

    if (graph.state_count == 0) {
        diagnostics.push(.no_states_defined, .@"error", null, "PLAN013: no states defined in PLAN graph");
    }
}
