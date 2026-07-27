const std = @import("std");
const plan_ir = @import("../../ir/plan.zig");
const diag = @import("diagnostics.zig");

pub fn checkDispatch(graph: plan_ir.PlanGraph, diagnostics: *diag.DiagnosticList) void {
    const tc = graph.transition_count;

    for (graph.dispatch_table) |r| {
        if (r.isEmpty()) continue;

        if (r.start >= tc or r.end > tc) {
            diagnostics.push(.invalid_dispatch_range, .@"error", null, "PLAN020: dispatch range references out-of-bounds transition index");
            return;
        }

        if (r.start >= r.end) {
            diagnostics.push(.invalid_dispatch_range, .@"error", null, "PLAN021: dispatch range start >= end");
            return;
        }
    }

    const expected_size = @as(usize, graph.state_count) * @as(usize, graph.dispatchColumns());
    if (graph.dispatch_table.len != expected_size) {
        diagnostics.push(.invalid_dispatch_range, .@"error", null, "PLAN022: dispatch table size mismatch");
    }
}
