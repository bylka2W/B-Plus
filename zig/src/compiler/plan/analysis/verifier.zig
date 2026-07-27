const std = @import("std");
const plan_ir = @import("../ir/plan.zig");

const check_ids = @import("checks/ids.zig");
const check_reachability = @import("checks/reachability.zig");
const check_determinism = @import("checks/determinism.zig");
const check_lifecycle = @import("checks/lifecycle.zig");
const check_dispatch = @import("checks/dispatch.zig");

pub const DiagnosticList = @import("checks/diagnostics.zig").DiagnosticList;

pub const VerifierResult = struct {
    passed: bool,
    diagnostics: DiagnosticList,

    pub fn deinit(self: *VerifierResult) void {
        self.diagnostics.deinit();
    }

    pub fn hasErrors(self: VerifierResult) bool {
        return self.diagnostics.hasErrors();
    }

    pub fn errorCount(self: VerifierResult) u32 {
        return self.diagnostics.errorCount();
    }

    pub fn warningCount(self: VerifierResult) u32 {
        return self.diagnostics.warningCount();
    }
};

pub const Verifier = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Verifier {
        return .{ .allocator = allocator };
    }

    pub fn verify(self: Verifier, graph: plan_ir.PlanGraph) VerifierResult {
        var diagnostics = DiagnosticList.init(self.allocator);

        check_ids.checkIds(graph, &diagnostics);
        check_lifecycle.checkLifecycle(graph, &diagnostics);
        check_dispatch.checkDispatch(graph, &diagnostics);

        if (!diagnostics.hasErrors()) {
            check_reachability.checkReachability(graph, &diagnostics, self.allocator);
            check_determinism.checkDeterminism(graph, &diagnostics);
        }

        return .{
            .passed = !diagnostics.hasErrors(),
            .diagnostics = diagnostics,
        };
    }
};

pub fn verifyPlan(allocator: std.mem.Allocator, graph: plan_ir.PlanGraph) VerifierResult {
    const verifier = Verifier.init(allocator);
    return verifier.verify(graph);
}
