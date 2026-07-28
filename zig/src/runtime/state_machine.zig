const std = @import("std");

pub const StateId = u32;
pub const EventId = u32;

pub const Transition = struct {
    from: StateId,
    event: EventId,
    to: StateId,
    guard: ?*const fn () bool = null,
};

pub const StateMachine = struct {
    current_state: StateId,
    transitions: []const Transition,
    entry_fns: []const ?*const fn () void,
    exit_fns: []const ?*const fn () void,
    state_count: u32,

    pub fn init(config: Config) StateMachine {
        return .{
            .current_state = config.initial_state,
            .transitions = config.transitions,
            .entry_fns = config.entry_fns,
            .exit_fns = config.exit_fns,
            .state_count = config.state_count,
        };
    }

    pub fn fire(self: *StateMachine, event: EventId) void {
        for (self.transitions) |*t| {
            if (t.from != self.current_state) continue;
            if (t.event != event) continue;
            if (t.guard) |g| {
                if (!g()) continue;
            }
            self.exitState(t.from);
            self.current_state = t.to;
            self.entryState(t.to);
            return;
        }
    }

    fn entryState(self: *StateMachine, state: StateId) void {
        if (state < self.entry_fns.len) {
            if (self.entry_fns[state]) |f| f();
        }
    }

    fn exitState(self: *StateMachine, state: StateId) void {
        if (state < self.exit_fns.len) {
            if (self.exit_fns[state]) |f| f();
        }
    }

    pub const Config = struct {
        initial_state: StateId = 0,
        transitions: []const Transition = &.{},
        entry_fns: []const ?*const fn () void = &.{},
        exit_fns: []const ?*const fn () void = &.{},
        state_count: u32 = 0,
    };
};

var global_machine: ?StateMachine = null;

pub fn initGlobalMachine(config: StateMachine.Config) void {
    global_machine = StateMachine.init(config);
}

pub fn bpc_fire(event_id: u32) void {
    if (global_machine) |*m| {
        m.fire(event_id);
    }
}

test "StateMachine basic dispatch" {
    var called_entry_b = false;
    const entry_a = struct {
        fn f() void {}
    }.f;
    const entry_b = struct {
        fn f(c: *bool) void {
            c.* = true;
        }
    }.f;
    _ = entry_a;

    const transitions = [_]Transition{
        .{ .from = 0, .event = 0, .to = 1 },
    };
    var entry_fns = [_]?*const fn () void{ null, null };
    entry_fns[1] = @ptrCast(&entry_b);

    var sm = StateMachine.init(.{
        .initial_state = 0,
        .transitions = &transitions,
        .entry_fns = &entry_fns,
        .state_count = 2,
    });

    sm.fire(0);
    try std.testing.expectEqual(@as(StateId, 1), sm.current_state);
}

test "StateMachine guard rejects" {
    const transitions = [_]Transition{
        .{ .from = 0, .event = 0, .to = 1, .guard = struct {
            fn g() bool {
                return false;
            }
        }.g },
    };

    var sm = StateMachine.init(.{
        .initial_state = 0,
        .transitions = &transitions,
        .state_count = 2,
    });

    sm.fire(0);
    try std.testing.expectEqual(@as(StateId, 0), sm.current_state);
}
