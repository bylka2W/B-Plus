const std = @import("std");
const plan_ir = @import("compiler/plan/ir/plan.zig");
const verifier = @import("compiler/plan/analysis/verifier.zig");
const plan_rt = @import("runtime/plan/plan.zig");
const ids = @import("compiler/frontend/foundation/ids/ids.zig");

const PlanStateId = ids.PlanStateId;
const PlanEventId = ids.PlanEventId;
const PlanMetadata = plan_ir.PlanMetadata;
const SymbolId = ids.SymbolId;
const DefId = ids.DefId;
const PlanFunctionTable = plan_rt.PlanFunctionTable;
const LifecycleHooks = plan_rt.LifecycleHooks;
const PlanContext = plan_rt.PlanContext;

// ──────────────────────────────────────────────
//  Shared counters for lifecycle hook tests
// ──────────────────────────────────────────────

var enter_count: u32 = 0;
var exit_count: u32 = 0;
var last_entered: PlanStateId = PlanStateId.new(0);
var last_exited: PlanStateId = PlanStateId.new(0);

fn testOnEnter(ctx: *PlanContext, state: PlanStateId) void {
    _ = ctx;
    enter_count += 1;
    last_entered = state;
}

fn testOnExit(ctx: *PlanContext, state: PlanStateId) void {
    _ = ctx;
    exit_count += 1;
    last_exited = state;
}

// ──────────────────────────────────────────────
//  Traffic Light graph builder
// ──────────────────────────────────────────────
//  GREEN(0) --timer--> YELLOW(1) --timer--> RED(2) --timer--> GREEN(0)

const TL_GREEN = 0;
const TL_YELLOW = 1;
const TL_RED = 2;
const TL_TIMER = 0;

fn buildTrafficLight(allocator: std.mem.Allocator) !PlanMetadata {
    const states = try allocator.alloc(plan_ir.State, 3);
    states[0] = .{
        .id = PlanStateId.new(TL_GREEN),
        .name = SymbolId.INVALID,
        .def_id = DefId.INVALID,
        .entry_fn = null,
        .exit_fn = null,
        .update_fn = null,
        .flags = .{ .is_initial = true, .has_entry = true },
        .variable_count = 0,
    };
    states[1] = .{
        .id = PlanStateId.new(TL_YELLOW),
        .name = SymbolId.INVALID,
        .def_id = DefId.INVALID,
        .entry_fn = null,
        .exit_fn = null,
        .update_fn = null,
        .flags = .{ .has_entry = true },
        .variable_count = 0,
    };
    states[2] = .{
        .id = PlanStateId.new(TL_RED),
        .name = SymbolId.INVALID,
        .def_id = DefId.INVALID,
        .entry_fn = null,
        .exit_fn = null,
        .update_fn = null,
        .flags = .{ .has_entry = true },
        .variable_count = 0,
    };

    const events = try allocator.alloc(plan_ir.EventDef, 1);
    events[0] = .{
        .id = PlanEventId.new(TL_TIMER),
        .name = SymbolId.INVALID,
        .payload = .none,
    };

    const transitions = try allocator.alloc(plan_ir.Transition, 3);
    transitions[0] = .{
        .id = plan_ir.PlanTransitionId.new(0),
        .from = PlanStateId.new(TL_GREEN),
        .event = PlanEventId.new(TL_TIMER),
        .to = PlanStateId.new(TL_YELLOW),
        .guard_fn = null,
        .action_fn = null,
        .priority = 0,
        .flags = .{},
    };
    transitions[1] = .{
        .id = plan_ir.PlanTransitionId.new(1),
        .from = PlanStateId.new(TL_YELLOW),
        .event = PlanEventId.new(TL_TIMER),
        .to = PlanStateId.new(TL_RED),
        .guard_fn = null,
        .action_fn = null,
        .priority = 0,
        .flags = .{},
    };
    transitions[2] = .{
        .id = plan_ir.PlanTransitionId.new(2),
        .from = PlanStateId.new(TL_RED),
        .event = PlanEventId.new(TL_TIMER),
        .to = PlanStateId.new(TL_GREEN),
        .guard_fn = null,
        .action_fn = null,
        .priority = 0,
        .flags = .{},
    };

    const columns: usize = 2;
    const dispatch_table = try allocator.alloc(plan_ir.TransitionRange, 3 * columns);
    for (dispatch_table) |*d| d.* = .{ .start = plan_ir.INVALID_RANGE_START, .end = plan_ir.INVALID_RANGE_START };
    dispatch_table[0 * columns + 0] = .{ .start = 0, .end = 1 };
    dispatch_table[1 * columns + 0] = .{ .start = 1, .end = 2 };
    dispatch_table[2 * columns + 0] = .{ .start = 2, .end = 3 };

    const state_names = try allocator.alloc(ids.SymbolId, 3);
    for (state_names) |*s| s.* = SymbolId.INVALID;

    const event_names = try allocator.alloc(ids.SymbolId, 1);
    for (event_names) |*e| e.* = SymbolId.INVALID;

    return PlanMetadata{
        .graph = .{
            .states = states,
            .transitions = transitions,
            .events = events,
            .dispatch_table = dispatch_table,
            .initial_state = PlanStateId.new(TL_GREEN),
            .state_count = 3,
            .transition_count = 3,
            .event_count = 1,
        },
        .state_names = state_names,
        .event_names = event_names,
    };
}

