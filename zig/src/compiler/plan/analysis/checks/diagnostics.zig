const std = @import("std");
const ids = @import("../../../frontend/foundation/ids/ids.zig");

const PlanStateId = ids.PlanStateId;

pub const DiagnosticSeverity = enum {
    @"error",
    warning,
};

pub const DiagnosticKind = enum {
    unknown_state_in_target,
    unknown_event_in_transition,
    invalid_state_id,
    invalid_event_id,
    no_states_defined,
    initial_state_not_defined,
    initial_state_is_terminal,
    unreachable_state,
    self_transition_without_event,
    ambiguous_transition,
    initial_state_dead_end,
    invalid_dispatch_range,
};

pub const PlanDiagnostic = struct {
    kind: DiagnosticKind,
    severity: DiagnosticSeverity,
    state_id: ?PlanStateId,
    message: []const u8,
};

pub const DiagnosticList = struct {
    items: std.ArrayList(PlanDiagnostic),

    pub fn init(allocator: std.mem.Allocator) DiagnosticList {
        return .{ .items = std.ArrayList(PlanDiagnostic).init(allocator) };
    }

    pub fn deinit(self: *DiagnosticList) void {
        self.items.deinit();
    }

    pub fn push(self: *DiagnosticList, kind: DiagnosticKind, severity: DiagnosticSeverity, state_id: ?PlanStateId, msg: []const u8) void {
        self.items.append(.{
            .kind = kind,
            .severity = severity,
            .state_id = state_id,
            .message = msg,
        }) catch {};
    }

    pub fn hasErrors(self: DiagnosticList) bool {
        for (self.items.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn errorCount(self: DiagnosticList) u32 {
        var count: u32 = 0;
        for (self.items.items) |d| {
            if (d.severity == .@"error") count += 1;
        }
        return count;
    }

    pub fn warningCount(self: DiagnosticList) u32 {
        var count: u32 = 0;
        for (self.items.items) |d| {
            if (d.severity == .warning) count += 1;
        }
        return count;
    }
};
