const std = @import("std");
const plan_ir = @import("../../compiler/plan/ir/plan.zig");
const ctx_mod = @import("context.zig");

const PlanGraph = plan_ir.PlanGraph;
const PlanStateId = plan_ir.PlanStateId;
const PlanEventId = plan_ir.PlanEventId;
const FunctionId = plan_ir.FunctionId;

pub const PlanContext = ctx_mod.PlanContext;
pub const PlanHandle = ctx_mod.PlanHandle;
pub const PLAN_HANDLE_INVALID = ctx_mod.PLAN_HANDLE_INVALID;

pub const GuardFn = *const fn (ctx: *PlanContext) bool;
pub const ActionFn = *const fn (ctx: *PlanContext) void;

pub const PlanFunctionTable = extern struct {
    guards: ?[*]const GuardFn,
    actions: ?[*]const ActionFn,
    guard_count: u32,
    action_count: u32,

    pub const empty = PlanFunctionTable{
        .guards = null,
        .actions = null,
        .guard_count = 0,
        .action_count = 0,
    };

    pub fn getGuard(self: PlanFunctionTable, id: FunctionId) ?GuardFn {
        const idx = id.index;
        if (idx >= self.guard_count) return null;
        if (self.guards) |guards| return guards[idx];
        return null;
    }

    pub fn getAction(self: PlanFunctionTable, id: FunctionId) ?ActionFn {
        const idx = id.index;
        if (idx >= self.action_count) return null;
        if (self.actions) |actions| return actions[idx];
        return null;
    }
};

pub const LifecycleHook = *const fn (ctx: *PlanContext, state: PlanStateId) void;

pub const LifecycleHooks = struct {
    on_enter: ?LifecycleHook,
    on_exit: ?LifecycleHook,
    on_update: ?LifecycleHook,

    pub const empty = LifecycleHooks{
        .on_enter = null,
        .on_exit = null,
        .on_update = null,
    };
};

pub const MachineFlags = packed struct {
    is_running: bool = false,
    is_paused: bool = false,
    has_error: bool = false,
    _: u29 = 0,
};

pub const DispatchResult = enum(u8) {
    transitioned = 0,
    always_transitioned = 1,
    no_transition = 2,
    guard_rejected = 3,
    machine_not_running = 4,
    machine_paused = 5,
};

pub const PlanMachine = struct {
    graph: *const PlanGraph,
    functions: *const PlanFunctionTable,
    ctx: PlanContext,
    lifecycle: LifecycleHooks,
    current_state: PlanStateId,
    previous_state: ?PlanStateId,
    flags: MachineFlags,
    dispatch_count: u64,

    pub fn init(config: MachineConfig) PlanMachine {
        return .{
            .graph = config.graph,
            .functions = config.functions,
            .ctx = config.context orelse PlanContext.empty,
            .lifecycle = config.lifecycle orelse LifecycleHooks.empty,
            .current_state = config.graph.initial_state,
            .previous_state = null,
            .flags = .{ .is_running = true },
            .dispatch_count = 0,
        };
    }

    pub fn sendEvent(self: *PlanMachine, event: PlanEventId) DispatchResult {
        if (!self.flags.is_running) return .machine_not_running;
        if (self.flags.is_paused) return .machine_paused;

        const transition = self.graph.dispatch(self.current_state, event) orelse
            return .no_transition;

        return self.executeTransition(transition);
    }

    pub fn sendEventAlways(self: *PlanMachine) DispatchResult {
        if (!self.flags.is_running) return .machine_not_running;
        if (self.flags.is_paused) return .machine_paused;

        const transition = self.graph.lookupAlways(self.current_state) orelse
            return .no_transition;

        return self.executeTransition(transition);
    }

    pub fn stabilize(self: *PlanMachine) void {
        var guard: u32 = 0;
        while (guard < self.graph.state_count + 1) : (guard += 1) {
            const result = self.sendEventAlways();
            switch (result) {
                .always_transitioned => {},
                else => break,
            }
        }
    }

    pub fn tick(self: *PlanMachine) void {
        self.ctx.frame += 1;
        if (self.lifecycle.on_update) |hook| {
            hook(&self.ctx, self.current_state);
        }
        self.stabilize();
    }

    pub fn currentState(self: *PlanMachine) ?plan_ir.State {
        return self.graph.getState(self.current_state);
    }

    pub fn isRunning(self: *PlanMachine) bool {
        return self.flags.is_running and !self.flags.has_error;
    }

    pub fn pause(self: *PlanMachine) void {
        self.flags.is_paused = true;
    }

    pub fn unpause(self: *PlanMachine) void {
        self.flags.is_paused = false;
    }

    pub fn stop(self: *PlanMachine) void {
        self.flags.is_running = false;
    }

    pub fn restart(self: *PlanMachine) void {
        self.current_state = self.graph.initial_state;
        self.previous_state = null;
        self.flags = .{ .is_running = true };
        self.dispatch_count = 0;
    }

    pub fn migrate(self: *PlanMachine, new_graph: *const PlanGraph) bool {
        const old_name = self.graph.getStateName(self.current_state);

        if (old_name) |name_id| {
            if (new_graph.findStateByName(name_id)) |new_state| {
                self.graph = new_graph;
                self.current_state = new_state;
                self.previous_state = null;
                return true;
            }
        }

        const old_idx = self.graph.getState(self.current_state);
        if (old_idx) |old_state| {
            if (new_graph.getState(old_state.id)) |new_state| {
                self.graph = new_graph;
                self.current_state = new_state.id;
                self.previous_state = null;
                return true;
            }
        }

        self.graph = new_graph;
        self.current_state = new_graph.initial_state;
        self.previous_state = null;
        return false;
    }

    fn executeTransition(self: *PlanMachine, t: *const plan_ir.Transition) DispatchResult {
        if (t.flags.has_guard) {
            if (t.guard_fn) |guard_id| {
                if (self.functions.getGuard(guard_id)) |guard_fn| {
                    if (!guard_fn(&self.ctx)) {
                        return .guard_rejected;
                    }
                }
            }
        }

        const old_state = self.current_state;

        if (self.lifecycle.on_exit) |hook| {
            hook(&self.ctx, old_state);
        }

        if (t.flags.has_action) {
            if (t.action_fn) |action_id| {
                if (self.functions.getAction(action_id)) |action_fn| {
                    action_fn(&self.ctx);
                }
            }
        }

        self.previous_state = old_state;
        self.current_state = t.to;
        self.dispatch_count += 1;

        if (self.lifecycle.on_enter) |hook| {
            hook(&self.ctx, self.current_state);
        }

        if (t.flags.is_always) return .always_transitioned;
        return .transitioned;
    }
};