fn makeMachine(metadata: *PlanMetadata) plan_rt.PlanMachine {
    return plan_rt.PlanMachine.init(.{
        .graph = &metadata.graph,
        .functions = &PlanFunctionTable.empty,
        .context = PlanContext.empty,
        .lifecycle = LifecycleHooks.empty,
    });
}

const timer = PlanEventId.new(TL_TIMER);

// ──────────────────────────────────────────────
//  TEST 1: Full cycle GREEN→YELLOW→RED→GREEN
// ──────────────────────────────────────────────

test "E2E: traffic light full cycle" {
    const allocator = std.testing.allocator;
    var metadata = try buildTrafficLight(allocator);
    defer metadata.deinit(allocator);

    var vresult = verifier.verifyPlan(allocator, metadata.graph);
    defer vresult.deinit();
    try std.testing.expect(vresult.passed);

    var m = makeMachine(&metadata);
    try std.testing.expect(m.isRunning());
    try std.testing.expect(m.current_state.index == TL_GREEN);

    var r = m.sendEvent(timer);
    try std.testing.expect(r == .transitioned);
    try std.testing.expect(m.current_state.index == TL_YELLOW);

    r = m.sendEvent(timer);
    try std.testing.expect(r == .transitioned);
    try std.testing.expect(m.current_state.index == TL_RED);

    r = m.sendEvent(timer);
    try std.testing.expect(r == .transitioned);
    try std.testing.expect(m.current_state.index == TL_GREEN);

    try std.testing.expect(m.dispatch_count == 3);
}

// ──────────────────────────────────────────────
//  TEST 2: Multiple cycles
// ──────────────────────────────────────────────

test "E2E: traffic light 10 cycles" {
    const allocator = std.testing.allocator;
    var metadata = try buildTrafficLight(allocator);
    defer metadata.deinit(allocator);

    var m = makeMachine(&metadata);

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        _ = m.sendEvent(timer);
        try std.testing.expect(m.current_state.index == TL_YELLOW);
        _ = m.sendEvent(timer);
        try std.testing.expect(m.current_state.index == TL_RED);
        _ = m.sendEvent(timer);
        try std.testing.expect(m.current_state.index == TL_GREEN);
    }

    try std.testing.expect(m.dispatch_count == 30);
}

// ──────────────────────────────────────────────
//  TEST 3: Unknown event → no_transition
// ──────────────────────────────────────────────

test "E2E: unknown event returns no_transition" {
    const allocator = std.testing.allocator;
    var metadata = try buildTrafficLight(allocator);
    defer metadata.deinit(allocator);

    var m = makeMachine(&metadata);
    const unknown = PlanEventId.new(99);
    const r = m.sendEvent(unknown);
    try std.testing.expect(r == .no_transition);
    try std.testing.expect(m.current_state.index == TL_GREEN);
}

// ──────────────────────────────────────────────
//  TEST 4: Lifecycle hooks fire correctly
// ──────────────────────────────────────────────

test "E2E: lifecycle hooks fire on transition" {
    const allocator = std.testing.allocator;
    var metadata = try buildTrafficLight(allocator);
    defer metadata.deinit(allocator);

    enter_count = 0;
    exit_count = 0;

    var m = plan_rt.PlanMachine.init(.{
        .graph = &metadata.graph,
        .functions = &PlanFunctionTable.empty,
        .context = PlanContext.empty,
        .lifecycle = .{
            .on_enter = testOnEnter,
            .on_exit = testOnExit,
            .on_update = null,
        },
    });

    _ = m.sendEvent(timer);
    try std.testing.expect(exit_count == 1);
    try std.testing.expect(enter_count == 1);
    try std.testing.expect(last_exited.index == TL_GREEN);
    try std.testing.expect(last_entered.index == TL_YELLOW);

    _ = m.sendEvent(timer);
    try std.testing.expect(exit_count == 2);
    try std.testing.expect(enter_count == 2);
    try std.testing.expect(last_exited.index == TL_YELLOW);
    try std.testing.expect(last_entered.index == TL_RED);
}

// ──────────────────────────────────────────────
//  TEST 5: Pause / unpause
// ──────────────────────────────────────────────

test "E2E: pause blocks, unpause restores" {
    const allocator = std.testing.allocator;
    var metadata = try buildTrafficLight(allocator);
    defer metadata.deinit(allocator);

    var m = makeMachine(&metadata);
    m.pause();
    try std.testing.expect(m.sendEvent(timer) == .machine_paused);
    try std.testing.expect(m.current_state.index == TL_GREEN);

    m.unpause();
    try std.testing.expect(m.sendEvent(timer) == .transitioned);
    try std.testing.expect(m.current_state.index == TL_YELLOW);
}

// ──────────────────────────────────────────────
//  TEST 6: Restart
// ──────────────────────────────────────────────

