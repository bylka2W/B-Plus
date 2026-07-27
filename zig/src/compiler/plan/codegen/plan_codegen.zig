const std = @import("std");
const plan_ir = @import("../ir/plan.zig");

const PlanGraph = plan_ir.PlanGraph;
const PlanStateId = plan_ir.PlanStateId;
const PlanEventId = plan_ir.PlanEventId;
const PlanMetadata = plan_ir.PlanMetadata;

pub const StateLayout = struct {
    id: u32,
    name_offset: u32,
    data_offset: u32,
    data_size: u32,
    variable_count: u32,
    flags: u32,
    has_entry: bool,
    has_exit: bool,
    has_update: bool,
};

pub const TransitionLayout = struct {
    id: u32,
    from: u32,
    event: ?u32,
    to: u32,
    guard_fn: ?u32,
    action_fn: ?u32,
    priority: u32,
    flags: u32,
};

pub const EventLayout = struct {
    id: u32,
    name_offset: u32,
    payload_type: u32,
};

pub const DispatchEntryLayout = struct {
    start: u32,
    end: u32,
};

pub const PlanBinary = struct {
    states: []const StateLayout,
    transitions: []const TransitionLayout,
    events: []const EventLayout,
    dispatch_table: []const DispatchEntryLayout,
    string_pool: []const u8,
    state_count: u32,
    event_count: u32,
    transition_count: u32,
    dispatch_columns: u32,
    initial_state: u32,

    pub fn deinit(self: *PlanBinary, allocator: std.mem.Allocator) void {
        allocator.free(self.states);
        allocator.free(self.transitions);
        allocator.free(self.events);
        allocator.free(self.dispatch_table);
        allocator.free(self.string_pool);
    }
};

pub const PlanCodegen = struct {
    allocator: std.mem.Allocator,
    metadata: *const PlanMetadata,
    strings: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, metadata: *const PlanMetadata) PlanCodegen {
        return .{
            .allocator = allocator,
            .metadata = metadata,
            .strings = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *PlanCodegen) void {
        self.strings.deinit();
    }

    fn addString(self: *PlanCodegen, s: []const u8) !u32 {
        const offset: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(s);
        try self.strings.append(0);
        return offset;
    }

    pub fn generate(self: *PlanCodegen) !PlanBinary {
        const graph = self.metadata.graph;

        var states = try self.allocator.alloc(StateLayout, graph.state_count);
        for (graph.states, 0..) |s, i| {
            const name_off = if (i < self.metadata.state_names.len)
                try self.addString("state")
            else
                0;

            states[i] = .{
                .id = s.id.index,
                .name_offset = name_off,
                .data_offset = 0,
                .data_size = s.variable_count * 8,
                .variable_count = s.variable_count,
                .flags = @bitCast(s.flags),
                .has_entry = s.entry_fn != null,
                .has_exit = s.exit_fn != null,
                .has_update = s.update_fn != null,
            };
        }

        var transitions = try self.allocator.alloc(TransitionLayout, graph.transition_count);
        for (graph.transitions, 0..) |t, i| {
            transitions[i] = .{
                .id = t.id.index,
                .from = t.from.index,
                .event = if (t.event) |ev| ev.index else null,
                .to = t.to.index,
                .guard_fn = if (t.guard_fn) |f| f.index else null,
                .action_fn = if (t.action_fn) |f| f.index else null,
                .priority = t.priority,
                .flags = @bitCast(t.flags),
            };
        }

        var events = try self.allocator.alloc(EventLayout, graph.event_count);
        for (graph.events, 0..) |e, i| {
            events[i] = .{
                .id = e.id.index,
                .name_offset = try self.addString("event"),
                .payload_type = @intFromEnum(e.payload),
            };
        }

        var dispatch_table = try self.allocator.alloc(DispatchEntryLayout, graph.dispatch_table.len);
        for (graph.dispatch_table, 0..) |d, i| {
            dispatch_table[i] = .{
                .start = d.start,
                .end = d.end,
            };
        }

        const string_pool = try self.strings.toOwnedSlice();

        return PlanBinary{
            .states = states,
            .transitions = transitions,
            .events = events,
            .dispatch_table = dispatch_table,
            .string_pool = string_pool,
            .state_count = graph.state_count,
            .event_count = graph.event_count,
            .transition_count = graph.transition_count,
            .dispatch_columns = graph.dispatchColumns(),
            .initial_state = graph.initial_state.index,
        };
    }
};
