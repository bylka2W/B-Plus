const std = @import("std");
const gpu_types = @import("gpu_types.zig");
const frame_graph = @import("frame_graph.zig");
const lifetime_graph = @import("lifetime_graph.zig");
const barrier_optimizer = @import("barrier_optimizer.zig");
const cost_scheduler = @import("cost_scheduler.zig");

/// Frame classification: what kind of frame the GPU should produce.
/// This is the canonical definition; fsr3_runtime re-exports it.
pub const FrameMode = enum(u32) {
    /// Render a real frame (full pipeline).
    real = 0,
    /// Generate an interpolated frame (FSR3 gen only).
    generated = 1,
    /// Skip frame entirely (budget exhausted).
    pass_through = 2,
};

/// Type of GPU dispatch: compute, graphics render pass, or async compute.
pub const DispatchType = enum(u32) {
    compute,
    graphics,
    async_compute,
};

/// A single dispatch unit derived from a GPU pass.
/// Maps one-to-one with GPUPassDesc in the sorted execution order.
pub const DispatchDesc = struct {
    pass_id: u32,
    dispatch_type: DispatchType,
    group_count_x: u32,
    group_count_y: u32,
    group_count_z: u32,
    estimated_cost_us: u32,
    barrier_index: u32,
    num_bindings: u32,
    binding_start: u32,
};

/// Resource binding slot classification for shader register mapping.
pub const ResourceSlotType = enum(u32) {
    texture,
    buffer,
    rw_buffer,
    sampler,
};

/// Describes how a resource is bound to a GPU pass.
/// Captures slot assignment + access mode for future DXIL lowering.
pub const BindingDesc = struct {
    pass_id: u32,
    resource_id: gpu_types.ResourceId,
    slot: u32,
    slot_type: ResourceSlotType,
    stage_flags: u32,
    read_write: bool,
};

/// Per-frame execution context fed into the GPU execution compiler.
/// Bridges FramePolicy decisions and temporal history state.
pub const ExecutionContext = struct {
    frame_index: u32,
    budget_us: u32,
    motion_intensity: f32,
    history_valid: bool,
    /// Scheduling mode: real / generated / pass_through.
    frame_mode: FrameMode = .real,
};

/// Compiled GPU execution plan — a flat, deterministic schedule of dispatches
/// with explicit binding information.
///
/// The plan has no references back to the source FrameGraph; it is a
/// self-contained executable description of what to issue on the GPU.
pub const GpuExecutionPlan = struct {
    allocator: std.mem.Allocator,
    dispatches: []DispatchDesc,
    bindings: []BindingDesc,
    frame_budget_us: u32,

    pub fn deinit(self: *GpuExecutionPlan) void {
        self.allocator.free(self.dispatches);
        self.allocator.free(self.bindings);
    }
};

/// Compile GPU execution plan from passes + lifetimes + barriers + context.
/// Produces a self-contained GpuExecutionPlan with deterministic ordering.
pub fn compileGpuExecutionPlan(
    allocator: std.mem.Allocator,
    gpu_passes: []const frame_graph.GPUPassDesc,
    lifetimes: *const lifetime_graph.LifetimeGraph,
    barriers: []const barrier_optimizer.BarrierSlot,
    ctx: ExecutionContext,
) !GpuExecutionPlan {
    _ = lifetimes;

    // Phase 1: Schedule — filter and prioritize passes by budget + frame mode
    const schedule = try cost_scheduler.scheduleGpuPasses(allocator, gpu_passes, ctx);
    defer allocator.free(schedule.order);

    var dispatches = std.ArrayList(DispatchDesc).init(allocator);
    errdefer dispatches.deinit();

    var bindings = std.ArrayList(BindingDesc).init(allocator);
    errdefer bindings.deinit();

    // Phase 2: Build dispatches only for scheduled (non-skipped) passes
    for (schedule.order) |idx| {
        const gp = &gpu_passes[idx];

        // Map barrier index: find the barrier slot matching this gpu_passes index
        var barrier_idx: u32 = 0;
        for (barriers, 0..) |slot, bi| {
            if (slot.pass_index == idx) {
                barrier_idx = @intCast(bi);
                break;
            }
        }

        const binding_start = @as(u32, @intCast(bindings.items.len));

        for (gp.bindings.entries, 0..) |entry, bi| {
            const slot_type: ResourceSlotType = switch (entry.key.kind) {
                .srv => .texture,
                .uav => .rw_buffer,
                .cbv => .buffer,
                .sampler => .sampler,
            };
            try bindings.append(.{
                .pass_id = gp.pass_id,
                .resource_id = entry.resource_id,
                .slot = @intCast(bi),
                .slot_type = slot_type,
                .stage_flags = 1,
                .read_write = entry.key.kind == .uav,
            });
        }

        const cost = cost_scheduler.PassCost.estimateFromGrid(gp.*);
        try dispatches.append(.{
            .pass_id = gp.pass_id,
            .dispatch_type = switch (gp.queue) {
                .compute => DispatchType.compute,
                .graphics => DispatchType.graphics,
            },
            .group_count_x = gp.grid.x,
            .group_count_y = gp.grid.y,
            .group_count_z = gp.grid.z,
            .estimated_cost_us = cost.gpu_us,
            .barrier_index = barrier_idx,
            .num_bindings = @intCast(bindings.items.len - binding_start),
            .binding_start = binding_start,
        });
    }

    return GpuExecutionPlan{
        .allocator = allocator,
        .dispatches = try dispatches.toOwnedSlice(),
        .bindings = try bindings.toOwnedSlice(),
        .frame_budget_us = ctx.budget_us,
    };
}