test "E2E: restart resets to initial" {
    const allocator = std.testing.allocator;
    var metadata = try buildTrafficLight(allocator);
    defer metadata.deinit(allocator);

    var m = makeMachine(&metadata);
    _ = m.sendEvent(timer);
    _ = m.sendEvent(timer);
    try std.testing.expect(m.current_state.index == TL_RED);

    m.restart();
    try std.testing.expect(m.current_state.index == TL_GREEN);
    try std.testing.expect(m.dispatch_count == 0);
}

// ──────────────────────────────────────────────
//  TEST 7: Guard rejection
// ──────────────────────────────────────────────

fn buildTrafficLightGuarded(allocator: std.mem.Allocator) !PlanMetadata {
    var metadata = try buildTrafficLight(allocator);

    const guarded_transitions = try allocator.alloc(plan_ir.Transition, 3);
    guarded_transitions[0] = .{
        .id = plan_ir.PlanTransitionId.new(0),
        .from = PlanStateId.new(TL_GREEN),
        .event = PlanEventId.new(TL_TIMER),
        .to = PlanStateId.new(TL_YELLOW),
        .guard_fn = plan_ir.FunctionId.new(0),
        .action_fn = null,
        .priority = 0,
        .flags = .{ .has_guard = true },
    };
    guarded_transitions[1] = metadata.graph.transitions[1];
    guarded_transitions[2] = metadata.graph.transitions[2];

    allocator.free(metadata.graph.transitions);
    metadata.graph.transitions = guarded_transitions;

    return metadata;
}

test "E2E: guard rejects transition" {
    const allocator = std.testing.allocator;
    var metadata = try buildTrafficLightGuarded(allocator);
    defer metadata.deinit(allocator);

    const always_false: plan_rt.GuardFn = struct {
        fn f(_: *PlanContext) bool {
            return false;
        }
    }.f;

    const guards_slice = [_]plan_rt.GuardFn{always_false};
    const table = PlanFunctionTable{
        .guards = &guards_slice,
        .actions = null,
        .guard_count = 1,
        .action_count = 0,
    };

    var m = plan_rt.PlanMachine.init(.{
        .graph = &metadata.graph,
        .functions = &table,
        .context = PlanContext.empty,
        .lifecycle = LifecycleHooks.empty,
    });

    const r = m.sendEvent(timer);
    try std.testing.expect(r == .guard_rejected);
    try std.testing.expect(m.current_state.index == TL_GREEN);
}

// ──────────────────────────────────────────────
//  TEST 8: Guard accepts transition
// ──────────────────────────────────────────────

test "E2E: guard accepts transition" {
    const allocator = std.testing.allocator;
    var metadata = try buildTrafficLightGuarded(allocator);
    defer metadata.deinit(allocator);

    const always_true: plan_rt.GuardFn = struct {
        fn f(_: *PlanContext) bool {
            return true;
        }
    }.f;

    const guards_slice = [_]plan_rt.GuardFn{always_true};
    const table = PlanFunctionTable{
        .guards = &guards_slice,
        .actions = null,
        .guard_count = 1,
        .action_count = 0,
    };

    var m = plan_rt.PlanMachine.init(.{
        .graph = &metadata.graph,
        .functions = &table,
        .context = PlanContext.empty,
        .lifecycle = LifecycleHooks.empty,
    });

    const r = m.sendEvent(timer);
    try std.testing.expect(r == .transitioned);
    try std.testing.expect(m.current_state.index == TL_YELLOW);
}

// ──────────────────────────────────────────────
//  TEST 9: Hot reload migrate (same state names)
// ──────────────────────────────────────────────

test "E2E: hot reload preserves current state" {
    const allocator = std.testing.allocator;
    var old_meta = try buildTrafficLight(allocator);
    defer old_meta.deinit(allocator);

    var new_meta = try buildTrafficLight(allocator);
    defer new_meta.deinit(allocator);

    var m = plan_rt.PlanMachine.init(.{
        .graph = &old_meta.graph,
        .functions = &PlanFunctionTable.empty,
        .context = PlanContext.empty,
        .lifecycle = LifecycleHooks.empty,
    });

    _ = m.sendEvent(timer);
    try std.testing.expect(m.current_state.index == TL_YELLOW);

    const ok = m.migrate(&new_meta.graph);
    try std.testing.expect(ok);
    try std.testing.expect(m.current_state.index == TL_YELLOW);
}

// ──────────────────────────────────────────────
//  TEST 10: HandleTable lifecycle
// ──────────────────────────────────────────────

test "E2E: handle table allocate/lookup/release" {
    const allocator = std.testing.allocator;
    var metadata = try buildTrafficLight(allocator);
    defer metadata.deinit(allocator);

    var m = makeMachine(&metadata);
    const handle = plan_rt.registerMachine(&m);
    try std.testing.expect(handle != plan_rt.PLAN_HANDLE_INVALID);

    const found = plan_rt.lookupMachine(handle);
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.current_state.index == TL_GREEN);

    plan_rt.unregisterMachine(handle);
    const gone = plan_rt.lookupMachine(handle);
    try std.testing.expect(gone == null);
}
