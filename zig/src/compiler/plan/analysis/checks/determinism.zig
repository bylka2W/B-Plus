const std = @import("std");
const plan_ir = @import("../../ir/plan.zig");
const diag = @import("diagnostics.zig");

pub fn checkDeterminism(graph: plan_ir.PlanGraph, diagnostics: *diag.DiagnosticList) void {
    if (graph.transition_count < 2) return;

    var i: u32 = 0;
    while (i < graph.transition_count) {
        const t = graph.transitions[i];

        if (t.flags.is_always) {
            var j = i + 1;
            while (j < graph.transition_count) {
                const t2 = graph.transitions[j];
                if (t2.from.index > t.from.index) break;
                if (t2.flags.is_always and t2.from.eql(t.from)) {
                    diagnostics.push(.ambiguous_transition, .@"error", t.from, "PLAN003: duplicate always transition from same state");
                    break;
                }
                j += 1;
            }
            i += 1;
            continue;
        }

        var j = i + 1;
        while (j < graph.transition_count) {
            const t2 = graph.transitions[j];

            if (t2.from.index > t.from.index) break;

            const same_event = if (t.event) |ev_a|
                if (t2.event) |ev_b|
                    ev_a.index == ev_b.index
                else
                    false
            else
                t2.event == null;

            if (!same_event) {
                j += 1;
                continue;
            }

            const both_have_no_guard = t.guard_fn == null and t2.guard_fn == null;

            if (both_have_no_guard) {
                diagnostics.push(.ambiguous_transition, .@"error", t.from, "PLAN003: ambiguous transition: same event, same state, no guards");
                break;
            }

            j += 1;
        }

        i = j;
    }
}
