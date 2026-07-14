const std = @import("std");
const frame_graph = @import("frame_graph.zig");
const gpu_types = @import("gpu_types.zig");
const resource_system = @import("resource_system.zig");
const lifetime_graph = @import("lifetime_graph.zig");
const barrier_optimizer = @import("barrier_optimizer.zig");
const gpu_execution = @import("gpu_execution.zig");

pub const ResourceAccess = enum(u8) {
    read,
    write,
    read_write,
};

pub const ResourceNode = struct {
    id: u32,
    resource_id: gpu_types.ResourceId,
    passes: []const u32,
    state: gpu_types.ResourceState = .common,
    access: ResourceAccess = .read,
    transient: bool = false,
};

pub const BarrierSlot = barrier_optimizer.BarrierSlot;

pub const RenderPlan = struct {
    nodes: []frame_graph.ExecutionNode,
    edges: []frame_graph.DependencyEdge,
    budget_us: u32,
    gpu_passes: []const frame_graph.GPUPassDesc,
    lifetimes: lifetime_graph.LifetimeGraph,
    auto_barriers: []const BarrierSlot,
    execution_plan: gpu_execution.GpuExecutionPlan,
};

pub const RenderGraph = struct {
    allocator: std.mem.Allocator,
    pool: *resource_system.ResourcePool,

    pub fn init(allocator: std.mem.Allocator, pool: *resource_system.ResourcePool) RenderGraph {
        return .{ .allocator = allocator, .pool = pool };
    }

    pub fn compile(
        self: *RenderGraph,
        frames: []const frame_graph.Pass,
        gpu_passes: []const frame_graph.GPUPassDesc,
        budget_us: u32,
    ) !RenderPlan {
        return self.compileWithMode(frames, gpu_passes, budget_us, .real);
    }

    pub fn compileWithMode(
        self: *RenderGraph,
        frames: []const frame_graph.Pass,
        gpu_passes: []const frame_graph.GPUPassDesc,
        budget_us: u32,
        frame_mode: gpu_execution.FrameMode,
    ) !RenderPlan {
        const fg = frame_graph.FrameGraph.init(frames);
        var plan = try fg.compile(self.allocator, budget_us);
        errdefer frame_graph.FrameGraph.deinitPlan(self.allocator, &plan);

        const lifetimes = try lifetime_graph.LifetimeGraph.build(self.allocator, gpu_passes, self.pool);
        errdefer lifetimes.deinit(self.allocator);

        var opt = barrier_optimizer.BarrierOptimizer.init(self.allocator);
        const barrier_result = try opt.optimize(gpu_passes, &lifetimes);
        errdefer self.allocator.free(barrier_result.barriers);

        const exec_ctx = gpu_execution.ExecutionContext{
            .frame_index = 0,
            .budget_us = budget_us,
            .motion_intensity = 0.0,
            .history_valid = false,
            .frame_mode = frame_mode,
        };
        const execution_plan = try gpu_execution.compileGpuExecutionPlan(
            self.allocator,
            gpu_passes,
            &lifetimes,
            barrier_result.barriers,
            exec_ctx,
        );
        errdefer execution_plan.deinit();

        return RenderPlan{
            .nodes = plan.nodes,
            .edges = plan.edges,
            .budget_us = plan.budget_us,
            .gpu_passes = gpu_passes,
            .lifetimes = lifetimes,
            .auto_barriers = barrier_result.barriers,
            .execution_plan = execution_plan,
        };
    }

    pub fn allocateTransients(self: *RenderGraph, plan: *RenderPlan) !void {
        for (plan.lifetimes.entries) |e| {
            if (!e.transient) continue;
            const handle = self.pool.getResource(e.resource_id) orelse continue;
            if (handle.d3d_resource != null) continue;
            switch (handle.desc) {
                .texture2d => |td| {
                    _ = try self.pool.createTexture2D(td);
                },
                .buffer => |bd| {
                    _ = try self.pool.createBuffer(bd);
                },
                .sampler => {},
            }
        }
    }

    pub fn releaseTransients(self: *RenderGraph, plan: *RenderPlan) void {
        for (plan.lifetimes.entries) |e| {
            if (!e.transient) continue;
            if (self.pool.getResource(e.resource_id)) |handle| {
                if (handle.d3d_resource != null) {
                    _ = self.pool.resources.remove(e.resource_id);
                }
            }
        }
    }

    pub fn deinitPlan(allocator: std.mem.Allocator, plan: *RenderPlan) void {
        frame_graph.FrameGraph.deinitPlan(allocator, &.{
            .nodes = plan.nodes,
            .edges = plan.edges,
            .budget_us = plan.budget_us,
        });
        var lifetimes = plan.lifetimes;
        lifetimes.deinit(allocator);
        allocator.free(plan.auto_barriers);
        plan.execution_plan.deinit();
    }

    /// Build FSR 3.1 resource barrier descriptions for a frame generation pipeline.
    /// Returns barriers for optical flow, confidence, disocclusion, and output resources.
    pub fn buildFSR3Barriers(
        pool: *resource_system.ResourcePool,
        optical_flow: gpu_types.ResourceId,
        confidence: gpu_types.ResourceId,
        disocclusion: gpu_types.ResourceId,
        output: gpu_types.ResourceId,
    ) ![4]gpu_types.BarrierDesc {
        var result: [4]gpu_types.BarrierDesc = undefined;
        var i: u32 = 0;

        const entries = [_]struct { id: gpu_types.ResourceId, target: gpu_types.ResourceState }{
            .{ .id = optical_flow, .target = .unordered_access },
            .{ .id = confidence, .target = .unordered_access },
            .{ .id = disocclusion, .target = .unordered_access },
            .{ .id = output, .target = .unordered_access },
        };

        for (entries) |e| {
            if (e.id != 0) {
                const handle = pool.getResource(e.id) orelse continue;
                result[i] = .{
                    .resource_id = e.id,
                    .state_before = @intFromEnum(handle.current_state),
                    .state_after = @intFromEnum(e.target),
                };
                i += 1;
            }
        }
        return result;
    }
};