pub const MachineConfig = struct {
    graph: *const PlanGraph,
    functions: *const PlanFunctionTable,
    context: ?PlanContext,
    lifecycle: ?LifecycleHooks,
};


const MAX_MACHINES = 256;

pub const SlotState = enum(u8) {
    free,
    used,
};

pub const HandleSlot = struct {
    machine: ?*PlanMachine,
    generation: u32,
    state: SlotState,
};

pub const HandleTable = struct {
    slots: [MAX_MACHINES]HandleSlot,
    free_list: [MAX_MACHINES]u32,
    free_top: u32,

    pub fn init() HandleTable {
        var table = HandleTable{
            .slots = undefined,
            .free_list = undefined,
            .free_top = MAX_MACHINES,
        };
        var i: u32 = 0;
        while (i < MAX_MACHINES) : (i += 1) {
            table.slots[i] = .{
                .machine = null,
                .generation = 0,
                .state = .free,
            };
            table.free_list[i] = MAX_MACHINES - 1 - i;
        }
        return table;
    }

    pub fn allocate(self: *HandleTable, m: *PlanMachine) PlanHandle {
        if (self.free_top == 0) return PLAN_HANDLE_INVALID;
        self.free_top -= 1;
        const slot_idx = self.free_list[self.free_top];
        self.slots[slot_idx] = .{
            .machine = m,
            .generation = self.slots[slot_idx].generation + 1,
            .state = .used,
        };
        return @as(PlanHandle, slot_idx) | (@as(PlanHandle, self.slots[slot_idx].generation) << 32);
    }

    pub fn lookup(self: *HandleTable, handle: PlanHandle) ?*PlanMachine {
        const slot_idx: u32 = @intCast(handle & 0xFFFFFFFF);
        const gen: u32 = @intCast(handle >> 32);
        if (slot_idx >= MAX_MACHINES) return null;
        if (self.slots[slot_idx].generation != gen) return null;
        if (self.slots[slot_idx].state != .used) return null;
        return self.slots[slot_idx].machine;
    }

    pub fn release(self: *HandleTable, handle: PlanHandle) void {
        const slot_idx: u32 = @intCast(handle & 0xFFFFFFFF);
        if (slot_idx >= MAX_MACHINES) return;
        self.slots[slot_idx].machine = null;
        self.slots[slot_idx].state = .free;
        self.free_list[self.free_top] = slot_idx;
        self.free_top += 1;
    }
};

var global_handle_table = HandleTable.init();

pub fn registerMachine(m: *PlanMachine) PlanHandle {
    return global_handle_table.allocate(m);
}

pub fn lookupMachine(handle: PlanHandle) ?*PlanMachine {
    return global_handle_table.lookup(handle);
}

pub fn unregisterMachine(handle: PlanHandle) void {
    global_handle_table.release(handle);
}

pub const MachineAllocator = struct {
    allocator: std.mem.Allocator,

    pub fn init() MachineAllocator {
        return .{ .allocator = std.heap.c_allocator };
    }

    pub fn create(self: MachineAllocator) ?*PlanMachine {
        return self.allocator.create(PlanMachine) catch null;
    }

    pub fn destroy(self: MachineAllocator, m: *PlanMachine) void {
        self.allocator.destroy(m);
    }
};
