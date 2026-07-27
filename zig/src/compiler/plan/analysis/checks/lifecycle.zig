const std = @import("std");
const plan_ir = @import("../../ir/plan.zig");
const diag = @import("diagnostics.zig");
const ids = @import("../../../frontend/foundation/ids/ids.zig");

const PlanStateId = ids.PlanStateId;

pub fn checkLifecycle(graph: plan_ir.PlanGraph, diagnostics: *diag.DiagnosticList) void {
    if (graph.state_count == 0) return;

    checkInitialDefined(graph, diagnostics);
    checkInitialNotTerminal(graph, diagnostics);
    checkInitialDeadEnd(graph, diagnostics);
}

fn checkInitialDefined(graph: plan_ir.PlanGraph, diagnostics: *diag.DiagnosticList) void {
    var found = false;
    for (graph.states) |s| {
        if (s.flags.is_initial) {
            found = true;
            break;
        }
    }
    if (!found) {
        diagnostics.push(.initial_state_not_defined, .@"error", null, "PLAN002: no initial state defined");
    }
}

fn checkInitialNotTerminal(graph: plan_ir.PlanGraph, diagnostics: *diag.DiagnosticList) void {
    if (graph.initial_state.index >= graph.state_count) return;
    const s = graph.states[graph.initial_state.index];
    if (s.flags.is_terminal) {
        diagnostics.push(.initial_state_is_terminal, .@"error", graph.initial_state, "PLAN003: initial state is marked terminal");
    }
}

fn checkInitialDeadEnd(graph: plan_ir.PlanGraph, diagnostics: *diag.DiagnosticList) void {
    if (graph.state_count <= 1) return;
    if (graph.initial_state.index >= graph.state_count) return;
    const s = graph.states[graph.initial_state.index];
    if (s.flags.is_terminal) return;

    for (graph.transitions) |t| {
        if (t.from.eql(graph.initial_state)) return;
    }

    diagnostics.push(.initial_state_dead_end, .@"warning", graph.initial_state, "PLAN102: initial state has no outgoing transitions");
}
