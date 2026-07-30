const std = @import("std");
const ast = @import("../frontend/ast.zig");

const Allocator = std.mem.Allocator;

pub const StateError = error{
    NoInitialState,
    DeadState,
    InfiniteAlwaysLoop,
    UnreachableState,
    StateNotDefined,
    OutOfMemory,
};

pub const StateDiagnostic = struct {
    kind: enum {
        no_initial_state,
        unreachable_state,
        dead_state,
        infinite_always_loop,
        state_not_defined_transition,
    },
    state_name: []const u8,
    message: []const u8,
};

pub const StateChecker = struct {
    allocator: Allocator,
    diagnostics: std.ArrayList(StateDiagnostic),

    pub fn init(allocator: Allocator) StateChecker {
        return .{
            .allocator = allocator,
            .diagnostics = std.ArrayList(StateDiagnostic).init(allocator),
        };
    }

    pub fn deinit(self: *StateChecker) void {
        for (self.diagnostics.items) |*d| {
            self.allocator.free(d.state_name);
            self.allocator.free(d.message);
        }
        self.diagnostics.deinit();
    }

    pub fn checkPlan(self: *StateChecker, program: *const ast.ProgramNode) !void {
        const plan = &program.plan;
        if (plan.states.items.len == 0) return;

        var initial_idx: usize = 0;
        var state_names = std.StringHashMap(usize).init(self.allocator);
        defer state_names.deinit();

        for (plan.states.items, 0..) |state, i| {
            try state_names.put(state.name, i);
        }

        if (plan.initial_state) |initial| {
            initial_idx = state_names.get(initial) orelse {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "initial state '{s}' is not defined in the state machine",
                    .{initial},
                );
                try self.diagnostics.append(.{
                    .kind = .state_not_defined_transition,
                    .state_name = try self.allocator.dupe(u8, initial),
                    .message = msg,
                });
                return;
            };
        }

        const initial_name = if (plan.initial_state) |n| n else plan.states.items[0].name;

        {
            const reachable = try self.computeReachableStates(plan.states.items, state_names, initial_idx);
            defer self.allocator.free(reachable);

            for (plan.states.items, 0..) |state, i| {
                if (!reachable[i]) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "state '{s}' is unreachable from initial state '{s}'",
                        .{ state.name, initial_name },
                    );
                    try self.diagnostics.append(.{
                        .kind = .unreachable_state,
                        .state_name = try self.allocator.dupe(u8, state.name),
                        .message = msg,
                    });
                }
            }
        }

        {
            const reachable = try self.computeReachableStates(plan.states.items, state_names, initial_idx);
            defer self.allocator.free(reachable);

            for (plan.states.items, 0..) |state, i| {
                if (reachable[i] and state.transitions.items.len == 0 and state.enter_body == null and state.exit_body == null) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "state '{s}' is reachable but has no transitions or behaviour",
                        .{state.name},
                    );
                    try self.diagnostics.append(.{
                        .kind = .dead_state,
                        .state_name = try self.allocator.dupe(u8, state.name),
                        .message = msg,
                    });
                }
            }
        }

        {
            for (plan.states.items, 0..) |state, i| {
                if (state.transitions.items.len == 0) continue;

                var has_event_transition = false;
                for (state.transitions.items) |t| {
                    if (!t.is_always) {
                        has_event_transition = true;
                        break;
                    }
                }

                if (!has_event_transition) {
                    var always_targets = std.ArrayList(usize).init(self.allocator);
                    defer always_targets.deinit();

                    for (state.transitions.items) |t| {
                        if (t.is_always) {
                            if (state_names.get(t.target)) |target_idx| {
                                try always_targets.append(target_idx);
                            }
                        }
                    }

                    for (always_targets.items) |target_idx| {
                        const target_state = &plan.states.items[target_idx];
                        var has_target_event = false;
                        for (target_state.transitions.items) |tt| {
                            if (!tt.is_always) {
                                has_target_event = true;
                                break;
                            }
                        }
                        if (!has_target_event) {
                            var has_return_to_self = false;
                            for (target_state.transitions.items) |tt| {
                                if (tt.is_always and std.mem.eql(u8, tt.target, state.name)) {
                                    has_return_to_self = true;
                                    break;
                                }
                            }
                            if (has_return_to_self) {
                                const msg = try std.fmt.allocPrint(self.allocator,
                                    "infinite always-transition loop detected: '{s}' -> '{s}' -> '{s}'. machine can never process events",
                                    .{ state.name, target_state.name, state.name },
                                );
                                try self.diagnostics.append(.{
                                    .kind = .infinite_always_loop,
                                    .state_name = try self.allocator.dupe(u8, state.name),
                                    .message = msg,
                                });
                            }
                        }
                    }
                }

                _ = i;
            }
        }
    }

    fn computeReachableStates(
        self: *StateChecker,
        states: []const ast.StateDefNode,
        name_map: std.StringHashMap(usize),
        start_idx: usize,
    ) ![]bool {
        var reachable = try self.allocator.alloc(bool, states.len);
        for (reachable, 0..) |*r, i| {
            r.* = (i == start_idx);
        }

        var changed = true;
        while (changed) {
            changed = false;
            for (states, 0..) |state, i| {
                if (!reachable[i]) continue;
                for (state.transitions.items) |t| {
                    if (name_map.get(t.target)) |target_idx| {
                        if (!reachable[target_idx]) {
                            reachable[target_idx] = true;
                            changed = true;
                        }
                    }
                }
            }
        }

        return reachable;
    }
};
