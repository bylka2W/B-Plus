const std = @import("std");
const machine = @import("../machine.zig");
const plan_ir = @import("../../../compiler/plan/ir/plan.zig");
const c_types = @import("types.zig");

const PlanMachine = machine.PlanMachine;
const PlanEventId = plan_ir.PlanEventId;
const PlanContext = machine.PlanContext;
const PlanFunctionTable = machine.PlanFunctionTable;
const PlanHandle = machine.PlanHandle;
const PLAN_HANDLE_INVALID = machine.PLAN_HANDLE_INVALID;
const DispatchResult = machine.DispatchResult;
const MachineAllocator = machine.MachineAllocator;

const alloc = MachineAllocator.init();

// ──────────────────────────────────────────────
//  C ABI exports (stable for UE5 / C++ / DLL)
// ──────────────────────────────────────────────

export fn bplus_plan_create(
    graph: ?*const plan_ir.PlanGraph,
    functions: ?*const PlanFunctionTable,
    user_ctx: ?*anyopaque,
    engine: ?*anyopaque,
) c_types.BPlusPlanHandle {
    const g = graph orelse return PLAN_HANDLE_INVALID;
    const f = functions orelse return PLAN_HANDLE_INVALID;

    const m = alloc.create() orelse return PLAN_HANDLE_INVALID;

    m.* = PlanMachine.init(.{
        .graph = g,
        .functions = f,
        .context = PlanContext{
            .user = user_ctx,
            .engine = engine,
            .allocator = null,
            .frame = 0,
        },
        .lifecycle = machine.LifecycleHooks.empty,
    });

    return machine.registerMachine(m);
}

export fn bplus_plan_destroy(handle: c_types.BPlusPlanHandle) void {
    if (machine.lookupMachine(handle)) |m| {
        machine.unregisterMachine(handle);
        alloc.destroy(m);
    }
}

export fn bplus_plan_send_event(
    handle: c_types.BPlusPlanHandle,
    event_id: u32,
) c_types.BPlusDispatchResult {
    if (machine.lookupMachine(handle)) |m| {
        const result = m.sendEvent(PlanEventId.new(event_id));
        return @intFromEnum(result);
    }
    return c_types.BPLUS_DISPATCH_NOT_RUNNING;
}

export fn bplus_plan_tick(handle: c_types.BPlusPlanHandle) void {
    if (machine.lookupMachine(handle)) |m| {
        m.tick();
    }
}

export fn bplus_plan_state(handle: c_types.BPlusPlanHandle) u32 {
    if (machine.lookupMachine(handle)) |m| {
        return m.current_state.index;
    }
    return 0;
}

export fn bplus_plan_is_running(handle: c_types.BPlusPlanHandle) u8 {
    if (machine.lookupMachine(handle)) |m| {
        return if (m.isRunning()) 1 else 0;
    }
    return 0;
}

export fn bplus_plan_pause(handle: c_types.BPlusPlanHandle) void {
    if (machine.lookupMachine(handle)) |m| {
        m.pause();
    }
}

export fn bplus_plan_unpause(handle: c_types.BPlusPlanHandle) void {
    if (machine.lookupMachine(handle)) |m| {
        m.unpause();
    }
}

export fn bplus_plan_stop(handle: c_types.BPlusPlanHandle) void {
    if (machine.lookupMachine(handle)) |m| {
        m.stop();
    }
}

export fn bplus_plan_restart(handle: c_types.BPlusPlanHandle) void {
    if (machine.lookupMachine(handle)) |m| {
        m.restart();
    }
}

export fn bplus_plan_dispatch_count(handle: c_types.BPlusPlanHandle) u64 {
    if (machine.lookupMachine(handle)) |m| {
        return m.dispatch_count;
    }
    return 0;
}

export fn bplus_plan_migrate(
    handle: c_types.BPlusPlanHandle,
    new_graph: ?*const plan_ir.PlanGraph,
) u8 {
    const g = new_graph orelse return 0;
    if (machine.lookupMachine(handle)) |m| {
        return if (m.migrate(g)) 1 else 0;
    }
    return 0;
}
