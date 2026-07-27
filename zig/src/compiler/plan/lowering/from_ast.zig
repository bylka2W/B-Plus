const std = @import("std");
const ast = @import("../../frontend/ast.zig");
const plan_ir = @import("ir/plan.zig");
const ids = @import("../../frontend/foundation/ids/ids.zig");

const SymbolId = ids.SymbolId;
const DefId = ids.DefId;
const PlanStateId = ids.PlanStateId;
const PlanEventId = ids.PlanEventId;

pub const PlanError = error{
    unknown_state,
    no_initial_state,
    out_of_memory,
};

pub const Diagnostic = struct {
    message: []const u8,
    line: u32,
};

pub const PlanLowering = struct {
    allocator: std.mem.Allocator,
    state_names: std.StringHashMap(PlanStateId),
    event_names: std.StringHashMap(PlanEventId),
    states: std.ArrayList(plan_ir.State),
    transitions: std.ArrayList(plan_ir.Transition),
    events: std.ArrayList(plan_ir.EventDef),
    diagnostics: std.ArrayList(Diagnostic),
    next_state_id: u32,
    next_event_id: u32,

    pub fn init(allocator: std.mem.Allocator) PlanLowering {
        return .{
            .allocator = allocator,
            .state_names = std.StringHashMap(PlanStateId).init(allocator),
            .event_names = std.StringHashMap(PlanEventId).init(allocator),
            .states = std.ArrayList(plan_ir.State).init(allocator),
            .transitions = std.ArrayList(plan_ir.Transition).init(allocator),
            .events = std.ArrayList(plan_ir.EventDef).init(allocator),
            .diagnostics = std.ArrayList(Diagnostic).init(allocator),
            .next_state_id = 0,
            .next_event_id = 0,
        };
    }

    pub fn deinit(self: *PlanLowering) void {
        self.state_names.deinit();
        self.event_names.deinit();
        self.states.deinit();
        self.transitions.deinit();
        self.events.deinit();
        self.diagnostics.deinit();
    }

    fn addDiagnostic(self: *PlanLowering, msg: []const u8) void {
        self.diagnostics.append(.{ .message = msg, .line = 0 }) catch {};
    }

    fn getOrAddState(self: *PlanLowering, name: []const u8) !PlanStateId {
        if (self.state_names.get(name)) |id| return id;

        const id = PlanStateId.new(self.next_state_id);
        self.next_state_id += 1;

        try self.state_names.put(name, id);
        try self.states.append(.{
            .id = id,
            .name = SymbolId.INVALID,
            .def_id = DefId.INVALID,
            .entry_fn = null,
            .exit_fn = null,
            .update_fn = null,
            .flags = .{
                .is_initial = (id.index == 0),
            },
            .variable_count = 0,
        });

        return id;
    }

    fn resolveState(self: *PlanLowering, name: []const u8) ?PlanStateId {
        return self.state_names.get(name);
    }

    fn getOrAddEvent(self: *PlanLowering, name: []const u8) !PlanEventId {
        if (self.event_names.get(name)) |id| return id;

        const id = PlanEventId.new(self.next_event_id);
        self.next_event_id += 1;

        try self.event_names.put(name, id);
        try self.events.append(.{
            .id = id,
            .name = SymbolId.INVALID,
            .payload = .none,
        });

        return id;
    }

    pub fn lower(self: *PlanLowering, program: *const ast.ProgramNode) !plan_ir.PlanMetadata {
        for (program.plan.states.items) |*state_def| {
            _ = try self.getOrAddState(state_def.name);
        }

        for (program.plan.states.items) |*state_def| {
            const from_id = self.getOrAddState(state_def.name) catch unreachable;

            for (state_def.transitions.items) |*trans| {
                const to_id = self.resolveState(trans.target) orelse {
                    self.addDiagnostic("PLAN001: unknown state in transition target");
                    return PlanError.unknown_state;
                };

                const event_id: ?PlanEventId = if (trans.event_name) |ev_name|
                    try self.getOrAddEvent(ev_name)
                else
                    null;

                try self.transitions.append(.{
                    .id = PlanTransitionId.new(@intCast(self.transitions.items.len)),
                    .from = from_id,
                    .event = event_id,
                    .to = to_id,
                    .guard_fn = null,
                    .action_fn = null,
                    .priority = 0,
                    .flags = .{
                        .is_always = trans.is_always,
                    },
                });
            }
        }

        if (self.states.items.len == 0) {
            return PlanError.no_initial_state;
        }

        const initial_state = PlanStateId.new(0);

        var state_names = try self.allocator.alloc(SymbolId, self.states.items.len);
        for (self.states.items, 0..) |s, i| {
            state_names[i] = s.name;
        }

        var event_names = try self.allocator.alloc(SymbolId, self.events.items.len);
        for (self.events.items, 0..) |e, i| {
            event_names[i] = e.name;
        }

        const state_count: u32 = @intCast(self.states.items.len);
        const event_count: u32 = @intCast(self.events.items.len);

        var sorted = try self.allocator.alloc(plan_ir.Transition, self.transitions.items.len);
        defer self.allocator.free(sorted);
        @memcpy(sorted, self.transitions.items);

        std.mem.sort(plan_ir.Transition, sorted, {}, struct {
            fn lessThan(_: void, a: plan_ir.Transition, b: plan_ir.Transition) bool {
                if (a.from.index != b.from.index) return a.from.index < b.from.index;
                const a_always: u32 = if (a.flags.is_always) 1 else 0;
                const b_always: u32 = if (b.flags.is_always) 1 else 0;
                if (a_always != b_always) return a_always < b_always;
                const a_ev = if (a.event) |e| e.index else std.math.maxInt(u32);
                const b_ev = if (b.event) |e| e.index else std.math.maxInt(u32);
                if (a_ev != b_ev) return a_ev < b_ev;
                return a.priority > b.priority;
            }
        }.lessThan);

        for (sorted, 0..) |*t, i| {
            t.id = PlanTransitionId.new(@intCast(i));
        }

        var dispatch_table: []const plan_ir.TransitionRange = &.{};
        {
            const columns: usize = @as(usize, event_count) + 1;
            const dispatch_size: usize = @as(usize, state_count) * columns;
            var dt = try self.allocator.alloc(plan_ir.TransitionRange, dispatch_size);
            for (dt) |*d| d.* = .{ .start = plan_ir.INVALID_RANGE_START, .end = plan_ir.INVALID_RANGE_START };

            const always_col = @as(usize, event_count);

            for (sorted, 0..) |t, i| {
                const si = t.from.index;
                if (si >= state_count) continue;

                if (t.flags.is_always) {
                    const idx = @as(usize, si) * columns + always_col;
                    const r = &dt[idx];
                    if (r.isEmpty()) {
                        r.start = @intCast(i);
                        r.end = @intCast(i + 1);
                    } else {
                        r.end = @intCast(i + 1);
                    }
                } else if (t.event) |ev| {
                    const ei = ev.index;
                    if (ei < event_count) {
                        const idx = @as(usize, si) * columns + @as(usize, ei);
                        const r = &dt[idx];
                        if (r.isEmpty()) {
                            r.start = @intCast(i);
                            r.end = @intCast(i + 1);
                        } else {
                            r.end = @intCast(i + 1);
                        }
                    }
                }
            }
            dispatch_table = dt;
        }

        const owned_transitions = try self.allocator.dupe(plan_ir.Transition, sorted);

        return plan_ir.PlanMetadata{
            .graph = .{
                .states = try self.states.toOwnedSlice(),
                .transitions = owned_transitions,
                .events = try self.events.toOwnedSlice(),
                .dispatch_table = dispatch_table,
                .initial_state = initial_state,
                .state_count = state_count,
                .transition_count = @intCast(self.transitions.items.len),
                .event_count = event_count,
            },
            .state_names = state_names,
            .event_names = event_names,
        };
    }
};

pub fn lowerPlan(allocator: std.mem.Allocator, program: *const ast.ProgramNode) !plan_ir.PlanMetadata {
    var lowering = PlanLowering.init(allocator);
    defer lowering.deinit();
    return try lowering.lower(program);
}
