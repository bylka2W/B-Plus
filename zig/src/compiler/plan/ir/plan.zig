const std = @import("std");
const ids = @import("../../frontend/foundation/ids/ids.zig");

pub const SymbolId = ids.SymbolId;
pub const DefId = ids.DefId;
pub const FunctionId = ids.BodyId;
pub const PlanStateId = ids.PlanStateId;
pub const PlanEventId = ids.PlanEventId;
pub const PlanTransitionId = ids.PlanTransitionId;

pub const INVALID_RANGE_START: u32 = 0xFFFF_FFFF;
pub const ALWAYS_EVENT_INDEX: u32 = 0xFFFF_FFFF;

pub const StateFlags = packed struct {
    is_initial: bool = false,
    is_terminal: bool = false,
    has_entry: bool = false,
    has_exit: bool = false,
    has_update: bool = false,
    _: u27 = 0,
};

pub const TransitionFlags = packed struct {
    has_guard: bool = false,
    has_action: bool = false,
    is_always: bool = false,
    _: u29 = 0,
};

pub const EventPayload = enum {
    none,
    int,
    float,
    string,
    ptr,
    custom,
};

pub const State = struct {
    id: PlanStateId,
    name: SymbolId,
    def_id: DefId,
    entry_fn: ?FunctionId,
    exit_fn: ?FunctionId,
    update_fn: ?FunctionId,
    flags: StateFlags,
    variable_count: u32,
};

pub const Transition = struct {
    id: PlanTransitionId,
    from: PlanStateId,
    event: ?PlanEventId,
    to: PlanStateId,
    guard_fn: ?FunctionId,
    action_fn: ?FunctionId,
    priority: u32,
    flags: TransitionFlags,
};

pub const EventDef = struct {
    id: PlanEventId,
    name: SymbolId,
    payload: EventPayload,
};

pub const TransitionRange = struct {
    start: u32,
    end: u32,

    pub fn isEmpty(self: TransitionRange) bool {
        return self.start == INVALID_RANGE_START;
    }
};

pub const PlanGraph = struct {
    states: []const State,
    transitions: []const Transition,
    events: []const EventDef,
    dispatch_table: []const TransitionRange,
    initial_state: PlanStateId,
    state_count: u32,
    transition_count: u32,
    event_count: u32,

    pub fn dispatchColumns(self: PlanGraph) u32 {
        return self.event_count + 1;
    }

    pub fn dispatchIndex(self: PlanGraph, state_idx: u32, event_idx: u32) u32 {
        return state_idx * self.dispatchColumns() + event_idx;
    }

    pub fn lookup(self: PlanGraph, current: PlanStateId, event: PlanEventId) ?*const Transition {
        const state_idx = current.index;
        const event_idx = event.index;
        if (state_idx >= self.state_count) return null;
        if (event_idx >= self.event_count) return null;

        const col = self.dispatchColumns();
        const range = self.dispatch_table[state_idx * col + event_idx];
        if (range.isEmpty()) return null;

        var best: ?*const Transition = null;
        var best_priority: u32 = 0;
        const slice = self.transitions[range.start..range.end];
        for (slice) |*t| {
            if (best == null or t.priority > best_priority) {
                best = t;
                best_priority = t.priority;
            }
        }
        return best;
    }

    pub fn lookupAlways(self: PlanGraph, current: PlanStateId) ?*const Transition {
        const state_idx = current.index;
        if (state_idx >= self.state_count) return null;

        const col = self.dispatchColumns();
        const always_col = self.event_count;
        const range = self.dispatch_table[state_idx * col + always_col];
        if (range.isEmpty()) return null;

        return &self.transitions[range.start];
    }

    pub fn dispatch(self: PlanGraph, current: PlanStateId, event: PlanEventId) ?*const Transition {
        if (self.lookup(current, event)) |t| return t;
        return self.lookupAlways(current);
    }

    pub fn getState(self: PlanGraph, id: PlanStateId) ?State {
        if (id.index < self.state_count) return self.states[id.index];
        return null;
    }

    pub fn getEvent(self: PlanGraph, id: PlanEventId) ?EventDef {
        if (id.index < self.event_count) return self.events[id.index];
        return null;
    }

    pub fn getStateName(self: PlanGraph, id: PlanStateId) ?SymbolId {
        const s = self.getState(id) orelse return null;
        if (s.name.index == SymbolId.INVALID.index) return null;
        return s.name;
    }

    pub fn findStateByName(self: PlanGraph, name: SymbolId) ?PlanStateId {
        for (self.states[0..self.state_count]) |s| {
            if (s.name.index == name.index) return s.id;
        }
        return null;
    }
};

pub const PlanMetadata = struct {
    graph: PlanGraph,
    state_names: []const SymbolId,
    event_names: []const SymbolId,

    pub fn deinit(self: *PlanMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.graph.states);
        allocator.free(self.graph.transitions);
        allocator.free(self.graph.events);
        if (self.graph.dispatch_table.len > 0) allocator.free(self.graph.dispatch_table);
        allocator.free(self.state_names);
        allocator.free(self.event_names);
    }
};
